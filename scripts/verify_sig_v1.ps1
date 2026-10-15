param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$Sig,
  [Parameter(Mandatory=$false)][string]$Principal = "single-tenant/local/authority/nfl",
  [Parameter(Mandatory=$false)][int]$TimeoutSeconds = 30
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Quote-Arg([string]$x){
  if ($null -eq $x) { return '""' }
  if ($x -eq "")    { return '""' }
  if ($x -match '[\s"]') { return '"' + ($x -replace '"','\"') + '"' }
  return $x
}
function Invoke-OpenSshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if(-not $ssh){ throw "SSH_KEYGEN_NOT_FOUND" }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach($a in @(@($Argv))){ [void]$parts.Add((Quote-Arg $a)) }
  $argStr = ($parts.ToArray() -join " ")
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }
  try { $p.StandardInput.Close() } catch { }
  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) { try { $p.Kill() | Out-Null } catch { } ; Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr) }
  $stdout=""; $stderr=""
  try { $stdout = $p.StandardOutput.ReadToEnd() } catch { $stdout = "" }
  try { $stderr = $p.StandardError.ReadToEnd()  } catch { $stderr = "" }
  $stdout = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  if ($p.ExitCode -ne 0) { Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGS: " + $argStr + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout) }
  return $true
}

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$AllowedSigners = Join-Path $root "proofs\trust\allowed_signers"
if (-not (Test-Path -LiteralPath $AllowedSigners -PathType Leaf)) { Die ("Missing allowed_signers: " + $AllowedSigners) }

if ([string]::IsNullOrWhiteSpace($Namespace)) { Die "Namespace empty" }
if ([string]::IsNullOrWhiteSpace($Principal)) { Die "Principal empty" }
if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Die ("Missing file: " + $File) }
if (-not (Test-Path -LiteralPath $Sig  -PathType Leaf)) { Die ("Missing sig: " + $Sig) }

if(-not (Test-Path -LiteralPath (Join-Path $root "proofs\_tmp"))){ New-Item -ItemType Directory -Force -Path (Join-Path $root "proofs\_tmp") | Out-Null }; $tmpRev = Join-Path (Join-Path $root "proofs\_tmp") ("nfl_revocations_empty_" + [Guid]::NewGuid().ToString("N") + ".txt")
"" | Set-Content -LiteralPath $tmpRev -Encoding UTF8

try {
  Write-Output ("RUN: ssh-keygen -Y verify (I=" + $Principal + " n=" + $Namespace + ")")
  [void](Invoke-OpenSshKeygenPSI -Argv @("-Y","verify","-f",$AllowedSigners,"-I",$Principal,"-n",$Namespace,"-s",$Sig,"-r",$tmpRev,$File) -TimeoutSeconds $TimeoutSeconds)
} finally {
  try { Remove-Item -LiteralPath $tmpRev -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Output "OK: VERIFIED"
