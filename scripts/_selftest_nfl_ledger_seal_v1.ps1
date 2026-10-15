<#
  _selftest_nfl_ledger_seal_v1.ps1

  Negative proof for nfl_ledger_seal_v1.ps1 (seal / verify-seal).
  Everything runs in a temp dir with throwaway ed25519 keys. Never uses the real
  signing key and never touches the real data\ledger.ndjson.

  Cases (verify-seal is always pinned to a TRUSTED pubkey):
    CLEAN            : seal with keyMain, trust keyMain  -> NFL_LEDGER_SEAL_VERIFY_OK
    WRONG_KEY        : seal with keyEvil, trust keyMain  -> SEAL_VERIFY_FAIL:SIG_INVALID
    TAMPERED_PAYLOAD : seal, edit seal_payload.txt        -> SEAL_VERIFY_FAIL:SIG_INVALID
    ALTERED_SEAL_HEAD: seal, edit seal.json head          -> SEAL_VERIFY_FAIL:LEDGER_HEAD_MISMATCH
    LEDGER_MUTATED   : seal, mutate the ledger            -> SEAL_VERIFY_FAIL:LEDGER_HEAD_MISMATCH
  Trust-bundle cases (verify-seal via -TrustBundlePath/-RootPubPath):
    BUNDLE_OK        : authorized key + verified root      -> NFL_LEDGER_SEAL_VERIFY_OK
    BUNDLE_WRONG_ROOT: bundle pinned to a different root    -> SEAL_VERIFY_FAIL:BUNDLE_SIG_INVALID
    BUNDLE_UNKNOWN_KEY: signer not listed in the bundle     -> SEAL_VERIFY_FAIL:SIGNER_NOT_IN_BUNDLE
    BUNDLE_WRONG_NS  : signer present, wrong namespace       -> SEAL_VERIFY_FAIL:NAMESPACE_NOT_AUTHORIZED
#>

