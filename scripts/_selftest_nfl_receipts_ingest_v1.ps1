<#
  _selftest_nfl_receipts_ingest_v1.ps1

  Positive and negative proof for:
    - the shared ledger writer (validation, self-chain across writers)
    - integration-receipt witnessing (proposal 0001 / Constellation proposal 0013)
    - NFL's own consumer-side receipts (nfl>cpr, nfl>neverlost) and their witnessing
    - inbox ingest: attribution, nfl.ingest.v1 envelopes -> nfl.receipt.v1, CPR failures, idempotency,
      never writing outside the NFL repository
  Works in a temp folder under proofs/_tmp only (the real ledger is never touched). Uses the real CPR
  verifier, copied into the temp folder so CPR's own receipts do not land in the CPR repository.
  On non-Windows hosts CPR's verifier needs a two-line System.Uri portability fix (reported to CPR);
  it is applied to the temp copy only and announced as CPR_PORTABILITY_SHIM_APPLIED.
#>
param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = "",
  [Parameter(Mandatory=$false)][string]$CprRoot = "",
  [switch]$Keep
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")
. (Join-Path $PSScriptRoot "_nfl_paths_v1.ps1")

function Fail([string]$m){ throw ("NFL_RECEIPTS_INGEST_SELFTEST_FAIL:" + $m) }
$RepoRoot = Resolve-NflRepoRoot $RepoRoot
$Cli = Join-NflPath $PSScriptRoot "nfl_cli_v1.ps1"
$Ingest = Join-NflPath $PSScriptRoot "nfl_ingest_inboxes_v1.ps1"
$MapSrc = Join-NflPath $RepoRoot ".constellation" "SERVICE_MAP.md"
if(-not (Test-Path -LiteralPath $MapSrc -PathType Leaf)){ Fail "SERVICE_MAP_COPY_MISSING" }

$results = New-Object System.Collections.Generic.List[object]
function Assert([string]$Case,[bool]$Cond,[string]$Detail){
  $results.Add([pscustomobject]@{ case=$Case; ok=$Cond }) | Out-Null
  if($Cond){ Write-Output ("PASS  " + $Case + "  " + $Detail) } else { Write-Output ("FAIL  " + $Case + "  " + $Detail) }
}
function Invoke-TestCli([string]$root,[string[]]$a){ return (Invoke-NflScript $Cli (@($a) + @("-RepoRoot",$root)) $root) }
function LedgerCount([string]$root){ return @(Read-NflLedgerLines (Get-NflLedgerPath $root)).Count }
function NewRoot([string]$n,[bool]$withMap){
  $r = Join-NflPath $TmpRoot $n
  New-Item -ItemType Directory -Force -Path $r | Out-Null
  if($withMap){ New-Item -ItemType Directory -Force -Path (Join-NflPath $r ".constellation") | Out-Null; Copy-Item -LiteralPath $MapSrc -Destination (Join-NflPath $r ".constellation" "SERVICE_MAP.md") }
  return (Resolve-Path -LiteralPath $r).Path
}
function WriteText([string]$p,[string]$t){ $d = Split-Path -Parent $p; if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Force -Path $d | Out-Null }; [System.IO.File]::WriteAllBytes($p,(Get-NflUtf8).GetBytes($t)) }

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$TmpRoot = Join-NflPath $RepoRoot "proofs" "_tmp" ("receipts_ingest_selftest_" + $RunId)
New-Item -ItemType Directory -Force -Path $TmpRoot | Out-Null

$Z = "0" * 64
$good = New-NflIntegrationReceiptLine -Consumer "runledger" -Provider "nfl" -Contract "nfl.ingest.v1" -RequestSha256 ("a" * 64) -Outcome "ok" -PrevSha256 $Z
$failRcpt = New-NflIntegrationReceiptLine -Consumer "runledger" -Provider "nfl" -Contract "nfl.ingest.v1" -RequestSha256 ("a" * 64) -Outcome "unavailable" -ErrorToken "NFL_UNREACHABLE" -PrevSha256 (Get-NflSha256HexOfString $good)
$unattr = New-NflIntegrationReceiptLine -Consumer "apv" -Provider "nfl" -Outcome "ok" -PrevSha256 $Z

