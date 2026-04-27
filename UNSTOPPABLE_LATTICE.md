# Unstoppable Lattice

Investigation of memory, storage, and cycle-growth issues that prevent lattice-node mining from running indefinitely without stalls or unbounded resource growth.

Audit: 2026-04-27

---

## Architecture summary

The storage layer uses a shared DiskBroker (one SQLite database for all chains) fronted by per-chain MemoryBroker LRU caches, all managed by VolumeBroker. Pins are ref-counted with owner tags (e.g. `"Nexus:42"`); data is evictable only when all owners release. Two orthogonal retention axes govern lifecycle: BlockRetention (tip/retention/historical) controls when block data is unpinned, and StorageMode (stateless/stateful/historical) controls when replaced state roots are unpinned via StateDiff. The StateDiff pipeline is threaded through validation -- `proveAndUpdateState` returns ref-counted maps of created/replaced CIDs, threaded from `validateFrontierState` through `processBlockHeader`. Mined blocks are broadcast with data inline via topic messages so peers need no round-trip fetch.

---

## Recently shipped -- 2026-04-25 to 2026-04-27

Five changes have closed major findings or eliminated whole classes of risk:

- **Volume-rooted child-chain fetch** (`9e9d03d`) -- `IvyFetcher` rewritten with explicit `enterVolume`/`exitVolume` lifecycle. The unbounded `[String: Data]` cache is gone; cache scope tracks Volume boundaries. Closes #1.
- **Validate state on the block-receive data path** (`f8c7baa`) -- gossip-received blocks now run full validation (`skipValidation: false`). Only mining and CAS recovery (trusted-data paths) skip. Closes #2.
- **Pin nexus blocks from descendant child blocks** (`8e503f2`) -- validator pins (`validates:<childCID>`) make anchor relationships explicit and queryable; cascade-prune cleans them up at retention depth.
- **Recover chain state in topological order** (`793723b`) -- startup loads parents before children, fixing CAS-recovery races.
- **Parent-anchored child-chain bootstrap with full validation** (`2f1db55`) -- followers no longer trust historical child blocks blindly. Subscribe(child) now implies subscribe(every ancestor); follower bootstrap walks the parent chain backward to derive each anchor and validates the entire child chain end-to-end (genesis + per-height PoW vs anchor + structural) before subscribing.

## Active findings -- 2026-04-27

### Critical

**1. Silent storage failures in block processing**

`ChainNetwork.swift:135-263` (and previously `LatticeNode+Blocks.swift:72-75`)

`storeBlockRecursively` now uses `do/catch` and logs errors. But several `ChainNetwork` paths still use `try?` -- `storeAndPublish`, `storeLocally`, `storeBatch`, `storeBlockBatch`, `setChainTip`. Critical block-store path is loud; bulk/tip-pin paths still silent.

*Impact:* Silent data loss on bulk/tip-pin paths. Blocks appear committed but underlying data may be missing.

*Fix:* Convert remaining `try?` sites to logged catches. Fail the operation when the failure is meaningful (tip pin, batch store on hot path).

---

### High

**2. Mempool-full gossip has no per-peer rate limit**

`ChainNetwork.swift:398-439`

The `mempool-full` topic handler accepts unlimited distinct transactions from a single peer. A malicious peer can flood the mempool with valid-but-useless transactions.

*Impact:* DoS vector. One peer can saturate mempool capacity and validation CPU.

*Fix:* Per-peer tx admission rate limit (e.g. 100 tx/sec), rejecting excess without validation overhead.

---

**3. evictUnpinned runs only every 60s**

`BackgroundLoops.swift:46`

Orphan volumes from rejected gossip blocks (`storeLocally` with no pin) accumulate on disk indefinitely until the next eviction sweep.

*Impact:* Disk usage spikes between sweeps. Under gossip spam, 60s of orphan accumulation can be significant.

*Fix:* Also trigger eviction after batch block rejection, or pin gossip blocks temporarily with TTL.

---

**4. Child block state application errors are silent**

`LatticeNode+Blocks.swift:854-857`

In `applyChildBlockStates`, if the childBlocks subtree cannot be resolved, the function silently returns. Child chain states diverge from nexus without warning. Function was heavily restructured (8e503f2 added validator pins) but the silent-return path on resolve-failure is unchanged.

