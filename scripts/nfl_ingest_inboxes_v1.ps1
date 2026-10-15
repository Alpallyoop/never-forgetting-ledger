<#
  nfl_ingest_inboxes_v1.ps1 -- idempotent inbox ingest (config/inbox_registry.json, nfl.inbox_registry.v1).

  Every item is attributed before anything is committed (proposal 0001):
    source "local"                -> NFL's own operator inbox
    integration "<c>><p>"         -> must be a registered integration (.constellation/SERVICE_MAP.md)
    payload/nfl.ingest.json       -> the envelope's producer; producer>nfl must be registered with nfl.ingest.v1
  Items that belong to nothing are not committed: they are counted and listed as NFL_INGEST_UNATTRIBUTED.

  mode packet  : CPR verifies the packet (nfl_witness_cpr_verify_v1.ps1). Then
                   with payload/nfl.ingest.json -> validate nfl.ingest.v1, commit commit_hash as
                     "nfl.ingest.v1:<producer>:<packet_id>" (packet_id = the CPR-verified id; the envelope's
                     own packet_id is recorded as declared_packet_id), issue nfl.receipt.v1
                   without an envelope          -> commit the packet_id as "packet:<source>:<inbox>"
  mode file    : commit the SHA-256 of every file as "file:<inbox>:<relative/path>"
  mode receipt : witness every constellation.integration.receipt.v1 line of every *.ndjson file
  Finally the receipts NFL wrote as a consumer (nfl>cpr, nfl>neverlost) are witnessed.

  NFL never creates a directory outside its own repository: a missing foreign inbox is "unavailable".
  Without the CPR verifier, packet items stay pending ("unavailable") and are retried next run.
  Telemetry: proofs/receipts/nfl_ingest_state.ndjson (dedup + per-item result), nfl_ingest_runs.ndjson,
  runtime/ingest/last_run.json.
#>
param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$CprRoot = "",
  [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")
. (Join-Path $PSScriptRoot "_nfl_paths_v1.ps1")

function Fail([string]$m){ throw ("NFL_INGEST_FAIL:" + $m) }

function Append-JsonLine([string]$Path,$Obj){
  [System.IO.File]::AppendAllText($Path, ((ConvertTo-NflCanonicalJson $Obj) + "`n"), (Get-NflUtf8))
}

function Rotate-IfLarge([string]$Path,[long]$MaxBytes){
  # Telemetry only (never the dedup/state file): archive once over MaxBytes; history is kept.
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return }
  if((Get-Item -LiteralPath $Path).Length -le $MaxBytes){ return }
  $archDir = Join-NflPath (Split-Path -Parent $Path) "archive"
  if(-not (Test-Path -LiteralPath $archDir -PathType Container)){ New-Item -ItemType Directory -Force -Path $archDir | Out-Null }
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $ext = [System.IO.Path]::GetExtension($Path)
  Move-Item -LiteralPath $Path -Destination (Join-NflPath $archDir ($base + "_" + $stamp + $ext)) -Force
}

function Load-SeenKeys([string]$StatePath){
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach($line in @(Read-NflLedgerLines $StatePath)){
    try {
      $o = ConvertFrom-NflJson $line
      $k = Get-NflProp $o 'process_key'
      $final = Get-NflProp $o 'final'
      # results marked final=$false (e.g. CPR unavailable) are retried
      if(($null -ne $k) -and ($final -ne $false)){
        [void]$set.Add([string]$k)
        $pk = Get-NflProp $o 'path_key'
        if($null -ne $pk){ [void]$set.Add([string]$pk) }
      }
    } catch { continue }
  }
  return ,$set
}

function Test-UnderRoot([string]$Path,[string]$Root){
  $p = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]'\',[char]'/')
  $r = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]'\',[char]'/')
  $cmp = if([System.IO.Path]::DirectorySeparatorChar -eq [char]'\'){ [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
  return ($p.Equals($r,$cmp) -or $p.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar,$cmp))
}

