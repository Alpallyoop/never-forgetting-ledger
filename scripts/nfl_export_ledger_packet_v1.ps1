param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_EXPORT_FAIL:" + $m) }
function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}
function ReadUtf8([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("READ_MISSING:" + $Path) }
  [System.IO.File]::ReadAllText($Path,(Utf8NoBom))
}
function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("WRITE_FAILED:" + $Path) }
}
function Sha256HexBytes([byte[]]$Bytes){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($Bytes)
    return ([System.BitConverter]::ToString($hash).Replace("-","").ToLowerInvariant())
  }
  finally {
    $sha.Dispose()
  }
}
function Sha256HexText([string]$Text){
  $u = NormalizeLf $Text
  return (Sha256HexBytes ((Utf8NoBom).GetBytes($u)))
}
function Sha256HexFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("HASH_MISSING:" + $Path) }
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function RelPath([string]$Root,[string]$Full){
  $bs=[char]92
  $r=(Resolve-Path -LiteralPath $Root).Path.TrimEnd($bs)
  $f=(Resolve-Path -LiteralPath $Full).Path
  $rel=$f.Substring($r.Length).TrimStart($bs)
  return $rel.Replace($bs,[char]47)
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Ledger = Join-Path $RepoRoot "data\ledger.ndjson"
if(-not (Test-Path -LiteralPath $Ledger -PathType Leaf)){ Fail "LEDGER_MISSING" }

$OutRoot = Join-Path $RepoRoot "packets\outbox"
EnsureDir $OutRoot

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$ledgerText = NormalizeLf (ReadUtf8 $Ledger)
$ledgerSha = Sha256HexText $ledgerText

$manifestObj = [ordered]@{
  schema = "nfl.ledger_export.packet_manifest.v1"
  export_utc = $stamp
  payload = [ordered]@{
    path = "payload/ledger.ndjson"
    sha256 = $ledgerSha
  }
}

$manifestText = NormalizeLf ($manifestObj | ConvertTo-Json -Compress -Depth 10)
$packetId = Sha256HexText $manifestText
$PacketDir = Join-Path $OutRoot $packetId

if(Test-Path -LiteralPath $PacketDir){ Remove-Item -LiteralPath $PacketDir -Recurse -Force }
EnsureDir $PacketDir
EnsureDir (Join-Path $PacketDir "payload")

$ManifestPath = Join-Path $PacketDir "manifest.json"
$PayloadPath  = Join-Path $PacketDir "payload\ledger.ndjson"
$IdPath       = Join-Path $PacketDir "packet_id.txt"
$SumPath      = Join-Path $PacketDir "sha256sums.txt"

WriteUtf8NoBomLfText $ManifestPath $manifestText
WriteUtf8NoBomLfText $PayloadPath  $ledgerText
WriteUtf8NoBomLfText $IdPath       $packetId

foreach($p in @($ManifestPath,$PayloadPath,$IdPath)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Fail ("POST_WRITE_MISSING:" + $p) }
}

$files = @(Get-ChildItem -LiteralPath $PacketDir -Recurse -File | Sort-Object FullName)
$lines = New-Object System.Collections.Generic.List[string]
foreach($f in @(@($files))){
  if($f.Name -eq "sha256sums.txt"){ continue }
  $h = Sha256HexFile $f.FullName
  $rel = RelPath $PacketDir $f.FullName
  [void]$lines.Add(($h + "  " + $rel))
}
WriteUtf8NoBomLfText $SumPath ((@($lines.ToArray()) -join "`n") + "`n")

if(-not (Test-Path -LiteralPath $SumPath -PathType Leaf)){ Fail "POST_WRITE_SUMS_MISSING" }

Write-Output "NFL_EXPORT_LEDGER_PACKET_OK"
Write-Output ("PACKET_ID=" + $packetId)
Write-Output ("PACKET_DIR=" + $PacketDir)
Write-Output ("PAYLOAD_SHA256=" + $ledgerSha)
