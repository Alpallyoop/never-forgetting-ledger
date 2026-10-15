# Never Forgetting Ledger (NFL)

NFL is the Constellation ecosystem's permanent integrity ledger for cryptographic hashes. It commits a
hash once, timestamps it, and lets anyone look it up or verify it later. It is append-only, self-chained
and deterministic. It witnesses evidence; it does not decide trust, judge packets or make policy.

Canonical role (Constellation registry): `nfl`, family `covenant`, layer `foundation.hash-ledger`.
Owns: committing, looking up and verifying hashes; witnessing integration receipts
(`constellation.integration.receipt.v1`) by hash; checkpoints, seals and signed portable exports.
Does not own: trust or signer lists (NeverLost), packet-law verification (CPR), policy (Arbiter, Covenant
Gate), or the content of what it witnesses.

## Surfaces

| Surface | Entry point | What it is |
|---|---|---|
| CLI | `scripts/nfl_cli_v1.ps1` (`nfl.cmd`, `scripts/nfl.ps1`) | commit, lookup, verify, verify-chain, witness-receipt, verify-receipt, witness-own-receipts |
| HTTP API | `scripts/nfl_api_v1.ps1` (`NFL_Runtime.cmd`) | `nfl.api.v1` on `http://127.0.0.1:8086/`, loopback only |
| Inbox ingest | `scripts/nfl_ingest_inboxes_v1.ps1` | scheduled (Windows task) or `nfl inbox ingest`; config `config/inbox_registry.json` |
| Durable ledger | `nfl_ledger_checkpoint_v1.ps1`, `nfl_ledger_seal_v1.ps1`, `nfl_ledger_export_v1.ps1`, `verify_nfl_export_v1.py` | tamper-evidence, signed seals, portable signed exports (see `docs/NFL_DURABLE_LEDGER_v1.md`) |
| Explorer | sibling repository `nfl-explorer` | desktop UI; talks to NFL only through the HTTP API |

All writers share one implementation, `scripts/_lib_nfl_v1.ps1`: one exclusive lock, one self-chain
(`seq` + `prev`, where `prev` is the previous record's link hash and each link covers that record's core and
its own `prev`, so the head commits to the whole history), a pin of where self-chaining started
(`data/ledger.selfchain.json`), one canonical record hash, identical results on Windows PowerShell 5.1 and
PowerShell 7.

## Result tokens

`COMMIT_OK`, `FOUND`, `NOT_FOUND`, `VERIFIED`, `NFL_LEDGER_CHAIN_OK`, `WITNESSED`, `ALREADY_WITNESSED`,
`REFUSED`, `NFL_RECEIPT_WITNESS_OK`, `NFL_INGEST_INBOXES_OK`, `NFL_INGEST_UNATTRIBUTED`. Failures are
`NFL_CLI_FAIL:<TOKEN>` (for example `BAD_HASH`, `ARTIFACT_CONTROL_CHAR`, `RECEIPT_UNATTRIBUTED`) with a
non-zero exit code.

## CLI

```powershell
.\scripts\nfl_cli_v1.ps1 commit -Hash <sha256> -Artifact "label"
.\scripts\nfl_cli_v1.ps1 lookup -Hash <sha256>
.\scripts\nfl_cli_v1.ps1 verify -File .\some\file
.\scripts\nfl_cli_v1.ps1 verify-chain
.\scripts\nfl_cli_v1.ps1 witness-receipt -ReceiptFile .\receipts.ndjson
.\scripts\nfl_cli_v1.ps1 verify-receipt  -ReceiptFile .\receipts.ndjson
```

The CLI works on the ledger of the current directory unless `-RepoRoot` is given. Hashes must be hex
digests (SHA-256 is the ecosystem default); artifact labels are at most 1024 characters with no control
characters.

## HTTP API (`nfl.api.v1`)

| Route | Result |
|---|---|
| `GET /health` | ledger count and chain status, registry copy present or `unavailable` |
| `GET /lookup?hash=` | `FOUND` (with every matching record) or `NOT_FOUND` |
| `POST /verify` `{"file":...}` or `{"sha256":...}` | `VERIFIED` or `NOT_FOUND` |
| `POST /commit` `{"hash","artifact",...}` | `COMMIT_OK` (optional `source_repo`, `source_repo_path`, `branch`, `commit_hash`, `remote`, `event_type`) |
| `GET /recent?limit=&source_repo=` | newest first, bounded |
| `GET /ledger/chain` | embedded self-chain verification |
| `POST /receipt/witness` `{"line"}` / `{"lines":[...]}` | per line `WITNESSED`, `ALREADY_WITNESSED` or `REFUSED` (422 when any is refused) |
| `POST /receipt/verify` | per line `VERIFIED` or `NOT_FOUND` |
| `GET /integrations?role=provider|consumer` | registered integrations NFL takes part in |
| `GET /receipts?packet_id=` | `nfl.receipt.v1` receipts issued for ingested envelopes |
| `GET /ingest/last-run`, `/ingest/runs`, `/ingest/state`, `/ingest/failures`; `POST /ingest/control` | ingest operations |

