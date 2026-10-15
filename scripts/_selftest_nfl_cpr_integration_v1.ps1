param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot,
  [Parameter(Mandatory=$false)]
  [string]$CprRepoRoot = $env:NFL_CPR_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$CprRepoRoot = [System.IO.Path]::GetFullPath($CprRepoRoot)

function Fail([string]$Code) {
  Write-Host ("NFL_CPR_SELFTEST_FAIL:" + $Code) -ForegroundColor Red
  exit 1
}

function Parse-GateFile([string]$Path) {
  $Tok = $null
  $Err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tok,[ref]$Err)
  if ($Err -and $Err.Count -gt 0) {
    $E = $Err[0]
    throw ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$E.Extent.StartLineNumber,$E.Extent.StartColumnNumber,$E.Message)
  }
}

try {
  Parse-GateFile (Join-Path $RepoRoot "scripts\nfl_build_packet_with_cpr_v1.ps1")
  Parse-GateFile (Join-Path $RepoRoot "scripts\nfl_verify_packet_with_cpr_v1.ps1")
  Parse-GateFile (Join-Path $RepoRoot "scripts\nfl_packet_build_entry_v1.ps1")
  Parse-GateFile (Join-Path $RepoRoot "scripts\nfl_packet_verify_entry_v1.ps1")
  Parse-GateFile (Join-Path $CprRepoRoot "cli\cpr.ps1")

  $InputDir = Join-Path $RepoRoot "proofs\_nfl_cpr_selftest_input"
  $OutDir = Join-Path $RepoRoot "proofs\_nfl_cpr_selftest_outbox"
  $ReceiptPath = Join-Path $RepoRoot "proofs\receipts\nfl.cpr.ndjson"

  if (Test-Path -LiteralPath $InputDir) {
    Remove-Item -LiteralPath $InputDir -Recurse -Force
  }
  if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
  }

  New-Item -ItemType Directory -Path $InputDir -Force | Out-Null

  $Enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText(
    (Join-Path $InputDir "hello.txt"),
    "nfl cpr selftest`n",
    $Enc
  )

  $PSExe = (Get-Process -Id $PID).Path

  $BuildOutput = & $PSExe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File (Join-Path $RepoRoot "scripts\nfl_packet_build_entry_v1.ps1") `
    -RepoRoot $RepoRoot `
    -InputDir $InputDir `
    -OutDir $OutDir `
    -CprRepoRoot $CprRepoRoot 2>&1

  $BuildExit = $LASTEXITCODE
  $BuildText = (($BuildOutput | ForEach-Object { $_.ToString() }) -join "`n")

  if ($BuildExit -ne 0) {
    $BuildText | Out-Host
    Fail "BUILD_EXIT_NONZERO"
  }
  if ($BuildText -notmatch 'NFL_CPR_BUILD_OK') {
    $BuildText | Out-Host
    Fail "BUILD_TOKEN_MISSING"
  }

  $PacketDir = Get-ChildItem -LiteralPath $OutDir -Directory | Select-Object -First 1 -ExpandProperty FullName
  if ([string]::IsNullOrWhiteSpace($PacketDir)) {
    Fail "PACKET_DIR_NOT_CREATED"
  }

  $VerifyOutput = & $PSExe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File (Join-Path $RepoRoot "scripts\nfl_packet_verify_entry_v1.ps1") `
    -RepoRoot $RepoRoot `
    -PacketPath $PacketDir `
    -CprRepoRoot $CprRepoRoot 2>&1

  $VerifyExit = $LASTEXITCODE
  $VerifyText = (($VerifyOutput | ForEach-Object { $_.ToString() }) -join "`n")

  if ($VerifyExit -ne 0) {
    $VerifyText | Out-Host
    Fail "VERIFY_EXIT_NONZERO"
  }
  if ($VerifyText -notmatch 'NFL_CPR_VERIFY_OK') {
    $VerifyText | Out-Host
    Fail "VERIFY_TOKEN_MISSING"
  }

  if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    Fail "RECEIPT_LOG_MISSING"
  }

  $ReceiptText = [System.IO.File]::ReadAllText($ReceiptPath)
  if ($ReceiptText -notmatch '"delegated_to":"CPR"') {
    Fail "DELEGATION_RECEIPT_MISSING"
  }

  Write-Host "NFL_CPR_SELFTEST_OK" -ForegroundColor Green
  exit 0
}
catch {
  Write-Host ("NFL_CPR_SELFTEST_FAIL:UNHANDLED:" + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
