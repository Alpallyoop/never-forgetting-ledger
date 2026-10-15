<#
  nfl_ledger_verify_chain_v1.ps1

  Verify the ledger's embedded self-chain (seq + prev written by every NFL writer).
  Records predating self-chaining (no prev field) form an "unchained prefix" and are
  not linkage-checked, but their record hash still anchors the first chained record.
  A record without prev after the chain has started is a failure (UNCHAINED_AFTER_CHAIN).

  record-hash (rh) = sha256( nfl.ledger.core.canon.v1 {hash,artifact,timestamp} ) -- identical to
  the checkpoint chain, so this is independent of the seq/prev fields themselves.
  For a chained record at index i: prev MUST equal (i==0 ? "GENESIS" : rh[i-1]); seq MUST equal i.
  Implementation: Test-NflLedgerChain in _lib_nfl_v1.ps1 (host-independent).
#>
param([Parameter(Mandatory=$false)][string]$RepoRoot = ".")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$c = Test-NflLedgerChain $RepoRoot
if(-not $c.Ok){
  Write-Output ("NFL_LEDGER_CHAIN_FAIL:" + $c.Error)
  if($c.Detail){ Write-Output $c.Detail }
  exit 1
}

$rcptPath = Join-NflPath $RepoRoot "proofs" "receipts" "nfl.ledger.chain_verify.ndjson"
$dir = Split-Path -Parent $rcptPath
if(-not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$rcpt = [ordered]@{
  schema = "nfl.ledger.chain_verify.receipt.v1"
  utc = (Get-NflUtc)
  ok = $true
  count = $c.Count
  unchained_prefix = $c.UnchainedPrefix
  chained_count = $c.ChainedCount
  head = $c.Head
}
[System.IO.File]::AppendAllText($rcptPath, ((ConvertTo-NflCanonicalJson $rcpt) + "`n"), (Get-NflUtf8))

Write-Output "NFL_LEDGER_CHAIN_OK"
Write-Output ("COUNT=" + $c.Count)
Write-Output ("UNCHAINED_PREFIX=" + $c.UnchainedPrefix)
Write-Output ("CHAINED_COUNT=" + $c.ChainedCount)
Write-Output ("HEAD=" + $c.Head)
exit 0