Guards: loopback prefix and loopback remote address only; `Host` must be the listener's own
`127.0.0.1:<port>` or `localhost:<port>`; any request with an `Origin` header gets 403 unless that origin was
allowed with `-AllowedOrigins`; bodies over 1 MiB are refused; path verification (`{"file":...}`) is off
unless started with `-AllowPathVerify`. Details:
`docs/NFL_API_QUICKSTART.md`.

## Integration receipts (proposal 0001)

Every registered integration writes a `constellation.integration.receipt.v1` line per exchange and NFL
commits its hash under `constellation.integration.receipt.v1:<consumer>><provider>`. NFL checks the line
byte for byte (canonical compact JSON, keys in schema order) and only commits receipts of integrations that
are registered in `.constellation/SERVICE_MAP.md` with witness `nfl`, the registered emitter and a
registered contract. Everything else is `REFUSED` with a named token and nothing is written. Witnessing is
idempotent. NFL being absent never touches the emitter's receipt.

NFL writes its own receipts as a consumer (`nfl>cpr` for every CPR verdict, `nfl>neverlost` for every trust
bundle used and every packet read from NeverLost's outbox) to
`proofs/receipts/integration/nfl__<provider>.ndjson` and witnesses them at the end of each ingest run or
with `witness-own-receipts`.

## Ingest contracts

- `nfl.ingest.v1` (`schemas/nfl.ingest.v1.schema.json`): producers ship it as `payload/nfl.ingest.json`
  inside a Packet Constitution v1 packet. After CPR verifies the packet, NFL commits `commit_hash` under
  `nfl.ingest.v1:<producer>:<packet_id>` and issues an `nfl.receipt.v1`.
- `nfl.receipt.v1` (`schemas/nfl.receipt.v1.schema.json`): appended to `proofs/receipts/nfl.receipt.v1.ndjson`
  (chained); fetch with `GET /receipts?packet_id=`.
- Inbox registry (`schemas/nfl.inbox_registry.v1.schema.json`): paths relative to this repository; each inbox
  is `source: local` or names a registered integration. NFL never creates folders outside its own repository;
  a missing foreign inbox is reported `unavailable`.

## Tests

```powershell
.\scripts\_RUN_nfl_selftests_v1.ps1          # everything below, fail-closed
```

Self-chain 6/6, checkpoint 5/5, seal 9/9, API 19/19, receipts + ingest 37/37 (needs CPR), portable export
9/9 (python3), and a read-only check of the real ledger's chain. `NFL_Apply_All.cmd` runs these plus the
Windows-only CLI full-green (real CPR, real ingest), refreshes the ingest task and commits a proven baseline.

## Working remotely

Run from a Linux cloud session (commands used and passing on 2026-10-15 with PowerShell 7.4.6, python3,
OpenSSH `ssh-keygen`):

```bash
pwsh -NoProfile -File scripts/_RUN_nfl_selftests_v1.ps1 -CprRoot ../cpr   # or NFL_CPR_ROOT=...
pwsh -NoProfile -File scripts/nfl_cli_v1.ps1 verify-chain -RepoRoot .
pwsh -NoProfile -File scripts/nfl_api_v1.ps1 -RepoRoot . -Prefix http://127.0.0.1:8086/
```

Only on Windows / the home computer: the ingest scheduled task (`nfl_install_ingest_task_v1.ps1`,
`nfl_ingest_control_v1.ps1 start|stop`), `_RUN_nfl_cli_full_green_v1.ps1` and `NFL_Apply_All.cmd`, and CPR's
own verifier unmodified (it uses Windows-only `System.Uri` path handling; the receipts+ingest self-test
applies a two-line fix to a temporary copy on Linux and says so). The ledger itself (`data/ledger.ndjson`),
signing keys and runtime receipts live on the home computer and are not in git.

## Packet law, Tier-0 and history

Packet Constitution v1 verification belongs to CPR. NFL's historical entry points (`verify_packet_v1.ps1`,
`_selftest_nfl_tier0_locked_v1.ps1`, `scan_inbox.ps1`, ...) are quarantine stubs that raise
`NFL_PACKET_LAW_MOVED_TO_CPR`. Tier-0 was frozen on 2026-03-07 (`test_vectors/tier0_frozen/`, tags
`nfl-tier0-green-20260307`, `nfl-tier0-release-hygiene-20260307`).

Current state and open items: `docs/NFL_HANDOFF_CURRENT.md`.
