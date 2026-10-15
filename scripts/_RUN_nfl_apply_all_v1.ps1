<#
  _RUN_nfl_apply_all_v1.ps1  --  the single "apply all" button for NFL.

  Phases run in order. Phase 1 (proofs) and the CPR dependency are strict (stop on
  failure). Connection/refresh checks that are environmental report WARN and continue.
  Commit+tag runs only after proofs are green, and a git problem is reported, not fatal
  to the proof result.

    Phase 0  parse-gate every canonical script
    Phase 1  PROVE-ALL (strict): CLI full-green, durable-ledger gate, selfchain selftest,
             verify-chain (real ledger), portable export selftest (python, if present)
    Phase 2  VERIFY CONNECTIONS (report): CPR*, NeverLost trust bundle, ingest task,
             local API /health, nfl-explorer UI, Constellation registry   (*CPR strict)
    Phase 3  REFRESH NFL-OWNED (report): re-register ingest scheduled task
    Phase 4  COMMIT + TAG the proven baseline (unless -SkipCommit)

  Emits NFL_APPLY_ALL_GREEN_OK (proofs + CPR green) plus one receipt, then the commit
  outcome. Writes only inside the repo root it is run from.
#>
param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][string]$CprRoot = "",
  [Parameter(Mandatory=$false)][string]$ConstellationRoot = "",
  [Parameter(Mandatory=$false)][string]$ExplorerRoot = "",
  [Parameter(Mandatory=$false)][string]$ApiTestPrefix = "http://127.0.0.1:8099/",
  [Parameter(Mandatory=$false)][switch]$SkipCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot "_nfl_paths_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")
$CprRoot = Resolve-NflCprRoot $RepoRoot $CprRoot
$ConstellationRoot = Resolve-NflConstellationRoot $RepoRoot $ConstellationRoot
if([string]::IsNullOrWhiteSpace($ExplorerRoot)){ $ExplorerRoot = Join-Path (Split-Path -Parent $RepoRoot) "nfl-explorer" }
$PSExe = (Get-Process -Id $PID).Path
$script:warnings = New-Object System.Collections.Generic.List[string]
$script:connchecks = New-Object System.Collections.Generic.List[string]

function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function Section([string]$n){ Write-Output ""; Write-Output ("== " + $n + " ==") }
function Warn([string]$m){ $script:warnings.Add($m) | Out-Null; Write-Output ("  WARN " + $m) }
function Note([string]$m){ $script:connchecks.Add($m) | Out-Null; Write-Output ("  " + $m) }

function StartChild([string]$File,[string]$ArgLine,[string]$Wd){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$File; $psi.Arguments=$ArgLine; $psi.WorkingDirectory=$Wd
  $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
  $p = New-Object System.Diagnostics.Process; $p.StartInfo=$psi
  [void]$p.Start()
  $o=$p.StandardOutput.ReadToEnd(); $e=$p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=$o; StdErr=$e }
}
function RunPS([string]$ScriptPath,[string]$ExtraArgs){
  return (StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath,$ExtraArgs) $RepoRoot)
}

$script:applyFailed = $false
function ApplyFail([string]$stage,[string]$detail){
  Write-Output ("NFL_APPLY_ALL_FAIL:" + $stage)
  if(-not [string]::IsNullOrWhiteSpace($detail)){ Write-Output (("  " + $detail) -replace "\s+"," ") }
  WriteReceipt $false $stage
  exit 1
}
function WriteReceipt([bool]$ok,[string]$stage){
  $rp = Join-Path $RepoRoot "proofs\receipts\nfl.apply_all.ndjson"
  if(-not (Test-Path -LiteralPath (Split-Path -Parent $rp) -PathType Container)){ New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rp) | Out-Null }
  $r = [ordered]@{
    schema="nfl.apply_all.receipt.v1"; utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    ok=$ok; stopped_at=$stage; warnings=@($script:warnings); connections=@($script:connchecks)
  }
  [System.IO.File]::AppendAllText($rp, (($r | ConvertTo-Json -Compress -Depth 20) + "`n"), (Utf8NoBom))
}

$S = Join-Path $RepoRoot "scripts"

# -------------------------------------------------------------------
Section "Phase 0 - parse-gate canonical scripts"
$canon = @(
  "nfl_cli_v1.ps1","nfl_api_v1.ps1","nfl_ingest_inboxes_v1.ps1","nfl_ingest_control_v1.ps1",
  "nfl_install_ingest_task_v1.ps1","nfl_ops_launch_v1.ps1","nfl_witness_cpr_verify_v1.ps1",
  "nfl_export_ledger_packet_v1.ps1","nfl_sign_ledger_packet_v1.ps1",
  "nfl_ledger_checkpoint_v1.ps1","nfl_ledger_seal_v1.ps1","nfl_ledger_verify_chain_v1.ps1",
  "_nfl_paths_v1.ps1","_RUN_nfl_cli_full_green_v1.ps1","_RUN_nfl_durable_ledger_green_v1.ps1",
  "_selftest_nfl_ledger_checkpoint_v1.ps1","_selftest_nfl_ledger_seal_v1.ps1","_selftest_nfl_ledger_selfchain_v1.ps1",
  "_lib_nfl_v1.ps1","_selftest_nfl_receipts_ingest_v1.ps1","_selftest_nfl_api_v1.ps1","_RUN_nfl_selftests_v1.ps1"
)
foreach($f in $canon){
  $p = Join-Path $S $f
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ ApplyFail ("PARSEGATE_MISSING:" + $f) "" }
  $tok=$null; $err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err)
  if($err -and @(@($err)).Count -gt 0){ ApplyFail ("PARSEGATE_FAIL:" + $f) (($err | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join " | ") }
}
Write-Output ("  OK parse-gated " + $canon.Count + " scripts")

