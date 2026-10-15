<#
  nfl_cli_v1.ps1 -- Never Forgetting Ledger CLI.

  commit          -Hash <hex> [-Artifact <label>]          -> COMMIT_OK  HASH= TIMESTAMP= SEQ=
  lookup          -Hash <hex>                              -> FOUND HASH= TIMESTAMP= ARTIFACT= SEQ= [MATCHES=] | NOT_FOUND
  verify          -File <path>                             -> HASH= then VERIFIED TIMESTAMP= SEQ= | NOT_FOUND
  verify-chain                                             -> NFL_LEDGER_CHAIN_OK COUNT= UNCHAINED_PREFIX= CHAINED_COUNT= HEAD=
  witness-receipt -ReceiptFile <ndjson> | -ReceiptLine <json>
                  constellation.integration.receipt.v1 lines (proposal 0001). Per line:
                    WITNESSED | ALREADY_WITNESSED   RECEIPT_SHA256= INTEGRATION=<consumer>><provider> SEQ=
                    REFUSED  RECEIPT_ERROR=<token>  (invalid, unregistered, wrong witness/emitter)
                  ends with NFL_RECEIPT_WITNESS_OK (exit 0) or NFL_CLI_FAIL:RECEIPT_REFUSED:<n> (exit 1)
  verify-receipt  -ReceiptFile | -ReceiptLine              -> per line VERIFIED SEQ= TIMESTAMP= | NOT_FOUND ; RECEIPT_SHA256=
  witness-own-receipts                                     -> commits the receipts NFL wrote as a consumer
                  (proofs/receipts/integration/nfl__*.ndjson): NFL_OWN_RECEIPTS_OK WITNESSED= ALREADY= INVALID=

  -RepoRoot defaults to the current directory (historical behavior; callers set the working directory).
  Failures: NFL_CLI_FAIL:<TOKEN> on stderr-equivalent throw, non-zero exit.
#>
param(
  [Parameter(Mandatory=$true,Position=0)]
  [ValidateSet("commit","lookup","verify","verify-chain","witness-receipt","verify-receipt","witness-own-receipts")]
  [string]$Command,

  [string]$Hash,
  [string]$Artifact,
  [string]$File,
  [string]$ReceiptFile,
  [string]$ReceiptLine,
  [string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")

function Fail([string]$m){ throw ("NFL_CLI_FAIL:" + ($m -replace '^NFL_','')) }

try { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path } catch { Fail "REPO_ROOT_NOT_FOUND" }

function Get-ReceiptLines(){
  if(-not [string]::IsNullOrEmpty($ReceiptLine)){ return ,@($ReceiptLine) }
  if([string]::IsNullOrWhiteSpace($ReceiptFile)){ Fail "MISSING_RECEIPT" }
  if(-not (Test-Path -LiteralPath $ReceiptFile -PathType Leaf)){ Fail ("RECEIPT_FILE_NOT_FOUND:" + $ReceiptFile) }
  $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ReceiptFile).Path)
  if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){ Fail "RECEIPT_FILE_HAS_BOM" }
  $text = (Get-NflUtf8).GetString($bytes)
  if($text.Contains("`r")){ Fail "RECEIPT_FILE_NOT_LF" }
  $lines = @($text.Split("`n") | Where-Object { $_.Length -gt 0 })
  if($lines.Count -eq 0){ Fail "RECEIPT_FILE_EMPTY" }
  return ,$lines
}

