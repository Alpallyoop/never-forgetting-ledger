# NFL CLI commands

`scripts/nfl_cli_v1.ps1 <command> [-RepoRoot <dir>]` (default: current directory). `nfl.cmd` / `scripts/nfl.ps1`
pass the same commands through with the repository as root.

| Command | Arguments | Success output | Failure |
|---|---|---|---|
| `commit` | `-Hash <hex>` `[-Artifact <label>]` | `COMMIT_OK`, `HASH=`, `TIMESTAMP=`, `SEQ=` | `NFL_CLI_FAIL:MISSING_HASH`, `BAD_HASH`, `ARTIFACT_TOO_LONG`, `ARTIFACT_CONTROL_CHAR`, `LEDGER_LOCK_TIMEOUT` |
| `lookup` | `-Hash <hex>` | `FOUND`, `HASH=`, `TIMESTAMP=`, `ARTIFACT=`, `SEQ=`, `[MATCHES=]`; or `NOT_FOUND` | `MISSING_HASH` |
| `verify` | `-File <path>` | `HASH=` then `VERIFIED`, `TIMESTAMP=`, `SEQ=`; or `NOT_FOUND` | `MISSING_FILE`, `FILE_NOT_FOUND:<path>` |
| `verify-chain` | | `NFL_LEDGER_CHAIN_OK`, `COUNT=`, `UNCHAINED_PREFIX=`, `CHAINED_COUNT=`, `HEAD=` | `NFL_LEDGER_CHAIN_FAIL:CHAIN_BREAK:<i>` / `SEQ_MISMATCH` / `UNCHAINED_AFTER_CHAIN` / `BAD_JSON_LINE` (exit 1) |
| `witness-receipt` | `-ReceiptFile <ndjson>` or `-ReceiptLine <json>` | per line `WITNESSED` / `ALREADY_WITNESSED` + `RECEIPT_SHA256=`, `INTEGRATION=`, `SEQ=`; then `NFL_RECEIPT_WITNESS_OK` | per line `REFUSED` + `RECEIPT_ERROR=`; then `NFL_CLI_FAIL:RECEIPT_REFUSED:<n>` (exit 1) |
| `verify-receipt` | `-ReceiptFile` or `-ReceiptLine` | per line `RECEIPT_SHA256=` + `VERIFIED`/`NOT_FOUND`; `NOT_FOUND_COUNT=` | |
| `receipt-head` | `-Integration <consumer>><provider>` | `INTEGRATION=`, `WITNESSED_COUNT=`, `HEAD=` (newest witnessed receipt hash; 64 zeros when none), `LAST_SEQ=`, then `NFL_RECEIPT_HEAD_OK`. Read-only (proposal 0003) | `NFL_CLI_FAIL:MISSING_INTEGRATION`, `RECEIPT_HEAD_BAD_INTEGRATION` |
| `witness-own-receipts` | | `WITNESSED=`, `ALREADY=`, `INVALID=`, `NFL_OWN_RECEIPTS_OK` | `NFL_CLI_FAIL:OWN_RECEIPTS_INVALID:<n>` |

Receipt refusal tokens: `RECEIPT_BAD_JSON`, `RECEIPT_NOT_ONE_LINE`, `RECEIPT_KEYS_NOT_CANONICAL`,
`RECEIPT_NOT_CANONICAL`, `RECEIPT_BAD_SCHEMA`, `RECEIPT_BAD_CONSUMER|PROVIDER|EMITTED_BY|CONTRACT|REQUEST_SHA256|RESPONSE_SHA256|CARRIED|OUTCOME|ERROR_TOKEN|PREV_SHA256`,
`RECEIPT_ERROR_TOKEN_ON_OK`, `RECEIPT_REGISTRY_UNAVAILABLE`, `RECEIPT_UNATTRIBUTED`, `RECEIPT_WITNESS_NOT_NFL`,
`RECEIPT_EMITTER_MISMATCH`, `RECEIPT_CONTRACT_NOT_REGISTERED`. Receipt files must be UTF-8 without BOM, LF only.

Other operational scripts: `nfl_export_ledger_packet_v1.ps1` / `nfl_sign_ledger_packet_v1.ps1` (ledger packet),
`nfl_ledger_checkpoint_v1.ps1 -Mode checkpoint|verify`, `nfl_ledger_seal_v1.ps1 -Mode seal|verify-seal`,
`nfl_ledger_export_v1.ps1` + `verify_nfl_export_v1.py`, `nfl_ingest_inboxes_v1.ps1`, `nfl_ingest_control_v1.ps1`.
