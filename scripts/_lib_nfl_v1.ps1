# _lib_nfl_v1.ps1 -- NFL shared core (dot-source). One implementation of the ledger for every surface
# (CLI, HTTP API, ingest, chain verify, checkpoint). Host-independent: identical bytes and hashes on
# Windows PowerShell 5.1 and PowerShell 7 (Windows or Linux). No machine paths, no network.
#
# Ledger record (data/ledger.ndjson, append-only, one JSON object per LF-terminated line):
#   core  : hash, artifact, timestamp           (the record hash covers only these, see Get-NflRecordHash)
#   extra : optional string fields (schema, source_repo, ...) written by the API / ingest
#   chain : seq (0-based line index), prev (link hash of the previous line, "GENESIS" for line 0; see
#           Get-NflLinkHash: a link covers the record's core and its own prev, so the head commits to all of it)
# Canonical core bytes (nfl.ledger.core.canon.v1):
#   {"hash":<str>,"artifact":<str|null>,"timestamp":<str>}  -- compact, keys in that order,
#   strings escaped per RFC 8259 minimal escaping (\" \\ \b \f \n \r \t, other < 0x20 as \u00xx).
#   This is byte-identical to ConvertTo-Json -Compress for every record the ledger has held so far.

Set-StrictMode -Version Latest

$script:NflGenesis = "GENESIS"
$script:NflReceiptSchema = "constellation.integration.receipt.v1"
$script:NflZero64 = ("0" * 64)

function Get-NflUtf8 { return (New-Object System.Text.UTF8Encoding($false)) }

