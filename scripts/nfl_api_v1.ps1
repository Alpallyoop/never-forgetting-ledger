<#
  nfl_api_v1.ps1 -- Never Forgetting Ledger local HTTP API (nfl.api.v1).

  Localhost only. The listener refuses a non-loopback prefix, any request whose Host header is not the
  listener's own loopback host:port (DNS-rebinding guard) and any request carrying a non-local Origin
  (cross-site guard). Writes go through the same single-writer ledger code as the CLI (_lib_nfl_v1.ps1).

  GET  /                      index
  GET  /health                service, ledger count, chain status
  GET  /lookup?hash=<hex>     FOUND | NOT_FOUND
  POST /verify                {"file":"<path on this machine>"} or {"sha256":"<hex>"} -> VERIFIED | NOT_FOUND
  POST /commit                {"hash","artifact", optional source_repo, source_repo_path, branch, commit_hash, remote, event_type}
  GET  /recent?limit=&source_repo=
  GET  /ledger/chain          embedded self-chain verification
  POST /receipt/witness       {"line":"<receipt json line>"} or {"lines":[...]}   (constellation.integration.receipt.v1)
  POST /receipt/verify        {"line":"..."} or {"lines":[...]}
  GET  /integrations          registered integrations NFL takes part in (from .constellation/SERVICE_MAP.md)
  GET  /receipts?packet_id=   nfl.receipt.v1 receipts NFL issued for nfl.ingest.v1 envelopes
  GET  /ingest/last-run | /ingest/runs | /ingest/state | /ingest/failures
  POST /ingest/control        {"action":"status|run-once|start|stop"}
#>
param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = "",
  [Parameter(Mandatory=$false)][string]$Prefix = "http://127.0.0.1:8086/",
  [Parameter(Mandatory=$false)][int]$DefaultLimit = 500,
  [Parameter(Mandatory=$false)][int]$MaxBodyBytes = 1048576,
  # Browser origins allowed to call the API (exact "scheme://host:port"). Default: none - the desktop explorer
  # calls from its main process and sends no Origin, so any page in any browser is refused.
  [Parameter(Mandatory=$false)][string[]]$AllowedOrigins = @(),
  # POST /verify {"file":...} hashes a path on this machine. Off by default (device files, network shares);
  # callers send {"sha256":...} instead.
  [Parameter(Mandatory=$false)][switch]$AllowPathVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_nfl_v1.ps1")

function Test-LocalOrigin([string]$origin){
  if([string]::IsNullOrEmpty($origin)){ return $true }
  return ($AllowedOrigins -ccontains $origin)
}

function Send-Json($res,$obj,[string]$allowOrigin,[int]$status = 200){
  $json = ConvertTo-NflCanonicalJson $obj
  $bytes = (Get-NflUtf8).GetBytes($json + "`n")
  if(-not [string]::IsNullOrEmpty($allowOrigin)){
    $res.Headers["Access-Control-Allow-Origin"] = $allowOrigin
    $res.Headers["Vary"] = "Origin"
    $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
  }
  $res.Headers["Cache-Control"] = "no-store"
  $res.Headers["X-Content-Type-Options"] = "nosniff"
  $res.StatusCode = $status
  $res.ContentType = "application/json; charset=utf-8"
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes,0,$bytes.Length)
  $res.OutputStream.Close()
}

function Read-NdjsonTail([string]$Path,[int]$Limit){
  # Bounded: only the last $Limit records are parsed. Newest last.
  $items = New-Object System.Collections.Generic.List[object]
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    foreach($ln in @(Get-Content -LiteralPath $Path -Tail $Limit -Encoding UTF8)){
      if([string]::IsNullOrWhiteSpace($ln)){ continue }
      try { $items.Add((ConvertFrom-NflJson $ln)) } catch { $items.Add([ordered]@{ schema="nfl.api.unparsable_line.v1"; raw=$ln }) }
    }
  }
  return $items.ToArray()
}

function Get-Limit($req,[int]$fallback){
  $q = [string]$req.QueryString["limit"]
  $n = 0
  if([int]::TryParse($q,[ref]$n) -and $n -gt 0 -and $n -le 100000){ return $n }
  return $fallback
}