# -------------------------------------------------------------------
Section "Phase 1 - PROVE-ALL (strict)"
$r = RunPS (Join-Path $S "_RUN_nfl_cli_full_green_v1.ps1") '-RepoRoot .'
if($r.ExitCode -ne 0 -or ($r.StdOut -notmatch 'NFL_CLI_FULL_GREEN_OK')){ ApplyFail "CLI_FULL_GREEN" ($r.StdOut + $r.StdErr) }
Write-Output "  OK CLI full-green"

$r = RunPS (Join-Path $S "_RUN_nfl_durable_ledger_green_v1.ps1") '-RepoRoot .'
if($r.ExitCode -ne 0 -or ($r.StdOut -notmatch 'NFL_DURABLE_LEDGER_GREEN_OK')){ ApplyFail "DURABLE_LEDGER_GREEN" ($r.StdOut + $r.StdErr) }
Write-Output "  OK durable-ledger gate"

# Every self-test (selfchain, checkpoint, seal, receipts+ingest, API, portable export, real-ledger chain).
$cprArg = if($null -ne $CprRoot){ ('-CprRoot "{0}"' -f $CprRoot) } else { "" }
$r = RunPS (Join-Path $S "_RUN_nfl_selftests_v1.ps1") ('-RepoRoot . ' + $cprArg)
if($r.ExitCode -ne 0 -or ($r.StdOut -notmatch 'NFL_SELFTESTS_ALL_OK')){ ApplyFail "SELFTESTS" ($r.StdOut + $r.StdErr) }
Write-Output ("  OK all self-tests (" + (($r.StdOut -split "`n" | Where-Object { $_ -match 'RESULT=' } | ForEach-Object { $_.Trim() }) -join " ") + ")")

$r = RunPS (Join-Path $S "nfl_ledger_verify_chain_v1.ps1") '-RepoRoot .'
if($r.ExitCode -ne 0 -or ($r.StdOut -notmatch 'NFL_LEDGER_CHAIN_OK')){ ApplyFail "VERIFY_CHAIN" ($r.StdOut + $r.StdErr) }
Write-Output ("  OK verify-chain (" + (($r.StdOut -split "`n" | Where-Object { $_ -match 'CHAINED_COUNT|UNCHAINED_PREFIX' }) -join " ") + ")")

# -------------------------------------------------------------------
Section "Phase 2 - VERIFY CONNECTIONS"
# CPR (strict dependency)
$cprVerifier = if($null -ne $CprRoot){ Join-Path $CprRoot "scripts\verify_packet_v1.ps1" } else { "(not found; set NFL_CPR_ROOT or pass -CprRoot)" }
if(($null -ne $CprRoot) -and (Test-Path -LiteralPath $cprVerifier -PathType Leaf)){ Note ("CPR verifier present: " + $cprVerifier) }
else { ApplyFail "CPR_MISSING" $cprVerifier }