# ---------------- ledger writer ----------------
$r = NewRoot "writer" $true
$x = Invoke-TestCli $r @("commit","-Hash","not-hex!","-Artifact","x")
Assert "C1_BAD_HASH_REFUSED" (($x.ExitCode -ne 0) -and (($x.StdOut + $x.StdErr) -match 'NFL_CLI_FAIL:BAD_HASH') -and ((LedgerCount $r) -eq 0)) ("exit=" + $x.ExitCode)
$x = Invoke-TestCli $r @("commit","-Hash",("b" * 64),"-Artifact","line1`nline2")
Assert "C2_CONTROL_CHAR_REFUSED" (($x.ExitCode -ne 0) -and ((LedgerCount $r) -eq 0)) ("exit=" + $x.ExitCode)
[void](Add-NflLedgerRecord -RepoRoot $r -Hash ("1" * 64) -Artifact "api-style" -Extra ([ordered]@{ schema="nfl.ledger.commit.v2"; source_repo="demo" }))
$x = Invoke-TestCli $r @("commit","-Hash",("2" * 64),"-Artifact","cli-style <&>'")
$v = Invoke-TestCli $r @("verify-chain")
Assert "C3_ONE_CHAIN_ACROSS_WRITERS" (($x.ExitCode -eq 0) -and ($v.ExitCode -eq 0) -and ($v.StdOut -match 'CHAINED_COUNT=2')) ("verify=" + ($v.StdOut -replace '\s+',' '))

# ---------------- integration receipts ----------------
$r = NewRoot "receipts" $true
$rf = Join-NflPath $r "emitter" "receipts.ndjson"
WriteText $rf ($good + "`n")
$x = Invoke-TestCli $r @("witness-receipt","-ReceiptFile",$rf)
Assert "R1_WITNESS_OK" (($x.ExitCode -eq 0) -and ($x.StdOut -match '(?m)^WITNESSED') -and ($x.StdOut -match 'NFL_RECEIPT_WITNESS_OK')) ("exit=" + $x.ExitCode)
$x = Invoke-TestCli $r @("verify-receipt","-ReceiptFile",$rf)
Assert "R2_VERIFY_OK" (($x.StdOut -match '(?m)^VERIFIED') -and ($x.StdOut -match 'NOT_FOUND_COUNT=0')) ""
$altered = $good.Replace('"outcome":"ok"','"outcome":"failed"')
$x = Invoke-TestCli $r @("verify-receipt","-ReceiptLine",$altered)
Assert "R3_ALTERED_LINE_NOT_FOUND" ($x.StdOut -match '(?m)^NOT_FOUND') ""
$before = LedgerCount $r
$x = Invoke-TestCli $r @("witness-receipt","-ReceiptLine",$unattr)
Assert "R4_UNATTRIBUTED_REFUSED" (($x.ExitCode -ne 0) -and ($x.StdOut -match 'RECEIPT_ERROR=RECEIPT_UNATTRIBUTED') -and ((LedgerCount $r) -eq $before)) ""
$x = Invoke-TestCli $r @("witness-receipt","-ReceiptFile",$rf)
Assert "R5_IDEMPOTENT" (($x.ExitCode -eq 0) -and ($x.StdOut -match '(?m)^ALREADY_WITNESSED') -and ((LedgerCount $r) -eq $before)) ""
$x = Invoke-TestCli $r @("witness-receipt","-ReceiptLine",($good.Replace('","','", "')))
Assert "R6_NONCANONICAL_REFUSED" (($x.ExitCode -ne 0) -and ($x.StdOut -match 'RECEIPT_ERROR=RECEIPT_NOT_CANONICAL')) ""
$x = Invoke-TestCli $r @("witness-receipt","-ReceiptLine",($good.Replace('"error_token":null','"error_token":"SHOULD_NOT_BE_HERE"')))
Assert "R7_TOKEN_ON_OK_REFUSED" (($x.ExitCode -ne 0) -and ($x.StdOut -match 'RECEIPT_ERROR=RECEIPT_ERROR_TOKEN_ON_OK')) ""
$x = Invoke-TestCli $r @("witness-receipt","-ReceiptLine",$failRcpt)
Assert "R8_FAILED_EXCHANGE_RECEIPT_WITNESSED" (($x.ExitCode -eq 0) -and ($x.StdOut -match '(?m)^WITNESSED')) ""
$r2 = NewRoot "no_registry" $false
$x = Invoke-TestCli $r2 @("witness-receipt","-ReceiptLine",$good)
Assert "R9_REGISTRY_UNAVAILABLE_REFUSED" (($x.ExitCode -ne 0) -and ($x.StdOut -match 'RECEIPT_REGISTRY_UNAVAILABLE') -and ((LedgerCount $r2) -eq 0)) ""
$shaBefore = Get-NflSha256File $rf
$x = Invoke-NflScript $Cli @("witness-receipt","-ReceiptFile",$rf,"-RepoRoot",(Join-NflPath $TmpRoot "no_such_nfl")) $TmpRoot
Assert "R10_NFL_ABSENT_EMITTER_UNTOUCHED" (($x.ExitCode -ne 0) -and ((Get-NflSha256File $rf) -eq $shaBefore)) ""

