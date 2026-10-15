param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $cr=[char]13; $lf=[char]10; $u=$t.Replace("$cr$lf","$lf").Replace("$cr","$lf"); if(-not $u.EndsWith("$lf")){ $u = $u + "$lf" }; return $u }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=Utf8NoBom; [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes((NormalizeLf $Text))); if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("WRITE_FAILED: " + $Path) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; throw ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }
function Sha256Hex([string]$Path){ (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function RelPath([string]$Root,[string]$Full){ $bs=[char]92; $r=(Resolve-Path -LiteralPath $Root).Path.TrimEnd($bs); $f=(Resolve-Path -LiteralPath $Full).Path; if($f.Length -lt $r.Length){ return $f.Replace($bs,[char]47) }; if($f.Substring(0,$r.Length).ToLowerInvariant() -ne $r.ToLowerInvariant()){ return $f.Replace($bs,[char]47) }; $rel=$f.Substring($r.Length).TrimStart($bs); return $rel.Replace($bs,[char]47) }
function WriteSha256Sums([string]$Root,[string]$OutPath,[string[]]$FilesAbs){ $rows=New-Object System.Collections.Generic.List[string]; foreach($fp in $FilesAbs){ if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){ throw ("SHA256SUMS_MISSING_FILE: " + $fp) }; $hex=Sha256Hex $fp; $rel=RelPath $Root $fp; [void]$rows.Add(($hex + "  " + $rel)) }; WriteUtf8NoBomLf $OutPath ((@($rows.ToArray()) -join "`n") + "`n") }
function RunChild([string]$PSExe,[string]$ScriptPath,[string]$RepoRoot,[string]$StdOut,[string]$StdErr){
  if(Test-Path -LiteralPath $StdOut -PathType Leaf){ Remove-Item -LiteralPath $StdOut -Force }
  if(Test-Path -LiteralPath $StdErr -PathType Leaf){ Remove-Item -LiteralPath $StdErr -Force }
  $args = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",$ScriptPath,"-RepoRoot",$RepoRoot)
  $p = Start-Process -FilePath $PSExe -ArgumentList $args -WorkingDirectory $RepoRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr
  $so = "" ; $se = ""
  if(Test-Path -LiteralPath $StdOut -PathType Leaf){ $so = [System.IO.File]::ReadAllText($StdOut,(Utf8NoBom)) }
  if(Test-Path -LiteralPath $StdErr -PathType Leaf){ $se = [System.IO.File]::ReadAllText($StdErr,(Utf8NoBom)) }
  return @{ exit=[int]$p.ExitCode; stdout=$so; stderr=$se }
}
function AssertContains([string]$Hay,[string]$Needle,[string]$FailToken){ if($null -eq $Hay){ $Hay="" }; if($Hay -notmatch [regex]::Escape($Needle)){ throw ($FailToken + ":MISSING_NEEDLE:" + $Needle) } }
function AssertAnyTokenExact([string]$Text,[string[]]$ExactTokens,[string]$FailToken){ $t=NormalizeLf $Text; foreach($x in @(@($ExactTokens))){ if($null -eq $x){ continue }; $pat="(?m)^" + [regex]::Escape([string]$x) + "$"; if($t -match $pat){ return } }; throw ($FailToken + ":NO_EXPECTED_TOKEN") }

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir=Join-Path $RepoRoot "scripts"
$ProofsDir=Join-Path $RepoRoot "proofs"
$RcptRoot=Join-Path $ProofsDir "receipts"
EnsureDir $ProofsDir
EnsureDir $RcptRoot

# narrow Tier-0 parse gate (NO _PATCH_*.ps1)
$must=@((Join-Path $ScriptsDir "verify_packet_v1.ps1"),(Join-Path $ScriptsDir "selftest_verify_packet_v1.ps1"),(Join-Path $ScriptsDir "selftest_vectors_v1.ps1"),(Join-Path $ScriptsDir "_selftest_nfl_tier0_v2.ps1"))
$libs=@(Get-ChildItem -LiteralPath $ScriptsDir -File -Filter "lib_*.ps1" -ErrorAction SilentlyContinue | Sort-Object FullName)
foreach($lf in $libs){ $must += @($lf.FullName) }
foreach($mf in $must){ if(-not (Test-Path -LiteralPath $mf -PathType Leaf)){ throw ("PARSEGATE_REQUIRED_MISSING: " + $mf) }; ParseGateFile $mf }
Write-Output "PARSE_GATE_OK"

$stamp=(Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$bundle=Join-Path $RcptRoot $stamp
EnsureDir $bundle
$out1=Join-Path $bundle "selftest_verify_packet.stdout.txt"
$err1=Join-Path $bundle "selftest_verify_packet.stderr.txt"
$out2=Join-Path $bundle "selftest_vectors.stdout.txt"
$err2=Join-Path $bundle "selftest_vectors.stderr.txt"
$PSExe=(Get-Command powershell.exe -ErrorAction Stop).Source
$st1=Join-Path $ScriptsDir "selftest_verify_packet_v1.ps1"
$st2=Join-Path $ScriptsDir "selftest_vectors_v1.ps1"
$r1=RunChild $PSExe $st1 $RepoRoot $out1 $err1
if($r1.exit -ne 0){ Write-Output ("SELFTEST_VERIFY_PACKET_EXIT=" + $r1.exit); throw "SELFTEST_VERIFY_PACKET_FAILED" }
AssertContains $r1.stdout "SELFTEST_OK" "SELFTEST_VERIFY_PACKET_BAD_STDOUT"
$r2=RunChild $PSExe $st2 $RepoRoot $out2 $err2
if($r2.exit -ne 0){ Write-Output ("SELFTEST_VECTORS_EXIT=" + $r2.exit); throw "SELFTEST_VECTORS_FAILED" }
AssertContains $r2.stdout "VECTOR_SELFTEST_OK" "SELFTEST_VECTORS_BAD_STDOUT"
$expected=@("NFL_VERIFY_FAIL:SHA256_MISMATCH","NFL_VERIFY_FAIL:MISSING_SIG","NFL_VERIFY_FAIL:SIG_VERIFY_FAIL","NFL_VERIFY_FAIL:MISSING_SHA256SUMS","NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE","NFL_VERIFY_FAIL:TRAVERSAL_PATH","NFL_VERIFY_FAIL:MISSING_TARGET")
AssertAnyTokenExact $r2.stdout $expected "ERROR_TAXONOMY_NOT_EMITTED"
$rcpt=Join-Path $bundle "nfl.tier0.selftest.v1.ndjson"
$obj=[ordered]@{ type="nfl.tier0.selftest.v1"; utc=$stamp; ok=$true; repo_root=$RepoRoot; bundle_dir=$bundle; selftest_verify_exit=[int]$r1.exit; selftest_vectors_exit=[int]$r2.exit }
$line=($obj | ConvertTo-Json -Compress)
WriteUtf8NoBomLf $rcpt ($line + "`n")
$files=@(Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName)
$abs=New-Object System.Collections.Generic.List[string]
foreach($ff in $files){ [void]$abs.Add($ff.FullName) }
$sum=Join-Path $bundle "sha256sums.txt"
WriteSha256Sums $bundle $sum ($abs.ToArray())
Write-Output "NFL_TIER0_SELFTEST_OK"
Write-Output ("BUNDLE_DIR=" + $bundle)
