# NFL API quickstart (`nfl.api.v1`)

Start (Windows: `NFL_Runtime.cmd`; any host with PowerShell):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\nfl_api_v1.ps1 -RepoRoot . -Prefix "http://127.0.0.1:8086/"
```

Prints `NFL_API_LISTENING` and `PREFIX=...`. The prefix must be loopback (`127.0.0.1` or `localhost`).

## Requests

```powershell
$B = "http://127.0.0.1:8086"
Invoke-RestMethod "$B/health"
Invoke-RestMethod -Method Post "$B/commit" -ContentType application/json -Body '{"hash":"<sha256>","artifact":"report-v1"}'
Invoke-RestMethod "$B/lookup?hash=<sha256>"
Invoke-RestMethod -Method Post "$B/verify" -ContentType application/json -Body '{"file":"C:\\path\\to\\file"}'
Invoke-RestMethod -Method Post "$B/verify" -ContentType application/json -Body '{"sha256":"<sha256>"}'
Invoke-RestMethod "$B/recent?limit=20"
Invoke-RestMethod "$B/ledger/chain"
Invoke-RestMethod -Method Post "$B/receipt/witness" -ContentType application/json -Body (@{ line = $receiptLine } | ConvertTo-Json -Compress)
Invoke-RestMethod -Method Post "$B/receipt/verify"  -ContentType application/json -Body (@{ line = $receiptLine } | ConvertTo-Json -Compress)
Invoke-RestMethod "$B/integrations?role=provider"
Invoke-RestMethod "$B/receipts?packet_id=<packet id>"
Invoke-RestMethod "$B/ingest/last-run"
Invoke-RestMethod -Method Post "$B/ingest/control" -ContentType application/json -Body '{"action":"status"}'
```

## Responses

Every response is one compact JSON object with `status`:

| Route | status values |
|---|---|
| `/health` | `OK` with `ledger { present, count, chain_ok, chain_error, unchained_prefix, chained_count, head }` and `registry` (`present` / `unavailable`) |
| `/commit` | `COMMIT_OK` with `hash`, `artifact`, `timestamp`, `seq` |
| `/lookup` | `FOUND` with `artifact`, `timestamp`, `seq`, `matches`, `items[]`; or `NOT_FOUND` |
| `/verify` | `VERIFIED` with `hash`, `file`, `artifact`, `timestamp`, `seq`; or `NOT_FOUND` |
| `/recent`, `/ingest/*` | `OK` with `count`, `limit`, `items[]` (newest first) |
| `/ledger/chain` | `NFL_LEDGER_CHAIN_OK` / `NFL_LEDGER_CHAIN_FAIL` with `ok`, `error`, counts, `head` |
| `/receipt/witness` | `NFL_RECEIPT_WITNESS_OK` (200) or `NFL_RECEIPT_REFUSED` (422); `items[]` with `WITNESSED` / `ALREADY_WITNESSED` / `REFUSED` + `error` |
| `/receipt/verify` | `OK`; `items[]` with `VERIFIED` / `NOT_FOUND`, `receipt_valid`, `receipt_error` |
| `/integrations` | `OK` (or `UNAVAILABLE` without `.constellation/SERVICE_MAP.md`) |
| errors | `ERROR` with `message` = token (`BAD_HASH`, `MISSING_HASH`, `BAD_JSON_BODY`, `BODY_TOO_LARGE`, ...), HTTP 400; `NOT_FOUND` 404; `FORBIDDEN` 403 |

## Security model

Local operator API, no authentication. It accepts a request only when the remote address is loopback, the
`Host` header is the listener's own loopback host:port (DNS-rebinding guard), and the request carries no
`Origin` header, unless that exact origin was passed in `-AllowedOrigins` (by default no web page, on any
host or port, can drive `/commit` or `/ingest/control`). The desktop explorer calls the API from its main
process and the dev server from Node, neither of which sends an `Origin`.

`POST /verify {"file":...}` hashes a path on the API's machine and is off unless the API was started with
`-AllowPathVerify`; even then only local absolute paths to regular files are accepted (no UNC shares, no
devices). Callers normally hash locally and send `{"sha256":...}`. Do not expose the API beyond loopback.
