param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = "C:\dev\nfl",
  [Parameter(Mandatory=$false)][string]$PacketRoot = "C:\covenant_inbox\0537effea5f535d061b313f72e37ca52d4a34fff00865066c51fa7dff410618a",
  [Parameter(Mandatory=$false)][string]$SigNamespace = "covenant-nfl"
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw ("NFL_SELFTEST_FAIL: " + $m) }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ return (New-Object System.Text.UTF8Encoding($false)) }
function CanonLf([string]$s){ return $s.Replace("`r`n","`n").Replace("`r","`n") }
function AppendUtf8NoBomLf([string]$Path,[string]$Line){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $t = CanonLf $Line
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  [System.IO.File]::AppendAllText($Path,$t,(Utf8NoBom))
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ Die ("MISSING_REPO_ROOT: " + $RepoRoot) }
$verify = Join-Path $RepoRoot "scripts\verify_packet_v1.ps1"
if(-not (Test-Path -LiteralPath $verify -PathType Leaf)){ Die ("MISSING_VERIFY: " + $verify) }
if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ Die ("MISSING_PACKET_ROOT: " + $PacketRoot) }

Write-Host ("SELFTEST_PACKET: " + $PacketRoot) -ForegroundColor Cyan
Write-Host ("SELFTEST_NAMESPACE: " + $SigNamespace) -ForegroundColor Cyan

# run verifier IN-PROCESS (no child PS serialization)
$res = & $verify -PacketRoot $PacketRoot -SigNamespace $SigNamespace
if(-not $res){ Die "VERIFY_RETURNED_NO_OUTPUT" }
$obj = $null
foreach($x in @(@($res))){ if($x -ne $null -and ($x.PSObject.Properties.Name -contains "ok")){ $obj = $x } }
if($obj -eq $null){ Die "VERIFY_DID_NOT_EMIT_RESULT_OBJECT_WITH_OK" }
if(-not [bool]$obj.ok){ Die "VERIFY_RESULT_NOT_OK" }

# append packet.verify.v1 receipt
$receiptPath = Join-Path $RepoRoot "proofs\receipts\nfl_verify_v1.ndjson"
$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$rec = [pscustomobject]@{
  ts = $ts
  event = "packet.verify.v1"
  status = "ok"
  packet_root = [string]$obj.packet_root
  sig_namespace = [string]$obj.sig_namespace
  principal = [string]$obj.principal
  sha256_entries = $obj.sha256_entries
  signature_path = [string]$obj.signature_path
  signed_target = [string]$obj.signed_target
  signer_pub = [string]$obj.signer_pub
  signer_key_hash = [string]$obj.signer_key_hash
}
$json = ($rec | ConvertTo-Json -Compress)
AppendUtf8NoBomLf $receiptPath $json
Write-Host ("RECEIPT_APPEND_OK: " + $receiptPath) -ForegroundColor Green
Write-Host "SELFTEST_OK" -ForegroundColor Green
