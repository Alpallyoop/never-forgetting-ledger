<#
  nfl_ingest_control_v1.ps1 -- control the inbox-ingest schedule.

  start | stop | status : the Windows scheduled task "NFL_Ingest_Inboxes_v1" (nfl_install_ingest_task_v1.ps1).
  run-once              : trigger the scheduled task; when there is no scheduler (Linux) or no task, run the
                          ingest directly in this process tree and say so (NFL_INGEST_RAN_DIRECT REASON=...).
  Where the scheduler does not exist, status reports STATE=UNAVAILABLE and start/stop fail closed.
#>
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("start","stop","run-once","status")]
  [string]$Action,
  [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")

function Fail([string]$m){ throw ("NFL_INGEST_CONTROL_FAIL:" + $m) }

$RepoRoot = Resolve-NflRepoRoot $RepoRoot
$TaskName = "NFL_Ingest_Inboxes_v1"
$schedulerAvailable = [bool](Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)
$task = $null
if($schedulerAvailable){ try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { $task = $null } }

function Invoke-Direct([string]$reason){
  $r = Invoke-NflScript (Join-NflPath $RepoRoot "scripts" "nfl_ingest_inboxes_v1.ps1") @("-RepoRoot",$RepoRoot) $RepoRoot
  Write-Output ("NFL_INGEST_RAN_DIRECT REASON=" + $reason)
  Write-Output $r.StdOut.TrimEnd()
  if($r.ExitCode -ne 0){ Write-Output $r.StdErr.TrimEnd(); Fail ("DIRECT_RUN_EXIT_" + $r.ExitCode) }
}

switch($Action){
  "start" {
    if(-not $schedulerAvailable){ Fail "SCHEDULER_UNAVAILABLE" }
    if($null -eq $task){ Fail ("TASK_MISSING:" + $TaskName) }
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Output "NFL_INGEST_STARTED"
  }
  "stop" {
    if(-not $schedulerAvailable){ Fail "SCHEDULER_UNAVAILABLE" }
    if($null -eq $task){ Fail ("TASK_MISSING:" + $TaskName) }
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Output "NFL_INGEST_STOPPED"
  }
  "run-once" {
    if(-not $schedulerAvailable){ Invoke-Direct "SCHEDULER_UNAVAILABLE" }
    elseif($null -eq $task){ Invoke-Direct "TASK_MISSING" }
    else { Start-ScheduledTask -TaskName $TaskName; Write-Output "NFL_INGEST_TRIGGERED" }
  }
  "status" {
    if(-not $schedulerAvailable){ Write-Output "STATE=UNAVAILABLE"; Write-Output "REASON=SCHEDULER_UNAVAILABLE" }
    elseif($null -eq $task){ Write-Output "STATE=TASK_MISSING" }
    else { $fresh = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop; Write-Output ("STATE=" + $fresh.State) }
  }
}