$evil = @(
  @("R13_ARRAY_SCHEMA", $good.Replace('"schema":"constellation.integration.receipt.v1"','"schema":["constellation.integration.receipt.v1"]')),
  @("R14_ARRAY_OUTCOME", $good.Replace('"outcome":"ok"','"outcome":["ok"]')),
  @("R15_ARRAY_EMITTED_BY", $good.Replace('"emitted_by":"consumer"','"emitted_by":["consumer"]')),
  @("R16_TRAILING_NEWLINE_IN_HASH", $good.Replace(('"request_sha256":"' + ("a" * 64) + '"'),('"request_sha256":"' + ("a" * 64) + '\n"')))
)
foreach($e in $evil){
  $before = LedgerCount $r
  $x = Invoke-TestCli $r @("witness-receipt","-ReceiptLine",$e[1])
  Assert $e[0] (($x.ExitCode -ne 0) -and ($x.StdOut -match '(?m)^REFUSED') -and ((LedgerCount $r) -eq $before)) (($x.StdOut -split "`n" | Where-Object { $_ -match 'RECEIPT_ERROR' }) -join "")
}

# NFL's own consumer-side receipts
$a1 = Write-NflOwnIntegrationReceipt -RepoRoot $r -Provider "cpr" -Contract "cpr.packet.manifest.v1" -RequestSha256 ("c" * 64) -ResponseSha256 ("d" * 64) -Outcome "ok"
$a2 = Write-NflOwnIntegrationReceipt -RepoRoot $r -Provider "cpr" -Contract "cpr.packet.manifest.v1" -RequestSha256 ("c" * 64) -Outcome "unavailable" -ErrorToken "CPR_VERIFIER_MISSING"
$lines = @(Read-NflLedgerLines $a1.Path)
$chainOk = ($lines.Count -eq 2) -and ((ConvertFrom-NflJson $lines[1]).prev_sha256 -eq (Get-NflSha256HexOfString $lines[0])) -and ((ConvertFrom-NflJson $lines[0]).prev_sha256 -eq $Z)
$s1 = Sync-NflOwnIntegrationReceipts $r
$s2 = Sync-NflOwnIntegrationReceipts $r
Assert "R11_OWN_RECEIPTS_CHAINED_AND_WITNESSED" ($a1.Ok -and $a2.Ok -and $chainOk -and ($s1.Witnessed -eq 2) -and ($s2.Witnessed -eq 0) -and ($s2.Already -eq 2)) ("sync1=" + $s1.Witnessed + " sync2=" + $s2.Already)
# torn last line must not swallow the next receipt
[System.IO.File]::AppendAllText($a1.Path,'{"torn":')
$a3 = Write-NflOwnIntegrationReceipt -RepoRoot $r -Provider "cpr" -Contract "cpr.packet.manifest.v1" -Outcome "ok"
$tl = @(Read-NflLedgerLines $a1.Path)
Assert "R17_TORN_LINE_ISOLATED" ($a3.Ok -and ($tl[$tl.Count-1] -match '^\{"schema":"constellation.integration.receipt.v1"') -and ($tl[$tl.Count-2] -eq '{"torn":')) ""
# a foreign file in the own-receipt folder is never witnessed
$rf2 = NewRoot "foreign_own" $true
$foreignOwn = Join-NflPath $rf2 "proofs" "receipts" "integration" "nfl__zzz.ndjson"
WriteText $foreignOwn ((New-NflIntegrationReceiptLine -Consumer "evil" -Provider "anything" -Outcome "ok" -PrevSha256 $Z) + "`n")
$sx = Sync-NflOwnIntegrationReceipts $rf2
Assert "R18_FOREIGN_OWN_RECEIPT_REFUSED" (((LedgerCount $rf2) -eq 0) -and ($sx.Invalid -ge 1)) ""
WriteText $a1.Path ($lines[0] + "`n" + $lines[1] + "`n")
$bad = $lines[0].Replace('"outcome":"ok"','"outcome":"failed"')
WriteText $a1.Path ($bad + "`n" + $lines[1] + "`n")
$s3 = Sync-NflOwnIntegrationReceipts $r
Assert "R12_TAMPERED_OWN_RECEIPT_DETECTED" ($s3.Invalid -ge 1) ("invalid=" + $s3.Invalid)

