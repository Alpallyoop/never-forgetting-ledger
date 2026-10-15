<#
  _RUN_nfl_durable_ledger_green_v1.ps1

  Standing durable-ledger integrity gate. One command re-proves:
    - checkpoint tamper-evidence self-test  (NFL_LEDGER_SELFTEST_OK)
    - seal forgery self-test                (NFL_LEDGER_SEAL_SELFTEST_OK)
    - live checkpoint / verify / seal / verify-seal on the real ledger

  Independent of CPR and any network/SaaS: durable-ledger integrity can be proven
  offline. Fail-closed; parse-gated; each stage asserts exit==0 AND a required token.
#>

param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_DURABLE_LEDGER_GREEN_FAIL:" + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
function ParseGateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("PARSEGATE_MISSING:" + $Path) }
  $tok=$null; $err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and @(@($err)).Count -gt 0){
    $msg = (($err | Select-Object -First 5 | ForEach-Object { $_.ToString() }) -join " | ")
    Fail ("PARSEGATE_FAIL:" + $Path + "::" + $msg)
  }
}
function StartChild([string]$FileName,[string]$Arguments,[string]$WorkingDir){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$FileName; $psi.Arguments=$Arguments; $psi.WorkingDirectory=$WorkingDir
  $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
  $p = New-Object System.Diagnostics.Process; $p.StartInfo=$psi
  [void]$p.Start()
  $o=$p.StandardOutput.ReadToEnd(); $e=$p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=$o; StdErr=$e }
}
function AssertSuccess([string]$Name,$R,[string]$Needle){
  if($R.ExitCode -ne 0){ Fail ($Name + "_EXIT_" + $R.ExitCode + ":" + ($R.StdOut + $R.StdErr).Trim()) }
  if(-not [string]::IsNullOrWhiteSpace($Needle) -and ($R.StdOut -notmatch [regex]::Escape($Needle))){
    Fail ($Name + "_MISSING_TOKEN:" + $Needle)
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe = (Get-Process -Id $PID).Path

$Ckpt      = Join-Path $RepoRoot "scripts\nfl_ledger_checkpoint_v1.ps1"
$CkptTest  = Join-Path $RepoRoot "scripts\_selftest_nfl_ledger_checkpoint_v1.ps1"
$Seal      = Join-Path $RepoRoot "scripts\nfl_ledger_seal_v1.ps1"
$SealTest  = Join-Path $RepoRoot "scripts\_selftest_nfl_ledger_seal_v1.ps1"
foreach($p in @($Ckpt,$CkptTest,$Seal,$SealTest)){ if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Fail ("MISSING:" + $p) } ; ParseGateFile $p }

$common = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File'

# 1) checkpoint tamper-evidence self-test
$r = StartChild $PSExe ('{0} "{1}" -RepoRoot "{2}"' -f $common,$CkptTest,$RepoRoot) $RepoRoot
AssertSuccess "CKPT_SELFTEST" $r "NFL_LEDGER_SELFTEST_OK"

# 2) seal forgery self-test
$r = StartChild $PSExe ('{0} "{1}" -RepoRoot "{2}"' -f $common,$SealTest,$RepoRoot) $RepoRoot
AssertSuccess "SEAL_SELFTEST" $r "NFL_LEDGER_SEAL_SELFTEST_OK"

# 3) live checkpoint
$r = StartChild $PSExe ('{0} "{1}" -RepoRoot "{2}" -Mode checkpoint' -f $common,$Ckpt,$RepoRoot) $RepoRoot
AssertSuccess "CHECKPOINT" $r "NFL_LEDGER_CHECKPOINT_OK"

# 4) live verify
$r = StartChild $PSExe ('{0} "{1}" -RepoRoot "{2}" -Mode verify' -f $common,$Ckpt,$RepoRoot) $RepoRoot
AssertSuccess "VERIFY" $r "NFL_LEDGER_VERIFY_OK"

# 5) live seal
$r = StartChild $PSExe ('{0} "{1}" -RepoRoot "{2}" -Mode seal' -f $common,$Seal,$RepoRoot) $RepoRoot
AssertSuccess "SEAL" $r "NFL_LEDGER_SEAL_OK"

# 6) live verify-seal
$r = StartChild $PSExe ('{0} "{1}" -RepoRoot "{2}" -Mode verify-seal' -f $common,$Seal,$RepoRoot) $RepoRoot
AssertSuccess "VERIFY_SEAL" $r "NFL_LEDGER_SEAL_VERIFY_OK"

# receipt
$utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$rcptPath = Join-Path $RepoRoot "proofs\receipts\nfl.durable_ledger_green.ndjson"
EnsureDir (Split-Path -Parent $rcptPath)
$rcpt = [ordered]@{
  schema="nfl.durable_ledger_green.receipt.v1"; utc=$utc; ok=$true
  stages=@("CKPT_SELFTEST","SEAL_SELFTEST","CHECKPOINT","VERIFY","SEAL","VERIFY_SEAL")
}
[System.IO.File]::AppendAllText($rcptPath, (($rcpt | ConvertTo-Json -Compress -Depth 10) + "`n"), (Utf8NoBom))

Write-Output "NFL_DURABLE_LEDGER_GREEN_OK"
Write-Output ("RECEIPT=" + $rcptPath)
