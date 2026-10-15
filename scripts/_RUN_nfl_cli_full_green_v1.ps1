param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_CLI_FULL_GREEN_FAIL:" + $m) }

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Utf8NoBom(){
  New-Object System.Text.UTF8Encoding($false)
}

function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}

function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
}

function ParseGateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("PARSEGATE_MISSING:" + $Path)
  }
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and @(@($err)).Count -gt 0){
    $msg = (($err | Select-Object -First 8 | ForEach-Object { $_.ToString() }) -join " | ")
    Fail ("PARSEGATE_FAIL:" + $Path + "::" + $msg)
  }
}

function StartChild([string]$FileName,[string]$Arguments,[string]$WorkingDir){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = $Arguments
  $psi.WorkingDirectory = $WorkingDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  return [pscustomobject]@{
    ExitCode = [int]$p.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
  }
}

function AssertSuccess([string]$Name,$Result,[string]$Needle){
  if($Result.ExitCode -ne 0){
    Fail ($Name + "_EXIT_" + $Result.ExitCode)
  }
  if([string]::IsNullOrWhiteSpace($Needle)){ return }
  if($Result.StdOut -notmatch [regex]::Escape($Needle)){
    Fail ($Name + "_MISSING_TOKEN:" + $Needle)
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe = (Get-Process -Id $PID).Path

$CliPath      = Join-Path $RepoRoot "scripts\nfl_cli_v1.ps1"
$ExportPath   = Join-Path $RepoRoot "scripts\nfl_export_ledger_packet_v1.ps1"
$SignPath     = Join-Path $RepoRoot "scripts\nfl_sign_ledger_packet_v1.ps1"
$WitnessPath  = Join-Path $RepoRoot "scripts\nfl_witness_cpr_verify_v1.ps1"
$IngestPath   = Join-Path $RepoRoot "scripts\nfl_ingest_inboxes_v1.ps1"
$ApiPath      = Join-Path $RepoRoot "scripts\nfl_api_v1.ps1"
$ConfigPath   = Join-Path $RepoRoot "config\inbox_registry.json"
$KeyPath      = Join-Path $RepoRoot "proofs\keys\id_ed25519"
. (Join-Path $PSScriptRoot "_nfl_paths_v1.ps1")
$CprRoot      = Resolve-NflCprRoot $RepoRoot ""
if($null -eq $CprRoot){ Fail "CPR_ROOT_NOT_FOUND (set NFL_CPR_ROOT)" }
$CprVerifier  = Join-Path $CprRoot "scripts\verify_packet_v1.ps1"

foreach($p in @($CliPath,$ExportPath,$SignPath,$WitnessPath,$IngestPath,$ApiPath,$ConfigPath,$CprVerifier)){
  if(-not (Test-Path -LiteralPath $p)){
    Fail ("MISSING_REQUIRED_PATH:" + $p)
  }
}

foreach($p in @($CliPath,$ExportPath,$SignPath,$WitnessPath,$IngestPath,$ApiPath,$CprVerifier)){
  ParseGateFile $p
}

if(-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)){ Fail "SIGNING_KEY_MISSING" }
if(-not (Test-Path -LiteralPath ($KeyPath + ".pub") -PathType Leaf)){ Fail "SIGNING_PUBKEY_MISSING" }

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunRoot = Join-Path $RepoRoot ("proofs\runs\nfl_cli_full_green\" + $RunId)
EnsureDir $RunRoot

# Clean outbox so we do not reuse stale packets.
$Outbox = Join-Path $RepoRoot "packets\outbox"
EnsureDir $Outbox
Get-ChildItem -LiteralPath $Outbox -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

# -------------------------------------------------------------------
# 1) CLI smoke: commit + lookup + verify
# -------------------------------------------------------------------
# SHA-256 of "nfl.cli.full_green.smoke:<run id>" (the ledger takes hex digests only).
$SmokeHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes("nfl.cli.full_green.smoke:" + $RunId))) -Algorithm SHA256).Hash.ToLowerInvariant()

$r1 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" commit -Hash "{1}" -Artifact "{2}"' -f $CliPath,$SmokeHash,("full-green-" + $RunId)) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "01_commit.stdout.txt") $r1.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "01_commit.stderr.txt") $r1.StdErr
AssertSuccess "CLI_COMMIT" $r1 "COMMIT_OK"

$r2 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" lookup -Hash "{1}"' -f $CliPath,$SmokeHash) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "02_lookup.stdout.txt") $r2.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "02_lookup.stderr.txt") $r2.StdErr
AssertSuccess "CLI_LOOKUP" $r2 "FOUND"

$r3 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" verify -File "{1}"' -f $CliPath,$CliPath) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "03_verify.stdout.txt") $r3.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "03_verify.stderr.txt") $r3.StdErr
if($r3.ExitCode -ne 0){ Fail ("CLI_VERIFY_EXIT_" + $r3.ExitCode) }
if(($r3.StdOut -notmatch 'VERIFIED') -and ($r3.StdOut -notmatch 'NOT_FOUND')){
  Fail "CLI_VERIFY_UNEXPECTED_OUTPUT"
}