# ---------------- ingest ----------------
if([string]::IsNullOrWhiteSpace($CprRoot)){ $CprRoot = Resolve-NflCprRoot $RepoRoot "" }
if($null -eq $CprRoot -or -not (Test-Path -LiteralPath (Join-NflPath $CprRoot "scripts" "verify_packet_v1.ps1") -PathType Leaf)){
  Fail "CPR_NOT_FOUND (set NFL_CPR_ROOT or pass -CprRoot)"
}
$ir = NewRoot "ingest" $true
$cprCopy = Join-NflPath $ir "_cpr"
New-Item -ItemType Directory -Force -Path (Join-NflPath $cprCopy "scripts") | Out-Null
foreach($f in @("verify_packet_v1.ps1","_lib_cpr_v1.ps1")){ Copy-Item -LiteralPath (Join-NflPath $CprRoot "scripts" $f) -Destination (Join-NflPath $cprCopy "scripts" $f) }
if([System.IO.Path]::DirectorySeparatorChar -ne [char]'\'){
  $lp = Join-NflPath $cprCopy "scripts" "_lib_cpr_v1.ps1"
  $t = [System.IO.File]::ReadAllText($lp)
  $t = $t.Replace("`$BaseUri = [System.Uri](`$BaseFull.TrimEnd('\') + '\')","`$BaseUri = New-Object System.Uri((`$BaseFull.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar), [System.UriKind]::Absolute)")
  $t = $t.Replace("`$TargetUri = [System.Uri]`$TargetFull","`$TargetUri = New-Object System.Uri(`$TargetFull, [System.UriKind]::Absolute)")
  [System.IO.File]::WriteAllText($lp,$t)
  Write-Output "NOTE  CPR_PORTABILITY_SHIM_APPLIED (temp copy only; System.Uri on non-Windows)"
}