try {
  if($Command -eq "commit"){
    $r = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $Hash -Artifact $Artifact
    Write-Output "COMMIT_OK"
    Write-Output ("HASH=" + $r.Hash)
    Write-Output ("TIMESTAMP=" + $r.Timestamp)
    Write-Output ("SEQ=" + $r.Seq)
    exit 0
  }

  if($Command -eq "lookup"){
    if([string]::IsNullOrWhiteSpace($Hash)){ Fail "MISSING_HASH" }
    $h = $Hash.Trim().ToLowerInvariant()
    $hits = @(Find-NflLedgerRecords $RepoRoot $h)
    if($hits.Count -eq 0){ Write-Output "NOT_FOUND"; exit 0 }
    $first = $hits[0]
    Write-Output "FOUND"
    Write-Output ("HASH=" + [string](Get-NflProp $first.Record 'hash'))
    Write-Output ("TIMESTAMP=" + [string](Get-NflProp $first.Record 'timestamp'))
    Write-Output ("ARTIFACT=" + [string](Get-NflProp $first.Record 'artifact'))
    Write-Output ("SEQ=" + $first.Seq)
    if($hits.Count -gt 1){ Write-Output ("MATCHES=" + $hits.Count) }
    exit 0
  }

  if($Command -eq "verify"){
    if([string]::IsNullOrWhiteSpace($File)){ Fail "MISSING_FILE" }
    if(-not (Test-Path -LiteralPath $File -PathType Leaf)){ Fail ("FILE_NOT_FOUND:" + $File) }
    $h = Get-NflSha256File $File
    Write-Output ("HASH=" + $h)
    $hits = @(Find-NflLedgerRecords $RepoRoot $h)
    if($hits.Count -eq 0){ Write-Output "NOT_FOUND"; exit 0 }
    Write-Output "VERIFIED"
    Write-Output ("TIMESTAMP=" + [string](Get-NflProp $hits[0].Record 'timestamp'))
    Write-Output ("SEQ=" + $hits[0].Seq)
    exit 0
  }

  if($Command -eq "verify-chain"){
    $c = Test-NflLedgerChain $RepoRoot
    if(-not $c.Ok){
      Write-Output ("NFL_LEDGER_CHAIN_FAIL:" + $c.Error)
      if($c.Detail){ Write-Output $c.Detail }
      exit 1
    }
    Write-Output "NFL_LEDGER_CHAIN_OK"
    Write-Output ("COUNT=" + $c.Count)
    Write-Output ("UNCHAINED_PREFIX=" + $c.UnchainedPrefix)
    Write-Output ("CHAINED_COUNT=" + $c.ChainedCount)
    Write-Output ("HEAD=" + $c.Head)
    exit 0
  }

  if($Command -eq "witness-receipt"){
    $lines = Get-ReceiptLines
    $integrations = Get-NflRegisteredIntegrations $RepoRoot
    $refused = 0; $done = 0
    foreach($line in $lines){
      $w = Invoke-NflWitnessReceiptLine $RepoRoot $line $integrations
      if($w.Status -eq "REFUSED"){
        $refused++
        Write-Output "REFUSED"
        Write-Output ("RECEIPT_ERROR=" + $w.Error)
        if($w.Sha256){ Write-Output ("RECEIPT_SHA256=" + $w.Sha256) }
        continue
      }
      $done++
      Write-Output $w.Status
      Write-Output ("RECEIPT_SHA256=" + $w.Sha256)
      Write-Output ("INTEGRATION=" + $w.Integration)
      Write-Output ("SEQ=" + $w.Seq)
      Write-Output ("TIMESTAMP=" + $w.Timestamp)
    }
    Write-Output ("WITNESSED_COUNT=" + $done)
    Write-Output ("REFUSED_COUNT=" + $refused)
    if($refused -gt 0){ Write-Output ("NFL_CLI_FAIL:RECEIPT_REFUSED:" + $refused); exit 1 }
    Write-Output "NFL_RECEIPT_WITNESS_OK"
    exit 0
  }

  if($Command -eq "witness-own-receipts"){
    $r = Sync-NflOwnIntegrationReceipts $RepoRoot
    Write-Output ("WITNESSED=" + $r.Witnessed)
    Write-Output ("ALREADY=" + $r.Already)
    Write-Output ("INVALID=" + $r.Invalid)
    if($r.Invalid -gt 0){ Write-Output ("NFL_CLI_FAIL:OWN_RECEIPTS_INVALID:" + $r.Invalid); exit 1 }
    Write-Output "NFL_OWN_RECEIPTS_OK"
    exit 0
  }

  if($Command -eq "verify-receipt"){
    $lines = Get-ReceiptLines
    $missing = 0
    foreach($line in $lines){
      $l = $line
      if($l.EndsWith("`n")){ $l = $l.Substring(0,$l.Length-1) }
      $h = Get-NflSha256HexOfString $l
      $chk = Test-NflIntegrationReceiptLine $l
      $label = $null
      if($chk.Ok){ $label = Get-NflReceiptLabel $chk.Consumer $chk.Provider }
      $hits = @(Find-NflLedgerRecords $RepoRoot $h | Where-Object { ($null -eq $label) -or ([string](Get-NflProp $_.Record 'artifact') -eq $label) })
      Write-Output ("RECEIPT_SHA256=" + $h)
      if($hits.Count -eq 0){ $missing++; Write-Output "NOT_FOUND"; continue }
      Write-Output "VERIFIED"
      Write-Output ("SEQ=" + $hits[0].Seq)
      Write-Output ("TIMESTAMP=" + [string](Get-NflProp $hits[0].Record 'timestamp'))
      if(-not $chk.Ok){ Write-Output ("RECEIPT_WARNING=" + $chk.Error) }
    }
    Write-Output ("NOT_FOUND_COUNT=" + $missing)
    exit 0
  }
} catch {
  $m = [string]$_.Exception.Message
  if($m -like "NFL_CLI_FAIL:*"){ throw }
  Fail $m
}
