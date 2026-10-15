param(
  [Parameter(Mandatory=$true)][string]$PacketDir,
  [Parameter(Mandatory=$true)][string]$SigningKeyPath,
  [Parameter(Mandatory=$true)][string]$SignerIdentity,
  [Parameter(Mandatory=$false)][string]$SignatureNamespace = "nfl/ledger-export"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_SIGN_FAIL:" + $m) }
function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}
function ReadUtf8([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("READ_MISSING:" + $Path) }
  [System.IO.File]::ReadAllText($Path,(Utf8NoBom))
}
function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("WRITE_FAILED:" + $Path) }
}
function Sha256HexFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("HASH_MISSING:" + $Path) }
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$PacketDir = (Resolve-Path -LiteralPath $PacketDir).Path
$SigningKeyPath = (Resolve-Path -LiteralPath $SigningKeyPath).Path

$ManifestPath = Join-Path $PacketDir "manifest.json"
$SumsPath     = Join-Path $PacketDir "sha256sums.txt"
$SigDir       = Join-Path $PacketDir "signatures"
$RootSigPath  = ($ManifestPath + ".sig")
$SigPath      = Join-Path $SigDir "manifest.sig"
$PubKeyPath   = ($SigningKeyPath + ".pub")
$PubCopyPath  = Join-Path $SigDir "signer.pub"
$AllowedPath  = Join-Path $SigDir "allowed_signers"
$EnvPath      = Join-Path $SigDir "sig_envelope.json"

if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){ Fail "MANIFEST_MISSING" }
if(-not (Test-Path -LiteralPath $SumsPath -PathType Leaf)){ Fail "SHA256SUMS_MISSING" }
if(-not (Test-Path -LiteralPath $SigningKeyPath -PathType Leaf)){ Fail "SIGNING_KEY_MISSING" }
if(-not (Test-Path -LiteralPath $PubKeyPath -PathType Leaf)){ Fail "PUBKEY_MISSING" }

$ssh = Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if($null -eq $ssh){ Fail "SSH_KEYGEN_MISSING" }

EnsureDir $SigDir

if(Test-Path -LiteralPath $RootSigPath -PathType Leaf){ Remove-Item -LiteralPath $RootSigPath -Force }
if(Test-Path -LiteralPath $SigPath -PathType Leaf){ Remove-Item -LiteralPath $SigPath -Force }
if(Test-Path -LiteralPath $PubCopyPath -PathType Leaf){ Remove-Item -LiteralPath $PubCopyPath -Force }
if(Test-Path -LiteralPath $AllowedPath -PathType Leaf){ Remove-Item -LiteralPath $AllowedPath -Force }
if(Test-Path -LiteralPath $EnvPath -PathType Leaf){ Remove-Item -LiteralPath $EnvPath -Force }

& $ssh.Source -Y sign -f $SigningKeyPath -n $SignatureNamespace $ManifestPath | Out-Host
if($LASTEXITCODE -ne 0){ Fail "SIGN_FAILED" }

if(-not (Test-Path -LiteralPath $RootSigPath -PathType Leaf)){ Fail "SIG_FILE_NOT_CREATED" }

Move-Item -LiteralPath $RootSigPath -Destination $SigPath -Force
Copy-Item -LiteralPath $PubKeyPath -Destination $PubCopyPath -Force

$pub = (ReadUtf8 $PubCopyPath).Trim()
$allowedLine = $SignerIdentity + " " + $pub
WriteUtf8NoBomLfText $AllowedPath ($allowedLine + "`n")

$env = [ordered]@{
  schema = "nfl.signature_envelope.v1"
  target = "manifest.json"
  signer_identity = $SignerIdentity
  namespace = $SignatureNamespace
  signature_path = "signatures/manifest.sig"
  public_key_path = "signatures/signer.pub"
  allowed_signers_path = "signatures/allowed_signers"
  manifest_sha256 = (Sha256HexFile $ManifestPath)
}
WriteUtf8NoBomLfText $EnvPath (($env | ConvertTo-Json -Compress -Depth 10))

# rewrite sha256sums to include signature artifacts
$files = @(Get-ChildItem -LiteralPath $PacketDir -Recurse -File | Sort-Object FullName)
$rows = New-Object System.Collections.Generic.List[string]
foreach($f in @(@($files))){
  if($f.FullName -eq $SumsPath){ continue }
  $rel = $f.FullName.Substring($PacketDir.Length + 1).Replace("\","/")
  $hash = Sha256HexFile $f.FullName
  [void]$rows.Add(($hash + "  " + $rel))
}
WriteUtf8NoBomLfText $SumsPath ((@($rows.ToArray()) -join "`n") + "`n")

if(-not (Test-Path -LiteralPath $SigPath -PathType Leaf)){ Fail "POST_SIG_MISSING" }
if(-not (Test-Path -LiteralPath $PubCopyPath -PathType Leaf)){ Fail "POST_PUBCOPY_MISSING" }
if(-not (Test-Path -LiteralPath $AllowedPath -PathType Leaf)){ Fail "POST_ALLOWED_MISSING" }
if(-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)){ Fail "POST_ENV_MISSING" }

Write-Output "NFL_SIGN_PACKET_OK"
Write-Output ("PACKET_DIR=" + $PacketDir)
Write-Output ("SIGNATURE_PATH=" + $SigPath)
Write-Output ("PUBCOPY_PATH=" + $PubCopyPath)
Write-Output ("ALLOWED_SIGNERS_PATH=" + $AllowedPath)
Write-Output ("ENVELOPE_PATH=" + $EnvPath)
