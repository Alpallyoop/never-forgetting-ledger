<#
  _selftest_nfl_ledger_selfchain_v1.ps1

  Negative proof for the embedded self-chain (CLI commit writes seq/prev under lock;
  nfl_ledger_verify_chain_v1.ps1 checks it). Temp dir only; uses the REAL CLI so seq/prev
  come from the actual writer. Never touches the real ledger.

  CLEAN         : 3 chained commits                 -> NFL_LEDGER_CHAIN_OK (chained=3, prefix=0)
  LEGACY_PREFIX : 2 legacy records + 2 commits       -> NFL_LEDGER_CHAIN_OK (prefix=2, chained=2)
  TAMPER_CORE   : mutate a chained record's core     -> CHAIN_FAIL:CHAIN_BREAK
  REORDER       : swap two chained records           -> CHAIN_FAIL:SEQ_MISMATCH or CHAIN_BREAK
#>
param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][switch]$Keep
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_LEDGER_SELFCHAIN_SELFTEST_FAIL:" + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function EnsureDir([string]$p){ if(-not [string]::IsNullOrWhiteSpace($p) -and -not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function WriteText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path; EnsureDir $dir
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($t))
}
function ReadLines([string]$Path){
  $raw = [System.IO.File]::ReadAllText($Path,(Utf8NoBom))
  $norm = ($raw -replace "`r`n","`n") -replace "`r","`n"
  return @(($norm -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
function WriteLines([string]$Path,[string[]]$Lines){ WriteText $Path (($Lines -join "`n") + "`n") }
function StartChild([string]$FileName,[string]$Arguments,[string]$WorkingDir){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$FileName; $psi.Arguments=$Arguments; $psi.WorkingDirectory=$WorkingDir
  $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
  $p = New-Object System.Diagnostics.Process; $p.StartInfo=$psi
  [void]$p.Start()
  $o=$p.StandardOutput.ReadToEnd(); $e=$p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=$o; StdErr=$e }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe = (Get-Process -Id $PID).Path
$Cli = Join-Path $RepoRoot "scripts\nfl_cli_v1.ps1"
$VerifyChain = Join-Path $RepoRoot "scripts\nfl_ledger_verify_chain_v1.ps1"
foreach($s in @($Cli,$VerifyChain)){ if(-not (Test-Path -LiteralPath $s -PathType Leaf)){ Fail ("MISSING_SCRIPT:" + $s) } }

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$TmpRoot = Join-Path $RepoRoot ("proofs\_tmp\selfchain_selftest_" + $RunId)
EnsureDir $TmpRoot

function Commit([string]$caseRoot,[string]$h,[string]$a){
  EnsureDir $caseRoot
  $r = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" commit -Hash "{1}" -Artifact "{2}"' -f $Cli,$h,$a) $caseRoot
  if($r.ExitCode -ne 0){ Fail ("COMMIT_FAILED:" + $h + ":" + $r.StdOut + $r.StdErr) }
}
function VerifyChain([string]$caseRoot){ return (StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f $VerifyChain,$caseRoot) $caseRoot) }
function LedgerOf([string]$caseRoot){ return (Join-Path $caseRoot "data\ledger.ndjson") }

$results = New-Object System.Collections.Generic.List[object]
function Assert([string]$Case,[bool]$Cond,[string]$Detail){
  $results.Add([pscustomobject]@{ case=$Case; ok=$Cond }) | Out-Null
  if($Cond){ Write-Output ("PASS  " + $Case + "  " + $Detail) } else { Write-Output ("FAIL  " + $Case + "  " + $Detail) }
}

# CLEAN
$c = Join-Path $TmpRoot "clean"
Commit $c "aaa1" "one"; Commit $c "bbb2" "two"; Commit $c "ccc3" "three"
$v = VerifyChain $c
Assert "CLEAN" (($v.ExitCode -eq 0) -and ($v.StdOut -match 'NFL_LEDGER_CHAIN_OK') -and ($v.StdOut -match 'CHAINED_COUNT=3') -and ($v.StdOut -match 'UNCHAINED_PREFIX=0')) ("exit=" + $v.ExitCode)

# LEGACY_PREFIX
$c = Join-Path $TmpRoot "legacy_prefix"
WriteLines (LedgerOf $c) @(
  ('{"hash":"leg1","artifact":"L1","timestamp":"2026-01-01T00:00:00Z"}'),
  ('{"hash":"leg2","artifact":"L2","timestamp":"2026-01-02T00:00:00Z"}')
)
Commit $c "ccc3" "three"; Commit $c "ddd4" "four"
$v = VerifyChain $c
Assert "LEGACY_PREFIX" (($v.ExitCode -eq 0) -and ($v.StdOut -match 'NFL_LEDGER_CHAIN_OK') -and ($v.StdOut -match 'UNCHAINED_PREFIX=2') -and ($v.StdOut -match 'CHAINED_COUNT=2')) ("exit=" + $v.ExitCode)

# TAMPER_CORE (mutate a chained record's core -> next record's prev breaks)
$c = Join-Path $TmpRoot "tamper_core"
Commit $c "aaa1" "one"; Commit $c "bbb2" "two"; Commit $c "ccc3" "three"
$lines = ReadLines (LedgerOf $c)
$o1 = $lines[1] | ConvertFrom-Json
$o1.artifact = "two-TAMPERED"
$lines[1] = ($o1 | ConvertTo-Json -Compress)
WriteLines (LedgerOf $c) $lines
$v = VerifyChain $c
Assert "TAMPER_CORE" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_CHAIN_FAIL:CHAIN_BREAK')) ("exit=" + $v.ExitCode)

# REORDER (swap two chained records)
$c = Join-Path $TmpRoot "reorder"
Commit $c "aaa1" "one"; Commit $c "bbb2" "two"; Commit $c "ccc3" "three"
$lines = ReadLines (LedgerOf $c)
$tmp = $lines[0]; $lines[0] = $lines[1]; $lines[1] = $tmp
WriteLines (LedgerOf $c) $lines
$v = VerifyChain $c
Assert "REORDER" (($v.ExitCode -eq 1) -and (($v.StdOut -match 'NFL_LEDGER_CHAIN_FAIL:SEQ_MISMATCH') -or ($v.StdOut -match 'NFL_LEDGER_CHAIN_FAIL:CHAIN_BREAK'))) ("exit=" + $v.ExitCode)

# CASCADE (rewrite a record AND repair the next record's prev -> the link after it still breaks)
$c = Join-Path $TmpRoot "cascade"
Commit $c "aaa1" "one"; Commit $c "bbb2" "two"; Commit $c "ccc3" "three"; Commit $c "ddd4" "four"
. (Join-Path $RepoRoot "scripts\_lib_nfl_v1.ps1")
$lines = ReadLines (LedgerOf $c)
$o1 = ConvertFrom-NflJson $lines[1]; $o1.hash = "ffff"; $o1.artifact = "forged"; $lines[1] = ConvertTo-NflCanonicalJson $o1
$o2 = ConvertFrom-NflJson $lines[2]; $o2.prev = Get-NflLinkHash $o1; $lines[2] = ConvertTo-NflCanonicalJson $o2
WriteLines (LedgerOf $c) $lines
$v = VerifyChain $c
Assert "CASCADE_REWRITE_DETECTED" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_CHAIN_FAIL:CHAIN_BREAK:3')) ("exit=" + $v.ExitCode)

# STRIP (remove seq/prev from every record to fake an unchained prefix -> the pin catches it)
$c = Join-Path $TmpRoot "strip"
Commit $c "aaa1" "one"; Commit $c "bbb2" "two"
$lines = @(ReadLines (LedgerOf $c) | ForEach-Object { $o = ConvertFrom-NflJson $_; ConvertTo-NflCanonicalJson ([ordered]@{ hash=$o.hash; artifact=$o.artifact; timestamp=$o.timestamp }) })
WriteLines (LedgerOf $c) $lines
$v = VerifyChain $c
Assert "STRIP_CHAIN_DETECTED" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'CHAIN_START_MOVED')) ("exit=" + $v.ExitCode)

$passed = @($results | Where-Object { $_.ok }).Count
$total  = $results.Count
if(-not $Keep){ Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ("RESULT=" + $passed + "/" + $total)
if($passed -ne $total){ Fail ("CASES_FAILED:" + ($total - $passed)) }
Write-Output "NFL_LEDGER_SELFCHAIN_SELFTEST_OK"