function Read-Body($req){
  if($req.ContentLength64 -gt $MaxBodyBytes){ throw "NFL_BODY_TOO_LARGE" }
  $ms = New-Object System.IO.MemoryStream
  try {
    $buf = New-Object byte[] 65536
    while(($n = $req.InputStream.Read($buf,0,$buf.Length)) -gt 0){
      $ms.Write($buf,0,$n)
      if($ms.Length -gt $MaxBodyBytes){ throw "NFL_BODY_TOO_LARGE" }
    }
    $raw = (Get-NflUtf8).GetString($ms.ToArray())
  } finally { $ms.Dispose() }
  if([string]::IsNullOrWhiteSpace($raw)){ throw "NFL_EMPTY_BODY" }
  try { return (ConvertFrom-NflJson $raw) } catch { throw "NFL_BAD_JSON_BODY" }
}

function Get-BodyLines($body){
  $lines = New-Object System.Collections.Generic.List[string]
  $one = Get-NflProp $body 'line'
  if($null -ne $one){ $lines.Add([string]$one) }
  $many = Get-NflProp $body 'lines'
  if($null -ne $many){ foreach($l in @($many)){ $lines.Add([string]$l) } }
  if($lines.Count -eq 0){ throw "NFL_MISSING_RECEIPT" }
  if($lines.Count -gt 1000){ throw "NFL_TOO_MANY_RECEIPTS" }
  return ,($lines.ToArray())
}

function Record-ToItem($hit){
  $r = $hit.Record
  $o = [ordered]@{}
  foreach($p in $r.PSObject.Properties){ $o[$p.Name] = $p.Value }
  if(-not $o.Contains("seq")){ $o["seq"] = $hit.Seq }
  return $o
}

$RepoRoot = Resolve-NflRepoRoot $RepoRoot
if(-not $Prefix.EndsWith("/")){ $Prefix += "/" }
$prefixUri = [Uri]$Prefix
if(@("127.0.0.1","localhost") -notcontains $prefixUri.Host){ throw "NFL_API_FAIL:PREFIX_NOT_LOOPBACK" }
$AllowedHosts = @(("127.0.0.1:" + $prefixUri.Port), ("localhost:" + $prefixUri.Port))

$LedgerPath = Get-NflLedgerPath $RepoRoot
$ReceiptsDir = Join-NflPath $RepoRoot "proofs" "receipts"

$listener = New-Object System.Net.HttpListener
[void]$listener.Prefixes.Add($Prefix)
$listener.Start()

Write-Output "NFL_API_LISTENING"
Write-Output ("PREFIX=" + $Prefix)