# -------------------------------------------------------------------
# 2) Export packet
# -------------------------------------------------------------------
$r4 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f $ExportPath,$RepoRoot) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "04_export.stdout.txt") $r4.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "04_export.stderr.txt") $r4.StdErr
AssertSuccess "EXPORT" $r4 "NFL_EXPORT_LEDGER_PACKET_OK"

$PacketDir = Get-ChildItem -LiteralPath $Outbox -Directory |
  Sort-Object LastWriteTimeUtc |
  Select-Object -Last 1 |
  ForEach-Object { $_.FullName }

if([string]::IsNullOrWhiteSpace($PacketDir)){ Fail "PACKET_DIR_RESOLUTION_FAILED" }

$ManifestPath = Join-Path $PacketDir "manifest.json"
$PacketIdPath = Join-Path $PacketDir "packet_id.txt"
$SumsPath     = Join-Path $PacketDir "sha256sums.txt"
$PayloadPath  = Join-Path $PacketDir "payload\ledger.ndjson"

foreach($p in @($ManifestPath,$PacketIdPath,$SumsPath,$PayloadPath)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("PACKET_SURFACE_MISSING:" + $p)
  }
}

# -------------------------------------------------------------------
# 3) Sign packet
# -------------------------------------------------------------------
$r5 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PacketDir "{1}" -SigningKeyPath "{2}" -SignerIdentity "nfl.local"' -f $SignPath,$PacketDir,$KeyPath) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "05_sign.stdout.txt") $r5.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "05_sign.stderr.txt") $r5.StdErr
AssertSuccess "SIGN" $r5 "NFL_SIGN_PACKET_OK"

$SigDir   = Join-Path $PacketDir "signatures"
$SigFile  = Join-Path $SigDir "manifest.sig"
$PubCopy  = Join-Path $SigDir "signer.pub"
$Allowed  = Join-Path $SigDir "allowed_signers"
$Envelope = Join-Path $SigDir "sig_envelope.json"

foreach($p in @($SigFile,$PubCopy,$Allowed,$Envelope)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("SIGNATURE_SURFACE_MISSING:" + $p)
  }
}

# -------------------------------------------------------------------
# 4) CPR verify
# -------------------------------------------------------------------
$r6 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{2}" -PacketPath "{1}"' -f $CprVerifier,$PacketDir,$CprRoot) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "06_cpr_verify.stdout.txt") $r6.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "06_cpr_verify.stderr.txt") $r6.StdErr
AssertSuccess "CPR_VERIFY" $r6 "CPR_VERIFY_OK"

# -------------------------------------------------------------------
# 5) NFL witness of CPR verify
# -------------------------------------------------------------------
$r7 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -CprVerifierPath "{2}" -PacketDir "{3}"' -f $WitnessPath,$RepoRoot,$CprVerifier,$PacketDir) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "07_witness.stdout.txt") $r7.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "07_witness.stderr.txt") $r7.StdErr
AssertSuccess "NFL_WITNESS" $r7 "NFL_WITNESS_CPR_VERIFY_OK"

# -------------------------------------------------------------------
# 6) Ingest smoke
# -------------------------------------------------------------------
$r8 = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f $IngestPath,$RepoRoot) $RepoRoot
WriteUtf8NoBomLfText (Join-Path $RunRoot "08_ingest.stdout.txt") $r8.StdOut
WriteUtf8NoBomLfText (Join-Path $RunRoot "08_ingest.stderr.txt") $r8.StdErr
AssertSuccess "INGEST" $r8 "NFL_INGEST_INBOXES_OK"

# -------------------------------------------------------------------
# 7) Freeze receipt
# -------------------------------------------------------------------
$ReceiptPath = Join-Path $RepoRoot "proofs\receipts\nfl_cli_full_green.ndjson"

$receipt = [ordered]@{
  schema = "nfl.cli.full_green.receipt.v1"
  utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  run_id = $RunId
  ok = $true
  packet_dir = $PacketDir
  cpr_verifier = $CprVerifier
  outputs = [ordered]@{
    commit = "COMMIT_OK"
    lookup = "FOUND"
    export = "NFL_EXPORT_LEDGER_PACKET_OK"
    sign = "NFL_SIGN_PACKET_OK"
    cpr_verify = "CPR_VERIFY_OK"
    witness = "NFL_WITNESS_CPR_VERIFY_OK"
    ingest = "NFL_INGEST_INBOXES_OK"
  }
  run_root = $RunRoot
}

[System.IO.File]::AppendAllText($ReceiptPath, (($receipt | ConvertTo-Json -Compress -Depth 20) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Output "NFL_CLI_FULL_GREEN_OK"
Write-Output ("RUN_ID=" + $RunId)
Write-Output ("RUN_ROOT=" + $RunRoot)
Write-Output ("PACKET_DIR=" + $PacketDir)
Write-Output ("RECEIPT=" + $ReceiptPath)