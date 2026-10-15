<#
  nfl_ledger_checkpoint_v1.ps1

  Durable witness-ledger tamper-evidence (non-mutating).

  Modes:
    checkpoint  - compute the canonical linked hash chain over data/ledger.ndjson
                  and APPEND a checkpoint record to
                  proofs/checkpoints/nfl_ledger_checkpoint_v1.ndjson
                  (also writes proofs/checkpoints/latest.json convenience pointer).
    verify      - recompute the chain over the CURRENT ledger and compare the
                  checkpointed prefix head to the latest checkpoint. Detects any
                  modification / reorder / deletion / truncation within the
                  checkpointed prefix. Legitimately appended records are reported,
                  not treated as failure.

  This script NEVER writes to the ledger. It is append-only for checkpoints.

  Chain (self-consistent; independent re-implementation must match canonicalization):
    canon_i   = nfl.ledger.core.canon.v1 of {hash,artifact,timestamp} (Get-NflCoreCanon; equals ConvertTo-Json -Compress for all existing records)
    rec_i     = sha256_hex(utf8(canon_i))
    head_0    = sha256_hex(utf8("nfl.ledger.chain.v1" + "\n" + rec_0))
    head_i    = sha256_hex(utf8(head_{i-1} + "\n" + rec_i))
#>

param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][ValidateSet("checkpoint","verify")][string]$Mode = "checkpoint"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")  # host-independent JSON + core canon

$GENESIS = "nfl.ledger.chain.v1"

function Fail([string]$m){
  throw ("NFL_LEDGER_" + $Mode.ToUpperInvariant() + "_FAIL:" + $m)
}

function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }

function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
}

function AppendUtf8NoBomLfLine([string]$Path,[string]$Line){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $existing = ""
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    $existing = [System.IO.File]::ReadAllText($Path)
    $existing = ($existing -replace "`r`n","`n") -replace "`r","`n"
  }
  if($existing.Length -gt 0 -and -not $existing.EndsWith("`n")){ $existing += "`n" }
  $existing += ($Line + "`n")
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($existing))
}