function Get-RelPath([string]$Path,[string]$Base){
  $p = [System.IO.Path]::GetFullPath($Path); $b = [System.IO.Path]::GetFullPath($Base).TrimEnd([char]'\',[char]'/')
  return ($p.Substring($b.Length).TrimStart([char]'\',[char]'/') -replace '\\','/')
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if([string]::IsNullOrWhiteSpace($ConfigPath)){ $ConfigPath = Join-NflPath $RepoRoot "config" "inbox_registry.json" }
$WitnessPath = Join-NflPath $PSScriptRoot "nfl_witness_cpr_verify_v1.ps1"
$CprRootResolved = Resolve-NflCprRoot $RepoRoot $CprRoot
$CprVerifier = if($null -ne $CprRootResolved){ Join-NflPath $CprRootResolved "scripts" "verify_packet_v1.ps1" } else { $null }

$ReceiptDir = Join-NflPath $RepoRoot "proofs" "receipts"
$StatePath = Join-NflPath $ReceiptDir "nfl_ingest_state.ndjson"
$RunPath = Join-NflPath $ReceiptDir "nfl_ingest_runs.ndjson"
if(-not (Test-Path -LiteralPath $ReceiptDir -PathType Container)){ New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null }

if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)){ Fail "INBOX_REGISTRY_MISSING" }
if(-not (Test-Path -LiteralPath $WitnessPath -PathType Leaf)){ Fail "WITNESS_WRAPPER_MISSING" }
$config = ConvertFrom-NflJson ([System.IO.File]::ReadAllText($ConfigPath,(Get-NflUtf8)))
if([string](Get-NflProp $config 'schema') -ne "nfl.inbox_registry.v1"){ Fail "BAD_REGISTRY_SCHEMA" }
if($null -eq (Get-NflProp $config 'inboxes')){ Fail "INBOXES_MISSING" }

$Integrations = Get-NflRegisteredIntegrations $RepoRoot
$Seen = Load-SeenKeys $StatePath

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$C = [ordered]@{ scanned=0; processed=0; skipped=0; failed=0; unattributed=0; pending=0 }
$InboxReport = New-Object System.Collections.Generic.List[object]
$Unattributed = New-Object System.Collections.Generic.List[string]

function Write-State([string]$Key,[string]$Inbox,[string]$Mode,[string]$Item,[string]$Result,[bool]$Ok,[bool]$Final,[hashtable]$More){
  $row = [ordered]@{ schema="nfl.ingest.state.v1"; utc=(Get-NflUtc); process_key=$Key; inbox_name=$Inbox; mode=$Mode; item_path=$Item; result=$Result; ok=$Ok; final=$Final }
  if($null -ne $More){ foreach($k in $More.Keys){ $row[$k] = $More[$k] } }
  Append-JsonLine $StatePath $row
  if($Final){ [void]$Seen.Add($Key); if(($null -ne $More) -and $More.ContainsKey('path_key')){ [void]$Seen.Add([string]$More['path_key']) } }
}

$names = @{}
foreach($inbox in @($config.inboxes)){
  $name = [string](Get-NflProp $inbox 'name'); $path = [string](Get-NflProp $inbox 'path'); $mode = [string](Get-NflProp $inbox 'mode')
  $source = [string](Get-NflProp $inbox 'source'); $integ = [string](Get-NflProp $inbox 'integration')
  if($name -notmatch '^[a-z0-9][a-z0-9-]*$'){ Fail ("BAD_INBOX_NAME:" + $name) }
  if($names.ContainsKey($name)){ Fail ("DUPLICATE_INBOX:" + $name) }; $names[$name] = $true
  if([string]::IsNullOrWhiteSpace($path)){ Fail ("INBOX_PATH_MISSING:" + $name) }
  if(@("packet","file","receipt") -notcontains $mode){ Fail ("BAD_MODE:" + $name + ":" + $mode) }

  $full = if([System.IO.Path]::IsPathRooted($path)){ [System.IO.Path]::GetFullPath($path) } else { [System.IO.Path]::GetFullPath((Join-NflPath $RepoRoot $path)) }
  $isLocal = Test-UnderRoot $full $RepoRoot

  # attribution of the inbox itself
  $attrib = $null; $attribErr = $null; $nflConsumer = $false
  if($source -eq "local"){ $attrib = "local" }
  elseif(-not [string]::IsNullOrWhiteSpace($integ)){
    $pair = $integ.Split('>')
    if($null -eq $Integrations){ $attribErr = "REGISTRY_UNAVAILABLE" }
    elseif($null -eq (Find-NflRegisteredIntegration $Integrations $pair[0] $pair[1])){ $attribErr = "INTEGRATION_NOT_REGISTERED" }
    else { $attrib = $integ; $nflConsumer = ($pair[0] -eq "nfl") }
  } else { $attribErr = "NO_SOURCE_OR_INTEGRATION" }

  if(-not (Test-Path -LiteralPath $full -PathType Container)){
    if($isLocal){ New-Item -ItemType Directory -Force -Path $full | Out-Null }
    else { $InboxReport.Add([ordered]@{ name=$name; mode=$mode; state="unavailable"; attribution=$attrib }); continue }
  }
  $inboxState = if($null -ne $attribErr){ "unattributed:" + $attribErr } else { "ok" }
  $InboxReport.Add([ordered]@{ name=$name; mode=$mode; state=$inboxState; attribution=$attrib })

  if($mode -eq "packet"){
    foreach($dir in @(Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue | Sort-Object Name)){
      $C.scanned++
      $pidFile = Join-NflPath $dir.FullName "packet_id.txt"
      # The packet id is only taken when packet_id.txt equals SHA-256(manifest.json) - recomputed here, not
      # trusted from the file or the folder name (CPR checks the same law).
      $packetId = $null
      $manPath = Join-NflPath $dir.FullName "manifest.json"
      $manBytes = $null
      if((Test-Path -LiteralPath $pidFile -PathType Leaf) -and (Test-Path -LiteralPath $manPath -PathType Leaf)){
        $t = ([System.IO.File]::ReadAllText($pidFile)).Trim().ToLowerInvariant()
        $manBytes = [System.IO.File]::ReadAllBytes($manPath)
        if((Test-NflHex64 $t) -and ($t -eq (Get-NflSha256Hex $manBytes))){ $packetId = $t }
      }
      $rel = Get-RelPath $dir.FullName $full
      # Dedup: a packet id is only trusted once CPR has verified it (success keys on the id); anything
      # that fails or cannot be attributed keys on its path, so a bad copy can never shadow a good one.
      $keyPath = "packet|" + $name + "|path:" + $rel
      $keyId = if($packetId){ "packet|" + $name + "|" + $packetId } else { $null }
      if($Seen.Contains($keyPath)){ $C.skipped++; continue }
      $idAlreadyWitnessed = (($null -ne $keyId) -and $Seen.Contains($keyId))
      $key = $keyPath

      $envPath = Join-NflPath $dir.FullName "payload" "nfl.ingest.json"
      $hasEnv = Test-Path -LiteralPath $envPath -PathType Leaf
      if($null -ne $attribErr){
        # Not final when the registry copy is only temporarily missing: retried on the next run.
        $C.unattributed++; $Unattributed.Add(($name + "/" + $rel))
        Write-State $key $name "packet" $rel "NFL_INGEST_UNATTRIBUTED" $false ($attribErr -ne "REGISTRY_UNAVAILABLE") @{ reason=$attribErr }
        continue
      }
      if($null -eq $CprVerifier){
        $C.pending++
        Write-State $key $name "packet" $rel "CPR_UNAVAILABLE" $false $false $null
        if($nflConsumer){ [void](Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider $integ.Split('>')[1] -Outcome "deferred" -ErrorToken "CPR_UNAVAILABLE") }
        continue
      }
      $w = Invoke-NflScript $WitnessPath @("-RepoRoot",$RepoRoot,"-CprVerifierPath",$CprVerifier,"-PacketDir",$dir.FullName) $RepoRoot
      $cprOk = (($w.ExitCode -eq 0) -and ($w.StdOut -match 'NFL_WITNESS_CPR_VERIFY_OK'))
      if($nflConsumer){
        $man = Join-NflPath $dir.FullName "manifest.json"
        [void](Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider $integ.Split('>')[1] -ResponseSha256 $(if(Test-Path -LiteralPath $man -PathType Leaf){ Get-NflSha256File $man } else { $null }) -Outcome $(if($cprOk){ "ok" } else { "refused" }) -ErrorToken "CPR_VERIFY_NOT_GREEN")
      }
      if(-not $cprOk){
        $C.failed++
        Write-State $key $name "packet" $rel "CPR_VERIFY_NOT_GREEN" $false $true @{ exit_code=$w.ExitCode; stdout=$w.StdOut; stderr=$w.StdErr }
        continue
      }

      if($idAlreadyWitnessed){
        # Same verified packet id seen before under another path: CPR passed, so it is a byte-identical copy.
        $C.skipped++
        Write-State $keyPath $name "packet" $rel "DUPLICATE_PACKET" $true $true @{ packet_id=$packetId }
        continue
      }

      if($hasEnv){
        $envObj = $null; $err = $null
        if($null -eq $packetId){ $err = "PACKET_ID_UNREADABLE" }
        $envBytes = [System.IO.File]::ReadAllBytes($envPath)
        $envText = (Get-NflUtf8).GetString($envBytes)
        if(($null -eq $err) -and -not $envText.TrimStart().StartsWith("{")){ $err = "INGEST_ENVELOPE_NOT_OBJECT" }
        if($null -eq $err){ try { $envObj = ConvertFrom-NflJson $envText } catch { $err = "INGEST_ENVELOPE_BAD_JSON" } }
        if($null -eq $err){ $err = Test-NflIngestEnvelope $envObj }
        if($null -eq $err){
          # Bind the envelope bytes read now to the verified manifest: its entry for payload/nfl.ingest.json
          # must carry this SHA-256 (closes the gap between CPR's check and this read).
          $envSha = Get-NflSha256Hex $envBytes
          $manText = (Get-NflUtf8).GetString($manBytes)
          $bound = $false
          try {
            $stack = New-Object System.Collections.Generic.Stack[object]; $stack.Push((ConvertFrom-NflJson $manText))
            while($stack.Count -gt 0){
              $n = $stack.Pop()
              if($n -is [System.Management.Automation.PSCustomObject]){
                if(([string](Get-NflProp $n 'path') -replace '\\','/') -eq "payload/nfl.ingest.json" -and [string](Get-NflProp $n 'sha256') -eq $envSha){ $bound = $true }
                foreach($pp in $n.PSObject.Properties){ if($null -ne $pp.Value){ $stack.Push($pp.Value) } }
              } elseif(($n -is [System.Array])){ foreach($x in $n){ if($null -ne $x){ $stack.Push($x) } } }
            }
          } catch { $bound = $false }
          if(-not $bound){ $err = "INGEST_ENVELOPE_NOT_BOUND_TO_MANIFEST" }
        }
        # Under Packet Constitution v1 Option A the packet id is SHA-256 of manifest.json, and the manifest
        # covers payload/nfl.ingest.json, so the envelope cannot carry the real packet id. NFL keys on the
        # CPR-verified id and records the producer's declared packet_id beside it (never as proof).
        if($null -ne $err){
          $C.failed++
          Write-State $key $name "packet" $rel $err $false $true $null
          continue
        }
        $reg = Find-NflRegisteredIntegration $Integrations $envObj.producer "nfl"
        $why = $null
        if($null -eq $Integrations){ $why = "REGISTRY_UNAVAILABLE" }
        elseif(($null -eq $reg) -or ((@($reg.contracts).Count -gt 0) -and (@($reg.contracts) -notcontains "nfl.ingest.v1"))){ $why = "PRODUCER_NOT_REGISTERED_FOR_NFL_INGEST:" + $envObj.producer }
        elseif(($attrib -ne "local") -and ($attrib -ne ($envObj.producer + ">nfl"))){ $why = "PRODUCER_NOT_INBOX_OWNER:" + $envObj.producer }
        if($null -ne $why){
          $C.unattributed++; $Unattributed.Add(($name + "/" + $rel))
          Write-State $key $name "packet" $rel "NFL_INGEST_UNATTRIBUTED" $false ($why -ne "REGISTRY_UNAVAILABLE") @{ reason=$why }
          continue
        }
        $commit = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $envObj.commit_hash -Artifact (Get-NflIngestLabel $envObj.producer $packetId) -IdempotentOnHashArtifact
        $rc = Add-NflIngestReceipt -RepoRoot $RepoRoot -Envelope $envObj -Commit $commit -PacketId $packetId
        $C.processed++
        Write-State $keyId $name "packet" $rel "NFL_INGEST_ENVELOPE_WITNESSED" $true $true @{ path_key=$keyPath; packet_id=$packetId; declared_packet_id=$envObj.packet_id; commit_hash=$envObj.commit_hash; producer=$envObj.producer; ledger_seq=$commit.Seq; receipt_id=$rc.Receipt.receipt_id }
        continue
      }

      if($null -eq $packetId){
        $C.failed++
        Write-State $key $name "packet" $rel "PACKET_ID_UNREADABLE" $false $true $null
        continue
      }
      $commit = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $packetId -Artifact ("packet:" + $attrib + ":" + $name) -IdempotentOnHashArtifact
      $C.processed++
      Write-State $keyId $name "packet" $rel "NFL_INGEST_PACKET_WITNESSED" $true $true @{ path_key=$keyPath; packet_id=$packetId; ledger_seq=$commit.Seq }
    }
  }

  if($mode -eq "file"){
    foreach($file in @(Get-ChildItem -LiteralPath $full -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)){
      $C.scanned++
      $hash = Get-NflSha256File $file.FullName
      $key = "file|" + $name + "|" + $hash
      if($Seen.Contains($key)){ $C.skipped++; continue }
      $rel = Get-RelPath $file.FullName $full
      if($null -ne $attribErr){
        $C.unattributed++; $Unattributed.Add(($name + "/" + $rel))
        Write-State $key $name "file" $rel "NFL_INGEST_UNATTRIBUTED" $false $true @{ sha256=$hash; reason=$attribErr }
        continue
      }
      $label = "file:" + $name + ":" + $rel
      if($label.Length -gt 1024){ $label = $label.Substring(0,1024) }
      $commit = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $hash -Artifact $label -IdempotentOnHashArtifact
      $C.processed++
      Write-State $key $name "file" $rel "COMMIT_OK" $true $true @{ sha256=$hash; ledger_seq=$commit.Seq }
    }
  }

  if($mode -eq "receipt"){
    foreach($file in @(Get-ChildItem -LiteralPath $full -File -Filter "*.ndjson" -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)){
      $C.scanned++
      $hash = Get-NflSha256File $file.FullName
      $key = "receipt|" + $name + "|" + $hash
      if($Seen.Contains($key)){ $C.skipped++; continue }
      $rel = Get-RelPath $file.FullName $full
      $text = (Get-NflUtf8).GetString([System.IO.File]::ReadAllBytes($file.FullName))
      $lines = @($text.Split("`n") | Where-Object { $_.Length -gt 0 })
      $wit = 0; $ref = 0; $errs = New-Object System.Collections.Generic.List[string]
      foreach($ln in $lines){
        $w = Invoke-NflWitnessReceiptLine $RepoRoot $ln $Integrations
        if($w.Status -eq "REFUSED"){ $ref++; $errs.Add($w.Error) } else { $wit++ }
      }
      if($ref -gt 0 -and $wit -eq 0){ $C.failed++ } else { $C.processed++ }
      if($ref -gt 0){ $C.unattributed += @($errs | Where-Object { $_ -eq "RECEIPT_UNATTRIBUTED" }).Count; if(@($errs | Where-Object { $_ -eq "RECEIPT_UNATTRIBUTED" }).Count -gt 0){ $Unattributed.Add(($name + "/" + $rel)) } }
      $final = -not (@($errs | Where-Object { $_ -eq "RECEIPT_REGISTRY_UNAVAILABLE" }).Count -gt 0)
      Write-State $key $name "receipt" $rel $(if($ref -eq 0){ "NFL_RECEIPT_WITNESS_OK" } else { "NFL_RECEIPT_REFUSED" }) ($ref -eq 0) $final @{ sha256=$hash; witnessed=$wit; refused=$ref; errors=@($errs | Select-Object -Unique) }
    }
  }
}

# Witness the receipts NFL wrote as a consumer during this run (and any earlier unwitnessed ones).
$own = Sync-NflOwnIntegrationReceipts $RepoRoot

Rotate-IfLarge $RunPath (5MB)
$ok = ($C.failed -eq 0)
Append-JsonLine $RunPath ([ordered]@{
  schema="nfl.ingest.run.receipt.v1"; utc=(Get-NflUtc); run_id=$RunId; ok=$ok
  scanned=$C.scanned; processed=$C.processed; skipped=$C.skipped; failed=$C.failed; unattributed=$C.unattributed; pending=$C.pending
  own_receipts_witnessed=$own.Witnessed; inboxes=$InboxReport.ToArray()
})

$RuntimeDir = Join-NflPath $RepoRoot "runtime" "ingest"
if(-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)){ New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null }
$lastRun = [ordered]@{
  schema="nfl.ingest.last_run.v1"; run_id=$RunId; utc=(Get-NflUtc)
  scanned=$C.scanned; processed=$C.processed; skipped=$C.skipped; failed=$C.failed; unattributed=$C.unattributed; pending=$C.pending; ok=$ok
  cpr=$(if($null -ne $CprVerifier){ "present" } else { "unavailable" }); registry=$(if($null -ne $Integrations){ "present" } else { "unavailable" })
  inboxes=$InboxReport.ToArray()
}
[System.IO.File]::WriteAllText((Join-NflPath $RuntimeDir "last_run.json"), ((ConvertTo-NflCanonicalJson $lastRun) + "`n"), (Get-NflUtf8))

Write-Output "NFL_INGEST_INBOXES_OK"
Write-Output ("RUN_ID=" + $RunId)
Write-Output ("SCANNED=" + $C.scanned)
Write-Output ("PROCESSED=" + $C.processed)
Write-Output ("SKIPPED=" + $C.skipped)
Write-Output ("FAILED=" + $C.failed)
Write-Output ("UNATTRIBUTED=" + $C.unattributed)
Write-Output ("PENDING=" + $C.pending)
Write-Output ("OWN_RECEIPTS_WITNESSED=" + $own.Witnessed)
foreach($i in $InboxReport){ Write-Output ("INBOX " + $i.name + " " + $i.state) }
foreach($u in $Unattributed){ Write-Output ("NFL_INGEST_UNATTRIBUTED " + $u) }
