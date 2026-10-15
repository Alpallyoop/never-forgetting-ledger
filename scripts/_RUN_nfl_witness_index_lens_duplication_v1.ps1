param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = "C:\dev\nfl",
  [Parameter(Mandatory=$false)][string]$SourcePacketDir = "C:\dev\index-lens\proofs\nfl_duplication\20260326T163943Z\packet"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $t = $Text -replace "`r`n","`n" -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}
function Parse-GateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("PARSE_GATE_MISSING_FILE: " + $Path) }
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and $err.Count -gt 0){
    $msg = ($err | ForEach-Object { $_.Message }) -join " | "
    Die ("PARSE_GATE_FAIL: " + $Path + " :: " + $msg)
  }
}
function ReadTextUtf8([string]$p){ return (Get-Content -Raw -LiteralPath $p -Encoding UTF8) }
function NormalizePacketId([string]$s){
  if($null -eq $s){ return "" }
  $t = $s.Trim()
  if(-not $t){ return "" }
  if($t.Length -ge 7 -and $t.Substring(0,7).ToLowerInvariant() -eq "sha256:"){ $t = $t.Substring(7).Trim() }
  return $t.ToLowerInvariant()
}
function Find-Verifier([string]$ScriptsDir){
  $candidates = @(
    (Join-Path $ScriptsDir "verify_packet_v1.ps1"),
    (Join-Path $ScriptsDir "nfl_verify_packet_v1.ps1"),
    (Join-Path $ScriptsDir "verify_nfl_packet_v1.ps1"),
    (Join-Path $ScriptsDir "verify_packet.ps1")
  )
  foreach($c in @($candidates)){ if(Test-Path -LiteralPath $c -PathType Leaf){ return $c } }
  Die ("MISSING_NFL_VERIFIER in " + $ScriptsDir)
}
function Get-RelPath([string]$Base,[string]$Child){
  $b = [System.IO.Path]::GetFullPath($Base)
  $c = [System.IO.Path]::GetFullPath($Child)
  $bu = New-Object System.Uri(($b.TrimEnd("\") + "\"))
  $cu = New-Object System.Uri($c)
  return [System.Uri]::UnescapeDataString($bu.MakeRelativeUri($cu).ToString()).Replace("/","\")
}
function Sha256HexFile([string]$p){ return ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()) }
function Append-Ndjson([string]$Path,[object]$Obj){
  $j = ($Obj | ConvertTo-Json -Depth 20 -Compress)
  $j = ($j -replace "`r`n","`n" -replace "`r","`n")
  if(-not $j.EndsWith("`n")){ $j += "`n" }
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $fs = New-Object System.IO.FileStream($Path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
  try {
    $sw = New-Object System.IO.StreamWriter($fs,$enc)
    try { $sw.Write($j); $sw.Flush() } finally { $sw.Dispose() }
  } finally { $fs.Dispose() }
}

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$SourcePacketDir = [System.IO.Path]::GetFullPath($SourcePacketDir)
$ScriptsDir = Join-Path $RepoRoot "scripts"
$Verifier = Find-Verifier $ScriptsDir
Parse-GateFile $Verifier

if(-not (Test-Path -LiteralPath $SourcePacketDir -PathType Container)){ Die ("MISSING_SOURCE_PACKET_DIR: " + $SourcePacketDir) }
$ManifestPath = Join-Path $SourcePacketDir "manifest.json"
$PacketIdPath = Join-Path $SourcePacketDir "packet_id.txt"
if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){ Die ("MISSING_SOURCE_MANIFEST: " + $ManifestPath) }
if(-not (Test-Path -LiteralPath $PacketIdPath -PathType Leaf)){ Die ("MISSING_SOURCE_PACKET_ID: " + $PacketIdPath) }
$packetId = NormalizePacketId (ReadTextUtf8 $PacketIdPath)
if($packetId -notmatch "^[0-9a-f]{64}$"){ Die ("BAD_SOURCE_PACKET_ID: " + $packetId) }

$RunRoot = Join-Path $RepoRoot "proofs\receipts\nfl_index_lens_witness"
EnsureDir $RunRoot
$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$RunDir = Join-Path $RunRoot $stamp
EnsureDir $RunDir
$DestRoot = Join-Path $RepoRoot "packets\inbox"
EnsureDir $DestRoot
$DestPacketDir = Join-Path $DestRoot ("index_lens_" + $packetId)
if(Test-Path -LiteralPath $DestPacketDir){ Die ("DEST_ALREADY_EXISTS: " + $DestPacketDir) }

# immutable copy into NFL control boundary
Copy-Item -LiteralPath $SourcePacketDir -Destination $DestPacketDir -Recurse -Force
$DestManifest = Join-Path $DestPacketDir "manifest.json"
if(-not (Test-Path -LiteralPath $DestManifest -PathType Leaf)){ Die ("DEST_MANIFEST_MISSING: " + $DestManifest) }

$VerifierText = Get-Content -Raw -LiteralPath $Verifier -Encoding UTF8
$acceptLegacy = $false
$args = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",$Verifier,"-ManifestPath",$DestManifest,"-Enforce")
if($VerifierText -match "AcceptLegacyRawManifest"){
  $args += "-AcceptLegacyRawManifest"
  $acceptLegacy = $true
}

$StdOut = Join-Path $RunDir "verify.stdout.log"
$StdErr = Join-Path $RunDir "verify.stderr.log"
$p = Start-Process -FilePath $PSExe -ArgumentList $args -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -Wait -PassThru -WindowStyle Hidden
$exitCode = [int]$p.ExitCode
$stdoutText = ""
$stderrText = ""
if(Test-Path -LiteralPath $StdOut -PathType Leaf){ $stdoutText = (Get-Content -Raw -LiteralPath $StdOut -Encoding UTF8) }
if(Test-Path -LiteralPath $StdErr -PathType Leaf){ $stderrText = (Get-Content -Raw -LiteralPath $StdErr -Encoding UTF8) }

$receipt = [ordered]@{
  schema = "nfl.index_lens_witness.v1"
  generated_utc = [DateTime]::UtcNow.ToString("o")
  repo_root = $RepoRoot
  source_packet_dir = $SourcePacketDir
  dest_packet_dir = $DestPacketDir
  manifest_path = $DestManifest
  packet_id = $packetId
  verifier = $Verifier
  verifier_accept_legacy_raw_manifest = $acceptLegacy
  verifier_exit_code = $exitCode
  dest_manifest_sha256 = (Sha256HexFile $DestManifest)
  stdout_log = $StdOut
  stderr_log = $StdErr
}
$receiptJson = ($receipt | ConvertTo-Json -Depth 20)
$receiptJson = ($receiptJson -replace "`r`n","`n" -replace "`r","`n")
Write-Utf8NoBomLf -Path (Join-Path $RunDir "nfl_index_lens_witness_receipt.json") -Text $receiptJson
Append-Ndjson -Path (Join-Path $RepoRoot "proofs\receipts\nfl_index_lens_witness.ndjson") -Obj $receipt

Write-Host ("SOURCE_PACKET: " + $SourcePacketDir) -ForegroundColor Gray
Write-Host ("DEST_PACKET: " + $DestPacketDir) -ForegroundColor Gray
Write-Host ("PACKET_ID: " + $packetId) -ForegroundColor Cyan
Write-Host ("VERIFIER: " + $Verifier) -ForegroundColor Gray
Write-Host ("ACCEPT_LEGACY: " + $acceptLegacy) -ForegroundColor Gray
Write-Host ("RUN_DIR: " + $RunDir) -ForegroundColor Gray

if(Test-Path -LiteralPath $StdOut -PathType Leaf){
  Write-Host "--- VERIFY STDOUT ---" -ForegroundColor Cyan
  Get-Content -LiteralPath $StdOut -Encoding UTF8 | Out-Host
}
if((Test-Path -LiteralPath $StdErr -PathType Leaf) -and ((Get-Item -LiteralPath $StdErr).Length -gt 0)){
  Write-Host "--- VERIFY STDERR ---" -ForegroundColor Cyan
  Get-Content -LiteralPath $StdErr -Encoding UTF8 | Out-Host
}

if($exitCode -ne 0){ Die ("NFL_WITNESS_VERIFY_FAILED_EXIT_" + $exitCode) }
Write-Host "NFL_INDEX_LENS_WITNESS_READY_OK" -ForegroundColor Green
