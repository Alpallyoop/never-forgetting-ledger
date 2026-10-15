param(
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter()][int]$TimeoutSeconds = 60
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "_lib_neverlost_v1.ps1")
function Invoke-SshKeygen([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if(-not $ssh){ throw "SSH_KEYGEN_NOT_FOUND" }

  $quoted = New-Object System.Collections.Generic.List[string]
  foreach ($a in @(@($Argv))) {
    if ($null -eq $a) { $a = "" }
    if ($a -match '[\s"]') { [void]$quoted.Add('"' + ($a -replace '"','\"') + '"') } else { [void]$quoted.Add($a) }
  }
  $argStr = ($quoted.ToArray() -join " ")

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  $sbOut = New-Object System.Text.StringBuilder
  $sbErr = New-Object System.Text.StringBuilder

  $outHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $e)
    if ($e.Data -ne $null) { [void]$sbOut.AppendLine($e.Data) }
  }
  $errHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $e)
    if ($e.Data -ne $null) { [void]$sbErr.AppendLine($e.Data) }
  }

  $p.add_OutputDataReceived($outHandler)
  $p.add_ErrorDataReceived($errHandler)

  if (-not $p.Start()) { throw "Failed to start ssh-keygen" }
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    throw ("ssh-keygen timeout after " + $TimeoutSeconds + "s: " + $argStr)
  }

  try { $p.WaitForExit() } catch { }

  $stdout = ($sbOut.ToString() -replace "
","
" -replace "","
").TrimEnd()
  $stderr = ($sbErr.ToString() -replace "
","
" -replace "","
").TrimEnd()

  if ($p.ExitCode -ne 0) {
    throw ("ssh-keygen failed (exit " + $p.ExitCode + "): " + $argStr + "
STDERR:
" + $stderr + "
STDOUT:
" + $stdout)
  }

  return $stdout
}

$Root = Get-RepoRoot
$KeyPriv = Join-Path $Root "proofs\keys\nfl-local_ed25519"
$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath $KeyPriv -PathType Leaf)) { throw ("Missing signing key: " + $KeyPriv) }
if (-not (Test-Path -LiteralPath $File -PathType Leaf))    { throw ("Missing file: " + $File) }
if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }

$OutSig = $File + ".sig"
if (Test-Path -LiteralPath $OutSig -PathType Leaf) { Remove-Item -LiteralPath $OutSig -Force }

Write-Output ("RUN: ssh-keygen -Y sign (I=" + $Principal + " n=" + $Namespace + ")")
Write-Output ("Signing file " + $File)

[void](Invoke-SshKeygen -Argv @("-Y","sign","-f",$KeyPriv,"-I",$Principal,"-n",$Namespace,"-s",$OutSig,$File) -TimeoutSeconds $TimeoutSeconds)

if (-not (Test-Path -LiteralPath $OutSig -PathType Leaf)) { throw ("Signature not created: " + $OutSig) }
Write-Output ("OK: " + $OutSig)