function Sha256Hex([byte[]]$bytes){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $h = $sha.ComputeHash($bytes)
    return (($h | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally { $sha.Dispose() }
}

function Sha256HexOfString([string]$s){
  return (Sha256Hex ((Utf8NoBom).GetBytes($s)))
}

function GetProp($obj,[string]$name){
  $p = $obj.PSObject.Properties[$name]
  if($null -eq $p){ return $null }
  return $p.Value
}

# ---- resolve paths --------------------------------------------------
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Ledger   = Join-Path $RepoRoot "data\ledger.ndjson"
$CkptDir  = Join-Path $RepoRoot "proofs\checkpoints"
$CkptLog  = Join-Path $CkptDir "nfl_ledger_checkpoint_v1.ndjson"
$Latest   = Join-Path $CkptDir "latest.json"

if(-not (Test-Path -LiteralPath $Ledger -PathType Leaf)){
  Fail ("LEDGER_MISSING:" + $Ledger)
}

# ---- read + canonicalize records ------------------------------------
$rawBytes = [System.IO.File]::ReadAllBytes($Ledger)
$LedgerSha = (Sha256Hex $rawBytes)

$raw = [System.Text.Encoding]::UTF8.GetString($rawBytes)
# strip a leading BOM char if present
if($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF){ $raw = $raw.Substring(1) }
$norm = ($raw -replace "`r`n","`n") -replace "`r","`n"
$rawLines = $norm -split "`n"

$recHashes = New-Object System.Collections.Generic.List[string]
$lineNo = 0
foreach($ln in $rawLines){
  $lineNo++
  $t = $ln.Trim()
  if($t.Length -eq 0){ continue }
  $o = $null
  try { $o = ConvertFrom-NflJson $t } catch { Fail ("BAD_JSON_LINE:" + $lineNo) }
  # nfl.ledger.core.canon.v1 (see _lib_nfl_v1.ps1): byte-identical to the historical
  # ConvertTo-Json -Compress output, but the same on Windows PowerShell 5.1 and PowerShell 7.
  $canon = Get-NflCoreCanon $o
  $recHashes.Add((Sha256HexOfString $canon)) | Out-Null
}

$count = $recHashes.Count

function ComputeHeadOverFirst([int]$n){
  if($n -le 0){ return (Sha256HexOfString ($GENESIS + "`n" + "EMPTY")) }
  $head = ""
  for($i=0; $i -lt $n; $i++){
    if($i -eq 0){
      $head = Sha256HexOfString ($GENESIS + "`n" + $recHashes[$i])
    } else {
      $head = Sha256HexOfString ($head + "`n" + $recHashes[$i])
    }
  }
  return $head
}

$fullHead = ComputeHeadOverFirst $count
$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ---- CHECKPOINT -----------------------------------------------------
if($Mode -eq "checkpoint"){
  $firstHash = ""
  $lastHash  = ""
  if($count -gt 0){ $firstHash = $recHashes[0]; $lastHash = $recHashes[$count-1] }

  $ckpt = [ordered]@{
    schema        = "nfl.ledger.checkpoint.v1"
    utc           = $nowUtc
    chain_algo    = "sha256-linked-canonical-v1"
    genesis       = $GENESIS
    count         = $count
    head          = $fullHead
    ledger_sha256 = $LedgerSha
    first_rec     = $firstHash
    last_rec      = $lastHash
  }
  $line = ($ckpt | ConvertTo-Json -Compress -Depth 10)
  AppendUtf8NoBomLfLine $CkptLog $line
  WriteUtf8NoBomLfText  $Latest ($ckpt | ConvertTo-Json -Depth 10)

  Write-Output "NFL_LEDGER_CHECKPOINT_OK"
  Write-Output ("COUNT=" + $count)
  Write-Output ("HEAD=" + $fullHead)
  Write-Output ("LEDGER_SHA256=" + $LedgerSha)
  Write-Output ("CHECKPOINT_LOG=" + $CkptLog)
  exit 0
}

# ---- VERIFY ---------------------------------------------------------
if($Mode -eq "verify"){
  if(-not (Test-Path -LiteralPath $CkptLog -PathType Leaf)){
    Fail "NO_CHECKPOINT"
  }
  $ckLines = @((Get-Content -LiteralPath $CkptLog -Encoding UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if($ckLines.Count -eq 0){ Fail "EMPTY_CHECKPOINT_LOG" }
  $last = ConvertFrom-NflJson $ckLines[$ckLines.Count-1]

  $ckCount = [int]$last.count
  $ckHead  = [string]$last.head

  if($count -lt $ckCount){
    Write-Output ("NFL_LEDGER_VERIFY_FAIL:LEDGER_TRUNCATED")
    Write-Output ("CHECKPOINT_COUNT=" + $ckCount)
    Write-Output ("CURRENT_COUNT=" + $count)
    exit 1
  }

  $prefixHead = ComputeHeadOverFirst $ckCount
  if($prefixHead -ne $ckHead){
    Write-Output ("NFL_LEDGER_VERIFY_FAIL:PREFIX_TAMPERED")
    Write-Output ("CHECKPOINT_HEAD=" + $ckHead)
    Write-Output ("RECOMPUTED_PREFIX_HEAD=" + $prefixHead)
    exit 1
  }

  $appended = $count - $ckCount

  # record a verify receipt (append-only evidence)
  $rcptPath = Join-Path $RepoRoot "proofs\receipts\nfl.ledger.verify.ndjson"
  $rcpt = [ordered]@{
    schema            = "nfl.ledger.verify.receipt.v1"
    utc               = $nowUtc
    ok                = $true
    checkpoint_count  = $ckCount
    current_count     = $count
    appended          = $appended
    checkpoint_head   = $ckHead
    current_head      = $fullHead
    current_ledger_sha256 = $LedgerSha
  }
  AppendUtf8NoBomLfLine $rcptPath ($rcpt | ConvertTo-Json -Compress -Depth 10)

  Write-Output "NFL_LEDGER_VERIFY_OK"
  Write-Output ("CHECKPOINT_PREFIX_INTACT=" + $ckCount)
  Write-Output ("APPENDED_SINCE_CHECKPOINT=" + $appended)
  Write-Output ("CURRENT_HEAD=" + $fullHead)
  exit 0
}

Fail "UNKNOWN_MODE"
