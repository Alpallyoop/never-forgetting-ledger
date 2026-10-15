param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot,
  [Parameter(Mandatory=$true)]
  [string]$InputDir,
  [Parameter(Mandatory=$true)]
  [string]$OutDir,
  [Parameter(Mandatory=$false)]
  [string]$CprRepoRoot = $env:NFL_CPR_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

& (Join-Path $RepoRoot "scripts\nfl_build_packet_with_cpr_v1.ps1") `
  -RepoRoot $RepoRoot `
  -InputDir $InputDir `
  -OutDir $OutDir `
  -CprRepoRoot $CprRepoRoot

exit $LASTEXITCODE
