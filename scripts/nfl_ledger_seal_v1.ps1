<#
  nfl_ledger_seal_v1.ps1

  Cryptographically SEAL a durable-ledger checkpoint, and VERIFY a seal.
  Reuses the OpenSSH ssh-keygen signing lane (same as nfl_sign_ledger_packet_v1.ps1).

  Modes:
    seal         - read the latest checkpoint, build a canonical seal payload
                   (head/count/ledger_sha256), sign it with proofs/keys/id_ed25519,
                   and store the seal under proofs/checkpoints/seals/<runid>/.
    verify-seal  - verify (1) the signature over the payload AND
                   (2) that the current ledger's first N records still chain to the
                   SEALED head. Both must hold -> NFL_LEDGER_SEAL_VERIFY_OK.

  Chain canonicalization is identical to nfl_ledger_checkpoint_v1.ps1.
#>

param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][ValidateSet("seal","verify-seal")][string]$Mode = "seal",
  [Parameter(Mandatory=$false)][string]$SealDir = "",
  [Parameter(Mandatory=$false)][string]$SignerIdentity = "nfl.local",
  [Parameter(Mandatory=$false)][string]$Namespace = "nfl/ledger-seal",
  [Parameter(Mandatory=$false)][string]$SigningKeyPath = "",
  [Parameter(Mandatory=$false)][string]$TrustedPubPath = "",
  [Parameter(Mandatory=$false)][string]$TrustBundlePath = "",
  [Parameter(Mandatory=$false)][string]$RootPubPath = "",
  [Parameter(Mandatory=$false)][string]$BundleNamespace = "nfl/ingest-receipt"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")  # host-independent JSON + core canon

$GENESIS = "nfl.ledger.chain.v1"

function Fail([string]$m){
  $tag = if($Mode -eq "seal"){ "SEAL" } else { "SEAL_VERIFY" }
  throw ("NFL_LEDGER_" + $tag + "_FAIL:" + $m)
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
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes((NormalizeLf $Text)))
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
  try { return ((($sha.ComputeHash($bytes)) | ForEach-Object { $_.ToString("x2") }) -join "") }
  finally { $sha.Dispose() }
}
function Sha256HexOfString([string]$s){ return (Sha256Hex ((Utf8NoBom).GetBytes($s))) }
function GetProp($obj,[string]$name){
  $p = $obj.PSObject.Properties[$name]
  if($null -eq $p){ return $null }
  return $p.Value
}
function KeyCore([string]$publine){
  # ssh pubkey "<type> <base64> [comment]" -> identity is type+base64 (comment ignored)
  $parts = @(($publine.Trim() -split '\s+'))
  if($parts.Count -ge 2){ return ($parts[0] + " " + $parts[1]) }
  return $publine.Trim()
}
function ResolveBundleAuthorized([string]$BundlePath,[string]$Ns){
  # Returns @{ authorized = @(@{principal;pub}); cores = @(all key-cores) } from a
  # neverlost.trust_bundle.v1 file: authorized = keys whose namespaces include $Ns.
  # Plain arrays throughout (robust in PS 5.1 StrictMode).
  $b = ConvertFrom-NflJson (Get-Content -LiteralPath $BundlePath -Raw)
  if([string](GetProp $b "schema") -ne "neverlost.trust_bundle.v1"){ Fail ("TRUST_BUNDLE_BAD_SCHEMA:" + [string](GetProp $b "schema")) }
  $authorized = @()
  $cores = @()
  foreach($pr in @(GetProp $b "principals")){
    $principal = [string](GetProp $pr "principal")
    foreach($k in @(GetProp $pr "keys")){
      $pub = [string](GetProp $k "pubkey")
      $cores += ,(KeyCore $pub)
      $nss = @(GetProp $k "namespaces" | ForEach-Object { [string]$_ })
      if($nss -contains $Ns){ $authorized += ,([pscustomobject]@{ principal=$principal; pub=$pub }) }
    }
  }
  return [pscustomobject]@{ authorized=@($authorized); cores=@($cores) }
}