function New-Packet([string]$OutRoot,[hashtable]$Files){
  # Packet Constitution v1 Option A: packet_id = SHA-256(manifest.json bytes); sha256sums covers every file.
  $tmp = Join-NflPath $OutRoot ("_build_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path (Join-NflPath $tmp "payload") | Out-Null
  $entries = New-Object System.Collections.Generic.List[object]
  foreach($n in ($Files.Keys | Sort-Object)){
    $p = Join-NflPath $tmp "payload" $n
    WriteText $p $Files[$n]
    $entries.Add([ordered]@{ path = ("payload/" + $n); bytes = [int](Get-Item -LiteralPath $p).Length; sha256 = (Get-NflSha256File $p) })
  }
  $man = ConvertTo-NflCanonicalJson ([ordered]@{ schema = "packet_manifest.v1"; files = $entries.ToArray() })
  WriteText (Join-NflPath $tmp "manifest.json") $man
  $packetId = Get-NflSha256HexOfString $man
  WriteText (Join-NflPath $tmp "packet_id.txt") ($packetId + "`n")
  $sums = New-Object System.Collections.Generic.List[string]
  foreach($f in @(Get-ChildItem -LiteralPath $tmp -File -Recurse)){
    $rel = $f.FullName.Substring($tmp.Length).TrimStart([char]'\',[char]'/') -replace '\\','/'
    $sums.Add(((Get-NflSha256File $f.FullName) + "  " + $rel))
  }
  WriteText (Join-NflPath $tmp "sha256sums.txt") ((($sums | Sort-Object) -join "`n") + "`n")
  $final = Join-NflPath $OutRoot $packetId
  Move-Item -LiteralPath $tmp -Destination $final
  return $packetId
}
function Envelope([string]$producer,[string]$commit){
  return (ConvertTo-NflCanonicalJson ([ordered]@{ schema="nfl.ingest.v1"; packet_id=("1" * 64); commit_hash=$commit; producer=$producer; producer_instance="inst-1"; tenant="single-tenant"; principal=("single-tenant/local/" + $producer); event_type="run.closed.v1"; event_time_utc="2026-10-15T12:00:00Z"; prev_links=@(); payload_mode="pointer_only"; payload_ref="commit_hash:x"; producer_key_id="k1"; producer_sig_ref="signatures/ingest.sig" }))
}
$inbox = Join-NflPath $ir "packets" "inbox"
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$commitHash = "c" * 64
$pEnv = New-Packet $inbox @{ "nfl.ingest.json" = (Envelope "runledger" $commitHash) }
$pPlain = New-Packet $inbox @{ "a.txt" = "hello`n" }
$pApv = New-Packet $inbox @{ "nfl.ingest.json" = (Envelope "apv" ("d" * 64)) }
$pBadEnv = New-Packet $inbox @{ "nfl.ingest.json" = '{"schema":"nfl.ingest.v1","packet_id":"x"}' }
# packet whose manifest does not list the envelope (CPR still passes: sha256sums covers every file)
$ubTmp = Join-NflPath $inbox "_ub"
New-Item -ItemType Directory -Force -Path (Join-NflPath $ubTmp "payload") | Out-Null
WriteText (Join-NflPath $ubTmp "payload" "nfl.ingest.json") (Envelope "runledger" ("e" * 64))
$ubMan = '{"schema":"packet_manifest.v1","note":"lists nothing"}'
WriteText (Join-NflPath $ubTmp "manifest.json") $ubMan
$pUnbound = Get-NflSha256HexOfString $ubMan
WriteText (Join-NflPath $ubTmp "packet_id.txt") ($pUnbound + "`n")
$ubSums = @(Get-ChildItem -LiteralPath $ubTmp -File -Recurse | ForEach-Object { (Get-NflSha256File $_.FullName) + "  " + ($_.FullName.Substring($ubTmp.Length).TrimStart([char]'\',[char]'/') -replace '\\','/') } | Sort-Object)
WriteText (Join-NflPath $ubTmp "sha256sums.txt") (($ubSums -join "`n") + "`n")
Move-Item -LiteralPath $ubTmp -Destination (Join-NflPath $inbox $pUnbound)
# envelope for runledger dropped in watchtower's outbox
$wtBox = Join-NflPath $ir "wt_outbox"
New-Item -ItemType Directory -Force -Path $wtBox | Out-Null
$pWrongOwner = New-Packet $wtBox @{ "nfl.ingest.json" = (Envelope "runledger" ("f" * 64)) }
$tamperDir = Join-NflPath $inbox "zz-tampered-copy"
Copy-Item -LiteralPath (Join-NflPath $inbox $pPlain) -Destination $tamperDir -Recurse
[System.IO.File]::AppendAllText((Join-NflPath $tamperDir "payload" "a.txt"),"tampered`n")
WriteText (Join-NflPath $ir "inbox" "raw" "sub" "f.txt") "raw file`n"
WriteText (Join-NflPath $ir "inbox" "receipts" "b.ndjson") ($good + "`n" + $unattr + "`n")
New-Item -ItemType Directory -Force -Path (Join-NflPath $ir "unreg" "pkt") | Out-Null
$foreign = Join-NflPath $TmpRoot "foreign_repo_absent"
$cfg = Join-NflPath $ir "inbox_registry.json"
WriteText $cfg (ConvertTo-NflCanonicalJson ([ordered]@{ schema="nfl.inbox_registry.v1"; inboxes=@(
  [ordered]@{ name="nfl-packets-inbox"; path="packets/inbox"; mode="packet"; source="local" },
  [ordered]@{ name="nfl-raw-files"; path="inbox/raw"; mode="file"; source="local" },
  [ordered]@{ name="nfl-integration-receipts"; path="inbox/receipts"; mode="receipt"; source="local" },
  [ordered]@{ name="foreign-absent"; path="../foreign_repo_absent/outbox"; mode="packet"; integration="watchtower>nfl" },
  [ordered]@{ name="unregistered"; path="unreg"; mode="packet"; integration="apv>nfl" },
  [ordered]@{ name="watchtower-outbox"; path="wt_outbox"; mode="packet"; integration="watchtower>nfl" }
) }))

$x = Invoke-NflScript $Ingest @("-RepoRoot",$ir,"-CprRoot",$cprCopy,"-ConfigPath",$cfg) $ir
$out = $x.StdOut
Assert "I0_INGEST_RUNS" (($x.ExitCode -eq 0) -and ($out -match 'NFL_INGEST_INBOXES_OK')) (($out + $x.StdErr) -replace '\s+',' ')
$state = @(Read-NflLedgerLines (Join-NflPath $ir "proofs" "receipts" "nfl_ingest_state.ndjson") | ForEach-Object { ConvertFrom-NflJson $_ })
function StateOf([string]$item){ return @($state | Where-Object { $_.item_path -eq $item }) }
$envRec = @(Find-NflLedgerRecords $ir $commitHash | Where-Object { (Get-NflProp $_.Record 'artifact') -eq (Get-NflIngestLabel "runledger" $pEnv) })
$rc = Test-NflReceiptChain $ir
$rcLines = @(Read-NflLedgerLines (Join-NflPath $ir "proofs" "receipts" "nfl.receipt.v1.ndjson"))
Assert "I1_ENVELOPE_WITNESSED_WITH_RECEIPT" (($envRec.Count -eq 1) -and $rc.Ok -and ($rc.Count -eq 1) -and ($rcLines[0] -match $pEnv) -and ($rcLines[0] -match '"declared_packet_id"')) ("receipt_chain=" + $rc.Ok)
Assert "I2_PLAIN_PACKET_WITNESSED" (@(Find-NflLedgerRecords $ir $pPlain).Count -eq 1) ""
Assert "I3_UNREGISTERED_PRODUCER_NOT_COMMITTED" ((@(Find-NflLedgerRecords $ir ("d" * 64)).Count -eq 0) -and (@(StateOf $pApv)[0].result -eq "NFL_INGEST_UNATTRIBUTED")) ""
Assert "I4_BAD_ENVELOPE_FAILED" ((@(StateOf $pBadEnv)[0].result -like "INGEST_ENVELOPE_*") -and (@(StateOf $pBadEnv)[0].ok -eq $false)) ([string](@(StateOf $pBadEnv)[0].result))
Assert "I5_TAMPERED_COPY_FAILS_CPR" ((@(StateOf "zz-tampered-copy")[0].result -eq "CPR_VERIFY_NOT_GREEN")) ""
Assert "I6_FILE_INBOX_COMMITTED" (@(Find-NflLedgerRecords $ir (Get-NflSha256File (Join-NflPath $ir "inbox" "raw" "sub" "f.txt")) | Where-Object { (Get-NflProp $_.Record 'artifact') -eq "file:nfl-raw-files:sub/f.txt" }).Count -eq 1) ""
Assert "I7_RECEIPT_INBOX_ATTRIBUTION" ((@(Find-NflLedgerRecords $ir (Get-NflSha256HexOfString $good)).Count -eq 1) -and (@(Find-NflLedgerRecords $ir (Get-NflSha256HexOfString $unattr)).Count -eq 0) -and ($out -match 'NFL_INGEST_UNATTRIBUTED nfl-integration-receipts/b.ndjson')) ""
Assert "I8_FOREIGN_INBOX_UNAVAILABLE_NOT_CREATED" (($out -match 'INBOX foreign-absent unavailable') -and -not (Test-Path -LiteralPath $foreign)) ""
Assert "I9_UNREGISTERED_INBOX_UNATTRIBUTED" (($out -match 'INBOX unregistered unattributed:INTEGRATION_NOT_REGISTERED') -and ($out -match 'NFL_INGEST_UNATTRIBUTED unregistered/pkt')) ""
Assert "I14_ENVELOPE_NOT_BOUND_TO_MANIFEST_REFUSED" ((@(StateOf $pUnbound)[0].result -eq "INGEST_ENVELOPE_NOT_BOUND_TO_MANIFEST") -and (@(Find-NflLedgerRecords $ir ("e" * 64)).Count -eq 0)) ([string](@(StateOf $pUnbound)[0].result))
Assert "I15_PRODUCER_NOT_INBOX_OWNER_REFUSED" ((@(StateOf $pWrongOwner)[0].reason -like "PRODUCER_NOT_INBOX_OWNER*") -and (@(Find-NflLedgerRecords $ir ("f" * 64)).Count -eq 0)) ([string](@(StateOf $pWrongOwner)[0].reason))
$own = @(Read-NflLedgerLines (Join-NflPath $ir "proofs" "receipts" "integration" "nfl__cpr.ndjson"))
$ownWitnessed = @($own | Where-Object { @(Find-NflLedgerRecords $ir (Get-NflSha256HexOfString $_)).Count -eq 1 }).Count
Assert "I10_NFL_CPR_RECEIPTS_WRITTEN_AND_WITNESSED" (($own.Count -ge 4) -and ($ownWitnessed -eq $own.Count) -and (@($own | Where-Object { $_ -match '"outcome":"failed"' }).Count -ge 1)) ("own=" + $own.Count)
$countBefore = LedgerCount $ir
$x2 = Invoke-NflScript $Ingest @("-RepoRoot",$ir,"-CprRoot",$cprCopy,"-ConfigPath",$cfg) $ir
Assert "I11_SECOND_RUN_IDEMPOTENT" (($x2.ExitCode -eq 0) -and ($x2.StdOut -match 'PROCESSED=0') -and ((LedgerCount $ir) -eq $countBefore)) ""
$pLate = New-Packet $inbox @{ "late.txt" = "arrived while CPR was missing`n" }
$env:NFL_CPR_ROOT_SAVED = $env:NFL_CPR_ROOT; $env:NFL_CPR_ROOT = (Join-NflPath $TmpRoot "no_cpr")
try { $x3 = Invoke-NflScript $Ingest @("-RepoRoot",$ir,"-CprRoot",(Join-NflPath $TmpRoot "no_cpr"),"-ConfigPath",$cfg) $ir } finally { $env:NFL_CPR_ROOT = $env:NFL_CPR_ROOT_SAVED }
$x4 = Invoke-NflScript $Ingest @("-RepoRoot",$ir,"-CprRoot",$cprCopy,"-ConfigPath",$cfg) $ir
Assert "I12_CPR_MISSING_PENDING_THEN_RETRIED" (($x3.StdOut -match 'PENDING=1') -and ($x4.StdOut -match 'PROCESSED=1') -and (@(Find-NflLedgerRecords $ir $pLate).Count -eq 1)) (($x3.StdOut -split "`n" | Where-Object { $_ -match 'PENDING=' }) -join "")
$v = Invoke-TestCli $ir @("verify-chain")
Assert "I13_LEDGER_CHAIN_OK" ($v.ExitCode -eq 0) ($v.StdOut -replace '\s+',' ')

$passed = @($results | Where-Object { $_.ok }).Count
$total = $results.Count
if(-not $Keep){ Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ("RESULT=" + $passed + "/" + $total)
if($passed -ne $total){ Fail ("CASES_FAILED:" + ($total - $passed)) }
Write-Output "NFL_RECEIPTS_INGEST_SELFTEST_OK"
