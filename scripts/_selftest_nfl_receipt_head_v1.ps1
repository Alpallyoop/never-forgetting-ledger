<#
  _selftest_nfl_receipt_head_v1.ps1 -- proof for "receipt-head" (NFL proposal 0003).

  receipt-head tells an emitter which receipt NFL witnessed last for one integration, so the emitter can check that
  its receipt file still contains it. Positive and negative cases, in a temp folder under proofs/_tmp only (the real
  ledger is never touched). No CPR, no network. Emits NFL_RECEIPT_HEAD_SELFTEST_OK.
#>
param([string]$RepoRoot = "",[switch]$Keep)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")
. (Join-Path $PSScriptRoot "_nfl_paths_v1.ps1")

function Fail([string]$m){ throw ("NFL_RECEIPT_HEAD_SELFTEST_FAIL:" + $m) }
$RepoRoot = Resolve-NflRepoRoot $RepoRoot
$Cli = Join-NflPath $PSScriptRoot "nfl_cli_v1.ps1"
$MapSrc = Join-NflPath $RepoRoot ".constellation" "SERVICE_MAP.md"
$IntSrc = Join-NflPath $RepoRoot ".constellation" "integrations.json"
if(-not (Test-Path -LiteralPath $MapSrc -PathType Leaf)){ Fail "SERVICE_MAP_COPY_MISSING" }

$results = New-Object System.Collections.Generic.List[object]
function Assert([string]$Case,[bool]$Cond,[string]$Detail){
  $results.Add([pscustomobject]@{ case=$Case; ok=$Cond }) | Out-Null
  if($Cond){ Write-Output ("PASS  " + $Case + "  " + $Detail) } else { Write-Output ("FAIL  " + $Case + "  " + $Detail) }
}
function Invoke-HeadCli([string]$root,[string[]]$a){ return (Invoke-NflScript $Cli (@($a) + @("-RepoRoot",$root)) $root) }
function Val([string]$out,[string]$key){ $m = [regex]::Match($out, '(?m)^' + [regex]::Escape($key) + '=(.*)$'); if($m.Success){ return $m.Groups[1].Value.Trim() } return $null }
function LedgerBytes([string]$root){ $p = Get-NflLedgerPath $root; if(Test-Path -LiteralPath $p){ return (Get-NflSha256File $p) } return "none" }

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$TmpRoot = Join-NflPath $RepoRoot "proofs" "_tmp" ("receipt_head_selftest_" + $RunId)
$r = Join-NflPath $TmpRoot "nfl"
New-Item -ItemType Directory -Force -Path (Join-NflPath $r ".constellation") | Out-Null
Copy-Item -LiteralPath $MapSrc -Destination (Join-NflPath $r ".constellation" "SERVICE_MAP.md")
if(Test-Path -LiteralPath $IntSrc -PathType Leaf){ Copy-Item -LiteralPath $IntSrc -Destination (Join-NflPath $r ".constellation" "integrations.json") }
$r = (Resolve-Path -LiteralPath $r).Path
$Z = "0" * 64

# two receipts of one integration, chained, plus one of another integration
$a1 = New-NflIntegrationReceiptLine -Consumer "runledger" -Provider "nfl" -Contract "nfl.ingest.v1" -RequestSha256 ("a" * 64) -Outcome "ok" -PrevSha256 $Z
$a2 = New-NflIntegrationReceiptLine -Consumer "runledger" -Provider "nfl" -Contract "nfl.ingest.v1" -RequestSha256 ("b" * 64) -Outcome "unavailable" -ErrorToken "NFL_UNREACHABLE" -PrevSha256 (Get-NflSha256HexOfString $a1)
$o1 = New-NflIntegrationReceiptLine -Consumer "nfl" -Provider "cpr" -Outcome "ok" -PrevSha256 $Z
$h1 = Get-NflSha256HexOfString $a1; $h2 = Get-NflSha256HexOfString $a2