# ---- resolve paths --------------------------------------------------
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Ledger   = Join-Path $RepoRoot "data\ledger.ndjson"
$CkptLog  = Join-Path $RepoRoot "proofs\checkpoints\nfl_ledger_checkpoint_v1.ndjson"
$SealsDir = Join-Path $RepoRoot "proofs\checkpoints\seals"
if([string]::IsNullOrWhiteSpace($SigningKeyPath)){ $SigningKeyPath = Join-Path $RepoRoot "proofs\keys\id_ed25519" }

if(-not (Test-Path -LiteralPath $Ledger -PathType Leaf)){ Fail ("LEDGER_MISSING:" + $Ledger) }

$ssh = Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if($null -eq $ssh){ Fail "SSH_KEYGEN_MISSING" }

# ---- ledger chain (identical algo to checkpoint script) -------------
function LoadRecHashes(){
  $rawBytes = [System.IO.File]::ReadAllBytes($Ledger)
  $raw = [System.Text.Encoding]::UTF8.GetString($rawBytes)
  if($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF){ $raw = $raw.Substring(1) }
  $norm = ($raw -replace "`r`n","`n") -replace "`r","`n"
  $out = New-Object System.Collections.Generic.List[string]
  foreach($ln in ($norm -split "`n")){
    $t = $ln.Trim()
    if($t.Length -eq 0){ continue }
    $o = $null
    try { $o = ConvertFrom-NflJson $t } catch { Fail "BAD_JSON_LINE" }
    $canon = Get-NflCoreCanon $o
    $out.Add((Sha256HexOfString $canon)) | Out-Null
  }
  return ,$out
}
function ComputeHeadOverFirst($recHashes,[int]$n){
  if($n -le 0){ return (Sha256HexOfString ($GENESIS + "`n" + "EMPTY")) }
  $head = ""
  for($i=0; $i -lt $n; $i++){
    if($i -eq 0){ $head = Sha256HexOfString ($GENESIS + "`n" + $recHashes[$i]) }
    else        { $head = Sha256HexOfString ($head + "`n" + $recHashes[$i]) }
  }
  return $head
}

function BuildPayload([string]$head,[int]$count,[string]$ledgerSha){
  return ("nfl.ledger.seal.v1`n" + "head=" + $head + "`n" + "count=" + $count + "`n" + "ledger_sha256=" + $ledgerSha + "`n")
}

# ---- ssh-keygen verify (message on stdin as RAW bytes) --------------
function VerifySignature([string]$AllowedPath,[string]$Identity,[string]$Ns,[string]$SigPath,[string]$PayloadPath){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh.Source
  $psi.Arguments = ('-Y verify -f "{0}" -I "{1}" -n "{2}" -s "{3}"' -f $AllowedPath,$Identity,$Ns,$SigPath)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $bytes = [System.IO.File]::ReadAllBytes($PayloadPath)
  $bs = $p.StandardInput.BaseStream
  $bs.Write($bytes,0,$bytes.Length); $bs.Flush(); $bs.Close()
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ code=[int]$p.ExitCode; out=$out; err=$err }
}

