# Proposal 0002 - Registry and contract alignment (for Constellation and NFL's neighbours)

Status: proposed 2026-10-15. Nothing here is changed by NFL itself: these are conflicts found during the
2026-10-15 audit between NFL's code, its canonical documents and Constellation's registry. Per the agent policy
they are reported, not silently resolved. Compatibility impact: documentation and registry only, except item 6,
which asks producers to know how NFL reads their envelopes.

## 1. NFL's own integration document disagrees with the registry

`docs/canonical/ECOSYSTEM_INTEGRATION.md` (managed by Constellation) says layer `witness-ledger`; the registry
says `foundation.hash-ledger`. It lists CPR and NeverLost as upstream; the registry lists only `neverlost` in
`upstream_services`, while `registry/integrations.json` records `nfl>cpr`, `nfl>neverlost` and `nfl>watchtower`.
Its contract families (`nfl.ingest.run.receipt.v1`, `nfl.cpr.*`, ...) are NFL's telemetry, not the families the
registry names (`nfl.ingest`, `nfl.receipt`).
**Request:** regenerate the document from the registry, and decide whether `cpr` (and `watchtower`) belong in
`upstream_services`. Note for the decision: NFL's ledger (commit, lookup, verify, chain, seal, export) needs no
CPR; only packet ingest does, and without CPR it reports items `pending`, never green.

## 2. `project.contract.json` is empty where the registry is not

`upstream_services`, `downstream_users` and `contract_families` are `[]`. **Request:** publish the registry values.

## 3. `downstream_users` is missing seven consumers

`registry/integrations.json` has 16 records with provider `nfl`. `downstream_users` lists 9; missing:
`covenant-gate`, `rebound`, `gos-runtime`, `global-workbench`, `convergence-suite`, `pie`, `watchtower`.

## 4. Contracts attributed to NFL that NFL does not define

| Record | Contract | Fact |
|---|---|---|
| `runledger>nfl` | `nfl.receipt.ingested.v1` | A RunLedger event type ("records an external witness receipt"), owned by RunLedger. The NFL contract it records is `nfl.receipt.v1`. |
| `global-workbench>nfl` | `nfl.settings.v1` | NFL has no settings contract. Needs the Global Workbench owner to say what is meant. |
| `watchtower>nfl` | `nfl.tier0.selftest.v1` | Frozen historical Tier-0 evidence (2026-03-07). Not a live exchange. |
| `live-state-surgeon>nfl` | `nfl.receipt.v1` | LSS's own docs say these are standalone-only local pointer rows; the integrated path is LSS -> WatchTower -> NFL. |

NFL now publishes the contracts it does own in `schemas/`: `nfl.ingest.v1`, `nfl.receipt.v1`,
`nfl.ledger.record.v1`, `nfl.inbox_registry.v1`. **Request:** list them as NFL's contract families
(`nfl.ingest`, `nfl.receipt`, `nfl.ledger`) and correct the records above.

## 5. Publish the integrations machine-readably into `.constellation/`

NFL must only commit receipts of registered integrations (shared invariant). The only copy it has is the
generated Markdown table in `.constellation/SERVICE_MAP.md`, which NFL parses. **Request:** also publish
`registry/integrations.json` as `.constellation/integrations.json`; NFL will prefer it when present.

## 6. `nfl.ingest.v1.packet_id` cannot be the Packet Constitution packet id

Under Packet Constitution v1 Option A (CPR) the packet id is SHA-256 of `manifest.json`, and the manifest covers
`payload/nfl.ingest.json`, so an envelope can never contain its own packet's id. RunLedger computes a different,
producer-specific id; Rebound's schema copy is looser than RunLedger's. NFL keys everything on the CPR-verified
id and records the envelope's value as `declared_packet_id` in `nfl.receipt.v1`, never as proof.
**Request (producers, Constellation):** treat `nfl.ingest.v1.packet_id` as the producer's declared id; use
NFL's `schemas/nfl.ingest.v1.schema.json` as the authoritative copy.

## 7. CPR's verifier does not run on Linux

`cpr/scripts/_lib_cpr_v1.ps1` `Get-RelativePathNormalized` builds `[System.Uri]` from `'<path>\'`, which on
Linux is a relative URI, so every verify fails with `MakeRelativeUri ... relative URI`. Two lines fix it
(`New-Object System.Uri(<path + DirectorySeparatorChar>, [System.UriKind]::Absolute)` for both URIs);
`build_packet_v1.ps1` has the same failure. For the CPR owner. NFL's self-test applies the fix to a temporary
copy only, and says so.

## 8. Receipt state `witnessed`

Constellation can move a record from `emitting` to `witnessed` by asking NFL: `nfl_cli_v1.ps1 verify-receipt
-ReceiptFile <emitter's receipts>` or `POST /receipt/verify`. Every line answering `VERIFIED` is witnessed.

## 9. NFL Explorer

See `nfl-explorer/docs/proposals/0001-ownership-and-contract.md` for its proposed `owns` / `does_not_own`.