function Get-NflUtc { return [DateTime]::UtcNow.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'",[Globalization.CultureInfo]::InvariantCulture) }

# ---- paths ------------------------------------------------------------------------------------
function Join-NflPath([string]$Base){
  # Join-NflPath $root "data" "ledger.ndjson"  or  Join-NflPath $root "data\ledger.ndjson"
  $p = $Base
  foreach($part in $args){
    foreach($seg in ([string]$part -split '[\\/]')){
      if([string]::IsNullOrEmpty($seg)){ continue }
      $p = [System.IO.Path]::Combine($p,$seg)
    }
  }
  return $p
}

function Resolve-NflRepoRoot([string]$RepoRoot){
  if([string]::IsNullOrWhiteSpace($RepoRoot)){ $RepoRoot = Split-Path -Parent $PSScriptRoot }
  return (Resolve-Path -LiteralPath $RepoRoot).Path
}

function Get-NflLedgerPath([string]$RepoRoot){ return (Join-NflPath $RepoRoot "data" "ledger.ndjson") }

function Get-NflHostExe {
  # The PowerShell executable running this script (powershell.exe on Windows PowerShell, pwsh on 7).
  try { $p = (Get-Process -Id $PID).Path; if($p -and (Test-Path -LiteralPath $p -PathType Leaf)){ return $p } } catch {}
  foreach($n in @("pwsh","powershell.exe","pwsh.exe")){ $c = Get-Command $n -ErrorAction SilentlyContinue; if($c){ return $c.Source } }
  throw "NFL_HOST_EXE_NOT_FOUND"
}

function ConvertTo-NflArg([string]$a){
  # Quote one argument for ProcessStartInfo.Arguments (Windows CRT / .NET rules; also valid on Linux).
  if($null -eq $a){ return '""' }
  if($a.Length -gt 0 -and $a -notmatch '[\s"]'){ return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach($ch in $a.ToCharArray()){
    if($ch -eq [char]92){ $bs++; continue }
    if($ch -eq [char]34){ [void]$sb.Append(('\' * (2*$bs+1))); [void]$sb.Append('"'); $bs = 0; continue }
    if($bs -gt 0){ [void]$sb.Append(('\' * $bs)); $bs = 0 }
    [void]$sb.Append($ch)
  }
  if($bs -gt 0){ [void]$sb.Append(('\' * (2*$bs))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Invoke-NflChild([string]$FileName,[string[]]$ArgList,[string]$WorkingDir){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = (($ArgList | ForEach-Object { ConvertTo-NflArg ([string]$_) }) -join " ")
  if(-not [string]::IsNullOrWhiteSpace($WorkingDir)){ $psi.WorkingDirectory = $WorkingDir }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $errTask = $p.StandardError.ReadToEndAsync()
  $o = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  $e = $errTask.Result
  return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=$o; StdErr=$e }
}

function Invoke-NflScript([string]$ScriptPath,[string[]]$ScriptArgs,[string]$WorkingDir){
  $all = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",$ScriptPath) + @($ScriptArgs)
  return (Invoke-NflChild (Get-NflHostExe) $all $WorkingDir)
}

# ---- hashing ----------------------------------------------------------------------------------
function Get-NflSha256Hex([byte[]]$Bytes){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ((($sha.ComputeHash($Bytes)) | ForEach-Object { $_.ToString("x2") }) -join "") }
  finally { $sha.Dispose() }
}
function Get-NflSha256HexOfString([string]$s){ return (Get-NflSha256Hex ((Get-NflUtf8).GetBytes($s))) }
function Get-NflSha256File([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("NFL_FILE_NOT_FOUND:" + $Path) }
  $fs = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ((($sha.ComputeHash($fs)) | ForEach-Object { $_.ToString("x2") }) -join "") }
  finally { $sha.Dispose(); $fs.Dispose() }
}

# ---- JSON (host-independent) ------------------------------------------------------------------
function ConvertFrom-NflJsonElement($el){
  $k = [string]$el.ValueKind
  if($k -eq "Object"){
    $o = [ordered]@{}
    foreach($p in $el.EnumerateObject()){ $o[$p.Name] = (ConvertFrom-NflJsonElement $p.Value) }
    return [pscustomobject]$o
  }
  if($k -eq "Array"){
    $list = New-Object System.Collections.Generic.List[object]
    foreach($i in $el.EnumerateArray()){ $list.Add((ConvertFrom-NflJsonElement $i)) }
    return ,($list.ToArray())
  }
  if($k -eq "String"){ return $el.GetString() }
  if($k -eq "Number"){ $l = 0L; if($el.TryGetInt64([ref]$l)){ return $l }; return [decimal]::Parse($el.GetRawText(),[Globalization.CultureInfo]::InvariantCulture) }
  if($k -eq "True"){ return $true }
  if($k -eq "False"){ return $false }
  return $null
}

function ConvertFrom-NflJson([string]$Text){
  # Strings stay strings on every host (PowerShell 7's ConvertFrom-Json turns ISO dates into DateTime,
  # which silently changes record hashes; this avoids that).
  if($null -eq $Text){ throw "NFL_JSON_EMPTY" }
  if($PSVersionTable.PSVersion.Major -ge 6){
    $doc = [System.Text.Json.JsonDocument]::Parse($Text)
    try { return (ConvertFrom-NflJsonElement $doc.RootElement) } finally { $doc.Dispose() }
  }
  return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-NflJsonString([string]$s){
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach($ch in $s.ToCharArray()){
    $c = [int]$ch
    if($c -eq 34){ [void]$sb.Append('\"') }
    elseif($c -eq 92){ [void]$sb.Append('\\') }
    elseif($c -eq 8){ [void]$sb.Append('\b') }
    elseif($c -eq 12){ [void]$sb.Append('\f') }
    elseif($c -eq 10){ [void]$sb.Append('\n') }
    elseif($c -eq 13){ [void]$sb.Append('\r') }
    elseif($c -eq 9){ [void]$sb.Append('\t') }
    elseif($c -lt 32){ [void]$sb.Append(('\u{0:x4}' -f $c)) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function ConvertTo-NflCanonicalJson($v){
  # Compact JSON, keys in insertion order. Floats are refused (shared invariant).
  if($null -eq $v){ return "null" }
  if($v -is [bool]){ if($v){ return "true" } else { return "false" } }
  if($v -is [string]){ return (ConvertTo-NflJsonString $v) }
  if($v -is [char]){ return (ConvertTo-NflJsonString ([string]$v)) }
  if(($v -is [int]) -or ($v -is [long]) -or ($v -is [int16]) -or ($v -is [byte]) -or ($v -is [uint32]) -or ($v -is [uint64])){
    return ([string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0}",$v))
  }
  if($v -is [decimal]){
    if($v -eq [decimal]::Truncate($v)){ return ([decimal]::Truncate($v)).ToString([Globalization.CultureInfo]::InvariantCulture) }
    throw "NFL_CANON_FLOAT_FORBIDDEN"
  }
  if(($v -is [double]) -or ($v -is [single])){ throw "NFL_CANON_FLOAT_FORBIDDEN" }
  if($v -is [System.Collections.IDictionary]){
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($key in $v.Keys){ $parts.Add(((ConvertTo-NflJsonString ([string]$key)) + ":" + (ConvertTo-NflCanonicalJson $v[$key]))) }
    return ("{" + ($parts -join ",") + "}")
  }
  if($v -is [System.Management.Automation.PSCustomObject]){
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($p in $v.PSObject.Properties){ $parts.Add(((ConvertTo-NflJsonString $p.Name) + ":" + (ConvertTo-NflCanonicalJson $p.Value))) }
    return ("{" + ($parts -join ",") + "}")
  }
  if($v -is [System.Collections.IEnumerable]){
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($i in $v){ $parts.Add((ConvertTo-NflCanonicalJson $i)) }
    return ("[" + ($parts -join ",") + "]")
  }
  throw ("NFL_CANON_UNSUPPORTED_TYPE:" + $v.GetType().FullName)
}

function Get-NflProp($o,[string]$Name){
  if($null -eq $o){ return $null }
  if($o -is [System.Collections.IDictionary]){ if($o.Contains($Name)){ return $o[$Name] }; return $null }
  $p = $o.PSObject.Properties[$Name]
  if($null -eq $p){ return $null }
  return $p.Value
}
function Test-NflProp($o,[string]$Name){
  if($o -is [System.Collections.IDictionary]){ return $o.Contains($Name) }
  return ($null -ne $o.PSObject.Properties[$Name])
}

# ---- validation -------------------------------------------------------------------------------
function Test-NflHex64([string]$h){ return ($null -ne $h -and $h -cmatch '^[0-9a-f]{64}\z') }

function Assert-NflCommitHash([string]$Hash){
  # A hex digest. SHA-256 (64 hex) is the ecosystem default; shorter/longer digests (sha1/sha512, test
  # vectors) stay accepted for compatibility with existing CLI/API callers. Anything else is refused.
  if([string]::IsNullOrWhiteSpace($Hash)){ throw "NFL_MISSING_HASH" }
  $h = $Hash.Trim().ToLowerInvariant()
  if($h -notmatch '^[0-9a-f]{4,128}\z'){ throw "NFL_BAD_HASH" }
  return $h
}

function Assert-NflArtifact([string]$Artifact){
  if($null -eq $Artifact){ return "" }
  if($Artifact.Length -gt 1024){ throw "NFL_ARTIFACT_TOO_LONG" }
  foreach($ch in $Artifact.ToCharArray()){ if([int]$ch -lt 32 -or [int]$ch -eq 127){ throw "NFL_ARTIFACT_CONTROL_CHAR" } }
  return $Artifact
}

# ---- ledger read ------------------------------------------------------------------------------
function Read-NflText([string]$Path){
  # Shares read AND write so readers never block the (lock-protected) appender on Windows.
  $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
  try { $sr = New-Object System.IO.StreamReader($fs,(Get-NflUtf8),$false); try { return $sr.ReadToEnd() } finally { $sr.Dispose() } } finally { $fs.Dispose() }
}

function Add-NflLine([string]$Path,[string]$Line){
  # Durable append of one LF-terminated line; a torn (unterminated) last line is closed first so the new
  # line can never be glued onto it. Caller holds the lock for $Path.
  $prefix = ""
  if((Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).Length -gt 0)){
    $fsr = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try { [void]$fsr.Seek(-1,[System.IO.SeekOrigin]::End); if($fsr.ReadByte() -ne 10){ $prefix = "`n" } } finally { $fsr.Dispose() }
  }
  $b = (Get-NflUtf8).GetBytes($prefix + $Line + "`n")
  $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
  try { $fs.Write($b,0,$b.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}
function Read-NflLedgerLines([string]$LedgerPath){
  if(-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)){ return @() }
  $raw = Read-NflText $LedgerPath
  if($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF){ $raw = $raw.Substring(1) }
  $norm = ($raw -replace "`r`n","`n") -replace "`r","`n"
  return @(($norm -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Read-NflLedgerRecords([string]$LedgerPath){
  $lines = @(Read-NflLedgerLines $LedgerPath)
  $out = New-Object System.Collections.Generic.List[object]
  for($i=0; $i -lt $lines.Count; $i++){
    $o = $null
    try { $o = ConvertFrom-NflJson $lines[$i] } catch { throw ("NFL_LEDGER_BAD_JSON_LINE:" + $i) }
    $out.Add($o)
  }
  return $out.ToArray()
}

function Get-NflCoreCanon($rec){
  $a = Get-NflProp $rec 'artifact'
  if($null -ne $a){ $a = [string]$a }
  $core = [ordered]@{ hash = [string](Get-NflProp $rec 'hash'); artifact = $a; timestamp = [string](Get-NflProp $rec 'timestamp') }
  return (ConvertTo-NflCanonicalJson $core)
}
function Get-NflRecordHash($rec){ return (Get-NflSha256HexOfString (Get-NflCoreCanon $rec)) }

function Get-NflLinkHash($rec){
  # Self-chain link (nfl.ledger.selfchain.v1). For a chained record (has prev) the link covers its own core
  # AND its prev, so every link commits to the whole history before it:
  #   link = sha256("nfl.ledger.selfchain.v1\n" + prev + "\n" + record_hash)
  # For a record of the unchained prefix (written before self-chaining) the link is its record hash.
  # The next record's prev must equal this link.
  $rh = Get-NflRecordHash $rec
  if(-not (Test-NflProp $rec 'prev')){ return $rh }
  return (Get-NflSha256HexOfString ("nfl.ledger.selfchain.v1`n" + [string](Get-NflProp $rec 'prev') + "`n" + $rh))
}

function Get-NflChainPinPath([string]$RepoRoot){ return (Join-NflPath $RepoRoot "data" "ledger.selfchain.json") }

# ---- ledger write (single writer, self-chained) ----------------------------------------------
function Open-NflLedgerLock([string]$LedgerPath,[int]$TimeoutMs = 15000){
  $dir = Split-Path -Parent $LedgerPath
  if(-not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $lockPath = $LedgerPath + ".lock"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while($true){
    try { return [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
    catch {
      if($sw.ElapsedMilliseconds -gt $TimeoutMs){ throw "NFL_LEDGER_LOCK_TIMEOUT" }
      Start-Sleep -Milliseconds 40
    }
  }
}

function Add-NflLedgerRecord {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$Hash,
    [string]$Artifact = "",
    [System.Collections.IDictionary]$Extra = $null,
    [switch]$IdempotentOnHashArtifact
  )
  $h = Assert-NflCommitHash $Hash
  $a = Assert-NflArtifact $Artifact
  $ledger = Get-NflLedgerPath $RepoRoot
  $lock = Open-NflLedgerLock $ledger
  try {
    $records = @(Read-NflLedgerRecords $ledger)
    if($IdempotentOnHashArtifact){
      for($i=0; $i -lt $records.Count; $i++){
        $r = $records[$i]
        if(([string](Get-NflProp $r 'hash') -eq $h) -and ([string](Get-NflProp $r 'artifact') -eq $a)){
          return [pscustomobject]@{ Duplicate=$true; Seq=$i; Timestamp=[string](Get-NflProp $r 'timestamp'); Hash=$h; Artifact=$a; RecordHash=(Get-NflRecordHash $r) }
        }
      }
    }
    $seq = $records.Count
    $prev = if($seq -eq 0){ $script:NflGenesis } else { Get-NflLinkHash $records[$seq-1] }
    # Pin where self-chaining started, so stripping seq/prev from records cannot turn them back into an
    # "unchained prefix" unnoticed.
    $pin = Get-NflChainPinPath $RepoRoot
    if(-not (Test-Path -LiteralPath $pin -PathType Leaf)){
      $start = $seq
      for($j=0; $j -lt $records.Count; $j++){ if(Test-NflProp $records[$j] 'prev'){ $start = $j; break } }
      [System.IO.File]::WriteAllText($pin, ((ConvertTo-NflCanonicalJson ([ordered]@{ schema = "nfl.ledger.selfchain_pin.v1"; chain_start_seq = $start })) + "`n"), (Get-NflUtf8))
    }
    $ts = Get-NflUtc
    $row = [ordered]@{ hash = $h; artifact = $a; timestamp = $ts }
    if($null -ne $Extra){
      foreach($k in $Extra.Keys){
        if(@("hash","artifact","timestamp","seq","prev") -contains [string]$k){ continue }
        $val = $Extra[$k]
        if($null -eq $val){ continue }
        $row[[string]$k] = (Assert-NflArtifact ([string]$val))
      }
    }
    $row["seq"] = $seq
    $row["prev"] = $prev
    $line = ConvertTo-NflCanonicalJson $row

    # Make sure the previous line is terminated, then append durably.
    $prefix = ""
    if(Test-Path -LiteralPath $ledger -PathType Leaf){
      $len = (Get-Item -LiteralPath $ledger).Length
      if($len -gt 0){
        $fsr = [System.IO.File]::Open($ledger,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        try { [void]$fsr.Seek(-1,[System.IO.SeekOrigin]::End); if($fsr.ReadByte() -ne 10){ $prefix = "`n" } } finally { $fsr.Dispose() }
      }
    }
    $bytes = (Get-NflUtf8).GetBytes($prefix + $line + "`n")
    $fs = [System.IO.File]::Open($ledger,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
    try { $fs.Write($bytes,0,$bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }

    # Verify the write before anyone reports success.
    $after = @(Read-NflLedgerLines $ledger)
    if($after.Count -ne ($seq + 1) -or $after[$after.Count-1] -ne $line){ throw "NFL_LEDGER_WRITE_NOT_VERIFIED" }
    return [pscustomobject]@{ Duplicate=$false; Seq=$seq; Timestamp=$ts; Hash=$h; Artifact=$a; RecordHash=(Get-NflSha256HexOfString (Get-NflCoreCanon $row)); Prev=$prev }
  } finally {
    $lock.Dispose()
  }
}

function Find-NflLedgerRecords([string]$RepoRoot,[string]$Hash){
  $h = $Hash.Trim().ToLowerInvariant()
  $records = @(Read-NflLedgerRecords (Get-NflLedgerPath $RepoRoot))
  $hits = New-Object System.Collections.Generic.List[object]
  for($i=0; $i -lt $records.Count; $i++){
    if([string](Get-NflProp $records[$i] 'hash') -eq $h){
      $hits.Add([pscustomobject]@{ Seq=$i; Record=$records[$i] })
    }
  }
  return $hits.ToArray()
}

function Test-NflLedgerChain([string]$RepoRoot){
  # Embedded self-chain (seq/prev). Records written before self-chaining (no prev) form an
  # "unchained prefix"; their record hash still anchors the first chained record.
  $ledger = Get-NflLedgerPath $RepoRoot
  if(-not (Test-Path -LiteralPath $ledger -PathType Leaf)){ return [pscustomobject]@{ Ok=$false; Error="LEDGER_MISSING"; Count=0; UnchainedPrefix=0; ChainedCount=0; Head=$null; Detail="" } }
  $records = $null
  try { $records = @(Read-NflLedgerRecords $ledger) } catch { return [pscustomobject]@{ Ok=$false; Error=([string]$_.Exception.Message -replace '^NFL_LEDGER_',''); Count=0; UnchainedPrefix=0; ChainedCount=0; Head=$null; Detail="" } }
  $chainedFrom = -1; $chained = 0; $prevLink = $null
  for($i=0; $i -lt $records.Count; $i++){
    $o = $records[$i]
    if(Test-NflProp $o 'prev'){
      if($chainedFrom -lt 0){ $chainedFrom = $i }
      $chained++
      $expected = if($i -eq 0){ $script:NflGenesis } else { $prevLink }
      if([string](Get-NflProp $o 'prev') -ne [string]$expected){
        return [pscustomobject]@{ Ok=$false; Error=("CHAIN_BREAK:" + $i); Count=$records.Count; UnchainedPrefix=$chainedFrom; ChainedCount=$chained; Head=$null; Detail=("EXPECTED_PREV=" + $expected + "`nRECORD_PREV=" + [string](Get-NflProp $o 'prev')) }
      }
    } elseif($chainedFrom -ge 0){
      return [pscustomobject]@{ Ok=$false; Error=("UNCHAINED_AFTER_CHAIN:" + $i); Count=$records.Count; UnchainedPrefix=$chainedFrom; ChainedCount=$chained; Head=$null; Detail="" }
    }
    if(Test-NflProp $o 'seq'){
      $s = Get-NflProp $o 'seq'
      if([string]$s -ne [string]$i){
        return [pscustomobject]@{ Ok=$false; Error=("SEQ_MISMATCH:" + $i + ":got=" + [string]$s); Count=$records.Count; UnchainedPrefix=$chainedFrom; ChainedCount=$chained; Head=$null; Detail="" }
      }
    }
    $prevLink = Get-NflLinkHash $o
  }
  $prefix = if($chainedFrom -lt 0){ $records.Count } else { $chainedFrom }
  $pin = Get-NflChainPinPath $RepoRoot
  if(Test-Path -LiteralPath $pin -PathType Leaf){
    $pv = $null
    try { $pv = ConvertFrom-NflJson (Read-NflText $pin) } catch {}
    $ps = Get-NflProp $pv 'chain_start_seq'
    if(($null -eq $ps) -or ([string]$ps -ne [string]$prefix)){
      return [pscustomobject]@{ Ok=$false; Error=("CHAIN_START_MOVED:pinned=" + [string]$ps + ":found=" + $prefix); Count=$records.Count; UnchainedPrefix=$prefix; ChainedCount=$chained; Head=$null; Detail="" }
    }
  }
  return [pscustomobject]@{ Ok=$true; Error=$null; Count=$records.Count; UnchainedPrefix=$prefix; ChainedCount=$chained; Head=$prevLink; Detail="" }
}

# ---- registered integrations (from the read-only .constellation copy) ------------------------
function Get-NflRegisteredIntegrations([string]$RepoRoot){
  # Parses the "## Integrations" table of .constellation/SERVICE_MAP.md (generated by Constellation from
  # registry/integrations.json). Returns $null when the copy is absent: callers report "unavailable".
  # Preferred: a machine-readable copy of registry/integrations.json, when Constellation publishes one.
  $json = Join-NflPath $RepoRoot ".constellation" "integrations.json"
  if(Test-Path -LiteralPath $json -PathType Leaf){
    $d = ConvertFrom-NflJson ([System.IO.File]::ReadAllText($json,(Get-NflUtf8)))
    $list = New-Object System.Collections.Generic.List[object]
    foreach($r in @(Get-NflProp $d 'integrations')){
      $rc = Get-NflProp $r 'receipt'
      $list.Add([pscustomobject]@{ consumer=[string]$r.consumer; provider=[string]$r.provider; contracts=@(@(Get-NflProp $r 'contracts') | Where-Object { $_ }); witness=[string](Get-NflProp $rc 'witness'); emitted_by=[string](Get-NflProp $rc 'emitted_by'); state=[string](Get-NflProp $rc 'state'); receipt="integrations.json" })
    }
    return $list.ToArray()
  }
  $map = Join-NflPath $RepoRoot ".constellation" "SERVICE_MAP.md"
  if(-not (Test-Path -LiteralPath $map -PathType Leaf)){ return $null }
  $lines = [System.IO.File]::ReadAllLines($map,(Get-NflUtf8))
  $in = $false
  $out = New-Object System.Collections.Generic.List[object]
  foreach($ln in $lines){
    if($ln -match '^##\s+Integrations\s*\z'){ $in = $true; continue }
    if($in -and $ln -match '^##\s'){ break }
    if(-not $in){ continue }
    if($ln -notmatch '^\|'){ continue }
    $cells = @($ln.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    if($cells.Count -lt 6){ continue }
    if($cells[0] -eq "Consumer" -or $cells[0] -match '^-+\z'){ continue }
    $contracts = @()
    if($cells[4] -ne "None"){ $contracts = @($cells[4].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $witness = $null
    if($cells[5] -match 'witness\s+([a-z0-9-]+)'){ $witness = $Matches[1] }
    $emittedBy = $null
    if($cells[5] -match '\bby\s+(consumer|provider)\b'){ $emittedBy = $Matches[1] }
    $state = $null
    if($cells[5] -match '^(specified|emitting|witnessed)\b'){ $state = $Matches[1] }
    $out.Add([pscustomobject]@{ consumer=$cells[0]; provider=$cells[1]; contracts=$contracts; witness=$witness; emitted_by=$emittedBy; state=$state; receipt=$cells[5] })
  }
  return $out.ToArray()
}

function Find-NflRegisteredIntegration($Integrations,[string]$Consumer,[string]$Provider){
  if($null -eq $Integrations){ return $null }
  foreach($i in $Integrations){ if($i.consumer -eq $Consumer -and $i.provider -eq $Provider){ return $i } }
  return $null
}

# ---- constellation.integration.receipt.v1 ----------------------------------------------------
function Get-NflReceiptLabel([string]$Consumer,[string]$Provider){ return ($script:NflReceiptSchema + ":" + $Consumer + ">" + $Provider) }

function Test-NflIntegrationReceiptLine([string]$Line){
  # Validates one receipt line against schemas/constellation.integration.receipt.v1.json, including the
  # byte rules (canonical compact form, keys in schema order). Returns Ok/Error/Sha256/Consumer/Provider.
  $fail = { param($e) return [pscustomobject]@{ Ok=$false; Error=$e; Sha256=$null; Consumer=$null; Provider=$null; Obj=$null } }
  if($null -eq $Line){ return (& $fail "RECEIPT_EMPTY") }
  $l = $Line
  if($l.EndsWith("`n")){ $l = $l.Substring(0,$l.Length-1) }
  if($l.Contains("`n") -or $l.Contains("`r")){ return (& $fail "RECEIPT_NOT_ONE_LINE") }
  if([string]::IsNullOrWhiteSpace($l)){ return (& $fail "RECEIPT_EMPTY") }
  $o = $null
  try { $o = ConvertFrom-NflJson $l } catch { return (& $fail "RECEIPT_BAD_JSON") }
  if($o -isnot [System.Management.Automation.PSCustomObject]){ return (& $fail "RECEIPT_NOT_OBJECT") }
  $keys = @($o.PSObject.Properties | ForEach-Object { $_.Name })
  $want = @("schema","consumer","provider","emitted_by","contract","request_sha256","response_sha256","carried","outcome","error_token","prev_sha256")
  if(($keys -join ",") -ne ($want -join ",")){ return (& $fail "RECEIPT_KEYS_NOT_CANONICAL") }
  try { $canon = ConvertTo-NflCanonicalJson $o } catch { return (& $fail "RECEIPT_NOT_CANONICAL") }
  if($canon -ne $l){ return (& $fail "RECEIPT_NOT_CANONICAL") }
  if(($o.schema -isnot [string]) -or ($o.schema -cne $script:NflReceiptSchema)){ return (& $fail "RECEIPT_BAD_SCHEMA") }
  foreach($n in @("consumer","provider")){ $v = $o.$n; if(($v -isnot [string]) -or ($v -cnotmatch '^[a-z0-9][a-z0-9-]*\z')){ return (& $fail ("RECEIPT_BAD_" + $n.ToUpperInvariant())) } }
  if(($o.emitted_by -isnot [string]) -or (@("consumer","provider") -cnotcontains $o.emitted_by)){ return (& $fail "RECEIPT_BAD_EMITTED_BY") }
  if(($null -ne $o.contract) -and (($o.contract -isnot [string]) -or ($o.contract -cnotmatch '^[a-z0-9][a-z0-9_.-]*\.v[0-9]+\z'))){ return (& $fail "RECEIPT_BAD_CONTRACT") }
  foreach($n in @("request_sha256","response_sha256")){ $v = $o.$n; if(($null -ne $v) -and (-not (($v -is [string]) -and (Test-NflHex64 $v)))){ return (& $fail ("RECEIPT_BAD_" + $n.ToUpperInvariant())) } }
  if(($o.carried -isnot [System.Array])){ return (& $fail "RECEIPT_BAD_CARRIED") }
  foreach($c in $o.carried){
    if($c -isnot [System.Management.Automation.PSCustomObject]){ return (& $fail "RECEIPT_BAD_CARRIED") }
    if((@($c.PSObject.Properties | ForEach-Object { $_.Name }) -join ",") -ne "contract,sha256"){ return (& $fail "RECEIPT_BAD_CARRIED") }
    if(($c.contract -isnot [string]) -or ($c.contract -cnotmatch '^[a-z0-9][a-z0-9_.-]*\.v[0-9]+\z')){ return (& $fail "RECEIPT_BAD_CARRIED") }
    if(($c.sha256 -isnot [string]) -or -not (Test-NflHex64 $c.sha256)){ return (& $fail "RECEIPT_BAD_CARRIED") }
  }
  if(($o.outcome -isnot [string]) -or (@("ok","refused","unavailable","unknown","deferred","failed") -cnotcontains $o.outcome)){ return (& $fail "RECEIPT_BAD_OUTCOME") }
  if($o.outcome -ceq "ok"){ if($null -ne $o.error_token){ return (& $fail "RECEIPT_ERROR_TOKEN_ON_OK") } }
  else { if(($o.error_token -isnot [string]) -or ($o.error_token -cnotmatch '^[A-Z][A-Z0-9_]*\z')){ return (& $fail "RECEIPT_BAD_ERROR_TOKEN") } }
  if(($o.prev_sha256 -isnot [string]) -or -not (Test-NflHex64 $o.prev_sha256)){ return (& $fail "RECEIPT_BAD_PREV_SHA256") }
  return [pscustomobject]@{ Ok=$true; Error=$null; Sha256=(Get-NflSha256HexOfString $l); Consumer=$o.consumer; Provider=$o.provider; Obj=$o }
}

function New-NflIntegrationReceiptLine {
  # Builds the canonical line NFL itself writes when it is the consumer of an integration.
  param(
    [Parameter(Mandatory=$true)][string]$Consumer,[Parameter(Mandatory=$true)][string]$Provider,
    [string]$Contract,[string]$RequestSha256,[string]$ResponseSha256,[object[]]$Carried = @(),
    [Parameter(Mandatory=$true)][string]$Outcome,[string]$ErrorToken,[Parameter(Mandatory=$true)][string]$PrevSha256
  )
  $row = [ordered]@{
    schema = $script:NflReceiptSchema; consumer = $Consumer; provider = $Provider; emitted_by = "consumer"
    contract = $(if([string]::IsNullOrEmpty($Contract)){ $null } else { $Contract })
    request_sha256 = $(if([string]::IsNullOrEmpty($RequestSha256)){ $null } else { $RequestSha256 })
    response_sha256 = $(if([string]::IsNullOrEmpty($ResponseSha256)){ $null } else { $ResponseSha256 })
    carried = @($Carried)
    outcome = $Outcome
    error_token = $(if($Outcome -eq "ok"){ $null } else { $ErrorToken })
    prev_sha256 = $PrevSha256
  }
  return (ConvertTo-NflCanonicalJson $row)
}

function Write-NflOwnIntegrationReceipt {
  # NFL as emitter (consumer side of nfl>cpr, nfl>neverlost, ...): write the receipt locally first, in
  # proofs/receipts/integration/nfl__<provider>.ndjson (chained per integration via prev_sha256).
  # Never throws on behalf of the caller's integration: problems come back in .Error.
  # Witnessing is a separate step (Sync-NflOwnIntegrationReceipts) so that verification commands never
  # mutate the ledger they are verifying.
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$Provider,
    [string]$Contract,[string]$RequestSha256,[string]$ResponseSha256,[object[]]$Carried = @(),
    [Parameter(Mandatory=$true)][string]$Outcome,[string]$ErrorToken
  )
  try {
    $dir = Join-NflPath $RepoRoot "proofs" "receipts" "integration"
    if(-not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-NflPath $dir ("nfl__" + $Provider + ".ndjson")
    $lock = Open-NflLedgerLock $path
    try {
      $prev = $script:NflZero64
      $existing = @(Read-NflLedgerLines $path)
      if($existing.Count -gt 0){ $prev = Get-NflSha256HexOfString $existing[$existing.Count-1] }
      $line = New-NflIntegrationReceiptLine -Consumer "nfl" -Provider $Provider -Contract $Contract -RequestSha256 $RequestSha256 -ResponseSha256 $ResponseSha256 -Carried $Carried -Outcome $Outcome -ErrorToken $ErrorToken -PrevSha256 $prev
      $chk = Test-NflIntegrationReceiptLine $line
      if(-not $chk.Ok){ throw ("NFL_OWN_RECEIPT_INVALID:" + $chk.Error) }
      Add-NflLine $path $line
    } finally { $lock.Dispose() }
    return [pscustomobject]@{ Ok=$true; Path=$path; Sha256=$chk.Sha256; Error=$null }
  } catch {
    return [pscustomobject]@{ Ok=$false; Path=$null; Sha256=$null; Error=[string]$_.Exception.Message }
  }
}

function Sync-NflOwnIntegrationReceipts([string]$RepoRoot){
  $integrations = Get-NflRegisteredIntegrations $RepoRoot
  # Witness every receipt NFL emitted as a consumer (idempotent: hash + label already present is skipped).
  $dir = Join-NflPath $RepoRoot "proofs" "receipts" "integration"
  $res = [pscustomobject]@{ Files=0; Lines=0; Witnessed=0; Already=0; Invalid=0 }
  if(-not (Test-Path -LiteralPath $dir -PathType Container)){ return $res }
  foreach($f in @(Get-ChildItem -LiteralPath $dir -File -Filter "nfl__*.ndjson" | Sort-Object Name)){
    $res.Files++
    $prev = $script:NflZero64
    foreach($line in @(Read-NflLedgerLines $f.FullName)){
      $res.Lines++
      $chk = Test-NflIntegrationReceiptLine $line
      $fileProvider = $f.Name.Substring(5, $f.Name.Length - 5 - ".ndjson".Length)
      $bad = (-not $chk.Ok) -or ($chk.Obj.prev_sha256 -ne $prev) -or ($chk.Consumer -ne "nfl") -or ($chk.Provider -ne $fileProvider) -or
             ($null -eq (Find-NflRegisteredIntegration $integrations "nfl" $chk.Provider))
      if($bad){ $res.Invalid++; $prev = Get-NflSha256HexOfString $line; continue }
      $prev = $chk.Sha256
      $r = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $chk.Sha256 -Artifact (Get-NflReceiptLabel $chk.Consumer $chk.Provider) -IdempotentOnHashArtifact
      if($r.Duplicate){ $res.Already++ } else { $res.Witnessed++ }
    }
  }
  return $res
}

# ---- witnessing one integration receipt line (shared by CLI, API, ingest) -------------------
# Read-only: what NFL has witnessed for one registered integration (NFL proposal 0003). Records are those committed with the
# artifact label "constellation.integration.receipt.v1:<consumer>><provider>", in ledger order. Count = how many; Head = the hash
# of the most recent one (64 zeros when none). An emitter compares Head with its own receipt file: Head must still be one of its
# lines, so a rewritten, removed or replaced witnessed receipt is caught even when the emitter's local files were both changed.
function Get-NflReceiptHead([string]$RepoRoot,[string]$Consumer,[string]$Provider){
  if($Consumer -cnotmatch '^[a-z0-9][a-z0-9-]*\z' -or $Provider -cnotmatch '^[a-z0-9][a-z0-9-]*\z'){ throw "NFL_RECEIPT_HEAD_BAD_INTEGRATION" }
  $label = Get-NflReceiptLabel $Consumer $Provider
  $records = @(Read-NflLedgerRecords (Get-NflLedgerPath $RepoRoot))
  $count = 0; $head = ("0" * 64); $seq = -1
  for($i=0; $i -lt $records.Count; $i++){
    if([string](Get-NflProp $records[$i] 'artifact') -ceq $label){ $count++; $head = [string](Get-NflProp $records[$i] 'hash'); $seq = $i }
  }
  return [pscustomobject]@{ Integration=($Consumer + ">" + $Provider); Count=$count; Head=$head; LastSeq=$seq }
}

function Invoke-NflWitnessReceiptLine([string]$RepoRoot,[string]$Line,$Integrations){
  # Fail closed: only a valid receipt of a registered integration whose witness is nfl is committed
  # (shared invariant: "a witness only commits hashes that belong to a registered integration").
  $chk = Test-NflIntegrationReceiptLine $Line
  $err = $null
  if(-not $chk.Ok){ $err = $chk.Error }
  elseif($null -eq $Integrations){ $err = "RECEIPT_REGISTRY_UNAVAILABLE" }
  else {
    $reg = Find-NflRegisteredIntegration $Integrations $chk.Consumer $chk.Provider
    if($null -eq $reg){ $err = "RECEIPT_UNATTRIBUTED" }
    elseif($reg.witness -ne "nfl"){ $err = "RECEIPT_WITNESS_NOT_NFL" }
    elseif(($null -ne $reg.emitted_by) -and ($reg.emitted_by -ne $chk.Obj.emitted_by)){ $err = "RECEIPT_EMITTER_MISMATCH" }
    elseif(($null -ne $chk.Obj.contract) -and (@($reg.contracts).Count -gt 0) -and (@($reg.contracts) -notcontains $chk.Obj.contract)){ $err = "RECEIPT_CONTRACT_NOT_REGISTERED" }
  }
  if($null -ne $err){
    return [pscustomobject]@{ Status="REFUSED"; Error=$err; Sha256=$chk.Sha256; Integration=$(if($chk.Ok){ $chk.Consumer + ">" + $chk.Provider } else { $null }); Seq=$null; Timestamp=$null }
  }
  $r = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $chk.Sha256 -Artifact (Get-NflReceiptLabel $chk.Consumer $chk.Provider) -IdempotentOnHashArtifact
  return [pscustomobject]@{ Status=$(if($r.Duplicate){ "ALREADY_WITNESSED" } else { "WITNESSED" }); Error=$null; Sha256=$chk.Sha256; Integration=($chk.Consumer + ">" + $chk.Provider); Seq=$r.Seq; Timestamp=$r.Timestamp }
}

# ---- nfl.ingest.v1 envelopes and nfl.receipt.v1 receipts --------------------------------------
function Test-NflIngestEnvelope($Env){
  # Mirrors schemas/nfl.ingest.v1.schema.json. Returns $null when valid, else an error token.
  if($Env -isnot [System.Management.Automation.PSCustomObject]){ return "INGEST_ENVELOPE_NOT_OBJECT" }
  $allowed = @("schema","packet_id","commit_hash","producer","producer_instance","tenant","principal","event_type","event_time_utc","prev_links","payload_mode","payload_ref","producer_key_id","producer_sig_ref")
  $names = @($Env.PSObject.Properties | ForEach-Object { $_.Name })
  foreach($n in $names){ if($allowed -cnotcontains $n){ return ("INGEST_ENVELOPE_UNKNOWN_FIELD:" + $n) } }
  foreach($n in $allowed){ if($names -cnotcontains $n){ return ("INGEST_ENVELOPE_MISSING:" + $n) } }
  if(($Env.schema -isnot [string]) -or ($Env.schema -cne "nfl.ingest.v1")){ return "INGEST_ENVELOPE_BAD_SCHEMA" }
  foreach($n in @("packet_id","commit_hash")){ $v = $Env.$n; if(($v -isnot [string]) -or -not (Test-NflHex64 $v)){ return ("INGEST_ENVELOPE_BAD_" + $n.ToUpperInvariant()) } }
  $lim = @{ producer=64; producer_instance=128; tenant=128; principal=256; event_type=256; payload_ref=2048; producer_key_id=128; producer_sig_ref=512 }
  foreach($n in $lim.Keys){ $v = $Env.$n; if(($v -isnot [string]) -or $v.Length -lt 1 -or $v.Length -gt $lim[$n]){ return ("INGEST_ENVELOPE_BAD_" + $n.ToUpperInvariant()) } }
  if(($Env.producer -isnot [string]) -or $Env.producer -cnotmatch '^[a-z0-9][a-z0-9-]*\z'){ return "INGEST_ENVELOPE_PRODUCER_NOT_SERVICE_ID" }
  if(($Env.event_time_utc -isnot [string]) -or ($Env.event_time_utc -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\z')){ return "INGEST_ENVELOPE_BAD_EVENT_TIME_UTC" }
  if($Env.prev_links -isnot [System.Array]){ return "INGEST_ENVELOPE_BAD_PREV_LINKS" }
  foreach($l in $Env.prev_links){ if(($l -isnot [string]) -or -not (Test-NflHex64 $l)){ return "INGEST_ENVELOPE_BAD_PREV_LINKS" } }
  if(($Env.payload_mode -isnot [string]) -or (@("pointer_only","inline_sealed","inline_plain") -cnotcontains $Env.payload_mode)){ return "INGEST_ENVELOPE_BAD_PAYLOAD_MODE" }
  return $null
}

function Get-NflIngestLabel([string]$Producer,[string]$PacketId){ return ("nfl.ingest.v1:" + $Producer + ":" + $PacketId) }

function Add-NflIngestReceipt {
  # Append one nfl.receipt.v1 line to proofs/receipts/nfl.receipt.v1.ndjson (chained). Idempotent per
  # packet_id + commit_hash: an existing receipt for the same pair is returned instead of a new one.
  param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)]$Envelope,[Parameter(Mandatory=$true)]$Commit,[Parameter(Mandatory=$true)][string]$PacketId)
  $path = Join-NflPath $RepoRoot "proofs" "receipts" "nfl.receipt.v1.ndjson"
  $dir = Split-Path -Parent $path
  if(-not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $lock = Open-NflLedgerLock $path
  try {
    $lines = @(Read-NflLedgerLines $path)
    foreach($ln in $lines){
      $o = ConvertFrom-NflJson $ln
      $p = @($o.pointers)
      $hasPid = @($p | Where-Object { $_.kind -eq "packet_id" -and $_.value -eq $PacketId }).Count -gt 0
      $hasCommit = @($p | Where-Object { $_.kind -eq "commit_hash" -and $_.value -eq $Envelope.commit_hash }).Count -gt 0
      if($hasPid -and $hasCommit){ return [pscustomobject]@{ Duplicate=$true; Line=$ln; Receipt=$o } }
    }
    $prev = if($lines.Count -gt 0){ Get-NflSha256HexOfString $lines[$lines.Count-1] } else { $script:NflZero64 }
    $plist = New-Object System.Collections.Generic.List[object]
    $plist.Add([ordered]@{ kind = "packet_id"; value = $PacketId })
    if([string]$Envelope.packet_id -ne $PacketId){ $plist.Add([ordered]@{ kind = "declared_packet_id"; value = [string]$Envelope.packet_id }) }
    $plist.Add([ordered]@{ kind = "commit_hash"; value = [string]$Envelope.commit_hash })
    $plist.Add([ordered]@{ kind = "ledger_record_hash"; value = [string]$Commit.RecordHash })
    $pointers = $plist.ToArray()
    $t = Get-NflUtc
    $seed = [ordered]@{ pointers = $pointers; receipt_time = $t }
    $row = [ordered]@{
      schema = "nfl.receipt.v1"; receipt_id = (Get-NflSha256HexOfString (ConvertTo-NflCanonicalJson $seed)); receipt_time = $t
      witness = "nfl"; namespace = "covenant-nfl"; mode = "pointer_only"; authoritative = $true; pointers = $pointers
      producer = [string]$Envelope.producer; event_type = [string]$Envelope.event_type; ledger_seq = [int]$Commit.Seq; prev_receipt_sha256 = $prev
    }
    $line = ConvertTo-NflCanonicalJson $row
    Add-NflLine $path $line
    return [pscustomobject]@{ Duplicate=$false; Line=$line; Receipt=(ConvertFrom-NflJson $line) }
  } finally { $lock.Dispose() }
}

function Test-NflReceiptChain([string]$RepoRoot){
  # Verifies proofs/receipts/nfl.receipt.v1.ndjson: every line valid, prev_receipt_sha256 chain intact,
  # receipt_id recomputed, and each commit_hash present in the ledger under its nfl.ingest.v1 label.
  $path = Join-NflPath $RepoRoot "proofs" "receipts" "nfl.receipt.v1.ndjson"
  $lines = @(Read-NflLedgerLines $path)
  $prev = $script:NflZero64
  for($i=0; $i -lt $lines.Count; $i++){
    $o = $null
    try { $o = ConvertFrom-NflJson $lines[$i] } catch { return [pscustomobject]@{ Ok=$false; Error=("BAD_JSON:" + $i); Count=$lines.Count } }
    if((ConvertTo-NflCanonicalJson $o) -ne $lines[$i]){ return [pscustomobject]@{ Ok=$false; Error=("NOT_CANONICAL:" + $i); Count=$lines.Count } }
    if($o.prev_receipt_sha256 -ne $prev){ return [pscustomobject]@{ Ok=$false; Error=("CHAIN_BREAK:" + $i); Count=$lines.Count } }
    $seed = [ordered]@{ pointers = $o.pointers; receipt_time = $o.receipt_time }
    if((Get-NflSha256HexOfString (ConvertTo-NflCanonicalJson $seed)) -ne $o.receipt_id){ return [pscustomobject]@{ Ok=$false; Error=("RECEIPT_ID_MISMATCH:" + $i); Count=$lines.Count } }
    $pid0 = [string](@($o.pointers | Where-Object { $_.kind -eq "packet_id" })[0].value)
    $ch = [string](@($o.pointers | Where-Object { $_.kind -eq "commit_hash" })[0].value)
    $hits = @(Find-NflLedgerRecords $RepoRoot $ch | Where-Object { [string](Get-NflProp $_.Record 'artifact') -eq (Get-NflIngestLabel $o.producer $pid0) })
    if($hits.Count -eq 0){ return [pscustomobject]@{ Ok=$false; Error=("COMMIT_NOT_IN_LEDGER:" + $i); Count=$lines.Count } }
    $prev = Get-NflSha256HexOfString $lines[$i]
  }
  return [pscustomobject]@{ Ok=$true; Error=$null; Count=$lines.Count }
}
