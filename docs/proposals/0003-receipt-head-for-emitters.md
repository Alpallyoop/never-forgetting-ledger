# Proposal 0003 - `receipt-head`: let an emitter check its receipts against what NFL witnessed

Status: implemented 2026-10-22 on the owner's instruction ("set this up", for Recognition's `recognition > soteriavault`
receipts; Recognition proposal 0005, Constellation proposal 0033). Decisions below are NFL's.
Compatibility impact: additive and read-only. No existing command, file or record changes.

## Why

An integration receipt file is a hash chain. A chain cannot see a change to its newest receipt, a receipt added at the
end, or the last receipts cut off, and an emitter's own second record (Recognition keeps one in its encrypted action
ledger) can be rewritten by a program running as the same Windows user. NFL's ledger is the independent witness the
shared invariants name. To use it, an emitter has to ask NFL one question: which receipt of my integration did you
witness last? `verify-receipt` answers for lines the emitter still has; it cannot reveal a witnessed line that is gone.

## What NFL now does

`nfl_cli_v1.ps1 receipt-head -Integration <consumer>><provider>` (and `Get-NflReceiptHead` in `_lib_nfl_v1.ps1`):

- reads the ledger (never writes it) and takes the records whose artifact label is exactly
  `constellation.integration.receipt.v1:<consumer>><provider>`, in ledger order;
- prints `INTEGRATION=`, `WITNESSED_COUNT=`, `HEAD=` (the hash of the most recent such record; 64 zeros when none),
  `LAST_SEQ=` (-1 when none), then `NFL_RECEIPT_HEAD_OK`;
- refuses a missing or malformed integration (`NFL_CLI_FAIL:MISSING_INTEGRATION`,
  `NFL_CLI_FAIL:RECEIPT_HEAD_BAD_INTEGRATION`: two lower-case service ids joined by `>`).

An unknown or never-witnessed integration is not an error: count 0, zero head. Witnessing stays idempotent per hash and
label, so witnessing a file again never moves the head.

## How an emitter uses it (not NFL's rule, recorded for reference)

NFL's `HEAD` must still be one of the emitter's receipt lines. Because every line links to the one before it, the
lines up to and including it are then exactly the ones NFL witnessed. A rewritten, removed or rebuilt witnessed receipt
fails that check even if the emitter's own files were all changed together. Receipts written after the last witnessing
are only as safe as the emitter's local records until they are witnessed; emitters should witness promptly.

## Proof

`scripts/_selftest_nfl_receipt_head_v1.ps1` (9 cases, temp ledger only, no CPR): empty ledger gives a zero head; one and
two witnessed receipts give the right count and the newest hash; another integration's receipts are counted separately;
witnessing again does not move the head; an unknown integration is empty, not an error; seven malformed integration
arguments (including upper case, three parts, path characters) are refused; the ledger bytes are unchanged by the
command; the chain still verifies. Added to `_RUN_nfl_selftests_v1.ps1` (stage `RECEIPT_HEAD`, and the parse gate).