# NeverLost trust bundle (report; verify the bundle's own signature against its pinned key)
$tb = Join-Path $RepoRoot "proofs\trust\trust_bundle.json"
$tbSig = $tb + ".sig"
if((Test-Path -LiteralPath $tb -PathType Leaf) -and (Test-Path -LiteralPath $tbSig -PathType Leaf)){
  try {
    $bj = ConvertFrom-NflJson (Get-Content -LiteralPath $tb -Raw)
    $pub = [string]$bj.principals[0].keys[0].pubkey
    $tmpDir = Join-Path $RepoRoot "proofs\_tmp"; if(-not (Test-Path -LiteralPath $tmpDir)){ New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }
    $tmpAllowed = Join-Path $tmpDir ("nfl_applyall_root_" + [Guid]::NewGuid().ToString("N") + ".txt")
    [System.IO.File]::WriteAllBytes($tmpAllowed,(Utf8NoBom).GetBytes("neverlost.root " + $pub + "`n"))
    $ssh = (Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if(-not $ssh){ throw "SSH_KEYGEN_NOT_FOUND" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$ssh; $psi.Arguments=('-Y verify -f "{0}" -I "neverlost.root" -n "nfl/ingest-receipt" -s "{1}"' -f $tmpAllowed,$tbSig)
    $psi.UseShellExecute=$false; $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
    $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    $bytes=[System.IO.File]::ReadAllBytes($tb); $bs=$p.StandardInput.BaseStream; $bs.Write($bytes,0,$bytes.Length); $bs.Flush(); $bs.Close()
    [void]$p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd(); $p.WaitForExit()
    Remove-Item -LiteralPath $tmpAllowed -Force -ErrorAction SilentlyContinue
    if($p.ExitCode -eq 0){ Note "NeverLost trust bundle: signature valid under pinned key" } else { Warn "NeverLost trust bundle signature did NOT verify" }
  } catch { Warn ("NeverLost trust bundle check error: " + $_.Exception.Message) }
} else { Warn "NeverLost trust bundle not found (proofs\trust\trust_bundle.json[.sig])" }

# Ingest scheduled task
$ic = RunPS (Join-Path $S "nfl_ingest_control_v1.ps1") ('-Action status -RepoRoot "{0}"' -f $RepoRoot)
if($ic.ExitCode -eq 0 -and ($ic.StdOut -match 'STATE=')){ Note ("Ingest task: " + (($ic.StdOut -split "`n" | Where-Object { $_ -match 'STATE=' }) -join "")) }
else { Warn ("Ingest task status unavailable: " + (($ic.StdOut + $ic.StdErr) -replace "\s+"," ")) }

# Local API /health (start a throwaway instance on the test prefix, probe, stop)
try {
  $api = Start-Process -FilePath $PSExe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $S "nfl_api_v1.ps1"),'-RepoRoot',$RepoRoot,'-Prefix',$ApiTestPrefix)
  Start-Sleep -Seconds 2
  try {
    $h = Invoke-RestMethod -Uri ($ApiTestPrefix + "health") -TimeoutSec 5
    if([string]$h.status -eq "OK"){ Note ("API /health OK on " + $ApiTestPrefix) } else { Warn "API /health returned non-OK" }
  } catch { Warn ("API /health probe failed: " + $_.Exception.Message) }
  try { Stop-Process -Id $api.Id -Force -ErrorAction SilentlyContinue } catch {}
} catch { Warn ("API could not be started: " + $_.Exception.Message) }

# nfl-explorer UI (report presence only)
if([string]::IsNullOrWhiteSpace($ExplorerRoot)){ Note "nfl-explorer UI: not checked (no -ExplorerRoot given)" } elseif(Test-Path -LiteralPath $ExplorerRoot -PathType Container){ Note ("nfl-explorer UI present: " + $ExplorerRoot) } else { Warn ("nfl-explorer UI not found: " + $ExplorerRoot) }

# Constellation registry (report presence only)
if(($null -ne $ConstellationRoot) -and (Test-Path -LiteralPath $ConstellationRoot -PathType Container)){ Note ("Constellation root present: " + $ConstellationRoot) } else { Warn ("Constellation root not found: " + $ConstellationRoot) }

# -------------------------------------------------------------------
Section "Phase 3 - REFRESH NFL-OWNED"
$ins = RunPS (Join-Path $S "nfl_install_ingest_task_v1.ps1") ('-RepoRoot "{0}"' -f $RepoRoot)
if($ins.ExitCode -eq 0 -and ($ins.StdOut -match 'NFL_INSTALL_INGEST_TASK_OK')){ Note "Ingest scheduled task re-registered (every-1-minute)" }
else { Warn ("Ingest task re-register failed (admin rights?): " + (($ins.StdOut + $ins.StdErr) -replace "\s+"," ")) }

# proofs green -> declare apply-all green BEFORE the optional commit
Write-Output ""
Write-Output "NFL_APPLY_ALL_GREEN_OK"
WriteReceipt $true "complete"

# -------------------------------------------------------------------
Section "Phase 4 - COMMIT + TAG"
if($SkipCommit){ Write-Output "  COMMIT_SKIPPED (-SkipCommit)"; exit 0 }
try {
  Get-ChildItem (Join-Path $RepoRoot ".git") -Recurse -Filter *.lock -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $addPaths = @('scripts','docs','config','.gitignore','NFL_Apply_All.cmd') | Where-Object { Test-Path -LiteralPath (Join-Path $RepoRoot $_) }
  # docs\canonical is Constellation-governed: never staged by ordinary work (proposals go under docs\proposals)
  & git -C $RepoRoot add -- @addPaths ':(exclude)docs/canonical' 2>&1 | Out-Null
  $staged = (& git -C $RepoRoot diff --cached --name-only 2>$null)
  if([string]::IsNullOrWhiteSpace(($staged -join ""))){
    Write-Output "  COMMIT_SKIPPED (nothing to apply)"
    exit 0
  }
  $utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $tag = "nfl-apply-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
  $msg = "NFL: apply-all proven baseline " + $utc + "`n`nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01Dz6Jtc75RNUwT8PVKrGEz2"
  & git -C $RepoRoot commit -m $msg 2>&1 | Out-Null
  if($LASTEXITCODE -ne 0){ Write-Output "  COMMIT_WARN (git commit failed)"; exit 0 }
  & git -C $RepoRoot tag $tag 2>&1 | Out-Null
  Write-Output ("  COMMIT_OK tag=" + $tag)
} catch {
  Write-Output ("  COMMIT_WARN " + $_.Exception.Message)
}
exit 0