*Impact:* Child chains silently fall out of sync with nexus. No alerting, no recovery path.

*Fix:* Log prominently when child state application fails. Consider marking the block as partially applied.

---

**5. recentPeerBlocks and peerBlockCounts cleanup is reactive, not time-based**

`LatticeNode+Blocks.swift:35,718-761`

Old peer entries never expire; cleanup only runs when hard cap is breached.

*Impact:* Memory grows with unique peer count over time. No natural decay.

*Fix:* Add periodic time-window expiry (e.g. drop entries older than 60s).

---

### Medium

**6. maxReorgDepth (100) vs retentionDepth (configurable, default 1000)**

`LatticeNode+Blocks.swift:17,367`

A legitimate reorg deeper than 100 blocks but within retentionDepth is rejected.

*Impact:* Honest reorgs in the 100-1000 block range are unnecessarily refused.

*Fix:* Derive maxReorgDepth from retentionDepth (e.g. `min(retentionDepth, 200)`).

---

**7. pinRequest handler has no rate limit**

`ChainNetwork.swift:454-470`

A peer can send unlimited pin requests, each triggering a DHT fetch.

*Impact:* DoS vector through unbounded DHT lookups.

*Fix:* Per-peer rate limit.

---

**8. Ivy dead code**

`Ivy.swift`

Mining challenge (~95 LOC), offerDirectConnect (~25 LOC), PEX (~130 LOC), zone sync/replication (~150 LOC) have 0 call sites in lattice-node. ~400 LOC of unreachable code.

*Impact:* Attack surface, maintenance burden, binary size.

*Fix:* Delete.

---

### Remaining from previous audit

