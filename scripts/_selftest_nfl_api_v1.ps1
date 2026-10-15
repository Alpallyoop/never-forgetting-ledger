<#
  _selftest_nfl_api_v1.ps1 -- positive and negative proof of the local HTTP API (nfl.api.v1).
  Starts a throwaway API on a free loopback port over a temp repo under proofs/_tmp (never the real
  ledger), exercises every route class, then stops it.
#>
param([string]$RepoRoot = "",[switch]$Keep)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")
function Fail([string]$m){ throw ("NFL_API_SELFTEST_FAIL:" + $m) }

$RepoRoot = Resolve-NflRepoRoot $RepoRoot
$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$T = Join-NflPath $RepoRoot "proofs" "_tmp" ("api_selftest_" + $RunId)
New-Item -ItemType Directory -Force -Path (Join-NflPath $T ".constellation") | Out-Null
Copy-Item -LiteralPath (Join-NflPath $RepoRoot ".constellation" "SERVICE_MAP.md") -Destination (Join-NflPath $T ".constellation" "SERVICE_MAP.md")
$T = (Resolve-Path -LiteralPath $T).Path

$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback,0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
$B = "http://127.0.0.1:" + $port

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Get-NflHostExe
$psi.Arguments = ((@("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",(Join-NflPath $PSScriptRoot "nfl_api_v1.ps1"),"-RepoRoot",$T,"-Prefix",($B + "/")) | ForEach-Object { ConvertTo-NflArg $_ }) -join " ")
$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
$api = [System.Diagnostics.Process]::Start($psi)

$results = New-Object System.Collections.Generic.List[object]
function Assert([string]$Case,[bool]$Cond,[string]$Detail){
  $results.Add([pscustomobject]@{ case=$Case; ok=$Cond }) | Out-Null
  if($Cond){ Write-Output ("PASS  " + $Case + "  " + $Detail) } else { Write-Output ("FAIL  " + $Case + "  " + $Detail) }
}
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(20)
function Call([string]$Method,[string]$Path,[string]$Body,[hashtable]$Headers){
  $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)),($B + $Path))
  if($null -ne $Headers){ foreach($k in $Headers.Keys){ [void]$req.Headers.TryAddWithoutValidation($k,$Headers[$k]) } }
  if($null -ne $Body){ $req.Content = New-Object System.Net.Http.StringContent($Body,(Get-NflUtf8),"application/json") }
  $resp = $http.SendAsync($req).GetAwaiter().GetResult()
  $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $obj = $null; try { $obj = ConvertFrom-NflJson $text } catch {}
  return [pscustomobject]@{ Code=[int]$resp.StatusCode; Text=$text; Obj=$obj }
}

