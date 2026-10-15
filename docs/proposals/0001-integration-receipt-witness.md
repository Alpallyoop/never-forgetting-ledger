# Proposal 0001 - Witness integration receipts, not loose files

Status: implemented 2026-10-15 (see "Implementation" below), from Constellation proposal 0013, which the owner accepted. Decisions below are NFL's.
Compatibility impact: additive. Existing commit, lookup, verify and inbox ingest keep working.

## Why

The owner's requirement: if there is an integration, there are integrated receipts, so NFL is not ingesting a
pile of files that nothing ties to anything. Constellation's registry now says every registered integration
(`registry/integrations.json`, 117 records) writes a `constellation.integration.receipt.v1` for every exchange,
locally first, and names NFL as the witness that commits its hash. Schema:
`Constellation-Network/schemas/constellation.integration.receipt.v1.json`; rules: Constellation SPEC section 6a.

## Proposed for NFL

1. **Accept integration receipts.** Commit `-Hash <receipt sha256> -Artifact
   "constellation.integration.receipt.v1:<consumer>><provider>"`. The hash is SHA-256 of the receipt line without
   its LF. NFL stores the hash and its own timestamp only; the receipt content stays with the emitter.
2. **Attribute what is ingested.** `nfl_ingest_inboxes_v1.ps1` reports, per item, which registered integration it
   belongs to (from the artifact label against `.constellation/registry.json`). Items with no registered
   integration are listed under a named token (for example `NFL_INGEST_UNATTRIBUTED`) instead of being committed
   silently. Whether they are then refused or committed with that flag is NFL's decision.
3. **Prove a record.** A verify path that, given a receipt line, recomputes its hash and answers `VERIFIED` /
   `NOT_FOUND`, so a record in Constellation can move from `emitting` to `witnessed`.
4. **Never block the emitter.** NFL unavailable must leave the emitter's local receipt intact and unwitnessed,
   never a failed integration.

## Tests (positive and negative)

Committed receipt verifies; altered receipt line does not; unknown integration label is flagged; the same receipt
committed twice stays one record (idempotent ingest); NFL absent leaves the emitter's receipt untouched.

## Not NFL's

Which receipt each integration writes, and who writes it, is in Constellation's registry. Signer lists and keys
stay with NeverLost.

## Implementation (2026-10-15)

| Item | Where | Decision taken |
|---|---|---|
| 1. Accept receipts | `nfl_cli_v1.ps1 witness-receipt`, `POST /receipt/witness`, ingest inbox mode `receipt` | Line checked byte for byte against the schema (canonical compact JSON, key order, patterns, ok/error_token rule). Committed only when the integration is registered with witness `nfl`, the registered emitter and, when the record lists contracts, a registered contract. Idempotent on hash + label. |
| 2. Attribution | `nfl_ingest_inboxes_v1.ps1` | Every inbox is `source: local` or names a registered integration; `nfl.ingest.v1` envelopes are attributed to their producer. Unattributed items are **refused** (not committed), counted and listed as `NFL_INGEST_UNATTRIBUTED`. |
| 3. Prove a record | `nfl_cli_v1.ps1 verify-receipt`, `POST /receipt/verify` | Recomputes the hash of the line and answers `VERIFIED` / `NOT_FOUND`. |
| 4. Never block the emitter | | NFL only reads the emitter's line; an absent NFL leaves it untouched (self-test R10). |
| NFL as emitter | `_lib_nfl_v1.ps1` `Write-NflOwnIntegrationReceipt`, `Sync-NflOwnIntegrationReceipts` | `nfl>cpr` per CPR verdict, `nfl>neverlost` per trust bundle used and per NeverLost outbox packet, chained per integration, witnessed after each ingest run or by `witness-own-receipts`. Verification commands never write the ledger themselves. |

Tests: `_selftest_nfl_receipts_ingest_v1.ps1` (37 cases) and `_selftest_nfl_api_v1.ps1` (19 cases), both in
`_RUN_nfl_selftests_v1.ps1`. The registered integrations are read from `.constellation/SERVICE_MAP.md`; see
proposal 0002 for the request to publish them machine-readably.
