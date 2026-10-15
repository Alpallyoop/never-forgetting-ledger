param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("NFL_CLI_SURFACE_FULL_GREEN_FAIL:" + $m)
}

function Parse-Gate([string]$Path){
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  if($errors -and $errors.Count -gt 0){
    $e = $errors[0]
    throw ("PARSE_FAIL:{0}:{1}:{2}:{3}" -f $Path,$e.Extent.StartLineNumber,$e.Extent.StartColumnNumber,$e.Message)
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

# -----------------------------
# 1. Parse-gate all PS scripts
# -----------------------------
$ScriptPaths = @(
  "scripts\nfl_ingest_inboxes_v1.ps1",
  "scripts\nfl_install_ingest_task_v1.ps1"
)

foreach($rel in $ScriptPaths){
  $p = Join-Path $RepoRoot $rel
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("MISSING_SCRIPT:" + $p)
  }
  Parse-Gate $p
}

# -----------------------------
# 2. Validate JSON config
# -----------------------------
$ConfigPath = Join-Path $RepoRoot "config\inbox_registry.json"

if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)){
  Fail ("CONFIG_MISSING:" + $ConfigPath)
}

try {
  $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
  Fail ("CONFIG_JSON_INVALID:" + $ConfigPath + "|" + $_.Exception.Message)
}

if(-not $json.schema){
  Fail "CONFIG_SCHEMA_MISSING"
}

if($json.schema -ne "nfl.inbox_registry.v1"){
  Fail ("CONFIG_SCHEMA_INVALID:" + $json.schema)
}

if(-not $json.inboxes -or $json.inboxes.Count -eq 0){
  Fail "CONFIG_INBOXES_EMPTY"
}

# -----------------------------
# 3. Run ingest manually
# -----------------------------
$IngestScript = Join-Path $RepoRoot "scripts\nfl_ingest_inboxes_v1.ps1"

$proc = Start-Process powershell.exe `
  -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$IngestScript`" -RepoRoot `"$RepoRoot`"" `
  -NoNewWindow `
  -Wait `
  -PassThru

if($proc.ExitCode -ne 0){
  Fail ("INGEST_FAILED_EXIT_" + $proc.ExitCode)
}

# -----------------------------
# 4. Verify receipts exist
# -----------------------------
$ReceiptsPath = Join-Path $RepoRoot "proofs\receipts"

if(-not (Test-Path -LiteralPath $ReceiptsPath)){
  Fail "RECEIPTS_DIR_MISSING"
}

$files = Get-ChildItem -Path $ReceiptsPath -Recurse -File -ErrorAction SilentlyContinue

if(-not $files -or $files.Count -eq 0){
  Fail "NO_RECEIPTS_WRITTEN"
}

# -----------------------------
# SUCCESS
# -----------------------------
Write-Output "NFL_CLI_SURFACE_FULL_GREEN_OK"