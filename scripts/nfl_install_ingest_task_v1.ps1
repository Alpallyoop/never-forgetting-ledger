param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_INSTALL_TASK_FAIL:" + $m) }

function Ensure-Dir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $u = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($u))
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$TaskName   = "NFL_Ingest_Inboxes_v1"
$PSExe      = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$SchTasks   = "$env:WINDIR\System32\schtasks.exe"
$WScriptExe = "$env:WINDIR\System32\wscript.exe"
$Runner     = Join-Path $RepoRoot "scripts\nfl_ingest_inboxes_v1.ps1"

if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Fail ("RUNNER_MISSING:" + $Runner) }
if(-not (Test-Path -LiteralPath $PSExe -PathType Leaf)){ Fail ("PSEXE_MISSING:" + $PSExe) }
if(-not (Test-Path -LiteralPath $SchTasks -PathType Leaf)){ Fail ("SCHTASKS_MISSING:" + $SchTasks) }
if(-not (Test-Path -LiteralPath $WScriptExe -PathType Leaf)){ Fail ("WSCRIPT_MISSING:" + $WScriptExe) }

$RuntimeDir = Join-Path $RepoRoot "runtime\scheduler"
Ensure-Dir $RuntimeDir

$VbsPath = Join-Path $RuntimeDir "run_ingest_hidden.vbs"

$vbsLines = @(
  'Set oShell = CreateObject("WScript.Shell")',
  'q = Chr(34)',
  ('cmd = q & "{0}" & q & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & "{1}" & q & " -RepoRoot " & q & "{2}" & q' -f $PSExe,$Runner,$RepoRoot),
  'oShell.Run cmd, 0, False'
)

Write-Utf8NoBomLf $VbsPath ([string]::Join("`n",$vbsLines))

try {
  $null = & $SchTasks /Delete /TN "$TaskName" /F 2>&1
} catch {
}

$TaskCmd = '"' + $WScriptExe + '" "' + $VbsPath + '"'
$ArgsLine = '/Create /SC MINUTE /MO 1 /TN "' + $TaskName + '" /TR "' + $TaskCmd + '" /F'

$proc = Start-Process -FilePath $SchTasks `
  -ArgumentList $ArgsLine `
  -NoNewWindow `
  -Wait `
  -PassThru

if($proc.ExitCode -ne 0){
  Fail ("CREATE_FAILED:" + $proc.ExitCode)
}

$verify = & $SchTasks /Query /TN "$TaskName" 2>&1
if(-not $verify){ Fail "TASK_NOT_FOUND" }

Write-Output "NFL_INSTALL_INGEST_TASK_OK"
Write-Output ("TASK_NAME=" + $TaskName)
Write-Output ("WRAPPER=" + $VbsPath)
Write-Output ("TASK_CMD=" + $TaskCmd)