param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_LEDGER_SEAL_SELFTEST_FAIL:" + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
function WriteText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path; EnsureDir $dir
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($t))
}
function WriteLedger([string]$Path,[string[]]$Records){
  $text = ""; foreach($r in $Records){ $text += ($r + "`n") }
  WriteText $Path $text
}
function Rec([string]$h,[string]$a,[string]$t){
  return ([ordered]@{ hash=$h; artifact=$a; timestamp=$t } | ConvertTo-Json -Compress)
}
function StartChild([string]$FileName,[string]$Arguments){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName; $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
  [void]$p.Start()
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; StdOut=$out; StdErr=$err }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe = (Get-Process -Id $PID).Path
$ssh = (Get-Command @("ssh-keygen.exe","ssh-keygen") -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if(-not $ssh){ throw "SSH_KEYGEN_NOT_FOUND" }
$CkptScript = Join-Path $RepoRoot "scripts\nfl_ledger_checkpoint_v1.ps1"
$SealScript = Join-Path $RepoRoot "scripts\nfl_ledger_seal_v1.ps1"
foreach($s in @($CkptScript,$SealScript)){ if(-not (Test-Path -LiteralPath $s -PathType Leaf)){ Fail ("MISSING_SCRIPT:" + $s) } }

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$TmpRoot = Join-Path $RepoRoot ("proofs\_tmp\ledger_seal_selftest_" + $RunId)
EnsureDir $TmpRoot

$SEED = @(
  (Rec "aaa1" "one"   "2026-01-01T00:00:00Z"),
  (Rec "bbb2" "two"   "2026-01-02T00:00:00Z"),
  (Rec "ccc3" "three" "2026-01-03T00:00:00Z")
)

function GenKey([string]$KeyPath){
  $r = StartChild $ssh ('-t ed25519 -f "{0}" -N "" -C "nfl-ledger-selftest" -q' -f $KeyPath)
  if($r.ExitCode -ne 0){ Fail ("KEYGEN_FAILED:" + $KeyPath + ":" + $r.StdErr.Trim()) }
  if(-not (Test-Path -LiteralPath ($KeyPath + ".pub") -PathType Leaf)){ Fail ("KEY_PUB_MISSING:" + $KeyPath) }
}
function RunCkpt([string]$caseRoot){ return (StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -Mode checkpoint' -f $CkptScript,$caseRoot)) }
function RunSeal([string]$caseRoot,[string]$KeyPath){ return (StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -Mode seal -SigningKeyPath "{2}"' -f $SealScript,$caseRoot,$KeyPath)) }
function RunVerifySeal([string]$caseRoot,[string]$TrustedPub){ return (StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -Mode verify-seal -TrustedPubPath "{2}"' -f $SealScript,$caseRoot,$TrustedPub)) }
function SealDirOf([string]$caseRoot){
  $sd = Join-Path $caseRoot "proofs\checkpoints\seals"
  $d = Get-ChildItem -LiteralPath $sd -Directory | Sort-Object Name | Select-Object -Last 1
  if($null -eq $d){ Fail ("NO_SEAL_DIR:" + $caseRoot) }
  return $d.FullName
}
$SEAL_NS = "nfl/ledger-seal"      # the seal signing namespace (verify-seal default)
$BUNDLE_NS = "neverlost/trust-bundle"  # the bundle-signing namespace for these tests
function WriteBundle([string]$Path,[string]$PubFile,[string[]]$Namespaces){
  $pub = ([System.IO.File]::ReadAllText($PubFile,(Utf8NoBom))).Trim()
  $b = [ordered]@{
    schema     = "neverlost.trust_bundle.v1"
    created_utc = "x"
    principals = @( [ordered]@{ principal="single-tenant/local/authority/nfl"; keys=@( [ordered]@{ key_id="k1"; pubkey=$pub; namespaces=$Namespaces } ) } )
  }
  WriteText $Path (($b | ConvertTo-Json -Depth 20))
}
function SignBundle([string]$Bundle,[string]$Key){
  $r = StartChild $ssh ('-Y sign -f "{0}" -n "{1}" "{2}"' -f $Key,$BUNDLE_NS,$Bundle)
  if($r.ExitCode -ne 0){ Fail ("BUNDLE_SIGN_FAILED:" + $r.StdErr.Trim()) }
}
function RunVerifyBundle([string]$caseRoot,[string]$Bundle,[string]$RootPub){
  $a = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -Mode verify-seal -TrustBundlePath "{2}" -BundleNamespace "{3}"' -f $SealScript,$caseRoot,$Bundle,$BUNDLE_NS)
  if(-not [string]::IsNullOrWhiteSpace($RootPub)){ $a += (' -RootPubPath "{0}"' -f $RootPub) }
  return (StartChild $PSExe $a)
}

$results = New-Object System.Collections.Generic.List[object]
function Assert([string]$Case,[bool]$Cond,[string]$Detail){
  $results.Add([pscustomobject]@{ case=$Case; ok=$Cond; detail=$Detail }) | Out-Null
  if($Cond){ Write-Output ("PASS  " + $Case + "  " + $Detail) } else { Write-Output ("FAIL  " + $Case + "  " + $Detail) }
}
function NewCase([string]$Name){
  $caseRoot = Join-Path $TmpRoot $Name
  WriteLedger (Join-Path $caseRoot "data\ledger.ndjson") $SEED
  $r = RunCkpt $caseRoot
  if($r.ExitCode -ne 0){ Fail ("CKPT_FAILED:" + $Name + ":" + $r.StdOut + $r.StdErr) }
  return $caseRoot
}

# --- CLEAN ---
$c = NewCase "clean"
GenKey (Join-Path $c "key_main")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("CLEAN_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$v = RunVerifySeal $c (Join-Path $c "key_main.pub")
Assert "CLEAN" (($v.ExitCode -eq 0) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_OK')) ("exit=" + $v.ExitCode)

# --- WRONG_KEY (forgery: sealed by evil key, trust the real key) ---
$c = NewCase "wrong_key"
GenKey (Join-Path $c "key_main")
GenKey (Join-Path $c "key_evil")
$s = RunSeal $c (Join-Path $c "key_evil")
if($s.ExitCode -ne 0){ Fail ("WRONGKEY_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$v = RunVerifySeal $c (Join-Path $c "key_main.pub")
Assert "WRONG_KEY" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:SIG_INVALID')) ("exit=" + $v.ExitCode)

# --- TAMPERED_PAYLOAD ---
$c = NewCase "tampered_payload"
GenKey (Join-Path $c "key_main")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("TP_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$sd = SealDirOf $c
$pp = Join-Path $sd "seal_payload.txt"
$orig = [System.IO.File]::ReadAllText($pp,(Utf8NoBom))
WriteText $pp ($orig + "tamper`n")
$v = RunVerifySeal $c (Join-Path $c "key_main.pub")
Assert "TAMPERED_PAYLOAD" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:SIG_INVALID')) ("exit=" + $v.ExitCode)

# --- ALTERED_SEAL_HEAD ---
$c = NewCase "altered_head"
GenKey (Join-Path $c "key_main")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("AH_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$sd = SealDirOf $c
$sj = Join-Path $sd "seal.json"
$seal = Get-Content -LiteralPath $sj -Raw | ConvertFrom-Json
$seal.head = "deadbeef00000000000000000000000000000000000000000000000000000000"
WriteText $sj ($seal | ConvertTo-Json -Depth 10)
$v = RunVerifySeal $c (Join-Path $c "key_main.pub")
Assert "ALTERED_SEAL_HEAD" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:LEDGER_HEAD_MISMATCH')) ("exit=" + $v.ExitCode)

# --- LEDGER_MUTATED ---
$c = NewCase "ledger_mutated"
GenKey (Join-Path $c "key_main")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("LM_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$mut = @( $SEED[0], (Rec "bbb2" "two-MUTATED" "2026-01-02T00:00:00Z"), $SEED[2] )
WriteLedger (Join-Path $c "data\ledger.ndjson") $mut
$v = RunVerifySeal $c (Join-Path $c "key_main.pub")
Assert "LEDGER_MUTATED" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:LEDGER_HEAD_MISMATCH')) ("exit=" + $v.ExitCode)

# --- BUNDLE_OK (authorized key for the seal namespace, bundle root-of-trust verified) ---
$c = NewCase "bundle_ok"
GenKey (Join-Path $c "key_main")
GenKey (Join-Path $c "key_root")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("BOK_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$bundle = Join-Path $c "trust_bundle.json"
WriteBundle $bundle (Join-Path $c "key_main.pub") @($SEAL_NS)
SignBundle $bundle (Join-Path $c "key_root")
$v = RunVerifyBundle $c $bundle (Join-Path $c "key_root.pub")
Assert "BUNDLE_OK" (($v.ExitCode -eq 0) -and ($v.StdOut -match 'BUNDLE_SIG_OK') -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_OK')) ("exit=" + $v.ExitCode)

# --- BUNDLE_WRONG_ROOT (bundle signed, but pinned root is a different key) ---
$c = NewCase "bundle_wrong_root"
GenKey (Join-Path $c "key_main")
GenKey (Join-Path $c "key_root")
GenKey (Join-Path $c "key_evilroot")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("BWR_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$bundle = Join-Path $c "trust_bundle.json"
WriteBundle $bundle (Join-Path $c "key_main.pub") @($SEAL_NS)
SignBundle $bundle (Join-Path $c "key_root")
$v = RunVerifyBundle $c $bundle (Join-Path $c "key_evilroot.pub")
Assert "BUNDLE_WRONG_ROOT" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:BUNDLE_SIG_INVALID')) ("exit=" + $v.ExitCode)

# --- BUNDLE_UNKNOWN_KEY (sealed by a key not listed in the bundle) ---
$c = NewCase "bundle_unknown_key"
GenKey (Join-Path $c "key_main")
GenKey (Join-Path $c "key_evil")
GenKey (Join-Path $c "key_root")
$s = RunSeal $c (Join-Path $c "key_evil")
if($s.ExitCode -ne 0){ Fail ("BUK_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$bundle = Join-Path $c "trust_bundle.json"
WriteBundle $bundle (Join-Path $c "key_main.pub") @($SEAL_NS)
SignBundle $bundle (Join-Path $c "key_root")
$v = RunVerifyBundle $c $bundle (Join-Path $c "key_root.pub")
Assert "BUNDLE_UNKNOWN_KEY" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:SIGNER_NOT_IN_BUNDLE')) ("exit=" + $v.ExitCode)

# --- BUNDLE_WRONG_NS (signer in bundle, but not authorized for the seal namespace) ---
$c = NewCase "bundle_wrong_ns"
GenKey (Join-Path $c "key_main")
GenKey (Join-Path $c "key_root")
$s = RunSeal $c (Join-Path $c "key_main")
if($s.ExitCode -ne 0){ Fail ("BWN_SEAL_FAILED:" + $s.StdOut + $s.StdErr) }
$bundle = Join-Path $c "trust_bundle.json"
WriteBundle $bundle (Join-Path $c "key_main.pub") @("nfl/some-other-namespace")
SignBundle $bundle (Join-Path $c "key_root")
$v = RunVerifyBundle $c $bundle (Join-Path $c "key_root.pub")
Assert "BUNDLE_WRONG_NS" (($v.ExitCode -eq 1) -and ($v.StdOut -match 'NFL_LEDGER_SEAL_VERIFY_FAIL:NAMESPACE_NOT_AUTHORIZED')) ("exit=" + $v.ExitCode)

# --- summary + receipt ---
$passed = @($results | Where-Object { $_.ok }).Count
$total  = $results.Count
$rcptPath = Join-Path $RepoRoot "proofs\receipts\nfl.ledger.seal_selftest.ndjson"
EnsureDir (Split-Path -Parent $rcptPath)
$rcpt = [ordered]@{
  schema="nfl.ledger.seal_selftest.receipt.v1"; utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  run_id=$RunId; passed=$passed; total=$total; ok=($passed -eq $total)
  cases=@($results | ForEach-Object { $_.case + "=" + ($(if($_.ok){"PASS"}else{"FAIL"})) })
}
[System.IO.File]::AppendAllText($rcptPath, (($rcpt | ConvertTo-Json -Compress -Depth 10) + "`n"), (Utf8NoBom))

if(-not $Keep){ Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ("RESULT=" + $passed + "/" + $total)
if($passed -ne $total){ Fail ("CASES_FAILED:" + ($total - $passed)) }
Write-Output "NFL_LEDGER_SEAL_SELFTEST_OK"
