NFL -> WatchTower handoff bundle

Purpose:
- consume locked NFL Tier-0 public surface
- verify WatchTower can read frozen NFL evidence
- do not modify NFL verifier law

Start from:
- scripts/_selftest_nfl_tier0_locked_v1.ps1
- frozen/*
- test_vectors/nfl_packet_verify_v1/suite.json

Expected next WatchTower work:
- import this handoff bundle into WatchTower repo
- write a WatchTower consume script
- verify WatchTower can parse locked NFL artifacts
- emit a WatchTower receipt over this handoff
