<#
  _RUN_nfl_selftests_v1.ps1 -- every NFL self-test in one command, on Windows PowerShell 5.1 or PowerShell 7
  (Windows or Linux). Fail-closed; each stage must exit 0 AND print its OK token. Temp folders only; the
  real ledger is read (verify-chain), never written. No scheduler, no git, no network.

    parse gate (all operational scripts)       selfchain 6/6      checkpoint 5/5     seal 9/9
    receipts + ingest 37/37 (needs CPR)        API 19/19          portable export 9/9 (python3/python)
    receipt-head 9/9 (proposal 0003)
    real ledger: embedded chain verifies

  -CprRoot / NFL_CPR_ROOT locate CPR; otherwise the sibling ../cpr is used. Emits NFL_SELFTESTS_ALL_OK.
#>
param([string]$RepoRoot = "",[string]$CprRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")
. (Join-Path $PSScriptRoot "_nfl_paths_v1.ps1")

function Fail([string]$m){ Write-Output ("NFL_SELFTESTS_FAIL:" + $m); exit 1 }
$RepoRoot = Resolve-NflRepoRoot $RepoRoot
$S = $PSScriptRoot

Write-Output "== parse gate"
$canon = @("_lib_nfl_v1.ps1","_nfl_paths_v1.ps1","nfl_cli_v1.ps1","nfl_api_v1.ps1","nfl_ingest_inboxes_v1.ps1","nfl_ingest_control_v1.ps1",
  "nfl_witness_cpr_verify_v1.ps1","nfl_ledger_checkpoint_v1.ps1","nfl_ledger_seal_v1.ps1","nfl_ledger_verify_chain_v1.ps1","nfl_ledger_export_v1.ps1",
  "nfl_export_ledger_packet_v1.ps1","nfl_sign_ledger_packet_v1.ps1","nfl_install_ingest_task_v1.ps1","nfl_ops_launch_v1.ps1","nfl.ps1",
  "_selftest_nfl_ledger_selfchain_v1.ps1","_selftest_nfl_ledger_checkpoint_v1.ps1","_selftest_nfl_ledger_seal_v1.ps1",
  "_selftest_nfl_receipts_ingest_v1.ps1","_selftest_nfl_receipt_head_v1.ps1","_selftest_nfl_api_v1.ps1","_RUN_nfl_durable_ledger_green_v1.ps1","_RUN_nfl_apply_all_v1.ps1")
foreach($f in $canon){
  $p = Join-NflPath $S $f
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Fail ("PARSEGATE_MISSING:" + $f) }
  $tok = $null; $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err)
  if($err -and @($err).Count -gt 0){ Fail ("PARSEGATE:" + $f + ":" + (@($err)[0].ToString())) }
}
Write-Output ("  OK " + $canon.Count + " scripts")

$stages = @(
  @{ n="SELFCHAIN";  f="_selftest_nfl_ledger_selfchain_v1.ps1";  a=@("-RepoRoot",$RepoRoot); t="NFL_LEDGER_SELFCHAIN_SELFTEST_OK" },
  @{ n="CHECKPOINT"; f="_selftest_nfl_ledger_checkpoint_v1.ps1"; a=@("-RepoRoot",$RepoRoot); t="NFL_LEDGER_SELFTEST_OK" },
  @{ n="SEAL";       f="_selftest_nfl_ledger_seal_v1.ps1";       a=@("-RepoRoot",$RepoRoot); t="NFL_LEDGER_SEAL_SELFTEST_OK" },
  @{ n="API";        f="_selftest_nfl_api_v1.ps1";               a=@("-RepoRoot",$RepoRoot); t="NFL_API_SELFTEST_OK" },
  @{ n="RECEIPT_HEAD"; f="_selftest_nfl_receipt_head_v1.ps1";    a=@("-RepoRoot",$RepoRoot); t="NFL_RECEIPT_HEAD_SELFTEST_OK" }
)
$cpr = Resolve-NflCprRoot $RepoRoot $CprRoot
if($null -eq $cpr){ Fail "CPR_NOT_FOUND (receipts+ingest selftest needs CPR; set NFL_CPR_ROOT or -CprRoot)" }
$stages += @{ n="RECEIPTS_INGEST"; f="_selftest_nfl_receipts_ingest_v1.ps1"; a=@("-RepoRoot",$RepoRoot,"-CprRoot",$cpr); t="NFL_RECEIPTS_INGEST_SELFTEST_OK" }

foreach($st in $stages){
  Write-Output ("== " + $st.n)
  $r = Invoke-NflScript (Join-NflPath $S $st.f) $st.a $RepoRoot
  $res = @($r.StdOut -split "`n" | Where-Object { $_ -match '^RESULT=' }) -join ""
  if(($r.ExitCode -ne 0) -or ($r.StdOut -notmatch [regex]::Escape($st.t))){
    Write-Output $r.StdOut; Write-Output $r.StdErr
    Fail $st.n
  }
  Write-Output ("  OK " + $res)
}

Write-Output "== EXPORT (python)"
$py = Get-Command @("python3","python") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if($null -eq $py){ Fail "PYTHON_NOT_FOUND (portable export verifier needs python3)" }
$r = Invoke-NflChild $py.Source @((Join-NflPath $S "_selftest_nfl_export_v1.py")) $RepoRoot
if(($r.ExitCode -ne 0) -or ($r.StdOut -notmatch 'NFL_EXPORT_SELFTEST_OK')){ Write-Output ($r.StdOut + $r.StdErr); Fail "EXPORT" }
Write-Output ("  OK " + (@($r.StdOut -split "`n" | Where-Object { $_ -match '^RESULT=' }) -join ""))

Write-Output "== REAL LEDGER (read-only)"
$c = Test-NflLedgerChain $RepoRoot
if(-not $c.Ok){ Fail ("REAL_LEDGER_CHAIN:" + $c.Error) }
Write-Output ("  OK count=" + $c.Count + " unchained_prefix=" + $c.UnchainedPrefix + " chained=" + $c.ChainedCount)
$rcp = Test-NflReceiptChain $RepoRoot
if(-not $rcp.Ok){ Fail ("REAL_RECEIPT_CHAIN:" + $rcp.Error) }
Write-Output ("  OK nfl.receipt.v1 receipts=" + $rcp.Count)

Write-Output "NFL_SELFTESTS_ALL_OK"
exit 0
