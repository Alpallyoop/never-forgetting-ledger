<#
  nfl_witness_cpr_verify_v1.ps1 -- run CPR's packet-law verifier on one packet and witness the verdict.

  NFL does not judge packets (CPR owns Packet Constitution v1). It records what CPR said:
    proofs/receipts/nfl.cpr_verify_witness.ndjson   nfl.cpr_verify_witness.receipt.v1 (one line per call)
    proofs/receipts/integration/nfl__cpr.ndjson     constellation.integration.receipt.v1 for the nfl>cpr exchange
      request_sha256  = SHA-256 of the packet's manifest.json bytes (null when absent)
      response_sha256 = SHA-256 of CPR's stdout bytes (UTF-8)
      outcome         = ok | failed (CPR not green) | unavailable (verifier missing)
  Emits NFL_WITNESS_CPR_VERIFY_OK only after both receipts are on disk; otherwise fails closed.
#>
param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$CprVerifierPath,
  [Parameter(Mandatory=$true)][string]$PacketDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")

function Fail([string]$m){ throw ("NFL_WITNESS_CPR_VERIFY_FAIL:" + $m) }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PacketDir = (Resolve-Path -LiteralPath $PacketDir).Path
$manifest = Join-NflPath $PacketDir "manifest.json"
$reqSha = if(Test-Path -LiteralPath $manifest -PathType Leaf){ Get-NflSha256File $manifest } else { $null }

if(-not (Test-Path -LiteralPath $CprVerifierPath -PathType Leaf)){
  [void](Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider "cpr" -Contract "cpr.packet.manifest.v1" -RequestSha256 $reqSha -Outcome "unavailable" -ErrorToken "CPR_VERIFIER_MISSING")
  Fail "CPR_VERIFIER_MISSING"
}
$CprVerifierPath = (Resolve-Path -LiteralPath $CprVerifierPath).Path
$CprRepoRoot = Split-Path -Parent (Split-Path -Parent $CprVerifierPath)

$RcptPath = Join-NflPath $RepoRoot "proofs" "receipts" "nfl.cpr_verify_witness.ndjson"
$RcptDir = Split-Path -Parent $RcptPath
if(-not (Test-Path -LiteralPath $RcptDir -PathType Container)){ New-Item -ItemType Directory -Force -Path $RcptDir | Out-Null }

$r = Invoke-NflScript $CprVerifierPath @("-RepoRoot",$CprRepoRoot,"-PacketPath",$PacketDir) $CprRepoRoot
$ok = (($r.ExitCode -eq 0) -and ($r.StdOut -match 'CPR_VERIFY_OK'))

$receipt = [ordered]@{
  schema = "nfl.cpr_verify_witness.receipt.v1"
  utc = (Get-NflUtc)
  ok = $ok
  packet_dir = $PacketDir
  cpr_repo_root = $CprRepoRoot
  cpr_verifier = $CprVerifierPath
  exit_code = [int]$r.ExitCode
  stdout = $r.StdOut
  stderr = $r.StdErr
}
[System.IO.File]::AppendAllText($RcptPath, ((ConvertTo-NflCanonicalJson $receipt) + "`n"), (Get-NflUtf8))

$respSha = Get-NflSha256HexOfString $r.StdOut
$own = Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider "cpr" -Contract "cpr.packet.manifest.v1" -RequestSha256 $reqSha -ResponseSha256 $respSha -Outcome $(if($ok){ "ok" } else { "failed" }) -ErrorToken "CPR_VERIFY_NOT_GREEN"
if(-not $own.Ok){ Write-Output ("WARNING: NFL_OWN_RECEIPT_NOT_WRITTEN:" + $own.Error) }

if(-not $ok){ Fail "CPR_VERIFY_NOT_GREEN" }

Write-Output "NFL_WITNESS_CPR_VERIFY_OK"
Write-Output ("RECEIPT=" + $RcptPath)
if($own.Ok){ Write-Output ("INTEGRATION_RECEIPT_SHA256=" + $own.Sha256) }
