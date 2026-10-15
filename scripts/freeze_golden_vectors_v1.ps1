param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [Parameter(Mandatory=$false)][string]$SourcePacketRoot = "C:\covenant_inbox\0537effea5f535d061b313f72e37ca52d4a34fff00865066c51fa7dff410618a",
  [Parameter(Mandatory=$false)][string]$SigNamespaceGood = "covenant-nfl",
  [Parameter(Mandatory=$false)][string]$SigNamespaceBad  = "covenant-nfl-BAD"
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw ("NFL_FREEZE_FAIL: " + $m) }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ Die "EnsureDir: empty" } if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ return (New-Object System.Text.UTF8Encoding($false)) }
function CanonLf([string]$s){ return $s.Replace("`r`n","`n").Replace("`r","`n") }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t = CanonLf $Text; if(-not $t.EndsWith("`n")){ $t += "`n" }; [System.IO.File]::WriteAllText($Path,$t,(Utf8NoBom)) }
function CopyDir([string]$src,[string]$dst){
  if(-not (Test-Path -LiteralPath $src -PathType Container)){ Die ("MISSING_SRC_DIR: " + $src) }
  if(Test-Path -LiteralPath $dst){ Die ("DEST_ALREADY_EXISTS: " + $dst) }
  EnsureDir $dst
  $items = @(@(Get-ChildItem -LiteralPath $src -Recurse -Force -ErrorAction Stop | Sort-Object FullName))
  foreach($it in @($items)){
    $rel = $it.FullName.Substring($src.Length).TrimStart("\","/")
    $out = Join-Path $dst $rel
    if($it.PSIsContainer){ EnsureDir $out; continue }
    $od = Split-Path -Parent $out; if($od){ EnsureDir $od }
    Copy-Item -LiteralPath $it.FullName -Destination $out -Force
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ Die ("MISSING_REPO_ROOT: " + $RepoRoot) }
$SourcePacketRoot = (Resolve-Path -LiteralPath $SourcePacketRoot).Path
if(-not (Test-Path -LiteralPath $SourcePacketRoot -PathType Container)){ Die ("MISSING_SOURCE_PACKET: " + $SourcePacketRoot) }

$vecRoot = Join-Path $RepoRoot "test_vectors\nfl_packet_verify_v1"
$posDir  = Join-Path $vecRoot "positive"
$negDir  = Join-Path $vecRoot "negative"
EnsureDir $posDir
EnsureDir $negDir

$packetId = Split-Path -Leaf $SourcePacketRoot
if([string]::IsNullOrWhiteSpace($packetId)){ Die "EMPTY_PACKET_ID_FROM_SOURCE" }
$posPacket = Join-Path $posDir ("packet_" + $packetId)
if(-not (Test-Path -LiteralPath $posPacket -PathType Container)){
  CopyDir $SourcePacketRoot $posPacket
  Write-Host ("FROZE_POSITIVE: " + $posPacket) -ForegroundColor Green
} else {
  Write-Host ("NOOP: positive already exists: " + $posPacket) -ForegroundColor Yellow
}

# Negative 1: tamper payload\sig_envelope.json (sha256 mismatch)
$neg1 = Join-Path $negDir ("tamper_payload_" + $packetId)
if(-not (Test-Path -LiteralPath $neg1 -PathType Container)){
  CopyDir $posPacket $neg1
  $tgt = Join-Path $neg1 "payload\sig_envelope.json"
  if(-not (Test-Path -LiteralPath $tgt -PathType Leaf)){ Die ("NEG1_MISSING_TARGET: " + $tgt) }
  $orig = [System.IO.File]::ReadAllText($tgt,(Utf8NoBom))
  $mut  = (CanonLf $orig) + "`n#tamper`n"
  [System.IO.File]::WriteAllText($tgt,$mut,(Utf8NoBom))
  Write-Host ("FROZE_NEG: " + $neg1 + " (tampered payload)") -ForegroundColor DarkYellow
} else { Write-Host ("NOOP: neg1 exists: " + $neg1) -ForegroundColor Yellow }

# Negative 2: delete signatures\ingest.sig (missing sig)
$neg2 = Join-Path $negDir ("missing_sig_" + $packetId)
if(-not (Test-Path -LiteralPath $neg2 -PathType Container)){
  CopyDir $posPacket $neg2
  $sig = Join-Path $neg2 "signatures\ingest.sig"
  if(Test-Path -LiteralPath $sig -PathType Leaf){ Remove-Item -LiteralPath $sig -Force }
  Write-Host ("FROZE_NEG: " + $neg2 + " (missing signatures\ingest.sig)") -ForegroundColor DarkYellow
} else { Write-Host ("NOOP: neg2 exists: " + $neg2) -ForegroundColor Yellow }

# Negative 3: wrong namespace (ssh-keygen verify must fail)
$neg3 = Join-Path $negDir ("wrong_namespace_" + $packetId)
if(-not (Test-Path -LiteralPath $neg3 -PathType Container)){
  CopyDir $posPacket $neg3
  Write-Host ("FROZE_NEG: " + $neg3 + " (use bad namespace at verify time)") -ForegroundColor DarkYellow
} else { Write-Host ("NOOP: neg3 exists: " + $neg3) -ForegroundColor Yellow }

# Suite descriptor (deterministic JSON)
$suite = [pscustomobject]@{
  schema = "nfl.packet_verify.suite.v1"
  created_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
  packet_id = $packetId
  positive = [pscustomobject]@{ packet_root = $posPacket; sig_namespace = $SigNamespaceGood; expect = "ok" }
  negatives = @(
    [pscustomobject]@{ name="tamper_payload"; packet_root=$neg1; sig_namespace=$SigNamespaceGood; expect="SHA256_MISMATCH" },
    [pscustomobject]@{ name="missing_sig";   packet_root=$neg2; sig_namespace=$SigNamespaceGood; expect="MISSING_SIG" },
    [pscustomobject]@{ name="wrong_namespace"; packet_root=$neg3; sig_namespace=$SigNamespaceBad; expect="SIG_VERIFY_FAIL" }
  )
}
$suitePath = Join-Path $vecRoot "suite.json"
$json = ($suite | ConvertTo-Json -Compress)
WriteUtf8NoBomLf $suitePath $json
Write-Host ("WROTE_SUITE: " + $suitePath) -ForegroundColor Green
Write-Host "FREEZE_OK" -ForegroundColor Green

# Emit path for callers
$suitePath