**9. finalizeSyncResult (P1 #12)** -- re-resolves txDict during sync. Fix: cache during download.

**10. stmtCache (P1 #16)** -- no formal cap but bounded by finite SQL strings. Low risk.

**11. inFlightBlockCIDs (P2 #10)** -- no cap. Low risk.

---

## Quick wins priority order

1. **Log remaining `try?` storage sites** (#1) -- finish what `storeBlockRecursively` started
2. **Per-peer mempool gossip rate limit** (#2) -- DoS vector
3. **Time-based expiry on peer tracking dicts** (#5) -- memory hygiene
4. **Log child-state apply failures** (#4) -- observability
5. **Delete dead Ivy code (I3-I6)** (#8) -- attack surface reduction
6. **Per-peer pinRequest rate limit** (#7) -- DoS vector
7. **Derive maxReorgDepth from retentionDepth** (#6) -- correctness

---

## Archive -- resolved items

<details>
<summary>Verification status table (2026-04-27)</summary>

| Item | Status | Note |
| --- | --- | --- |
| 2026-04 #1 IvyFetcher.cache | DONE | Volume-scoped enterVolume/exitVolume lifecycle (9e9d03d) |
| 2026-04 #2 skipValidation peer blocks | DONE | Full validation on gossip-recv (f8c7baa) |
| 2026-04 #9 Nonce API semantics | DONE | `getNextNonce` exposed; `getNonce` is wrapper |
| 2026-04 #12 Ivy pendingRequests | DONE | `canRegisterPending` enforces `maxPendingRequests` (4096) |
| 2026-04 follower trust | DONE | Parent-anchored bootstrap with full validation (2f1db55) |
| P0 #1 diagLog | DONE | Gated behind env flag |
| P0 #2 recentBlockExpiry | OBSOLETE | BlockchainProtectionPolicy deleted; pin lifecycle via VolumeBroker |
| P0 #3 accountCIDs LRU | OBSOLETE | BlockchainProtectionPolicy deleted; ref-counted pins |
| P0 #4 tx_history pruner | DONE | pruneTransactionHistory runs in GC loop |
| P0 #4a pin/announce coupling | OBSOLETE | Old protection policy gone; explicit owner tags + ref counts |
| P1 #5 double child-block writes | DONE | Shared DiskBroker eliminates cross-broker copies |
| P1 #6 mempool fetcherCache | DONE | Incremental cache in NodeMempool |
| P1 #7 serial pin announces | DONE | Parallelized |
| P1 #8 resolveLatestMinerNonce | DONE | Cached with reorg invalidation |
| P1 #11 backfillBlockIndex | DONE | Skips when populated |
| P1 #12 finalizeSyncResult | STILL VALID | Cache txDict during sync |
| P1 #13 recoverFromCAS | DONE | Uses skipValidation for trusted CAS data |
| P1 #14 per-chain maps | DONE | destroyChainNetwork cleans up all maps |
| P1 #15 NodeMetrics keys | DONE | Cleaned up in destroyChainNetwork |
| P1 #16 stmtCache | STILL VALID | Bounded by distinct SQL strings (finite) |
| P2 #9 watchdog submit timeout | DONE | Inner timeout with raceSubmitWithTimeout |
| P2 #10 inFlightBlockCIDs cap | STILL VALID | Low risk |
| P2 #17 difficultyHashPrefixBytes | OBSOLETE | Allocation per iteration, not a leak |
| S1 Mempool admission DoS | DONE | Per-sender nonce-gap cap, fee floor, RBF, fee-priority eviction |
| S2 PoW-short-circuit ordering | DONE | Short-circuit before validate |
| S3 Reorg vs retentionDepth | DONE | Fail-loud on deep reorg |
| S4 Shared-CAS isolation | REDESIGNED | Shared DiskBroker intentional; pin owners provide isolation |
| S5 PinAnnounce verification | DONE | Tally demotion on fetch-failure |
| S6 Block timestamp validation | DONE | MTP + future drift bounds in Lattice core |
| S7 SQLite WAL/VACUUM | DONE | Checkpoint + incremental vacuum in maintenance loop |
| S8 childBlocks serialization | DONE | SerializationPinningTests.swift |
| S9 Anchor-peer demotion | DONE | Score-based demotion |
| S10 maybePersist cadence | DONE | Measured and tuned |
| I1 CASBridge | DELETED | Ivy rewritten as stateless transport |
| I2 Volume fetching | NOW USED | VolumeBroker provides Volume-level fetch/store |
| I3 mining challenge | STILL VALID | 0 call sites |
| I4 offerDirectConnect | STILL VALID | 0 call sites |
| I5 PEX | STILL VALID | 0 call sites |
| I6 Zone sync / replication | STILL VALID | 0 call sites |
| I7 LocalDiscovery default | DONE | Default flipped to false |
| I8 STUN | STILL VALID | Conditional on deployment model |
| I9 PeerHealthMonitor | STILL VALID | Optional for trusted setups |
| I10 SendBudget | DELETED | Removed from Ivy |
| I11 pendingRequests | STILL VALID | Unbounded continuations |
| E1 TIMING prints | DONE | Removed with diagLog gating |
| E2 DiagCommand/IdentityCommand | Low priority | ~100 LOC dev-only |
| E3 MultiNodeClient/ClusterCommand | Low priority | ~480 LOC dev scaffolding |
| E4 settleWithCreditors | DONE | Moved off critical path |
| E5 HealthCheck file-writer | Low priority | RPC /health covers it |
| E6 Deposit/Receipt RPC | Low priority | Disable if unused |
| E7 Stale Tally imports | Low priority | Cosmetic |
| E8 SyncStrategy.headersFirst | Low priority | ~80 LOC unreachable |
| E9 Wallet.swift builders | Low priority | Test-only |
| E10 DNSSeeds.runDig | Low priority | ~41 LOC subprocess fallback |
| E11 CLI subcommands in daemon | Low priority | ~1300 LOC movable to tools binary |
| L1 ChainSpec presets | Low priority | Move to test target |
| L2 BlockBuilder constructors | KEEP | Production usage confirmed |
| L3 ChainSpec validate helpers | Low priority | ~15 LOC dead |
| L4 Block genesis helpers | Low priority | Infrequent paths |
| L5 ChainSpec aggregate stats | Low priority | ~40 LOC removable |
| L6 CollectionConcurrencyKit | Low priority | Benchmark before changing |
| L7 Block.version field | KEEP | Hard-fork-only removal |

</details>

---

## Real-node smoke testing plan -- 2026-04-27

### What we have

Eight `.mjs` smoke tests in `lattice-app/` spawn real `LatticeNode` binaries and drive them via RPC. Each test boots fresh `/tmp/...` data dirs, so they're self-contained and CI-friendly.

| Test | Scenario | Asserts |
| --- | --- | --- |
| `smoke-sync` | 2 nodes, A miner, B follower with `--subscribe Nexus/Payments` | B converges on both Nexus and Payments tips |
| `smoke-multinode-convergence` | 3 nodes mesh, A mines | All three tips identical after mining stops |
| `smoke-restart-resilience` | One node, swap, SIGKILL, respawn, swap again | Pre-restart deposit consumed; post-restart swap settles |
| `smoke-swap` | Single devnet, deposit/receipt/withdraw | One full uniform-rate cycle |
| `smoke-variable-rate-swap` | As above, 2.5x rate | Asymmetric pair preserved |
| `smoke-grandchild-swap` | `Nexus → Mid → {Alpha, Beta}`, receipt on Mid | 3 cycles each on Alpha and Beta |
| `smoke-multidepth-swap` | 3-deep branching tree | Exact balance deltas at every (source, receipt) depth combo |
| `smoke-stateless` | CLI flag wiring | `--stateless --mine` rejected; `--stateless` boots |

### Gaps (concerns with no smoke coverage)

1. **Adversarial peer behavior** -- forged blocks, bad signatures, equivocation, mempool spam.
2. **Network partition / heal** -- no link drop, asymmetric loss, or three-way split.
3. **Late-joiner deep sync** -- `smoke-sync` covers only height ~10; no test exercises bootstrap at height 200+.
4. **Parent-dependency invariant** -- the new (commit 2f1db55) subscription/mining gates have no smoke coverage.
5. **Long-running multi-chain stability** -- the RSS pathology in multi-chain merged mining (project memory) is unobserved by any smoke test.
6. **Stateless follower depth** -- `smoke-stateless` only verifies CLI flags, not actual following with bounded disk.
7. **Mempool back-pressure / DoS** -- finding #2 has no test.

### Plan

**Phase A -- Refactor scaffolding (1-2 days).** Extract a `smoke-lib.mjs` consolidating the helpers each test currently reimplements: `secp` HMAC bootstrap, `base32Encode`, `computeAddress`, `sign`, `rpc`, `getNonce`/`Balance`/`Deposit`/`Receipt`, `submit`, `waitForHeight`, `pollUntil`, `stageFund` (swap tests); `startNode`/`teardown`, `waitForRPC`, `readIdentity` (process-spawning tests). Behavior unchanged; ~150 LOC duplication removed per test file.

**Phase B -- New tests filling the gaps.** Each <300 LOC, process-spawning, deterministic, fresh tmp dirs.

1. `smoke-late-joiner.mjs` -- A mines `Nexus + Payments` to height 200; B joins fresh with `--subscribe Nexus/Payments`. Pass: B's tip CID matches A on both chains within 90s.
2. `smoke-parent-dependency.mjs` -- B starts with `--subscribe Nexus/Mid/Stable`. Verify subscribed paths cover Nexus, Nexus/Mid, AND Nexus/Mid/Stable. RPC `mining/start Stable` fails (or no-ops) when parent isn't mining. Confirms commit 2f1db55 gates.
3. `smoke-partition.mjs` -- 3 nodes all mining; partition `{A,B}` vs `{C}` for 30s via firewall hooks (or peer-disconnect RPC). Heal. Pass: all three converge to the heaviest tip; reorg events fire on the losing side.
4. `smoke-byzantine-bad-block.mjs` -- A test peer (Swift binary in `Tests/`) gossips a forged block (correct PoW prefix, mutated state root). Pass: honest node rejects without applying state; honest tip unchanged.
5. `smoke-stability-multichain.mjs` -- A miner with 3 child chains all merge-mining. Run 30 minutes. Sample RSS every 30s. Pass: RSS stays under 2x initial steady-state; height progresses on all chains.
6. `smoke-mempool-spam.mjs` -- A mines, B floods 1000 valid tx/sec for 30s. Pass: A's mempool stays under cap; A keeps mining; B's admission gets throttled (when finding #2 lands).
7. `smoke-stateless-follower.mjs` -- A mines to height 50; B joins as `--stateless --subscribe Nexus/Payments`. Pass: B answers `/api/chain/info` with correct tips; B's data dir stays under 10 MB.

**Phase C -- Test runner + CI.** `smoke-all.mjs` runs every smoke sequentially with timing and pass/fail summary; each test gets `/tmp/smoke-{name}-{run-id}/`. `smoke-stability-multichain` is opt-in via env flag (long-running). Wire to CI on every PR.

**Phase D -- Promotion to canary.** Migrate the stable subset to a continuously-running cloud canary (single region first, then multi-region per the Phase 5 plan in the archive below). Each canary failure pages.

### Acceptance

- All 15 smoke tests (8 existing + 7 new) green when run via `smoke-all.mjs`.
- `smoke-stability-multichain.mjs` runs cleanly on a developer laptop without OOM.
- `smoke-all.mjs` wall-clock under 30 minutes (excluding stability test).
- New tests use shared scaffolding from `smoke-lib.mjs`.

---

## Archive -- Testing plan (from 2026-04-21 audit)

<details>
<summary>Full testing plan</summary>

### Principles

1. No single-box test can prove global behavior -- latency, clock skew, asymmetric routes, and NAT variety only show up on real infra. Budget real cloud multi-region time.
2. Every consensus-critical rule needs a golden test -- serialization, difficulty, timestamp bounds, reorg depth. Regressions here are silent and irreversible.
3. Liveness is measured, not asserted -- "the miner didn't stall" is a pass-fail metric on wall-clock block cadence under load, not a unit assertion.
4. Adversarial first, happy-path last -- a Byzantine harness that can lie, withhold, and spam is required to test anything a real public network will do.

### Harness requirements

- Multi-node orchestrator (seed from MultiNodeClient + ClusterCommand).
- Byzantine peer shim (~300 LOC harness code).
- Clock control (injection point for block.timestamp).
- Network chaos (tc/netem/iptables/toxiproxy wrapped in test DSL).
- Determinism harness (replay-and-diff binary with golden fixtures).
- Telemetry sink (Grafana + Prometheus from /metrics endpoint).

### Phase 1 -- protocol unit / integration (one box, in-process)

Handshake + routing, block gossip, tx gossip, PinAnnounce flow, CAS fetch miss flow, reorg path, merged-mining commit atomicity.

Pass criteria: CI green + golden-block bit-identity.

### Phase 2 -- small cluster (3-10 nodes, one box)

Single-writer convergence, two competing miners, three-way partition + merge, late-joiner sync, graceful vs ungraceful restart, deep reorg near retentionDepth.

### Phase 3 -- network-hostile (single box, tc/netem)

Latency matrix, asymmetric bandwidth, partition durations, NAT variants, clock skew.

Pass criteria: zero stuck-miner events in 24h; block cadence drift at most 10% from baseline.

### Phase 4 -- adversarial / Byzantine

Eclipse attempt, selfish mining, PinAnnounce liar, timestamp warp, mempool nonce-gap spam, fork-choice equal-work race, malicious child chain.

### Phase 5 -- global scale (multi-region cloud, 30+ days)

50-100 nodes across 4+ regions, continuous chaos, sustained tx load, stall detection, growth curve plotting, cross-version compat.

### Phase 6 -- production rollout playbook

Canary tier, mining canary, tripwires, forensic logs, documented rollback.

### Signals / exit criteria

| Phase | Exit criterion |
| --- | --- |
| 1 | CI green + golden-block bit-identity |
| 2 | 10-node cluster 48h no stall, no state divergence |
| 3 | All matrix cells complete; no stall > 3x block time |
| 4 | Every adversarial test has a pass or tracked ticket |
| 5 | 30-day run, all growth curves flatten |
| 6 | Three clean canary-to-full rollouts |

### Harness backlog

1. Clock injection point in BlockBuilder / MinerLoop.
2. Byzantine peer variant with toggleable misbehaviors.
3. Network-chaos test DSL.
4. Determinism harness (replay-and-diff binary).
5. Grafana dashboard JSON in repo.
6. Forensic-log env flag plumbing.

</details>
