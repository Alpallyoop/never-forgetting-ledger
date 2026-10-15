# NFL Tier-0 Lock

Status: GREEN / LOCKED

Canonical latest green bundle:
- C:\dev\nfl\proofs\receipts\20260307T031736Z

Frozen bundle:
- C:\dev\nfl\test_vectors\tier0_frozen\nfl_tier0_green_20260307

Tier-0 scope locked:
- scripts/verify_packet_v1.ps1
- scripts/selftest_verify_packet_v1.ps1
- scripts/selftest_vectors_v1.ps1
- scripts/_selftest_nfl_tier0_v2.ps1

Verified negative tokens:
- NFL_VERIFY_FAIL:SHA256_MISMATCH
- NFL_VERIFY_FAIL:MISSING_SIG
- NFL_VERIFY_FAIL:SIG_VERIFY_FAIL
- NFL_VERIFY_FAIL:MISSING_SHA256SUMS
- NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE
- NFL_VERIFY_FAIL:TRAVERSAL_PATH
- NFL_VERIFY_FAIL:MISSING_TARGET

Tier-0 completion claim:
- positive vector verifies
- negative suite fails deterministically
- taxonomy tokens emit
- receipts append
- transcript bundle emits
- sha256 evidence bundle emits
- parse-gate required
- no false green on locked suite
