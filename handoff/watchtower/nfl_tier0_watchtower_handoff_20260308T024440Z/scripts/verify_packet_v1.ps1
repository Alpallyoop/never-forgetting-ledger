param(
  [Parameter(Mandatory=$true)][string]$PacketRoot,
  [Parameter(Mandatory=$true)][string]$SigNamespace
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw ("NFL_VERIFY_FAIL: " + $m) }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ return (New-Object System.Text.UTF8Encoding($false)) }
function CanonLf([string]$s){ return $s.Replace("`r`n","`n").Replace("`r","`n") }
function ReadUtf8([string]$p){ return [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function HexSha256Bytes([byte[]]$b){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $h = $sha.ComputeHash($b)
  } finally { $sha.Dispose() }
  $sb = New-Object System.Text.StringBuilder
  for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }
  return $sb.ToString()
}
function VerifySha256Sums([string]$root){
  $sumPath = Join-Path $root "sha256sums.txt"
  if(-not (Test-Path -LiteralPath $sumPath -PathType Leaf)){ Die ("MISSING_SHA256SUMS: " + $sumPath) }
  $lines = Get-Content -LiteralPath $sumPath -ErrorAction Stop
  $arr = @(@($lines))
  if(@($arr).Count -eq 0){ Die "EMPTY_SHA256SUMS" }
  $count = 0
  foreach($ln0 in @($arr)){
    $ln = CanonLf ([string]$ln0)
    if([string]::IsNullOrWhiteSpace($ln)){ continue }
    $m = [regex]::Match($ln, "^(?<hex>[0-9a-fA-F]{64})\s+\*?(?<rel>.+)$")
    if(-not $m.Success){ Die ("BAD_SHA256SUM_LINE: " + $ln) }
    $hex = ($m.Groups["hex"].Value).ToLowerInvariant()
    $rel = $m.Groups["rel"].Value
    $rel = $rel.Trim()
    $rel = $rel -replace "^[\\/]+",""
    $full = Join-Path $root $rel
    if(-not (Test-Path -LiteralPath $full -PathType Leaf)){ Die ("Missing file: " + $full) }
    $b = [System.IO.File]::ReadAllBytes($full)
    $calc = HexSha256Bytes $b
    if($calc -ne $hex){ Die ("SHA256_MISMATCH: " + $rel + " expected=" + $hex + " got=" + $calc) }
    $count++
  }
  return $count
}

$PacketRoot = (Resolve-Path -LiteralPath $PacketRoot).Path
if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ Die ("PacketRoot not found: " + $PacketRoot) }
Write-Host ("PACKET: " + $PacketRoot) -ForegroundColor Cyan
Write-Host ("NAMESPACE: " + $SigNamespace) -ForegroundColor Cyan

$shaEntries = VerifySha256Sums $PacketRoot
Write-Host ("OK: sha256sums verified entries=" + $shaEntries) -ForegroundColor Green

$sigPath = Join-Path $PacketRoot "signatures\ingest.sig"
$targetPath = Join-Path $PacketRoot "payload\sig_envelope.json"
$pubPath = Join-Path $PacketRoot "signer_ed25519.pub"
if(-not (Test-Path -LiteralPath $sigPath -PathType Leaf)){ Die ("MISSING_SIG: " + $sigPath) }
if(-not (Test-Path -LiteralPath $targetPath -PathType Leaf)){ Die ("MISSING_TARGET: " + $targetPath) }
if(-not (Test-Path -LiteralPath $pubPath -PathType Leaf)){ Die ("MISSING_SIGNER_PUB: " + $pubPath) }
Write-Host ("SIG: " + $sigPath)
Write-Host ("TARGET: " + $targetPath)
Write-Host ("PUB: " + $pubPath)

# principal: read from sig_envelope.json if present
$principal = $null
try {
  $envTxt = ReadUtf8 $targetPath
  $envObj = $envTxt | ConvertFrom-Json -ErrorAction Stop
  if($envObj -ne $null){
    if(($envObj.PSObject.Properties.Name -contains "principal") -and $envObj.principal){ $principal = [string]$envObj.principal }
    elseif(($envObj.PSObject.Properties.Name -contains "signing_principal") -and $envObj.signing_principal){ $principal = [string]$envObj.signing_principal }
    elseif(($envObj.PSObject.Properties.Name -contains "producer") -and $envObj.producer){ $principal = [string]$envObj.producer }
  }
} catch { $principal = $null }
if([string]::IsNullOrWhiteSpace($principal)){ $principal = "single-tenant/owner/user/keira" }
Write-Host ("PRINCIPAL: " + $principal)

# build allowed_signers temp file: "<principal> <pubkeyline>"
$tmpDir = Join-Path $env:TEMP ("covenant_allowed_signers_" + (Get-Date).ToString("yyyyMMdd_HHmmssfff"))
EnsureDir $tmpDir
$asPath = Join-Path $tmpDir "allowed_signers"
$pubLine = (ReadUtf8 $pubPath).Trim()
if([string]::IsNullOrWhiteSpace($pubLine)){ Die ("EMPTY_SIGNER_PUB: " + $pubPath) }
$asLine = ($principal + " " + $pubLine)
[System.IO.File]::WriteAllText($asPath, (CanonLf $asLine) + "`n", (Utf8NoBom))
Write-Host ("ALLOWED_SIGNERS_TMP: " + $asPath)

# ssh-keygen verify: feed signed data via stdin
$ssh = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
if(-not (Test-Path -LiteralPath $ssh -PathType Leaf)){ Die ("MISSING_SSH_KEYGEN: " + $ssh) }
$bytes = [System.IO.File]::ReadAllBytes($targetPath)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ssh
# Avoid String.Format/-f: build args by concatenation with explicit quoting
$psi.Arguments = ("-Y verify -f `"" + $asPath + "`" -I `"" + $principal + "`" -n `"" + $SigNamespace + "`" -s `"" + $sigPath + "`"")
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
Write-Host ("VERIFY_CMD: " + $ssh + " " + $psi.Arguments) -ForegroundColor DarkGray
[void]$p.Start()
$p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd()
$err = $p.StandardError.ReadToEnd()
$p.WaitForExit()
if(-not [string]::IsNullOrWhiteSpace($out)){ Write-Host $out }
if(-not [string]::IsNullOrWhiteSpace($err)){ Write-Host $err -ForegroundColor DarkYellow }
if($p.ExitCode -ne 0){ Die ("SIG_VERIFY_FAIL exit=" + $p.ExitCode) }
Write-Host "SIG_VERIFY_OK" -ForegroundColor Green

# derive signer key hash for receipt (from pubkey bytes)
$pubBytes = [System.Text.Encoding]::UTF8.GetBytes((CanonLf $pubLine))
$signerKeyHash = HexSha256Bytes $pubBytes

# emit result object (for in-process consumers)
$result = [pscustomobject]@{
  ok = $true
  packet_root = $PacketRoot
  sig_namespace = $SigNamespace
  principal = $principal
  sha256_entries = $shaEntries
  signature_path = $sigPath
  signed_target = $targetPath
  signer_pub = $pubPath
  signer_key_hash = $signerKeyHash
}
$result
