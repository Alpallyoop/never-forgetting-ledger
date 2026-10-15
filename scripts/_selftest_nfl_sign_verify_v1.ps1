param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $root "scripts"

$mk = Join-Path $ScriptsDir "make_allowed_signers_v1.ps1"
if (Test-Path -LiteralPath $mk -PathType Leaf) {
  Write-Output "RUN: make_allowed_signers_v1.ps1"
  & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $mk -Root $root | Out-Null
} else {
  Write-Output "SKIP: make_allowed_signers_v1.ps1 not present"
}

$payload = Join-Path $root "proofs\_tmp_selftest_payload.txt"
$sig     = Join-Path $root "proofs\_tmp_selftest_payload.sig"
"selftest " + (Get-Date).ToUniversalTime().ToString("o") | Set-Content -LiteralPath $payload -Encoding UTF8

$ns   = "nfl/selftest"
$sign = Join-Path $ScriptsDir "sign_file_v1.ps1"
$ver  = Join-Path $ScriptsDir "verify_sig_v1.ps1"
if (-not (Test-Path -LiteralPath $sign -PathType Leaf)) { Die ("Missing sign script: " + $sign) }
if (-not (Test-Path -LiteralPath $ver  -PathType Leaf)) { Die ("Missing verify script: " + $ver) }

Write-Output "RUN: sign_file_v1.ps1"
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $sign -RepoRoot $root -Namespace $ns -File $payload -OutSig $sig | Out-Null

Write-Output "RUN: verify_sig_v1.ps1"
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $ver -RepoRoot $root -Namespace $ns -File $payload -Sig $sig | Out-Null

Write-Output "PASS: NFL SIGN/VERIFY SELFTEST v1"
