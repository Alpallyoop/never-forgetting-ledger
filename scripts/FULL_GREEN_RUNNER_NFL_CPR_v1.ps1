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
  Write-Host ("NFL_CPR_FULL_GREEN_FAIL:" + $Code) -ForegroundColor Red
  exit 1
}

try {
  $PSExe = (Get-Process -Id $PID).Path

  $Output = & $PSExe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File (Join-Path $RepoRoot "scripts\_selftest_nfl_cpr_integration_v1.ps1") `
    -RepoRoot $RepoRoot `
    -CprRepoRoot $CprRepoRoot 2>&1

  $ExitCode = $LASTEXITCODE
  $OutputText = (($Output | ForEach-Object { $_.ToString() }) -join "`n")

  if ($ExitCode -ne 0) {
    $OutputText | Out-Host
    Fail "SELFTEST_EXIT_NONZERO"
  }

  if ($OutputText -notmatch 'NFL_CPR_SELFTEST_OK') {
    $OutputText | Out-Host
    Fail "SELFTEST_TOKEN_MISSING"
  }

  Write-Host "NFL_CPR_FULL_GREEN_OK" -ForegroundColor Green
  exit 0
}
catch {
  Write-Host ("NFL_CPR_FULL_GREEN_FAIL:UNHANDLED:" + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
