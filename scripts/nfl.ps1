<#
  nfl.ps1 -- operator front-end for the Never Forgetting Ledger (nfl.cmd on Windows).
  Every ledger write goes through _lib_nfl_v1.ps1 (one writer, locked, self-chained). NFL stores hashes
  only: it never copies the content it witnesses.
#>
param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Cli = Join-NflPath $PSScriptRoot "nfl_cli_v1.ps1"
$InboxRegistry = Join-NflPath $RepoRoot "config" "inbox_registry.json"
if($null -eq $Rest){ $Rest = @() }

function Fail([string]$m){ throw ("NFL_FAIL:" + $m) }
function GetArg([string]$name){
  for($i=0; $i -lt $Rest.Count; $i++){ if($Rest[$i] -eq $name -and ($i + 1) -lt $Rest.Count){ return $Rest[$i + 1] } }
  return $null
}
function HasFlag([string]$name){ return ($Rest -contains $name) }

function Help {
@"
NFL - Never Forgetting Ledger

  nfl commit -Hash <hex> [-Artifact <label>]       commit a hash
  nfl lookup -Hash <hex>                           FOUND / NOT_FOUND
  nfl verify -File <path>                          hash a file and look it up
  nfl verify-chain                                 verify the ledger's embedded chain
  nfl witness-receipt -ReceiptFile <ndjson>        witness constellation.integration.receipt.v1 lines
  nfl verify-receipt  -ReceiptFile <ndjson>        VERIFIED / NOT_FOUND per receipt line
  nfl witness-own-receipts                         witness the receipts NFL wrote as a consumer

  nfl artifact commit -file <path> [-artifact <label>]
  nfl artifact commit -dir <path>  [-artifact <label>]
      -dir commits the SHA-256 of a deterministic manifest (sorted "sha256  relative/path" lines, LF);
      the manifest is kept in runtime/manifests/<hash>.txt so the directory can be re-verified later.

  nfl inbox list
  nfl inbox add -name <name> -path <dir> -mode packet|file|receipt (-local | -integration <consumer>><provider>)
  nfl inbox ingest

  nfl api [-Prefix http://127.0.0.1:8086/]          run the local HTTP API in this window
  nfl selftest                                      run every self-test (_RUN_nfl_selftests_v1.ps1)
"@
}

if($Rest.Count -eq 0 -or $Rest[0] -eq "help"){ Help; exit 0 }
$cmd = $Rest[0]

if(@("commit","lookup","verify","verify-chain","witness-receipt","verify-receipt","witness-own-receipts") -contains $cmd){
  $r = Invoke-NflScript $Cli (@($Rest) + @("-RepoRoot",$RepoRoot)) $RepoRoot
  if($r.StdOut){ Write-Output $r.StdOut.TrimEnd() }
  if($r.StdErr){ Write-Output $r.StdErr.TrimEnd() }
  exit $r.ExitCode
}

if($cmd -eq "api"){
  $prefix = GetArg "-Prefix"; if(-not $prefix){ $prefix = "http://127.0.0.1:8086/" }
  & (Join-NflPath $PSScriptRoot "nfl_api_v1.ps1") -RepoRoot $RepoRoot -Prefix $prefix
  exit $LASTEXITCODE
}

if($cmd -eq "selftest"){
  & (Join-NflPath $PSScriptRoot "_RUN_nfl_selftests_v1.ps1") -RepoRoot $RepoRoot
  exit $LASTEXITCODE
}

if($cmd -eq "inbox"){
  $sub = if($Rest.Count -gt 1){ $Rest[1] } else { "" }
  if($sub -eq "list"){ Write-Output ([System.IO.File]::ReadAllText($InboxRegistry,(Get-NflUtf8))); exit 0 }
  if($sub -eq "ingest"){
    $r = Invoke-NflScript (Join-NflPath $PSScriptRoot "nfl_ingest_inboxes_v1.ps1") @("-RepoRoot",$RepoRoot) $RepoRoot
    Write-Output ($r.StdOut + $r.StdErr).TrimEnd()
    exit $r.ExitCode
  }
  if($sub -eq "add" -or $sub -eq "add-repo"){
    $name = GetArg "-name"; $path = GetArg "-path"; $mode = GetArg "-mode"; $integ = GetArg "-integration"
    if(-not $mode){ $mode = "packet" }
    if([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[a-z0-9][a-z0-9-]*$'){ Fail "BAD_INBOX_NAME" }
    if([string]::IsNullOrWhiteSpace($path)){ Fail "MISSING_PATH" }
    if(@("packet","file","receipt") -notcontains $mode){ Fail "BAD_MODE" }
    if((-not (HasFlag "-local")) -and [string]::IsNullOrWhiteSpace($integ)){ Fail "NEED_-local_OR_-integration" }
    $cfg = ConvertFrom-NflJson ([System.IO.File]::ReadAllText($InboxRegistry,(Get-NflUtf8)))
    $list = New-Object System.Collections.Generic.List[object]
    foreach($i in @($cfg.inboxes)){ if($i.name -ne $name){ $list.Add($i) } }
    $row = [ordered]@{ name = $name; path = $path; mode = $mode }
    if(HasFlag "-local"){ $row["source"] = "local" } else { $row["integration"] = $integ }
    $list.Add($row)
    $out = ConvertTo-NflCanonicalJson ([ordered]@{ schema = "nfl.inbox_registry.v1"; inboxes = $list.ToArray() })
    [System.IO.File]::WriteAllText($InboxRegistry, ($out + "`n"), (Get-NflUtf8))
    Write-Output "NFL_INBOX_ADD_OK"
    Write-Output ("INBOX=" + $name)
    exit 0
  }
  Fail ("UNKNOWN_INBOX_COMMAND:" + $sub)
}

if($cmd -eq "artifact"){
  if($Rest.Count -lt 2 -or $Rest[1] -ne "commit"){ Fail "UNKNOWN_ARTIFACT_COMMAND" }
  $file = GetArg "-file"; $dir = GetArg "-dir"; $label = GetArg "-artifact"
  if(-not [string]::IsNullOrWhiteSpace($file)){
    $h = Get-NflSha256File $file
    if([string]::IsNullOrWhiteSpace($label)){ $label = "file:" + (Split-Path -Leaf $file) }
    $r = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $h -Artifact $label
    Write-Output "NFL_ARTIFACT_COMMIT_OK"; Write-Output "TYPE=file"; Write-Output ("HASH=" + $h); Write-Output ("SEQ=" + $r.Seq)
    exit 0
  }
  if(-not [string]::IsNullOrWhiteSpace($dir)){
    $root = (Resolve-Path -LiteralPath $dir).Path
    $lines = New-Object System.Collections.Generic.List[string]
    foreach($f in @(Get-ChildItem -LiteralPath $root -Recurse -File)){
      $rel = $f.FullName.Substring($root.Length).TrimStart([char]'\',[char]'/') -replace '\\','/'
      $lines.Add(((Get-NflSha256File $f.FullName) + "  " + $rel))
    }
    $sorted = [string[]]$lines.ToArray(); [Array]::Sort($sorted,[StringComparer]::Ordinal)
    $text = ($sorted -join "`n") + "`n"
    $h = Get-NflSha256HexOfString $text
    $mdir = Join-NflPath $RepoRoot "runtime" "manifests"
    if(-not (Test-Path -LiteralPath $mdir)){ New-Item -ItemType Directory -Force -Path $mdir | Out-Null }
    [System.IO.File]::WriteAllText((Join-NflPath $mdir ($h + ".txt")), $text, (Get-NflUtf8))
    if([string]::IsNullOrWhiteSpace($label)){ $label = "dir-manifest:" + (Split-Path -Leaf $root) }
    $r = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash $h -Artifact $label
    Write-Output "NFL_ARTIFACT_COMMIT_OK"; Write-Output "TYPE=directory"; Write-Output ("HASH=" + $h); Write-Output ("FILES=" + $sorted.Count); Write-Output ("SEQ=" + $r.Seq)
    exit 0
  }
  Fail "MISSING_FILE_OR_DIR"
}

Fail ("UNKNOWN_COMMAND:" + $cmd)