try {
  $up = $false
  for($i=0; $i -lt 100 -and -not $up; $i++){ try { $h = Call "GET" "/health" $null $null; $up = ($h.Code -eq 200) } catch { Start-Sleep -Milliseconds 200 } }
  if(-not $up){ Fail ("API_DID_NOT_START:" + $api.StandardError.ReadToEnd()) }

  $h = Call "GET" "/health" $null $null
  Assert "A1_HEALTH" (($h.Obj.status -eq "OK") -and ($h.Obj.registry -eq "present") -and ($h.Obj.ledger.present -eq $false)) ""
  $c = Call "POST" "/commit" ('{"hash":"' + ("A" * 64) + '","artifact":"api-test","source_repo":"demo"}') $null
  Assert "A2_COMMIT" (($c.Code -eq 200) -and ($c.Obj.status -eq "COMMIT_OK") -and ($c.Obj.seq -eq 0) -and ($c.Obj.hash -eq ("a" * 64))) $c.Text
  $c2 = Call "POST" "/commit" '{"hash":"zz top","artifact":"x"}' $null
  Assert "A3_COMMIT_BAD_HASH_400" (($c2.Code -eq 400) -and ($c2.Obj.message -eq "BAD_HASH")) $c2.Text
  $lk = Call "GET" ("/lookup?hash=" + ("a" * 64)) $null $null
  Assert "A4_LOOKUP_FOUND" (($lk.Obj.status -eq "FOUND") -and ($lk.Obj.artifact -eq "api-test")) ""
  $lk2 = Call "GET" ("/lookup?hash=" + ("e" * 64)) $null $null
  Assert "A5_LOOKUP_NOT_FOUND" ($lk2.Obj.status -eq "NOT_FOUND") ""
  $f = Join-NflPath $T "file.txt"; [System.IO.File]::WriteAllText($f,"verify me`n")
  $fh = Get-NflSha256File $f
  [void](Call "POST" "/commit" ('{"hash":"' + $fh + '","artifact":"file"}') $null)
  $vf = Call "POST" "/verify" (ConvertTo-NflCanonicalJson ([ordered]@{ file = $f })) $null
  Assert "A6_VERIFY_FILE" (($vf.Obj.status -eq "VERIFIED") -and ($vf.Obj.hash -eq $fh)) ""
  $vs = Call "POST" "/verify" ('{"sha256":"' + ("e" * 64) + '"}') $null
  Assert "A7_VERIFY_SHA_NOT_FOUND" ($vs.Obj.status -eq "NOT_FOUND") ""
  $rc = Call "GET" "/recent?limit=1" $null $null
  Assert "A8_RECENT_BOUNDED_NEWEST_FIRST" (($rc.Obj.count -eq 1) -and (@($rc.Obj.items)[0].hash -eq $fh)) ""
  $ch = Call "GET" "/ledger/chain" $null $null
  Assert "A9_CHAIN_OK" (($ch.Obj.ok -eq $true) -and ($ch.Obj.chained_count -eq 2)) ""
  $good = New-NflIntegrationReceiptLine -Consumer "runledger" -Provider "nfl" -Contract "nfl.ingest.v1" -Outcome "ok" -PrevSha256 ("0" * 64)
  $bad = New-NflIntegrationReceiptLine -Consumer "apv" -Provider "nfl" -Outcome "ok" -PrevSha256 ("0" * 64)
  $w = Call "POST" "/receipt/witness" (ConvertTo-NflCanonicalJson ([ordered]@{ lines = @($good,$bad) })) $null
  Assert "A10_RECEIPT_WITNESS_MIXED_422" (($w.Code -eq 422) -and ($w.Obj.witnessed -eq 1) -and ($w.Obj.refused -eq 1) -and (@($w.Obj.items)[1].error -eq "RECEIPT_UNATTRIBUTED")) ""
  $vr = Call "POST" "/receipt/verify" (ConvertTo-NflCanonicalJson ([ordered]@{ line = $good })) $null
  Assert "A11_RECEIPT_VERIFY" (@($vr.Obj.items)[0].status -eq "VERIFIED") ""
  $ig = Call "GET" "/integrations?role=provider" $null $null
  Assert "A12_INTEGRATIONS" (($ig.Obj.status -eq "OK") -and ($ig.Obj.count -ge 10)) ("count=" + $ig.Obj.count)
  $ev = Call "POST" "/commit" ('{"hash":"' + ("b" * 64) + '"}') @{ Origin = "http://evil.example" }
  Assert "A13_FOREIGN_ORIGIN_403" (($ev.Code -eq 403) -and (@(Find-NflLedgerRecords $T ("b" * 64)).Count -eq 0)) ""
  $lo = Call "GET" "/health" $null @{ Origin = "http://localhost:5173" }
  Assert "A14_LOCAL_ORIGIN_ALLOWED" ($lo.Code -eq 200) ""
  $nf = Call "GET" "/nope" $null $null
  Assert "A15_UNKNOWN_ROUTE_404" ($nf.Code -eq 404) ""
  $big = Call "POST" "/commit" ('{"hash":"' + ("c" * 64) + '","artifact":"' + ("x" * 1100000) + '"}') $null
  Assert "A16_BODY_TOO_LARGE" (($big.Code -eq 400) -and ($big.Obj.message -eq "BODY_TOO_LARGE")) ""
  $ctl = Call "POST" "/ingest/control" '{"action":"status"}' $null
  Assert "A17_INGEST_CONTROL_STATUS" (($ctl.Code -eq 200) -and ($ctl.Obj.output -match 'STATE=')) ""
  $ctl2 = Call "POST" "/ingest/control" '{"action":"rm -rf"}' $null
  Assert "A18_INGEST_CONTROL_BAD_ACTION" ($ctl2.Code -eq 400) ""
} finally {
  try { if(-not $api.HasExited){ $api.Kill() } } catch {}
  $http.Dispose()
}

$passed = @($results | Where-Object { $_.ok }).Count
$total = $results.Count
if(-not $Keep){ Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ("RESULT=" + $passed + "/" + $total)
if($passed -ne $total -or $total -eq 0){ Fail ("CASES_FAILED:" + ($total - $passed)) }
Write-Output "NFL_API_SELFTEST_OK"
