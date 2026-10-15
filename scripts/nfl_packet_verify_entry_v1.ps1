param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot,
  [Parameter(Mandatory=$true)]
  [string]$PacketPath,
  [Parameter(Mandatory=$false)]
  [string]$CprRepoRoot = $env:NFL_CPR_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

& (Join-Path $RepoRoot "scripts\nfl_verify_packet_with_cpr_v1.ps1") `
  -RepoRoot $RepoRoot `
  -PacketPath $PacketPath `
  -CprRepoRoot $CprRepoRoot

exit $LASTEXITCODE
