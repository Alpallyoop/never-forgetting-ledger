# NFL - current handoff

**Reconciled:** 2026-10-15 (supersedes the 2026-08-21 handoff; the 2026-10-07 audit is `NFL_AUDIT_20261007.md`).
**Repository:** `<dev root>/_Covenant-systems/nfl` (S: family layout, proposal 0009). GitHub:
`Alpallyoop/never-forgetting-ledger`.

## 1. What NFL is

The ecosystem's append-only hash ledger and witness. Commit a hash once, verify it forever. CPR judges packets,
NeverLost decides trust, Arbiter / Covenant Gate decide policy; NFL records what it was shown and what those
authorities said, and can prove it later (self-chain, checkpoints, signed seals, portable signed exports).

## 2. State

| Area | Status |
|---|---|
| Ledger core: one writer for CLI, API, ingest, `nfl.ps1` (`_lib_nfl_v1.ps1`) | done 2026-10-15: exclusive lock, self-chain `seq`/`prev`, write verified before `COMMIT_OK`, hex-digest and label validation |
| Host independence | done 2026-10-15: identical hashes on PowerShell 5.1 and 7 (PowerShell 7's `ConvertFrom-Json` turned timestamps into dates and broke chain and checkpoint verification on 7; the Windows-made checkpoint now verifies on Linux) |
| HTTP API `nfl.api.v1` | done: `/lookup` and `/verify` added (README promised them, code lacked them), commit goes through the shared writer, Host + Origin guards, 1 MiB body cap |
| Integration receipts (proposal 0001) | done: witness / verify / attribution / NFL's own `nfl>cpr` and `nfl>neverlost` receipts |
| Contracts | `schemas/nfl.ingest.v1`, `nfl.receipt.v1`, `nfl.ledger.record.v1`, `nfl.inbox_registry.v1` |
| Ingest | rewritten: relative inbox paths (the `C:/dev/...` paths broke at the S: move; ingest had been scanning nothing since 2026-10-13), no folders created in other repositories, attribution, `nfl.ingest.v1` envelopes -> `nfl.receipt.v1`, verified packet ids committed, dedup that a bad copy cannot poison, CPR missing = `pending` and retried |
| Durable ledger (checkpoint / seal / export / trust bundle + root of trust) | done 2026-08/10, unchanged in behaviour |
| Tests | `_RUN_nfl_selftests_v1.ps1`: parse gate 23, self-chain 4/4, checkpoint 5/5, seal 9/9, API 18/18, receipts + ingest 29/29, export 9/9, real ledger chain; all green on Linux / PowerShell 7.4.6 on 2026-10-15 |
| Quarantine lane for invalid ingest | not built: failed items are recorded (`ok:false`, token) and never reach the ledger, but are not moved |

## 3. Needs the home computer (Windows)

1. Run `NFL_Apply_All.cmd`: proves everything with the real CPR on Windows PowerShell 5.1, re-registers the
   ingest task, commits and tags the baseline. Nothing from this pass is committed yet.
2. First ingest run after this change re-checks the 29 packets in `packets/inbox` (old dedup keys were absolute
   `C:\dev` paths) and commits their verified packet ids once as `packet:local:nfl-packets-inbox`.
3. `proofs/keys/id_ed25519` is a private key on disk (gitignored, never tracked). It is the dev signing key; a
   NeverLost-issued key should replace it (NeverLost owns keys).

## 4. Open items owned elsewhere

See `docs/proposals/0002-registry-alignment-for-constellation.md`: registry / integration-document mismatches,
contracts attributed to NFL that NFL does not define (`nfl.settings.v1`, `nfl.receipt.ingested.v1`), the
`nfl.ingest.v1.packet_id` vs Packet Constitution conflict, publishing `integrations.json` into `.constellation/`,
and CPR's verifier failing on Linux.