try {
  while($listener.IsListening){
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $allow = ""
    try {
      $path = $req.Url.AbsolutePath
      $method = $req.HttpMethod.ToUpperInvariant()
      $origin = [string]$req.Headers["Origin"]
      $hostHdr = ([string]$req.Headers["Host"]).ToLowerInvariant()

      if(-not [System.Net.IPAddress]::IsLoopback($req.RemoteEndPoint.Address)){
        Send-Json $res ([ordered]@{ status = "FORBIDDEN"; message = "remote address not loopback" }) "" 403
        continue
      }
      if($AllowedHosts -notcontains $hostHdr){
        Send-Json $res ([ordered]@{ status = "FORBIDDEN"; message = "host not allowed" }) "" 403
        continue
      }
      if(-not (Test-LocalOrigin $origin)){
        Send-Json $res ([ordered]@{ status = "FORBIDDEN"; message = "cross-origin request rejected" }) "" 403
        continue
      }
      $allow = if([string]::IsNullOrEmpty($origin)){ "" } else { $origin }

      if($method -eq "OPTIONS"){ Send-Json $res ([ordered]@{ status = "OK" }) $allow; continue }

      if($method -eq "GET" -and $path -eq "/"){
        Send-Json $res ([ordered]@{
          status = "OK"; service = "nfl.api.v1"; message = "Never Forgetting Ledger API"
          routes = @("GET /health","GET /lookup?hash=","POST /verify","POST /commit","GET /recent","GET /ledger/chain","POST /receipt/witness","POST /receipt/verify","GET /integrations","GET /receipts","GET /ingest/last-run","GET /ingest/runs","GET /ingest/state","GET /ingest/failures","POST /ingest/control")
        }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/health"){
        $c = Test-NflLedgerChain $RepoRoot
        $integ = Get-NflRegisteredIntegrations $RepoRoot
        Send-Json $res ([ordered]@{
          status = "OK"; service = "nfl.api.v1"; prefix = $Prefix
          ledger = [ordered]@{ present = (Test-Path -LiteralPath $LedgerPath -PathType Leaf); count = $c.Count; chain_ok = $c.Ok; chain_error = $c.Error; unchained_prefix = $c.UnchainedPrefix; chained_count = $c.ChainedCount; head = $c.Head }
          registry = $(if($null -eq $integ){ "unavailable" } else { "present" })
        }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/lookup"){
        $h = [string]$req.QueryString["hash"]
        if([string]::IsNullOrWhiteSpace($h)){ throw "NFL_MISSING_HASH" }
        $h = $h.Trim().ToLowerInvariant()
        $hits = @(Find-NflLedgerRecords $RepoRoot $h)
        if($hits.Count -eq 0){ Send-Json $res ([ordered]@{ status = "NOT_FOUND"; hash = $h }) $allow; continue }
        $first = $hits[0].Record
        Send-Json $res ([ordered]@{
          status = "FOUND"; hash = $h; artifact = [string](Get-NflProp $first 'artifact'); timestamp = [string](Get-NflProp $first 'timestamp')
          seq = $hits[0].Seq; matches = $hits.Count; items = @($hits | ForEach-Object { Record-ToItem $_ })
        }) $allow
        continue
      }

      if($method -eq "POST" -and $path -eq "/verify"){
        $body = Read-Body $req
        $file = [string](Get-NflProp $body 'file')
        $sha = [string](Get-NflProp $body 'sha256')
        if(-not [string]::IsNullOrWhiteSpace($file)){
          if(-not $AllowPathVerify){ throw "NFL_PATH_VERIFY_DISABLED" }
          if($file.StartsWith("\\") -or $file.StartsWith("//") -or -not [System.IO.Path]::IsPathRooted($file)){ throw "NFL_PATH_NOT_LOCAL_ABSOLUTE" }
          if(-not (Test-Path -LiteralPath $file -PathType Leaf)){ throw "NFL_FILE_NOT_FOUND" }
          $fi = Get-Item -LiteralPath $file
          if(($fi.Attributes -band [System.IO.FileAttributes]::Device) -or ($IsLinux -and $fi.FullName.StartsWith("/dev/")) -or ($IsLinux -and $fi.FullName.StartsWith("/proc/"))){ throw "NFL_PATH_NOT_REGULAR_FILE" }
          $h = Get-NflSha256File $file
        } elseif(-not [string]::IsNullOrWhiteSpace($sha)){
          $h = Assert-NflCommitHash $sha
          $file = ""
        } else { throw "NFL_MISSING_FILE" }
        $hits = @(Find-NflLedgerRecords $RepoRoot $h)
        if($hits.Count -eq 0){ Send-Json $res ([ordered]@{ status = "NOT_FOUND"; hash = $h; file = $file }) $allow; continue }
        $first = $hits[0].Record
        Send-Json $res ([ordered]@{ status = "VERIFIED"; hash = $h; file = $file; artifact = [string](Get-NflProp $first 'artifact'); timestamp = [string](Get-NflProp $first 'timestamp'); seq = $hits[0].Seq }) $allow
        continue
      }

      if($method -eq "POST" -and $path -eq "/commit"){
        $body = Read-Body $req
        $extra = [ordered]@{ schema = "nfl.ledger.commit.v2" }
        foreach($k in @("source_repo","source_repo_path","branch","commit_hash","remote","event_type")){
          $v = Get-NflProp $body $k
          if(-not [string]::IsNullOrEmpty([string]$v)){ $extra[$k] = [string]$v }
        }
        $r = Add-NflLedgerRecord -RepoRoot $RepoRoot -Hash ([string](Get-NflProp $body 'hash')) -Artifact ([string](Get-NflProp $body 'artifact')) -Extra $extra
        Send-Json $res ([ordered]@{ status = "COMMIT_OK"; hash = $r.Hash; artifact = $r.Artifact; timestamp = $r.Timestamp; seq = $r.Seq }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/recent"){
        $limit = Get-Limit $req $DefaultLimit
        $items = @(Read-NdjsonTail $LedgerPath $limit)
        $sourceRepo = [string]$req.QueryString["source_repo"]
        if(-not [string]::IsNullOrWhiteSpace($sourceRepo)){ $items = @($items | Where-Object { [string](Get-NflProp $_ 'source_repo') -eq $sourceRepo }) }
        [array]::Reverse($items)
        Send-Json $res ([ordered]@{ status = "OK"; count = $items.Count; limit = $limit; items = $items }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/ledger/chain"){
        $c = Test-NflLedgerChain $RepoRoot
        $st = if($c.Ok){ "NFL_LEDGER_CHAIN_OK" } else { "NFL_LEDGER_CHAIN_FAIL" }
        Send-Json $res ([ordered]@{ status = $st; ok = $c.Ok; error = $c.Error; count = $c.Count; unchained_prefix = $c.UnchainedPrefix; chained_count = $c.ChainedCount; head = $c.Head }) $allow
        continue
      }

      if($method -eq "POST" -and $path -eq "/receipt/witness"){
        $body = Read-Body $req
        $lines = Get-BodyLines $body
        $integrations = Get-NflRegisteredIntegrations $RepoRoot
        $results = New-Object System.Collections.Generic.List[object]
        $refused = 0
        foreach($line in $lines){
          $w = Invoke-NflWitnessReceiptLine $RepoRoot $line $integrations
          if($w.Status -eq "REFUSED"){ $refused++; $results.Add([ordered]@{ status = "REFUSED"; error = $w.Error; receipt_sha256 = $w.Sha256 }); continue }
          $results.Add([ordered]@{ status = $w.Status; receipt_sha256 = $w.Sha256; integration = $w.Integration; seq = $w.Seq; timestamp = $w.Timestamp })
        }
        $st = if($refused -eq 0){ "NFL_RECEIPT_WITNESS_OK" } else { "NFL_RECEIPT_REFUSED" }
        Send-Json $res ([ordered]@{ status = $st; witnessed = ($lines.Count - $refused); refused = $refused; items = $results.ToArray() }) $allow $(if($refused -eq 0){ 200 } else { 422 })
        continue
      }

      if($method -eq "POST" -and $path -eq "/receipt/verify"){
        $body = Read-Body $req
        $lines = Get-BodyLines $body
        $results = New-Object System.Collections.Generic.List[object]
        foreach($line in $lines){
          $l = $line
          if($l.EndsWith("`n")){ $l = $l.Substring(0,$l.Length-1) }
          $h = Get-NflSha256HexOfString $l
          $chk = Test-NflIntegrationReceiptLine $l
          $label = $null
          if($chk.Ok){ $label = Get-NflReceiptLabel $chk.Consumer $chk.Provider }
          $hits = @(Find-NflLedgerRecords $RepoRoot $h | Where-Object { ($null -eq $label) -or ([string](Get-NflProp $_.Record 'artifact') -eq $label) })
          if($hits.Count -eq 0){ $results.Add([ordered]@{ status = "NOT_FOUND"; receipt_sha256 = $h; receipt_valid = $chk.Ok; receipt_error = $chk.Error }); continue }
          $results.Add([ordered]@{ status = "VERIFIED"; receipt_sha256 = $h; seq = $hits[0].Seq; timestamp = [string](Get-NflProp $hits[0].Record 'timestamp'); receipt_valid = $chk.Ok; receipt_error = $chk.Error })
        }
        Send-Json $res ([ordered]@{ status = "OK"; items = $results.ToArray() }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/integrations"){
        $integ = Get-NflRegisteredIntegrations $RepoRoot
        if($null -eq $integ){ Send-Json $res ([ordered]@{ status = "UNAVAILABLE"; message = ".constellation/SERVICE_MAP.md missing" }) $allow; continue }
        $mine = @($integ | Where-Object { $_.consumer -eq "nfl" -or $_.provider -eq "nfl" -or $_.witness -eq "nfl" })
        $who = [string]$req.QueryString["role"]
        if($who -eq "provider"){ $mine = @($mine | Where-Object { $_.provider -eq "nfl" }) }
        elseif($who -eq "consumer"){ $mine = @($mine | Where-Object { $_.consumer -eq "nfl" }) }
        Send-Json $res ([ordered]@{ status = "OK"; count = $mine.Count; items = $mine }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/receipts"){
        $p = Join-NflPath $ReceiptsDir "nfl.receipt.v1.ndjson"
        $limit = Get-Limit $req $DefaultLimit
        $items = @(Read-NdjsonTail $p $limit)
        $pid0 = [string]$req.QueryString["packet_id"]
        if(-not [string]::IsNullOrWhiteSpace($pid0)){
          $items = @($items | Where-Object { @((Get-NflProp $_ 'pointers')) | Where-Object { (Get-NflProp $_ 'kind') -eq 'packet_id' -and (Get-NflProp $_ 'value') -eq $pid0.ToLowerInvariant() } })
        }
        [array]::Reverse($items)
        Send-Json $res ([ordered]@{ status = "OK"; count = $items.Count; limit = $limit; items = $items }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/last-run"){
        $p = Join-NflPath $RepoRoot "runtime" "ingest" "last_run.json"
        $item = $null
        if(Test-Path -LiteralPath $p -PathType Leaf){ $item = ConvertFrom-NflJson ([System.IO.File]::ReadAllText($p,(Get-NflUtf8))) }
        Send-Json $res ([ordered]@{ status = "OK"; item = $item }) $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/runs"){
        $limit = Get-Limit $req $DefaultLimit
        $items = @(Read-NdjsonTail (Join-NflPath $ReceiptsDir "nfl_ingest_runs.ndjson") $limit)
        [array]::Reverse($items)
        Send-Json $res ([ordered]@{ status = "OK"; count = $items.Count; limit = $limit; items = $items }) $allow
        continue
      }

      if($method -eq "GET" -and ($path -eq "/ingest/state" -or $path -eq "/ingest/failures")){
        $limit = Get-Limit $req $DefaultLimit
        $items = @(Read-NdjsonTail (Join-NflPath $ReceiptsDir "nfl_ingest_state.ndjson") $limit)
        if($path -eq "/ingest/failures"){
          $items = @($items | Where-Object { ((Get-NflProp $_ 'ok') -eq $false) -or ([string](Get-NflProp $_ 'stderr') -match "FAIL|ERROR|CPR_VERIFY_NOT_GREEN|NFL_VERIFY_FAIL") })
        }
        [array]::Reverse($items)
        Send-Json $res ([ordered]@{ status = "OK"; count = $items.Count; limit = $limit; items = $items }) $allow
        continue
      }

      if($method -eq "POST" -and $path -eq "/ingest/control"){
        $body = Read-Body $req
        $action = [string](Get-NflProp $body 'action')
        if(@("status","run-once","start","stop") -notcontains $action){ throw ("NFL_BAD_ACTION:" + $action) }
        $script = Join-NflPath $PSScriptRoot "nfl_ingest_control_v1.ps1"
        if(-not (Test-Path -LiteralPath $script -PathType Leaf)){ throw "NFL_CONTROL_SCRIPT_MISSING" }
        $r = Invoke-NflScript $script @("-RepoRoot",$RepoRoot,"-Action",$action) $RepoRoot
        Send-Json $res ([ordered]@{ status = $(if($r.ExitCode -eq 0){ "OK" } else { "ERROR" }); action = $action; exit_code = $r.ExitCode; output = ($r.StdOut + $r.StdErr) }) $allow $(if($r.ExitCode -eq 0){ 200 } else { 500 })
        continue
      }

      Send-Json $res ([ordered]@{ status = "NOT_FOUND"; message = "endpoint not found"; path = $path }) $allow 404
    } catch {
      $m = [string]$_.Exception.Message
      try { Send-Json $res ([ordered]@{ status = "ERROR"; message = ($m -replace '^NFL_','') }) $allow 400 } catch {}
    }
  }
}
finally {
  if($listener.IsListening){ $listener.Stop() }
  $listener.Close()
}
