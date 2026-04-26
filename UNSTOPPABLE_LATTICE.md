# Unstoppable Lattice

Investigation of memory, storage, and cycle-growth issues that prevent lattice-node mining from running indefinitely without stalls or unbounded resource growth.

Audit: 2026-04-25

---

## Architecture summary

The storage layer uses a shared DiskBroker (one SQLite database for all chains) fronted by per-chain MemoryBroker LRU caches, all managed by VolumeBroker. Pins are ref-counted with owner tags (e.g. `"Nexus:42"`); data is evictable only when all owners release. Two orthogonal retention axes govern lifecycle: BlockRetention (tip/retention/historical) controls when block data is unpinned, and StorageMode (stateless/stateful/historical) controls when replaced state roots are unpinned via StateDiff. The StateDiff pipeline is threaded through validation -- `proveAndUpdateState` returns ref-counted maps of created/replaced CIDs, threaded from `validateFrontierState` through `processBlockHeader`. Mined blocks are broadcast with data inline via topic messages so peers need no round-trip fetch.

---

## Active findings -- 2026-04-25

### Critical

**1. IvyFetcher.cache grows without bound**

`IvyFetcher.swift:24`

The `cache: [String: Data]` dict accumulates entries on every `provide()` and `fetch()` call with no eviction. Mining sessions that process thousands of blocks exhaust heap memory.

*Impact:* Unbounded memory growth proportional to blocks processed. Mining eventually OOMs.

*Fix:* LRU cap (e.g. 50k entries) or clear after each block processing cycle.

---

**2. skipValidation=true on peer-received blocks**

`LatticeNode+Blocks.swift:615-620`

Blocks received from peers via gossip are processed with `skipValidation: true`. Pre-checks cover PoW, timestamp, and block size -- but NOT state transitions. A peer with sufficient hashpower could forge valid-PoW blocks with invalid state (minting coins, crediting accounts).

*Impact:* Consensus safety violation. Invalid state transitions accepted without verification.

*Fix:* Either re-enable validation for peer blocks (requires making sub-tree data available, e.g. by sending Volume payloads inline alongside blocks), or add a deferred validation pass that checks state consistency within retentionDepth.

---

**3. Silent storage failures in block processing**

`ChainNetwork.swift:119-120,126,247` and `LatticeNode+Blocks.swift:72-75`

All DiskBroker store and pin operations use `try?`, silently discarding errors. If disk is full or SQLite is corrupt, blocks are announced as stored but data is lost.

*Impact:* Silent data loss. Blocks appear committed but underlying data may be missing, causing fetch failures for peers and state corruption on restart.

*Fix:* Log errors at minimum. For critical paths (storeBlockRecursively), fail the block submission rather than proceeding with partial data.

---

### High

**4. Mempool-full gossip has no per-peer rate limit**

`ChainNetwork.swift:382-423`

The `mempool-full` topic handler accepts unlimited distinct transactions from a single peer. A malicious peer can flood the mempool with valid-but-useless transactions.

*Impact:* DoS vector. One peer can saturate mempool capacity and validation CPU.

*Fix:* Per-peer tx admission rate limit (e.g. 100 tx/sec), rejecting excess without validation overhead.

---

**5. evictUnpinned runs only every 60s**

`BackgroundLoops.swift:50`

Orphan volumes from rejected gossip blocks (`storeLocally` with no pin) accumulate on disk indefinitely until the next eviction sweep.

*Impact:* Disk usage spikes between sweeps. Under gossip spam, 60s of orphan accumulation can be significant.

*Fix:* Also trigger eviction after batch block rejection, or pin gossip blocks temporarily with TTL.

---

**6. Child block state application errors are silent**

`LatticeNode+Blocks.swift:833-843`

In `applyChildBlockStates`, if the childBlocks subtree cannot be resolved, the function silently returns. Child chain states diverge from nexus without warning.

*Impact:* Child chains silently fall out of sync with nexus. No alerting, no recovery path.

*Fix:* Log prominently when child state application fails. Consider marking the block as partially applied.

---

**7. recentPeerBlocks and peerBlockCounts cleanup is reactive, not time-based**

`LatticeNode+Blocks.swift:35,721-761`

Old peer entries never expire; cleanup only runs when hard cap is breached.

*Impact:* Memory grows with unique peer count over time. No natural decay.

*Fix:* Add periodic time-window expiry (e.g. drop entries older than 60s).

---

### Medium

**8. maxReorgDepth (100) vs retentionDepth (configurable, default 1000)**

`LatticeNode+Blocks.swift:17,374`

A legitimate reorg deeper than 100 blocks but within retentionDepth is rejected.

*Impact:* Honest reorgs in the 100-1000 block range are unnecessarily refused.

*Fix:* Derive maxReorgDepth from retentionDepth (e.g. `min(retentionDepth, 200)`).

---

**9. Nonce API semantics undocumented**

`LatticeNode+State.swift:55-76`

`getNonce` returns next-valid, `getAccount` returns next-valid in its nonce field. No type-level distinction between "last used" and "next valid" nonces.

*Impact:* Caller confusion. Off-by-one errors in transaction construction.

*Fix:* Rename to `getNextNonce` in the public API, or add documentation.

---

**10. pinRequest handler has no rate limit**

`ChainNetwork.swift:428-455`

A peer can send unlimited pin requests, each triggering a DHT fetch.

*Impact:* DoS vector through unbounded DHT lookups.

*Fix:* Per-peer rate limit.

---

**11. Ivy dead code**

`Ivy.swift`

Mining challenge (~95 LOC), offerDirectConnect (~25 LOC), PEX (~130 LOC), zone sync/replication (~150 LOC) have 0 call sites in lattice-node. ~400 LOC of unreachable code.

*Impact:* Attack surface, maintenance burden, binary size.

*Fix:* Delete.

---

**12. Ivy pendingRequests unbounded**

`Ivy.swift:23`

Continuation dict keyed by CID with no cap.

*Impact:* Slow memory leak under sustained fetch activity.

*Fix:* BoundedDictionary.

---

### Remaining from previous audit

**13. finalizeSyncResult (P1 #12)** -- re-resolves txDict during sync. Fix: cache during download.

**14. stmtCache (P1 #16)** -- no formal cap but bounded by finite SQL strings. Low risk.

**15. inFlightBlockCIDs (P2 #10)** -- no cap. Low risk.

**16. childBlocks serialization (S8)** -- DONE as of 2026-04-25 (SerializationPinningTests.swift).

---

## Quick wins priority order

1. **IvyFetcher.cache LRU cap** (#1) -- direct memory leak during mining
2. **Log storage errors** (#3) -- silent data loss
3. **Per-peer mempool gossip rate limit** (#4) -- DoS vector
4. **Time-based expiry on peer tracking dicts** (#7) -- memory hygiene
5. **Delete dead Ivy code (I3-I6)** (#11) -- attack surface reduction
6. **Ivy pendingRequests BoundedDictionary** (#12) -- long-running leak
7. **Derive maxReorgDepth from retentionDepth** (#8) -- correctness
8. **Address skipValidation for peer blocks** (#2) -- consensus safety (complex, needs design)

---

## Archive -- resolved items

<details>
<summary>Verification status table (2026-04-25)</summary>

| Item | Status | Note |
| --- | --- | --- |
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
