# Ecosystem Integration — nfl

## Canonical service identity

| Field | Value |
|---|---|
| Service ID | `nfl` |
| Canonical name | Never Forgetting Ledger (NFL) |
| Ecosystem layer | `witness-ledger` |
| Standalone-first | `true` |

## Role

NFL is the ecosystem's **append-only witness / integrity ledger** and its operational
surface (CLI + local HTTP API + inbox ingest). It records cryptographic hashes and the
verdicts it witnesses, deterministically and without mutation, so that evidence is never
lost and can always be independently re-verified.

NFL witnesses evidence. It does not manufacture truth, decide trust, or enforce policy.

## This service owns

- Append-only witness receipts and the hash ledger (`data/ledger.ndjson`)
- `commit` / `lookup` / `verify` operations (CLI `nfl_cli_v1.ps1`, API `nfl_api_v1.ps1`)
- Witnessing of CPR packet-law verdicts (`nfl_witness_cpr_verify_v1.ps1`)
- Ledger packet export and signing (`nfl_export_ledger_packet_v1.ps1`, `nfl_sign_ledger_packet_v1.ps1`)
- Idempotent inbox ingest and its receipts (`nfl_ingest_inboxes_v1.ps1`)
- Deterministic result tokens and `NFL_*` failure taxonomy
- Frozen Tier-0 evidence bundle (`test_vectors/tier0_frozen/`)

## This service does not own

- Packet Constitution / Option-A packet-law verification → **CPR** (`../cpr`)
- Trust authority — which key/principal is authorized to make a claim → **NeverLost** (future)
- Policy / permit decisions → **Covenant Gate / Arbiter**
- Identity, device posture, artifact packaging, restore/capture → respective instruments
- SaaS auth, payments, licensing entitlement → commercial control plane (post-instrument)

## Upstream services

- **CPR** — authoritative packet-law verifier (`../cpr/scripts/verify_packet_v1.ps1`).
  NFL consumes CPR verdicts and witnesses them; NFL does not re-implement packet law.
- **NeverLost** *(planned)* — trust bundles (`trust_bundle.json`) resolving authorized
  principals / keys / namespace authorization. Not yet wired; scaffolding present in
  `_bootstrap_neverlost_v1_nfl*.ps1` and `_lib_neverlost_v1.ps1`.

## Downstream consumers or operators

- Consumers of witnessed receipts (e.g. contribution / governance layers) that treat an
  NFL receipt as evidence of what was observed.
- Operators driving `commit` / `lookup` / `verify` via CLI or the local HTTP API.

## Contract families

- `nfl.ingest.run.receipt.v1`, `nfl.ingest.last_run.v1` — ingest telemetry
- `nfl.cpr.*` — CPR witness receipts (verify witness, transition)
- Ledger record: `{"hash","artifact","timestamp"}` (append-only)
- CLI/API result tokens: `COMMIT_OK`, `FOUND`, `NOT_FOUND`, `VERIFIED`; failures `NFL_CLI_FAIL:*`
- Tier-0 evidence: `nfl.tier0.selftest.v1` (historical, frozen)

## Integration rules

1. This repository must remain independently understandable, testable, buildable, and releasable.
2. Ecosystem integrations extend capability but do not replace standalone correctness.
3. Integrations use explicit, versioned schemas and receipts.
4. No undocumented database sharing, hidden filesystem coupling, or implicit trust is permitted.
5. Producer claims must be independently verified by the receiving boundary where verification is required.
6. Integration failure must not silently corrupt local authoritative state.
7. Missing upstream services must produce an explicit unavailable, unknown, deferred, or failed state.
8. This repository's current implementation must not be treated as the complete product definition.

## Authoritative ecosystem sources

- `.constellation/SERVICE_MAP.md`
- `.constellation/registry.json`
- `.constellation/AGENT_POLICY.md`
- `.constellation/SHARED_INVARIANTS.md`

## Change governance

Changes to this service's ecosystem role, ownership boundaries, upstream dependencies, or
downstream responsibilities require:

1. A proposal under `docs\proposals`.
2. A documented compatibility impact.
3. Updated service-map and registry entries.
4. Updated positive and negative integration tests.
5. A new service-map receipt.