$x = Invoke-HeadCli $r @("receipt-head","-Integration","runledger>nfl")
Assert "H1_EMPTY_LEDGER_ZERO_HEAD" (($x.ExitCode -eq 0) -and ((Val $x.StdOut "WITNESSED_COUNT") -eq "0") -and ((Val $x.StdOut "HEAD") -eq $Z) -and ((Val $x.StdOut "LAST_SEQ") -eq "-1") -and ($x.StdOut -match 'NFL_RECEIPT_HEAD_OK')) ""

$x = Invoke-HeadCli $r @("witness-receipt","-ReceiptLine",$a1)
$x = Invoke-HeadCli $r @("receipt-head","-Integration","runledger>nfl")
Assert "H2_ONE_WITNESSED" (((Val $x.StdOut "WITNESSED_COUNT") -eq "1") -and ((Val $x.StdOut "HEAD") -eq $h1) -and ((Val $x.StdOut "INTEGRATION") -eq "runledger>nfl")) ""

[void](Add-NflLedgerRecord -RepoRoot $r -Hash $o1.Length.ToString().PadLeft(64,'c') -Artifact (Get-NflReceiptLabel "nfl" "cpr"))
$x = Invoke-HeadCli $r @("witness-receipt","-ReceiptLine",$a2)
$x = Invoke-HeadCli $r @("receipt-head","-Integration","runledger>nfl")
Assert "H3_HEAD_IS_MOST_RECENT" (((Val $x.StdOut "WITNESSED_COUNT") -eq "2") -and ((Val $x.StdOut "HEAD") -eq $h2)) ("head=" + (Val $x.StdOut "HEAD"))
$x = Invoke-HeadCli $r @("receipt-head","-Integration","nfl>cpr")
Assert "H4_OTHER_INTEGRATIONS_SEPARATE" (((Val $x.StdOut "WITNESSED_COUNT") -eq "1") -and ((Val $x.StdOut "HEAD") -ne $h2)) ""

$x = Invoke-HeadCli $r @("witness-receipt","-ReceiptLine",$a1)
$x = Invoke-HeadCli $r @("receipt-head","-Integration","runledger>nfl")
Assert "H5_REWITNESS_DOES_NOT_MOVE_HEAD" (((Val $x.StdOut "WITNESSED_COUNT") -eq "2") -and ((Val $x.StdOut "HEAD") -eq $h2)) "witnessing is idempotent per hash and label"

$x = Invoke-HeadCli $r @("receipt-head","-Integration","recognition>soteriavault")
Assert "H6_UNKNOWN_INTEGRATION_EMPTY_NOT_ERROR" (($x.ExitCode -eq 0) -and ((Val $x.StdOut "WITNESSED_COUNT") -eq "0") -and ((Val $x.StdOut "HEAD") -eq $Z)) ""

$before = LedgerBytes $r
$bad = @("", "runledger", "a>b>c", "Runledger>nfl", "runledger>../x", "runledger>nfl;x", ">nfl")
$refused = 0
foreach($b in $bad){
  $a = @("receipt-head"); if($b -ne ""){ $a += @("-Integration",$b) }
  $y = Invoke-HeadCli $r $a
  if($y.ExitCode -ne 0 -and (($y.StdOut + $y.StdErr) -match 'NFL_CLI_FAIL:(MISSING_INTEGRATION|RECEIPT_HEAD_BAD_INTEGRATION)')){ $refused++ }
}
Assert "H7_BAD_INTEGRATION_REFUSED" ($refused -eq $bad.Count) ("refused=" + $refused + "/" + $bad.Count)
Assert "H8_READ_ONLY" ((LedgerBytes $r) -eq $before) "receipt-head never writes the ledger"

$v = Invoke-HeadCli $r @("verify-chain")
Assert "H9_LEDGER_CHAIN_OK" ($v.ExitCode -eq 0) ""

$passed = @($results | Where-Object { $_.ok }).Count
$total = $results.Count
if(-not $Keep){ Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ("RESULT=" + $passed + "/" + $total)
if($passed -ne $total){ Fail ("CASES_FAILED:" + ($total - $passed)) }
Write-Output "NFL_RECEIPT_HEAD_SELFTEST_OK"
