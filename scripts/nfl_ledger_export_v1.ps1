<#
  nfl_ledger_export_v1.ps1

  Produce a PORTABLE, self-verifiable export of the ledger under
  proofs/exports/<runid>/. The export uses a language-neutral canonicalization
  (no dependency on PowerShell JSON), so an independent verifier in any language
  can recompute the chain head. The export is signed with ssh-keygen.

  Canonicalization (identical in verify_nfl_export_v1.py):
    canon_i  = "hash=" + hash + "\n" + "artifact=" + artifact + "\n" + "timestamp=" + timestamp   (no trailing newline)
    rec_i    = sha256_hex(utf8(canon_i))
    head_0   = sha256_hex(utf8("nfl.ledger.export.v1" + "\n" + rec_0))
    head_i   = sha256_hex(utf8(head_{i-1} + "\n" + rec_i))
  Signed payload:
    "nfl.ledger.export.v1\ncount=<N>\nexport_head=<head>\nledger_sha256=<sha>\n"
#>

param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][string]$SignerIdentity = "nfl.local",
  [Parameter(Mandatory=$false)][string]$Namespace = "nfl/ledger-export-seal",
  [Parameter(Mandatory=$false)][string]$SigningKeyPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")  # host-independent JSON + core canon

$GENESIS = "nfl.ledger.export.v1"

function Fail([string]$m){ throw ("NFL_LEDGER_EXPORT_FAIL:" + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}
function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes((NormalizeLf $Text)))
}
function WriteUtf8NoBomExact([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($Text))
}
function Sha256Hex([byte[]]$b){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try { return ((($sha.ComputeHash($b)) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $sha.Dispose() }
}
function Sha256HexOfString([string]$s){ return (Sha256Hex ((Utf8NoBom).GetBytes($s))) }
function GetProp($o,[string]$n){ $p=$o.PSObject.Properties[$n]; if($null -eq $p){ return $null }; return $p.Value }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Ledger   = Join-Path $RepoRoot "data\ledger.ndjson"
if(-not (Test-Path -LiteralPath $Ledger -PathType Leaf)){ Fail ("LEDGER_MISSING:" + $Ledger) }
if([string]::IsNullOrWhiteSpace($SigningKeyPath)){ $SigningKeyPath = Join-Path $RepoRoot "proofs\keys\id_ed25519" }
if(-not (Test-Path -LiteralPath $SigningKeyPath -PathType Leaf)){ Fail ("SIGNING_KEY_MISSING:" + $SigningKeyPath) }
$pubPath = $SigningKeyPath + ".pub"
if(-not (Test-Path -LiteralPath $pubPath -PathType Leaf)){ Fail ("PUBKEY_MISSING:" + $pubPath) }
$ssh = Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if($null -eq $ssh){ Fail "SSH_KEYGEN_MISSING" }

# ---- read ledger, build canonical records + chain -------------------
$rawBytes = [System.IO.File]::ReadAllBytes($Ledger)
$LedgerSha = Sha256Hex $rawBytes
$raw = [System.Text.Encoding]::UTF8.GetString($rawBytes)
if($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF){ $raw = $raw.Substring(1) }
$norm = ($raw -replace "`r`n","`n") -replace "`r","`n"

$records = New-Object System.Collections.Generic.List[object]
$recHashes = New-Object System.Collections.Generic.List[string]
foreach($ln in ($norm -split "`n")){
  $t = $ln.Trim()
  if($t.Length -eq 0){ continue }
  $o = $null
  try { $o = ConvertFrom-NflJson $t } catch { Fail "BAD_JSON_LINE" }
  $h = [string](GetProp $o "hash")
  $aRaw = (GetProp $o "artifact")
  $a = if($null -eq $aRaw){ "" } else { [string]$aRaw }
  $ts = [string](GetProp $o "timestamp")
  foreach($fv in @($h,$a,$ts)){
    if($fv -match "`n" -or $fv.Contains([char]0x1f)){ Fail "FIELD_HAS_CONTROL_CHAR" }
  }
  $canon = ("hash=" + $h + "`n" + "artifact=" + $a + "`n" + "timestamp=" + $ts)
  $recHashes.Add((Sha256HexOfString $canon)) | Out-Null
  $records.Add(([ordered]@{ hash=$h; artifact=$a; timestamp=$ts })) | Out-Null
}
$count = $recHashes.Count
if($count -eq 0){ Fail "EMPTY_LEDGER" }

$head = ""
for($i=0; $i -lt $count; $i++){
  if($i -eq 0){ $head = Sha256HexOfString ($GENESIS + "`n" + $recHashes[$i]) }
  else        { $head = Sha256HexOfString ($head + "`n" + $recHashes[$i]) }
}

# ---- write export bundle -------------------------------------------
$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$dir = Join-Path $RepoRoot ("proofs\exports\" + $RunId)
EnsureDir $dir
$recordsFile = Join-Path $dir "records.ndjson"
$payloadFile = Join-Path $dir "export_payload.txt"
$sigFile     = Join-Path $dir "export_payload.txt.sig"
$pubCopy     = Join-Path $dir "signer.pub"
$allowed     = Join-Path $dir "allowed_signers"
$manifest    = Join-Path $dir "export_manifest.json"

$recLines = New-Object System.Collections.Generic.List[string]
foreach($r in $records){ $recLines.Add(($r | ConvertTo-Json -Compress)) | Out-Null }
WriteUtf8NoBomExact $recordsFile (($recLines.ToArray() -join "`n") + "`n")

# exact payload (NO extra normalization beyond explicit LFs)
$payload = ($GENESIS + "`n" + "count=" + $count + "`n" + "export_head=" + $head + "`n" + "ledger_sha256=" + $LedgerSha + "`n")
WriteUtf8NoBomExact $payloadFile $payload

& $ssh.Source -Y sign -f $SigningKeyPath -n $Namespace $payloadFile | Out-Host
if($LASTEXITCODE -ne 0){ Fail "SIGN_FAILED" }
if(-not (Test-Path -LiteralPath $sigFile -PathType Leaf)){ Fail "SIG_NOT_CREATED" }

Copy-Item -LiteralPath $pubPath -Destination $pubCopy -Force
$pub = ([System.IO.File]::ReadAllText($pubCopy,(Utf8NoBom))).Trim()
WriteUtf8NoBomExact $allowed ($SignerIdentity + " " + $pub + "`n")

$man = [ordered]@{
  schema        = "nfl.ledger.export.v1"
  utc           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  export_algo   = "sha256-linked-fieldkv-v1"
  genesis       = $GENESIS
  count         = $count
  export_head   = $head
  ledger_sha256 = $LedgerSha
  signer_identity = $SignerIdentity
  namespace     = $Namespace
  records_file  = "records.ndjson"
  payload_file  = "export_payload.txt"
  signature_file = "export_payload.txt.sig"
  public_key_file = "signer.pub"
  allowed_signers_file = "allowed_signers"
}
WriteUtf8NoBomLfText $manifest (($man | ConvertTo-Json -Depth 10))

Write-Output "NFL_LEDGER_EXPORT_OK"
Write-Output ("EXPORT_DIR=" + $dir)
Write-Output ("COUNT=" + $count)
Write-Output ("EXPORT_HEAD=" + $head)
