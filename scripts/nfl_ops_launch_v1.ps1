<#
  nfl_ops_launch_v1.ps1 -- one-click local operations: start the NFL API and open NFL Explorer.

  -RepoRoot      NFL repository (default: this script's repository)
  -ExplorerRoot  NFL Explorer repository (default: the sibling ..\nfl-explorer)
  -ApiPrefix     loopback prefix for the API (default http://127.0.0.1:8086/)
  -Browser       open the explorer as a web page (npm run dev) instead of the desktop app (npm run desktop)
  The explorer only talks to NFL through this API (NFL_API_BASE); it never touches the ledger files.
#>
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExplorerRoot = "",
  [string]$ApiPrefix = "http://127.0.0.1:8086/",
  [switch]$Browser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if([string]::IsNullOrWhiteSpace($ExplorerRoot)){ $ExplorerRoot = Join-Path (Split-Path -Parent $RepoRoot) "nfl-explorer" }
$PSExe = (Get-Process -Id $PID).Path
$ApiScript = Join-Path $RepoRoot "scripts\nfl_api_v1.ps1"

if(-not (Test-Path -LiteralPath $ApiScript)){ throw "NFL_OPS_LAUNCH_FAIL:MISSING_API_SCRIPT:$ApiScript" }
if(-not (Test-Path -LiteralPath (Join-Path $ExplorerRoot "package.json"))){ throw "NFL_OPS_LAUNCH_FAIL:MISSING_EXPLORER:$ExplorerRoot" }

Start-Process -WindowStyle Hidden -FilePath $PSExe -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass",
  "-File", "`"$ApiScript`"",
  "-RepoRoot", "`"$RepoRoot`"",
  "-Prefix", "`"$ApiPrefix`""
)
Start-Sleep -Seconds 2

$env:NFL_API_BASE = $ApiPrefix.TrimEnd("/")
$script = if($Browser){ "dev" } else { "desktop" }
Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList @("/c","cd /d `"$ExplorerRoot`" && npm run $script")
if($Browser){ Start-Sleep -Seconds 3; Start-Process "http://localhost:5173/" }

Write-Output "NFL_OPS_LAUNCH_OK"
Write-Output ("API=" + $ApiPrefix)
Write-Output ("EXPLORER=" + $ExplorerRoot + " (npm run " + $script + ")")
