<#
  _selftest_nfl_ledger_checkpoint_v1.ps1

  Negative proof for nfl_ledger_checkpoint_v1.ps1.
  Builds throwaway ledgers in a temp dir, runs the REAL checkpoint script
  against them, and asserts:

    CLEAN     : verify -> NFL_LEDGER_VERIFY_OK
    APPEND    : append a record -> verify OK, APPENDED_SINCE_CHECKPOINT=1
    TAMPER    : mutate a checkpointed record -> NFL_LEDGER_VERIFY_FAIL:PREFIX_TAMPERED
    TRUNCATE  : drop a checkpointed record  -> NFL_LEDGER_VERIFY_FAIL:LEDGER_TRUNCATED
    REORDER   : swap two checkpointed records -> NFL_LEDGER_VERIFY_FAIL:PREFIX_TAMPERED

  NEVER touches the real data\ledger.ndjson. Emits a selftest receipt.
#>

param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_LEDGER_SELFTEST_FAIL:" + $m) }

function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function WriteLedger([string]$Path,[string[]]$Records){
  $dir = Split-Path -Parent $Path
  EnsureDir $dir
  $text = ""
  foreach($r in $Records){ $text += ($r + "`n") }
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($text))
}

function Rec([string]$h,[string]$a,[string]$t){
  return ([ordered]@{ hash=$h; artifact=$a; timestamp=$t } | ConvertTo-Json -Compress)
}

function StartChild([string]$FileName,[string]$Arguments){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=$out; StdErr=$err }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe = (Get-Process -Id $PID).Path
$Script = Join-Path $RepoRoot "scripts\nfl_ledger_checkpoint_v1.ps1"
if(-not (Test-Path -LiteralPath $Script -PathType Leaf)){ Fail ("MISSING_SCRIPT:" + $Script) }

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$TmpRoot = Join-Path $RepoRoot ("proofs\_tmp\ledger_selftest_" + $RunId)
EnsureDir $TmpRoot

function RunMode([string]$CaseRoot,[string]$Mode){
  return (StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -Mode {2}' -f $Script,$CaseRoot,$Mode))
}

function NewCase([string]$Name,[string[]]$Records){
  $caseRoot = Join-Path $TmpRoot $Name
  WriteLedger (Join-Path $caseRoot "data\ledger.ndjson") $Records
  return $caseRoot
}

$SEED = @(
  (Rec "aaa1" "one"   "2026-01-01T00:00:00Z"),
  (Rec "bbb2" "two"   "2026-01-02T00:00:00Z"),
  (Rec "ccc3" "three" "2026-01-03T00:00:00Z")
)

$results = New-Object System.Collections.Generic.List[object]

function Assert([string]$Case,[bool]$Cond,[string]$Detail){
  $results.Add([pscustomobject]@{ case=$Case; ok=$Cond; detail=$Detail }) | Out-Null
  if($Cond){ Write-Output ("PASS  " + $Case + "  " + $Detail) }
  else      { Write-Output ("FAIL  " + $Case + "  " + $Detail) }
}

# --- CLEAN ---
$c = NewCase "clean" $SEED
$null = RunMode $c "checkpoint"
$v = RunMode $c "verify"
Assert "CLEAN" (($v.ExitCode -eq 0) -and ($v.StdOut -match 'NFL_LEDGER_VERIFY_OK')) ("exit=" + $v.ExitCode)

# --- APPEND (legit) ---
$c = NewCase "append" $SEED
$null = RunMode $c "checkpoint"
$led = Join-Path $c "data\ledger.ndjson"
Add-Content -LiteralPath $led -Value ((Rec "ddd4" "four" "2026-01-04T00:00:00Z") + "`n") -Encoding UTF8
$v = RunMode $c "verify"
Assert "APPEND" (($v.ExitCode -eq 0) -and ($v.StdOut -match 'NFL_LEDGER_VERIFY_OK') -and ($v.StdOut -match 'APPENDED_SINCE_CHECKPOINT=1')) ("exit=" + $v.ExitCode)

# --- TAMPER (mutate checkpointed record #2) ---
$c = NewCase "tamper" $SEED
$null = RunMode $c "checkpoint"
$tampered = @(
  (Rec "aaa1" "one"          "2026-01-01T00:00:00Z"),
  (Rec "bbb2" "two-TAMPERED" "2026-01-02T00:00:00Z"),
  (Rec "ccc3" "three"        "2026-01-03T00:00:00Z")
)
WriteLedger (Join-Path $c "data\ledger.ndjson") $tampered
$v = RunMode $c "verify"
Assert "TAMPER" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_VERIFY_FAIL:PREFIX_TAMPERED')) ("exit=" + $v.ExitCode)

# --- TRUNCATE (drop checkpointed record #3) ---
$c = NewCase "truncate" $SEED
$null = RunMode $c "checkpoint"
WriteLedger (Join-Path $c "data\ledger.ndjson") @($SEED[0],$SEED[1])
$v = RunMode $c "verify"
Assert "TRUNCATE" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_VERIFY_FAIL:LEDGER_TRUNCATED')) ("exit=" + $v.ExitCode)

# --- REORDER (swap records #1 and #2) ---
$c = NewCase "reorder" $SEED
$null = RunMode $c "checkpoint"
WriteLedger (Join-Path $c "data\ledger.ndjson") @($SEED[1],$SEED[0],$SEED[2])
$v = RunMode $c "verify"
Assert "REORDER" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_VERIFY_FAIL:PREFIX_TAMPERED')) ("exit=" + $v.ExitCode)

# --- summary + receipt ---
$passed = @($results | Where-Object { $_.ok }).Count
$total  = $results.Count

$rcptPath = Join-Path $RepoRoot "proofs\receipts\nfl.ledger.selftest.ndjson"
$rcpt = [ordered]@{
  schema = "nfl.ledger.selftest.receipt.v1"
  utc    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  run_id = $RunId
  passed = $passed
  total  = $total
  ok     = ($passed -eq $total)
  cases  = @($results | ForEach-Object { $_.case + "=" + ($(if($_.ok){"PASS"}else{"FAIL"})) })
}
$dir = Split-Path -Parent $rcptPath
EnsureDir $dir
Add-Content -LiteralPath $rcptPath -Value (($rcpt | ConvertTo-Json -Compress -Depth 10) + "`n") -Encoding UTF8

if(-not $Keep){
  Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("RESULT=" + $passed + "/" + $total)
if($passed -ne $total){ Fail ("CASES_FAILED:" + ($total - $passed)) }
Write-Output "NFL_LEDGER_SELFTEST_OK"
