param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot,
  [Parameter(Mandatory=$true)]
  [string]$InputDir,
  [Parameter(Mandatory=$true)]
  [string]$OutDir,
  [Parameter(Mandatory=$false)]
  [string]$CprRepoRoot = $env:NFL_CPR_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$InputDir = [System.IO.Path]::GetFullPath($InputDir)
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$CprRepoRoot = [System.IO.Path]::GetFullPath($CprRepoRoot)

function Die([string]$Message) {
  throw $Message
}

function EnsureDir([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    Die "ENSURE_DIR_EMPTY_PATH"
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text) {
  $Parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($Parent)) {
    EnsureDir $Parent
  }
  $T = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $T.EndsWith("`n")) {
    $T += "`n"
  }
  $Enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$T,$Enc)
}

function Parse-GateFile([string]$Path) {
  $Tok = $null
  $Err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tok,[ref]$Err)
  if ($Err -and $Err.Count -gt 0) {
    $E = $Err[0]
    throw ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$E.Extent.StartLineNumber,$E.Extent.StartColumnNumber,$E.Message)
  }
}

function Get-RelativePathNormalized([string]$BasePath,[string]$TargetPath) {
  $BaseFull = [System.IO.Path]::GetFullPath($BasePath)
  $TargetFull = [System.IO.Path]::GetFullPath($TargetPath)
  $BaseUri = [System.Uri]($BaseFull.TrimEnd('\') + '\')
  $TargetUri = [System.Uri]$TargetFull
  $Rel = $BaseUri.MakeRelativeUri($TargetUri).ToString()
  $Rel = [System.Uri]::UnescapeDataString($Rel)
  return $Rel.Replace('\','/')
}

function Add-NflCprReceipt([string]$RepoRoot,[hashtable]$Receipt) {
  $ReceiptPath = Join-Path $RepoRoot "proofs\receipts\nfl.cpr.ndjson"
  $Line = ($Receipt | ConvertTo-Json -Depth 20 -Compress)
  $Existing = ""
  if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
    $Existing = [System.IO.File]::ReadAllText($ReceiptPath)
    $Existing = $Existing.Replace("`r`n","`n").Replace("`r","`n")
  }
  if ($Existing.Length -gt 0 -and -not $Existing.EndsWith("`n")) {
    $Existing += "`n"
  }
  $Existing += $Line
  $Existing += "`n"
  Write-Utf8NoBomLf $ReceiptPath $Existing
}

function Fail([string]$Code,[string]$Detail) {
  $Receipt = [ordered]@{
    schema = "nfl.cpr.receipt.v1"
    event_type = "build"
    result = "FAIL"
    code = $Code
    detail = $Detail
    input_dir = $InputDir.Replace('\','/')
    out_dir = $OutDir.Replace('\','/')
  }
  Add-NflCprReceipt -RepoRoot $RepoRoot -Receipt $Receipt
  Write-Host ("NFL_CPR_BUILD_FAIL:" + $Code) -ForegroundColor Red
  exit 1
}

try {
  Parse-GateFile (Join-Path $CprRepoRoot "cli\cpr.ps1")

  if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
    Fail "INPUT_DIR_MISSING" $InputDir
  }

  EnsureDir $OutDir

  $PSExe = (Get-Process -Id $PID).Path
  $Output = & $PSExe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File (Join-Path $CprRepoRoot "cli\cpr.ps1") `
    build `
    -RepoRoot $CprRepoRoot `
    -InputDir $InputDir `
    -OutDir $OutDir 2>&1

  $ExitCode = $LASTEXITCODE
  $OutputText = (($Output | ForEach-Object { $_.ToString() }) -join "`n")

  if ($ExitCode -ne 0) {
    $OutputText | Out-Host
    Fail "CPR_BUILD_NONZERO" $OutputText
  }

  if ($OutputText -notmatch 'CPR_BUILD_OK') {
    $OutputText | Out-Host
    Fail "CPR_BUILD_TOKEN_MISSING" $OutputText
  }

  $PacketDir = ""
  $PacketId = ""

  foreach ($Line in ($OutputText -split "`n")) {
    if ($Line -like 'PACKET_DIR:*') {
      $PacketDir = $Line.Substring('PACKET_DIR:'.Length).Trim()
    }
    if ($Line -like 'PACKET_ID:*') {
      $PacketId = $Line.Substring('PACKET_ID:'.Length).Trim().ToLowerInvariant()
    }
  }

  $Receipt = [ordered]@{
    schema = "nfl.cpr.receipt.v1"
    event_type = "build"
    result = "PASS"
    input_dir = $InputDir.Replace('\','/')
    out_dir = $OutDir.Replace('\','/')
    packet_dir = $PacketDir.Replace('\','/')
    packet_rel = (Get-RelativePathNormalized $RepoRoot $PacketDir)
    packet_id = $PacketId
    delegated_to = "CPR"
  }

  Add-NflCprReceipt -RepoRoot $RepoRoot -Receipt $Receipt

  Write-Host ("PACKET_DIR: " + $PacketDir) -ForegroundColor Gray
  Write-Host ("PACKET_ID: " + $PacketId) -ForegroundColor Gray
  Write-Host "NFL_CPR_BUILD_OK" -ForegroundColor Green
  exit 0
}
catch {
  Fail "UNHANDLED" $_.Exception.Message
}
