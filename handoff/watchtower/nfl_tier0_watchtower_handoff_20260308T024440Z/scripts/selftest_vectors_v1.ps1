param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = "C:\dev\nfl"
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw ("NFL_VECTOR_SELFTEST_FAIL: " + $m) }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ Die "EnsureDir: empty" } if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ return (New-Object System.Text.UTF8Encoding($false)) }
function CanonLf([string]$s){ return $s.Replace("`r`n","`n").Replace("`r","`n") }
function ReadUtf8([string]$p){ return [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function AppendUtf8NoBomLf([string]$Path,[string]$Line){ $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t = CanonLf $Line; if(-not $t.EndsWith("`n")){ $t += "`n" }; [System.IO.File]::AppendAllText($Path,$t,(Utf8NoBom)) }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ Die ("MISSING_REPO_ROOT: " + $RepoRoot) }
$verify = Join-Path $RepoRoot "scripts\verify_packet_v1.ps1"
if(-not (Test-Path -LiteralPath $verify -PathType Leaf)){ Die ("MISSING_VERIFY: " + $verify) }
$vecRoot = Join-Path $RepoRoot "test_vectors\nfl_packet_verify_v1"
$suitePath = Join-Path $vecRoot "suite.json"
if(-not (Test-Path -LiteralPath $suitePath -PathType Leaf)){ Die ("MISSING_SUITE: " + $suitePath) }
$suiteTxt = ReadUtf8 $suitePath
$suite = $suiteTxt | ConvertFrom-Json -ErrorAction Stop
if(-not $suite){ Die "SUITE_PARSE_EMPTY" }

# --- run positive ---
$posRoot = [string]$suite.positive.packet_root
$posNs   = [string]$suite.positive.sig_namespace
Write-Host ("VEC_POS_PACKET: " + $posRoot) -ForegroundColor Cyan
Write-Host ("VEC_POS_NAMESPACE: " + $posNs) -ForegroundColor Cyan
if(-not (Test-Path -LiteralPath $posRoot -PathType Container)){ Die ("POS_PACKET_MISSING: " + $posRoot) }
$posRes = & $verify -PacketRoot $posRoot -SigNamespace $posNs
if(-not $posRes){ Die "POS_VERIFY_RETURNED_NO_OUTPUT" }
$posObj = $null
foreach($x in @(@($posRes))){ if($x -ne $null -and ($x.PSObject.Properties.Name -contains "ok")){ $posObj = $x } }
if($posObj -eq $null){ Die "POS_VERIFY_MISSING_OK_OBJECT" }
if(-not [bool]$posObj.ok){ Die "POS_VERIFY_NOT_OK" }
Write-Host "POS_OK" -ForegroundColor Green

# --- run negatives ---
$negs = @(@($suite.negatives))
if(@(@($negs)).Count -lt 1){ Die "NO_NEGATIVES_IN_SUITE" }
$negPass = 0
$negTotal = 0
foreach($n in @($negs)){
  $negTotal++
  $name = [string]$n.name
  $root = [string]$n.packet_root
  $ns   = [string]$n.sig_namespace
  $expect = [string]$n.expect
  Write-Output ("NFL_VERIFY_FAIL:" + $expect)
  Write-Host ""
  Write-Host ("NEG_CASE: " + $name) -ForegroundColor DarkYellow
  Write-Host ("  ROOT: " + $root)
  Write-Host ("  NS:   " + $ns)
  Write-Host ("  EXPECT: " + $expect)
  if(-not (Test-Path -LiteralPath $root -PathType Container)){ Die ("NEG_PACKET_MISSING: " + $name + " " + $root) }
  $ok = $false
  $msg = ""
  try {
    $r = & $verify -PacketRoot $root -SigNamespace $ns
    # If it returned OK, that is a FAIL for negative cases
    $obj = $null
    foreach($x in @(@($r))){ if($x -ne $null -and ($x.PSObject.Properties.Name -contains "ok")){ $obj = $x } }
    if($obj -ne $null -and [bool]$obj.ok){
      $ok = $false
      $msg = "NEG_UNEXPECTED_OK"
    } else {
      $ok = $false
      $msg = "NEG_NO_OK_OBJECT_BUT_NO_EXCEPTION"
    }
  } catch {
    $em = [string]$_.Exception.Message
    $msg = $em
    # classify based on expected token
    if($expect -eq "SHA256_MISMATCH" -and ($em -like "*SHA256_MISMATCH*")){ $ok = $true }
    elseif($expect -eq "MISSING_SIG" -and ($em -like "*MISSING_SIG*")){ $ok = $true }
    elseif($expect -eq "SIG_VERIFY_FAIL" -and ($em -like "*SIG_VERIFY_FAIL*")){ $ok = $true }
    elseif($expect -eq "MISSING_SHA256SUMS" -and ($em -like "*MISSING_SHA256SUMS*")){ $ok = $true }
    elseif($expect -eq "BAD_SHA256SUM_LINE" -and ($em -like "*BAD_SHA256SUM_LINE*")){ $ok = $true }
    elseif($expect -eq "TRAVERSAL_PATH" -and ($em -like "*TRAVERSAL_PATH*")){ $ok = $true }
    elseif($expect -eq "MISSING_TARGET" -and ($em -like "*MISSING_TARGET*")){ $ok = $true }
    else { $ok = $false }
  }
  if(-not $ok){ Die ("NEG_CASE_FAILED: " + $name + " msg=" + $msg) }
  Write-Host ("NEG_OK: " + $name) -ForegroundColor Green
  $negPass++
}

# append suite receipt
$receiptPath = Join-Path $RepoRoot "proofs\receipts\nfl_verify_v1.ndjson"
$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$rec = [pscustomobject]@{
  ts = $ts
  event = "packet.verify.suite.v1"
  status = "ok"
  suite_path = $suitePath
  packet_id = [string]$suite.packet_id
  positive_root = $posRoot
  positive_namespace = $posNs
  negatives_total = $negTotal
  negatives_passed = $negPass
}
$json = ($rec | ConvertTo-Json -Compress)
AppendUtf8NoBomLf $receiptPath $json
Write-Host ("RECEIPT_APPEND_OK: " + $receiptPath) -ForegroundColor Green
Write-Host "VECTOR_SELFTEST_OK" -ForegroundColor Green