# ====================================================================
# SEAL
# ====================================================================
if($Mode -eq "seal"){
  if(-not (Test-Path -LiteralPath $CkptLog -PathType Leaf)){ Fail "NO_CHECKPOINT" }
  $ckLines = @((Get-Content -LiteralPath $CkptLog -Encoding UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if($ckLines.Count -eq 0){ Fail "EMPTY_CHECKPOINT_LOG" }
  $ck = ConvertFrom-NflJson $ckLines[$ckLines.Count-1]

  $head     = [string]$ck.head
  $count    = [int]$ck.count
  $ledgerSha= [string]$ck.ledger_sha256

  # bind: recompute head over current ledger prefix, must equal checkpoint head
  $recHashes = LoadRecHashes
  $recompute = ComputeHeadOverFirst $recHashes $count
  if($recompute -ne $head){ Fail "CHECKPOINT_STALE_VS_LEDGER" }

  if(-not (Test-Path -LiteralPath $SigningKeyPath -PathType Leaf)){ Fail ("SIGNING_KEY_MISSING:" + $SigningKeyPath) }
  $pubPath = $SigningKeyPath + ".pub"
  if(-not (Test-Path -LiteralPath $pubPath -PathType Leaf)){ Fail ("PUBKEY_MISSING:" + $pubPath) }

  $RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  $dir = Join-Path $SealsDir $RunId
  EnsureDir $dir
  $payloadPath = Join-Path $dir "seal_payload.txt"
  $sigPath     = Join-Path $dir "seal_payload.txt.sig"
  $pubCopy     = Join-Path $dir "signer.pub"
  $allowed     = Join-Path $dir "allowed_signers"
  $sealJson    = Join-Path $dir "seal.json"

  WriteUtf8NoBomLfText $payloadPath (BuildPayload $head $count $ledgerSha)

  & $ssh.Source -Y sign -f $SigningKeyPath -n $Namespace $payloadPath | Out-Host
  if($LASTEXITCODE -ne 0){ Fail "SIGN_FAILED" }
  if(-not (Test-Path -LiteralPath $sigPath -PathType Leaf)){ Fail "SIG_NOT_CREATED" }

  Copy-Item -LiteralPath $pubPath -Destination $pubCopy -Force
  $pub = ([System.IO.File]::ReadAllText($pubCopy,(Utf8NoBom))).Trim()
  WriteUtf8NoBomLfText $allowed ($SignerIdentity + " " + $pub + "`n")

  $seal = [ordered]@{
    schema        = "nfl.ledger.seal.v1"
    utc           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    run_id        = $RunId
    signer_identity = $SignerIdentity
    namespace     = $Namespace
    head          = $head
    count         = $count
    ledger_sha256 = $ledgerSha
    payload       = "seal_payload.txt"
    signature     = "seal_payload.txt.sig"
    public_key    = "signer.pub"
    allowed_signers = "allowed_signers"
  }
  WriteUtf8NoBomLfText $sealJson (($seal | ConvertTo-Json -Depth 10))

  # immediate self-check: verify our own seal before declaring OK
  $chk = VerifySignature $allowed $SignerIdentity $Namespace $sigPath $payloadPath
  if($chk.code -ne 0){ Fail ("SELF_VERIFY_FAILED:" + ($chk.err.Trim())) }

  AppendUtf8NoBomLfLine (Join-Path $RepoRoot "proofs\receipts\nfl.ledger.seal.ndjson") ($seal | ConvertTo-Json -Compress -Depth 10)

  Write-Output "NFL_LEDGER_SEAL_OK"
  Write-Output ("SEAL_DIR=" + $dir)
  Write-Output ("HEAD=" + $head)
  Write-Output ("COUNT=" + $count)
  exit 0
}

# ====================================================================
# VERIFY-SEAL
# ====================================================================
if($Mode -eq "verify-seal"){
  if([string]::IsNullOrWhiteSpace($SealDir)){
    if(-not (Test-Path -LiteralPath $SealsDir -PathType Container)){ Fail "NO_SEALS" }
    $latest = Get-ChildItem -LiteralPath $SealsDir -Directory | Sort-Object Name | Select-Object -Last 1
    if($null -eq $latest){ Fail "NO_SEALS" }
    $SealDir = $latest.FullName
  }
  $SealDir = (Resolve-Path -LiteralPath $SealDir).Path

  $sealJson = Join-Path $SealDir "seal.json"
  $payloadPath = Join-Path $SealDir "seal_payload.txt"
  $sigPath = Join-Path $SealDir "seal_payload.txt.sig"
  $allowed = Join-Path $SealDir "allowed_signers"
  foreach($p in @($sealJson,$payloadPath,$sigPath,$allowed)){
    if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Fail ("SEAL_SURFACE_MISSING:" + $p) }
  }
  $seal = ConvertFrom-NflJson (Get-Content -LiteralPath $sealJson -Raw)
  $sealedHead  = [string]$seal.head
  $sealedCount = [int]$seal.count
  $identity    = [string]$seal.signer_identity
  $ns          = [string]$seal.namespace

  # (1) signature over payload. Two trust models:
  #   - TrustBundlePath: authorize the signer via a neverlost.trust_bundle.v1 (optionally
  #     root-of-trust verified against RootPubPath); the signer must be a key the bundle
  #     lists for the seal's namespace. (Parity with verify_nfl_export_v1.py.)
  #   - else TrustedPubPath: pin to a single out-of-band pubkey (default id_ed25519.pub).
  if(-not [string]::IsNullOrWhiteSpace($TrustBundlePath)){
    if(-not (Test-Path -LiteralPath $TrustBundlePath -PathType Leaf)){ Fail ("TRUST_BUNDLE_MISSING:" + $TrustBundlePath) }

    if(-not [string]::IsNullOrWhiteSpace($RootPubPath)){
      if(-not (Test-Path -LiteralPath $RootPubPath -PathType Leaf)){ Fail ("ROOT_PUB_MISSING:" + $RootPubPath) }
      $bundleSig = $TrustBundlePath + ".sig"
      if(-not (Test-Path -LiteralPath $bundleSig -PathType Leaf)){ Fail ("BUNDLE_SIG_MISSING:" + $bundleSig) }
      $rootPub = ([System.IO.File]::ReadAllText($RootPubPath,(Utf8NoBom))).Trim()
      EnsureDir (Join-Path $RepoRoot "proofs\_tmp"); $tmpRoot = Join-Path (Join-Path $RepoRoot "proofs\_tmp") ("nfl_root_allowed_" + [Guid]::NewGuid().ToString("N") + ".txt")
      WriteUtf8NoBomLfText $tmpRoot ("neverlost.root " + $rootPub + "`n")
      try {
        $rb = VerifySignature $tmpRoot "neverlost.root" $BundleNamespace $bundleSig $TrustBundlePath
      } finally {
        if(Test-Path -LiteralPath $tmpRoot -PathType Leaf){ Remove-Item -LiteralPath $tmpRoot -Force -ErrorAction SilentlyContinue }
      }
      if($rb.code -ne 0){
        [void](Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider "neverlost" -Contract "neverlost.trust_bundle.v1" -ResponseSha256 (Get-NflSha256File $TrustBundlePath) -Outcome "refused" -ErrorToken "BUNDLE_SIG_INVALID")
        Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:BUNDLE_SIG_INVALID"
        Write-Output ("SSHKEYGEN_STDERR=" + ($rb.err.Trim()))
        exit 1
      }
      Write-Output ("BUNDLE_SIG_OK root=" + $RootPubPath + " ns=" + $BundleNamespace)
      [void](Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider "neverlost" -Contract "neverlost.trust_bundle.v1" -ResponseSha256 (Get-NflSha256File $TrustBundlePath) -Outcome "ok")
    } else {
      Write-Output "WARNING: BUNDLE_UNVERIFIED (no -RootPubPath; bundle contents trusted on faith)"
      [void](Write-NflOwnIntegrationReceipt -RepoRoot $RepoRoot -Provider "neverlost" -Contract "neverlost.trust_bundle.v1" -ResponseSha256 (Get-NflSha256File $TrustBundlePath) -Outcome "unknown" -ErrorToken "BUNDLE_UNVERIFIED")
    }

    try {
      $resolved = ResolveBundleAuthorized $TrustBundlePath $ns
      $authorized = @($resolved.authorized)
      $allCores = @($resolved.cores)
      $r = $null
      foreach($cand in $authorized){
        EnsureDir (Join-Path $RepoRoot "proofs\_tmp"); $tmpAllowed = Join-Path (Join-Path $RepoRoot "proofs\_tmp") ("nfl_bundle_allowed_" + [Guid]::NewGuid().ToString("N") + ".txt")
        WriteUtf8NoBomLfText $tmpAllowed ([string]$cand.principal + " " + [string]$cand.pub + "`n")
        try {
          $try = VerifySignature $tmpAllowed ([string]$cand.principal) $ns $sigPath $payloadPath
        } finally {
          if(Test-Path -LiteralPath $tmpAllowed -PathType Leaf){ Remove-Item -LiteralPath $tmpAllowed -Force -ErrorAction SilentlyContinue }
        }
        if($try.code -eq 0){ $r = $try; Write-Output ("SIGNATURE_OK authorized_principal=" + [string]$cand.principal); break }
      }
    } catch {
      Write-Output ("NFL_LEDGER_SEAL_VERIFY_FAIL:BUNDLE_AUTH_EXCEPTION:" + $_.Exception.Message + " @line " + $_.InvocationInfo.ScriptLineNumber)
      exit 1
    }
    if($null -eq $r){
      # precise reason via the seal's bundled signer.pub (messaging only; the anchor is the bundle)
      $signerCore = KeyCore ([System.IO.File]::ReadAllText((Join-Path $SealDir "signer.pub"),(Utf8NoBom)))
      $authCores = @($authorized | ForEach-Object { KeyCore ([string]$_.pub) })
      if(-not ($allCores -contains $signerCore)){
        Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:SIGNER_NOT_IN_BUNDLE"
      } elseif(-not ($authCores -contains $signerCore)){
        Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:NAMESPACE_NOT_AUTHORIZED"
      } else {
        Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:SIG_INVALID"
      }
      exit 1
    }
  } else {
    if([string]::IsNullOrWhiteSpace($TrustedPubPath)){ $TrustedPubPath = Join-Path $RepoRoot "proofs\keys\id_ed25519.pub" }
    if(-not (Test-Path -LiteralPath $TrustedPubPath -PathType Leaf)){ Fail ("TRUSTED_PUB_MISSING:" + $TrustedPubPath) }
    $trustedPub = ([System.IO.File]::ReadAllText($TrustedPubPath,(Utf8NoBom))).Trim()
    EnsureDir (Join-Path $RepoRoot "proofs\_tmp"); $tmpAllowed = Join-Path (Join-Path $RepoRoot "proofs\_tmp") ("nfl_seal_allowed_" + [Guid]::NewGuid().ToString("N") + ".txt")
    WriteUtf8NoBomLfText $tmpAllowed ($identity + " " + $trustedPub + "`n")
    try {
      $r = VerifySignature $tmpAllowed $identity $ns $sigPath $payloadPath
    } finally {
      if(Test-Path -LiteralPath $tmpAllowed -PathType Leaf){ Remove-Item -LiteralPath $tmpAllowed -Force -ErrorAction SilentlyContinue }
    }
    if($r.code -ne 0){
      Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:SIG_INVALID"
      Write-Output ("SSHKEYGEN_STDERR=" + ($r.err.Trim()))
      exit 1
    }
  }

  # (2) ledger still chains to the sealed head
  $recHashes = LoadRecHashes
  if($recHashes.Count -lt $sealedCount){
    Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:LEDGER_TRUNCATED"
    exit 1
  }
  $recompute = ComputeHeadOverFirst $recHashes $sealedCount
  if($recompute -ne $sealedHead){
    Write-Output "NFL_LEDGER_SEAL_VERIFY_FAIL:LEDGER_HEAD_MISMATCH"
    Write-Output ("SEALED_HEAD=" + $sealedHead)
    Write-Output ("RECOMPUTED=" + $recompute)
    exit 1
  }

  AppendUtf8NoBomLfLine (Join-Path $RepoRoot "proofs\receipts\nfl.ledger.seal_verify.ndjson") ([ordered]@{
    schema="nfl.ledger.seal_verify.receipt.v1"; utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    ok=$true; seal_dir=$SealDir; sealed_count=$sealedCount; sealed_head=$sealedHead
  } | ConvertTo-Json -Compress -Depth 10)

  Write-Output "NFL_LEDGER_SEAL_VERIFY_OK"
  Write-Output ("SEAL_DIR=" + $SealDir)
  Write-Output ("SEALED_COUNT=" + $sealedCount)
  Write-Output ("SIGNATURE=VALID")
  Write-Output ("LEDGER_MATCHES_SEALED_HEAD=YES")
  exit 0
}

Fail "UNKNOWN_MODE"
