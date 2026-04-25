# Unstoppable Lattice

Investigation of memory, storage, and cycle-growth issues that prevent lattice-node mining from running indefinitely without stalls or unbounded resource growth.

Findings are ranked by impact on "mining becomes unstoppable": things that eventually freeze the miner come first, per-block work that grows with chain state comes next, and latent stall modes round out the list.

---

## Major architecture change — 2026-04-25 (VolumeBroker migration)

The storage layer was completely replaced. Per-CID Acorn storage is gone. The new model:

- **VolumeBroker** replaces Acorn. Storage is Volume-granular (root CID + all entry CIDs stored/evicted as a unit).
- **Shared DiskBroker** — one SQLite database for all chains (was per-chain isolated). Eliminates cross-chain resolution failures.
- **Per-chain MemoryBroker** — LRU cache per chain cascading to the shared DiskBroker.
- **Ref-counted pins** with owner tags (`"Nexus:42"` = block 42 on Nexus). Pin/unpin carry a count. Data evictable only when all owners release all pins.
- **Two orthogonal retention axes:**
  - `BlockRetention` (tip/retention/historical) — controls when block data is unpinned
  - `StorageMode` (stateless/stateful/historical) — controls when replaced state roots are unpinned via StateDiff
- **StateDiff** threaded through the validation pipeline — `proveAndUpdateState` returns ref-counted maps of created/replaced CIDs, threaded from `validateFrontierState` through `processBlockHeader`.
- **Inline block gossip** — mined blocks broadcast with data inline via topic messages (no round-trip fetch needed by peers).
- **Tally gate removed** from block reception — PoW + timestamp + rate-limit are sufficient; tally was blocking legitimate consensus messages from fresh peers.

**Deleted:** `BlockchainProtectionPolicy`, `UnionProtectionPolicy`, `AcornFetcher`, `BufferedStorer` (moved to tests), `AcornDiskWorker`, `AcornMemoryWorker`, per-chain `volumes.sqlite`.

---

## Verification status — 2026-04-25

| Item | Status | Note |
| --- | --- | --- |
| P0 #1 diagLog | **DONE** | Gated behind env flag; `[TIMING]` prints removed |
| P0 #2 recentBlockExpiry | **OBSOLETE** | `BlockchainProtectionPolicy` deleted. Pin lifecycle now handled by VolumeBroker owner-based pins |
| P0 #3 accountCIDs LRU | **OBSOLETE** | `BlockchainProtectionPolicy` deleted. Account pins use VolumeBroker ref-counted pins |
| P0 #4 `tx_history` pruner | **DONE** | `pruneTransactionHistory(belowHeight:keepAddress:)` runs in GC loop |
| P0 #4a pin/announce coupling | **OBSOLETE** | Old protection policy gone. Pin lifecycle is now explicit: owner tags + ref counts + evictUnpinned |
| P1 #5 double child-block writes | **DONE** | Shared DiskBroker means all chains write to one store. No cross-broker copies needed |
| P1 #6 mempool fetcherCache | **DONE** | Incremental cache in NodeMempool |
| P1 #7 serial pin announces | **DONE** | Parallelized |
| P1 #8 resolveLatestMinerNonce | **DONE** | Cached with reorg invalidation |
| P1 #11 backfillBlockIndex | **DONE** | Skips when populated |
| P1 #12 finalizeSyncResult | STILL VALID | Cache txDict during sync |
| P1 #13 recoverFromCAS | **FIXED** | Uses `skipValidation: true` — CAS data is trusted (PoW already verified at accept time) |
| P1 #14 per-chain maps | **DONE** | `destroyChainNetwork` cleans up all maps |
| P1 #15 NodeMetrics keys | **DONE** | Cleaned up in destroyChainNetwork |
| P1 #16 stmtCache | STILL VALID | Bounded by distinct SQL strings (finite) |
| P2 #9 watchdog submit timeout | **DONE** | Inner timeout with `raceSubmitWithTimeout` |
| P2 #10 inFlightBlockCIDs cap | STILL VALID | Low-risk |
| P2 #17 difficultyHashPrefixBytes | STILL VALID | Allocation per iteration, not a leak |
| S1 Mempool admission DoS | **DONE** | Per-sender nonce-gap cap, fee floor, RBF, fee-priority eviction |
| S2 PoW-short-circuit ordering | **DONE** | Short-circuit before validate |
| S3 Reorg vs retentionDepth | **DONE** | Fail-loud on deep reorg |
| S4 Shared-CAS isolation | **REDESIGNED** | Shared DiskBroker is intentional. Pin owners provide per-chain isolation. No eviction quota needed — unpinned data is evictable regardless of chain |
| S5 PinAnnounce verification | **DONE** | Tally demotion on fetch-failure |
| S6 Block timestamp validation | **DONE** | MTP + future drift bounds in Lattice core |
| S7 SQLite WAL/VACUUM | **DONE** | Checkpoint + incremental vacuum in maintenance loop |
| S8 childBlocks serialization | STILL VALID | Needs golden-block round-trip test |
| S9 Anchor-peer demotion | **DONE** | Score-based demotion |
| S10 maybePersist cadence | **DONE** | Measured and tuned |
| I1 CASBridge | **DELETED** | Ivy rewritten as stateless transport |
| I2 Volume fetching | **NOW USED** | VolumeBroker provides Volume-level fetch/store |
| I3 mining challenge | STILL VALID | 0 call sites |
| I4 offerDirectConnect | STILL VALID | 0 call sites |
| I5 PEX | STILL VALID | 0 call sites |
| I6 Zone sync / replication | STILL VALID | 0 call sites |
| I7 LocalDiscovery default | **DONE** | Default flipped to `false` |
| I8 STUN | STILL VALID (conditional) | |
| I9 PeerHealthMonitor | STILL VALID (optional) | |
| I10 SendBudget | **DELETED** | Removed from Ivy |
| I11 pendingRequests | STILL VALID | Unbounded continuations |
| L1-L7 | See original entries below | L2 confirmed keep; L5/L7 narrowed |

**Net delta:** 25 of 40+ items resolved. The VolumeBroker migration eliminated the entire Acorn/BlockchainProtectionPolicy/UnionProtectionPolicy surface. Remaining open items are mostly Ivy cleanup (I3-I6, I11) and the serialization round-trip test (S8).

### Audit additions — items this doc was missing

The first pass was framed as "what prevents mining from running indefinitely" (liveness + growth). A chain-node audit should also cover Byzantine / soundness. Items added in this pass:

| Added | Item | Type |
| --- | --- | --- |
| P0 #4a | Pin-announce / pin-retention coupling invariant | Soundness |
| S1 | Mempool admission DoS rules (nonce-gap, fee floor, RBF) | DoS |
| S2 | PoW verify caching on gossip-recv short-circuit | DoS |
| S3 | Reorg depth vs `retentionDepth` (turns storage knob into safety knob) | Consensus |
| S4 | Shared-CAS cross-chain isolation (post-`d4e746a`) | DoS |
| S5 | PinAnnounce verification + reputation demotion | Soundness |
| S6 | Block timestamp validation bounds | Consensus |
| S7 | SQLite WAL / VACUUM hygiene | Operational |
| S8 | `childBlocks` serialization as PoW preimage | Consensus-fragile |
| S9 | Anchor-peer demotion path | Byzantine |
| S10 | `maybePersist` cadence needs measurement, not guessing | Operational |

Severity re-rates:

- **P2 #9 is the real #1** of the quick-wins list. It's the only item that causes a miner freeze in bounded time; everything else is months-to-years of growth. The naïve "cancel and respawn" fix re-proposed in the original doc is the exact anti-pattern the code comment already rejects — see the updated fix block at P2 #9 for the safer inner-timeout construction.
- **P1 #14 is not a tail-item.** `deployChildChain` RPC (commit `8a9a5ab`, handler at `RPCServer.swift:582`) makes dynamic child-chain subscription a first-class feature. Lifecycle leaks there are actively exploitable if deploy is exposed to untrusted callers.
- **P1 #8 needs reorg invalidation, not just tip-match invalidation.** See updated fix block.
- **E4 settleWithCreditors → background** needs replay-protection audit first. See updated fix block.

---

## P0 — Unbounded resource growth that eventually freezes the miner

### 1. `diagLog` grows `/tmp/lattice-diag.log` without limit (and does an open/seek/write/close every call)

`Sources/LatticeNode/Chain/LatticeNode+Blocks.swift:18-29`

- Written on every `processBlockHeader` enter/exit (`LatticeNode+Blocks.swift:178,:181`), every `submitMinedBlock` enter/exit (`LatticeNode+Mining.swift:85,:93`), every `IvyFetcher` outcome (`IvyFetcher.swift:63,70,74,80,85`), and every `CompositeFetcher` fallback (`CompositeFetcher.swift:25,29`).
- No size cap, no rotation, no truncation. On a long-running miner producing hundreds of blocks/day plus gossip fetches, this file grows linearly forever until `/tmp` fills and writes start silently failing (but the syscalls still happen).
- Each call opens a new `FileHandle`, `seekToEnd`s, writes, closes — ~5 syscalls per fetch. Under churn this is a real throughput tax.

**Fix:** gate behind an env flag so it's off by default; when on, rotate at a size cap (e.g. 64 MiB, keep one `.old`). Keep a single long-lived handle, not open/close per line.

### 2. `BlockchainProtectionPolicy.recentBlockExpiry` is never pruned

`Sources/LatticeNode/Network/BlockchainProtectionPolicy.swift:23,110`

- `addRecentBlock` is called from `setChainTip` on every accepted block.
- `pruneExpiredRecentBlocks()` exists but has zero callers (verified by grep). Entries accumulate one-per-block forever and each entry is consulted on every eviction check via `isProtected`.

**Fix:** call `pruneExpiredRecentBlocks()` from the `gcTask` loop in `BackgroundLoops.swift:63-78`.

### 3. `BlockchainProtectionPolicy.accountCIDs` grows unboundedly

`Sources/LatticeNode/Network/BlockchainProtectionPolicy.swift:13,65-67`; populated via `pinAccountData` (`LatticeNode+Blocks.swift:925-953`) on every block that touches our address (every coinbase does).

- For a miner, this grows by ~3 entries per block (block hash + txCID + bodyCID). After a year of block production, this is millions of entries permanently in memory and checked on every eviction.

**Fix:** bound to an LRU with a large cap (100k+), or back it by `tx_history` plus a small hot-set, since startup already rebuilds pins from `tx_history`. Losing old account pins is fine because the network will have other pinners.

**Soundness caveat — pin/announce coupling.** `pinAccountData` calls `publishPinAnnounce` with `expiry = now + 86400` (24h). If we LRU-evict the pin before the announce expires, we are advertising data we no longer serve — peers route fetches to us and timeout, which Ivy/Tally may read as poor reputation, triggering demotion. Any LRU fix for this item **must** either (a) retract announces on eviction, (b) gate eviction on `now > announceExpiry`, or (c) shorten announce TTL to match the eviction window. Today the eviction policy does not know about announces at all. See new P0 #4a below.

### 4. `StateStore.tx_history` table grows forever on disk

`Sources/LatticeNode/Storage/StateStore.swift:44-53,155-162`

- Indexed by `(address, height DESC)`; no pruner anywhere in the codebase.
- `pruneDiffs` in `startGarbageCollectionLoop` only prunes `state_diffs`, never `tx_history`.

**Fix:** add `pruneTransactionHistory(belowHeight:)` for addresses that aren't this node's own, and call it from the GC loop. Keep full history for `nodeAddress` since pin rebuild depends on it.

**Design smell:** ask why a headless miner stores other addresses' tx history at all. If it's only there to back RPC `getTransactionsByAddress`, gate the table behind a config flag (`enableAddressIndex: Bool`). Pure miners don't need it; RPC-serving nodes do.

### 4a. PinAnnounce / pin-retention coupling invariant (NEW — soundness P0)

`LatticeNode+Blocks.swift:950-952` publishes `pinAnnounce(rootCID, selector: "/", expiry: now+86400)` for every CID we pin via `pinAccountData`. The eviction policy (`BlockchainProtectionPolicy`, `recentBlockExpiry`, any LRU we add for #3) operates **independently** of announce lifetimes. Three failure modes:

1. **Eviction-before-expiry:** an LRU cap on `accountCIDs` (the proposed fix to P0 #3) evicts a pinned CID while a 24h announce is still live. Peers route requests to us; we 404; Ivy reputation drops; we get throttled by `SendBudget` upstream.
2. **Restart-before-reannounce:** `pinReannounceTask` (started in `LatticeNode.start()`) is the only path that refreshes announces. If it has a bug or is paused (e.g. during sync), announces expire while pins remain — we hold bytes nobody asks us for, and we drop off the provider list silently.
3. **Crash-during-pin:** `pinAccountBatch` then `publishPinAnnounce` is two operations with no atomicity. A crash between leaves us pinning bytes we never announced (wasted disk) or announcing bytes we crashed before pinning (lying to the network).

**Fix:** make pin retention an explicit function of (a) recency, (b) announce expiry. The simplest version: `isProtected(cid)` returns true iff `cid` has any live announce (`announceExpiry[cid] > now`). Eviction then "just works" — anything no longer announced is fair game. `pinReannounceTask` becomes the single source of pin lifetime.

This is a soundness item, not a growth item; placing here in P0 because it interacts with the LRU fix proposed for P0 #3 and could turn that fix into a regression if not designed together.

---

## P1 — Per-block work that scales with something

### 5. Child blocks are written to CAS twice per nexus block — **PARTIALLY FIXED**

- `submitMinedBlock` → `storeBlockRecursively(block, network: nexus)` (`LatticeNode+Mining.swift:76`). Because the nexus block's Merkle tree includes the children (via `childBlocks`), `storeRecursively` walks and stores them into the nexus CAS.
- `processBlockAndRecoverReorg` → `applyChildBlockStates` → `storeBlockRecursively(childBlock, network: childNet)` (`LatticeNode+Blocks.swift:792`).
- Fixed: commits `d4e746a` (shared CAS) and `0d33338` (short-circuit storeRecursively) made `storeBlockRecursively` use `BufferedStorer(skipSet: network.snapshotLastStoredCIDs())`, so repeat writes of the same CID are deduped at the storer layer. This kills the "doubled disk writes" part.
- Still open: the second pass still walks the child's Merkle tree and still performs `registerVolume` on the child network. Walk cost is O(child tx count) per block, not zero.

**Remaining fix:** narrow the second pass to just `registerVolume(rootCID: childCID, childCIDs: …)` on the child network — avoid the trie walk entirely. The eviction policy only needs to know the child's subtree; it doesn't need the bytes re-touched.

### 6. `buildMempoolAwareFetcher` re-serializes the entire mempool on every block apply

`Sources/LatticeNode/Chain/LatticeNode+Blocks.swift:719-723` → `NodeMempool.fetcherCache()` (`NodeMempool.swift:245-258`)

- Walks all `byCID.values`, calls `tx.toData()` and `body.toData()` per entry, returns a new `[String: Data]` of up to `2 × maxSize` entries. `maxSize` default is 10_000.
- Called from `applyAcceptedBlock` (every accepted block) and from `recoverOrphanedTransactions` (every reorg).

**Fix:** maintain the cache incrementally in `NodeMempool.insertEntry` / `removeEntry`, or hand out an actor-scoped view that the `MempoolAwareFetcher` dereferences lazily.

### 7. `pinAccountData` publishes pin announces serially

`Sources/LatticeNode/Chain/LatticeNode+Blocks.swift:950-952`

- For a block with N txs involving our address, N sequential `await ivy.publishPinAnnounce`. Runs inside `applyAcceptedBlock` which is on the miner-submit path.

**Fix:** fire these via `withTaskGroup` concurrently, or push them onto a background queue that runs outside the block-submit critical section.

### 8. `resolveLatestMinerNonce` re-resolves the frontier every miner iteration

`Sources/LatticeNode/Mining/MinerLoop.swift:413-428`

- Called from `buildCoinbaseTransaction` every iteration (`MinerLoop.swift:450`). Does `previousBlock.frontier.resolve(fetcher: fetcher).node` then resolves the nonce key.
- The `cachedTipBlock` caches the block but, unless the `BlockBuilder` happens to leave `frontier.node` populated, each hit still re-walks the radix trie to read one account nonce.

**Fix:** cache the miner's last-seen nonce alongside `cachedTipBlock`. When the tip hash matches, skip the frontier resolve entirely — we're the only writer of our nonce, so `(cached nonce) + (number of miner-signed txs in the previous iteration's block)` is authoritative.

**Reorg hazard — must invalidate on every reorg event.** The proposed formula assumes the previous iteration's block landed on the main chain. If it was orphaned by a reorg and the winning block had a *different* set of miner-signed txs (or none), the cached nonce is ahead of the real state and every subsequent coinbase fails `nonceGap` until restart. This is exactly the failure class that commits `c7d006c` and `9db1033` already fought through once. The cache must be keyed on `(tipCID, nonce)` *and* invalidated whenever `processBlockAndRecoverReorg` reports a reorg outcome, not just when the tip CID changes (the new tip of a reorg has a different CID, but the cached value was derived from a no-longer-canonical ancestor).

---

## P2 — Stall-failure modes not covered by the current watchdog

### 9. Watchdog never fires during a stuck `submitMinedBlock`

`Sources/LatticeNode/Mining/MinerLoop.swift:106-127`

- `isSubmitting` guards restart. If `lattice.processBlockHeader` inside `processBlockAndRecoverReorg` hangs (e.g. a pinner fetch wedges an actor), the submit window is open forever and the miner never recovers — by design, to avoid concurrent resolves.
- There's no upper bound on `isSubmitting` duration.

**Fix — naïve version is dangerous.** The obvious "flip `isSubmitting=false`, cancel task, respawn" is the exact anti-pattern the code comment at `MinerLoop.swift:35-41` already calls out: cancelling a Swift `Task` does not interrupt an in-flight actor await, so spawning a new mineLoop layers a second blocked task on top of the first and doubles memory pressure while the original deadlock continues.

Safer construction:

1. **Inner timeout, not outer cancel.** Wrap the `lattice.processBlockHeader` call inside `submitMinedBlock` with `Task.withThrowingTaskGroup` + a 20-minute `Task.sleep` racer. If the sleep wins, we record a critical-stall event and throw — the `defer` in `submitMinedBlock` releases `isSubmitting` cleanly, and the outer MinerLoop resumes on its own.
2. **Persist chain state before release.** Between the timeout firing and releasing `isSubmitting`, call `persistChainState`. Otherwise SQLite (which flushed inside `storeBlockRecursively`) is ahead of `ChainState`, and next boot does a needless `recoverFromCAS` walk — costly and logs a false-positive "ungraceful shutdown" warning.
3. **Accept partial commit as a normal state.** `recoverFromCAS` already handles SQLite-ahead-of-chain-state; the safety net is there. The fix just has to make *using* it cheap (above).

Losing a single block submit is cheaper than a silent hang, but layering concurrent blocked tasks is worse than both.

### 10. `inFlightBlockCIDs` has no size cap

`Sources/LatticeNode/Chain/LatticeNode+Blocks.swift:153-155`; declared at `LatticeNode.swift:31`

- Safe under Swift's `defer` semantics for normal exits. But the set has no size cap, so any future codepath that inserts without a symmetric remove would grow it forever. Low-risk today but worth capping defensively.

---

## P1 (cont.) — Startup costs that scale with chain length

### 11. `backfillBlockIndex()` re-walks the entire chain on every start

`Sources/LatticeNode/Chain/LatticeNode+Persistence.swift:139-160`

- Loops `for i in 0...height` calling `chainState.getMainChainBlockHash(atIndex: i)` once per index. Called from `LatticeNode.start()` before mining resumes.
- Growth: O(chain-height) per boot. At ~300 blocks/hour that's ~2.6M loop iterations/year — seconds-to-minutes of wall clock before the miner comes online.

**Fix:** skip the scan when `StateStore.blockIndex` is already populated up to `height` (compare counts). Alternatively, store a `lastBackfilledIndex` watermark and resume from there.

### 12. `finalizeSyncResult` re-resolves every synced block's transaction trie

`Sources/LatticeNode/Chain/LatticeNode+Sync.swift:197-240` (specifically 210-222)

- After sync, replays all synced blocks and calls `block.transactions.resolveRecursive(fetcher:)` per block to drive the StateStore rebuild from accountActions. The comment at `:209` explicitly says this is "sparse replay — no full state pull".
- Growth: O(`retentionDepth`) ≈ 1000 resolveRecursive calls after a long outage.

Note since initial audit: this is no longer gratuitous validation — it's required for sparse state rebuild. The cost is real but the work has a purpose now.

**Fix:** cache the resolved txDict during the sync download (which already fetches block data) and reuse it here instead of re-issuing a round trip.

### 13. `recoverFromCAS()` re-walks and re-validates the gap

`Sources/LatticeNode/Chain/LatticeNode+Persistence.swift:73-132` (89-113)

- On ungraceful shutdown, walks backwards from SQLite tip to ChainState tip, re-validating every block in between. PoW re-check + Block decode per gap-block.
- Growth: O(uptime-since-last-persist) ≈ hundreds of blocks for hour-long gaps.

**Fix:** `maybePersist` already flushes periodically — tighten its cadence on mining-active nodes (the gap you're recovering from is exactly the window since last persist).

---

## P1 (cont.) — Lifecycle leaks that grow with churned child chains

If a node ever unsubscribes from a child chain (testnets, deploy cycles, chain reorgs into a new spec), the following actor-level maps on `LatticeNode` are **inserted into but never removed from**:

### 14. Per-chain dictionaries never shrink on unsubscribe

`Sources/LatticeNode/Chain/LatticeNode.swift` — all of these hold one entry per unique directory ever registered:

- `networks` (line 18) — `ChainNetwork` holding Ivy + mempool + fetcher
- `stateStores` (line 43) — SQLite connection + buffers
- `persisters` (line 20) — JSON encoder state
- `tipCaches` (line 44), `frontierCaches` (line 45)
- `feeEstimators` (line 39) — each holds a 100-entry rolling window
- `unionProtection.policies` (`UnionProtectionPolicy.swift:9`) — holds per-chain `accountCIDs` + `recentBlockExpiry` (both already P0 growth sources)

Today `stopMining(directory:)` only removes from `miners` and flips the config subscription; none of the above maps are touched.

**Fix:** add a `destroyChainNetwork(directory:)` that removes from all seven maps + closes the `StateStore` connection. Call from `stopMining` when `directory != nexus`. Low urgency for steady-state miners, but required for any multi-chain lifecycle.

### 15. `NodeMetrics` keys grow with chain count

`Sources/LatticeNode/Health/Metrics.swift:6-9` populated via `RPCServer.swift:1123-1125`.

- `counters` / `gauges` / `histogramSums` / `histogramCounts` dicts keyed by strings like `lattice_chain_height{chain="..."}`. Every `/metrics` scrape loops the whole set.
- Growth: per unique subscribed chain, per metric type. Also coupled to the lifecycle leak in #14 — even unsubscribed chains keep their metric keys.

**Fix:** drop metric keys in the same `destroyChainNetwork` hook. If not worth the plumbing, disable the metrics endpoint by default (see extraneous list below).

### 16. `SQLiteDatabase.stmtCache` has no cap

`Sources/LatticeNode/Storage/SQLiteDatabase.swift:12`

- Caches prepared statements keyed by SQL string. Practical bound is "number of distinct query strings" which is finite, but nothing enforces it — any future query built via string interpolation (e.g., per-chain table names) would grow unboundedly.

**Fix:** LRU cap at a modest size (256), or audit that all SQL strings are compile-time constants and add a comment locking that invariant in.

---

## P2 (cont.) — Minor / defensive

### 17. `MinerLoop.difficultyHashPrefixBytes()` allocates per iteration

`Sources/LatticeNode/Mining/MinerLoop.swift:340-366`

- Allocates a new `ContiguousArray<UInt8>` (reserve 512) once per mining iteration. Not a leak — allocator pressure only.

**Fix:** hoist the buffer to the actor and reuse. Nice-to-have, not urgent.

---

## Extraneous surface — code we likely don't need

All items below were individually verified via grep; several claims from the initial audit pass (Tally unused, AcornMemoryWorker unused, `discoveryOnly` dead, CompositeFetcher single-fallback) turned out to be wrong and are **not** in this list.

### E1. `[TIMING]` print statements on the block path

`MinerLoop.swift`, `LatticeNode+Blocks.swift`, `StateStore.swift` — 13 call sites producing stdout spam on every block. Same diagnostic role as `diagLog` (P0 #1) but going to stdout instead of `/tmp`. Remove together with the diagLog fix.

### E2. `DiagCommand` and `IdentityCommand`

- `Sources/LatticeNode/CLI/DiagCommand.swift` (74 lines) — genesis-hash diagnostics, dev-only.
- `Sources/LatticeNode/CLI/IdentityCommand.swift` (27 lines) — `publicKeyOnly` flag has both branches print the same thing; fully subsumed by `KeysCommand`.

Both safe to delete; ~100 LOC.

### E3. `MultiNodeClient` + `ClusterCommand`

- `Sources/LatticeNode/Testing/MultiNodeClient.swift` (323 lines) — only caller is `ClusterCommand`.
- `Sources/LatticeNode/CLI/ClusterCommand.swift` — multi-node orchestration for local dev clusters.

If you're shipping a single-miner daemon, this is ~480 LOC of dev-only scaffolding that shouldn't be in the production binary. Move to a separate `tools/` target or delete.

### E4. `settleWithCreditors` on the block-submit path

`Sources/LatticeNode/Chain/LatticeNode+Mining.swift:107-125` — walks all Ivy ledger lines per block; submits settlements for any peer we owe. This runs **inside the submit critical section**. For a standalone miner with no active creditor relationships the loop is a no-op but still pays the `allLines` traversal per block.

**Fix:** short-circuit when `allLines.isEmpty`, or fork the settlement publish to a background task so it doesn't gate `processBlockAndRecoverReorg`. Don't delete outright — Ivy settlement is a real feature.

**Orphan-block replay risk for the background-task variant.** If we fork settlement publish and the block is subsequently orphaned, we've credited ourselves work for a block that isn't on the canonical chain. Two questions to answer before shipping the background variant: (a) does `Ivy.submitSettlement` replay-protect `(peer, nonce, blockHash)` tuples so a re-settlement after the next real block is idempotent? (b) do creditors verify the block hash is on the canonical chain before crediting, or just that it meets difficulty? If (a) is no or (b) is "just difficulty," the fix must wait for `accepted == true` from `processBlockAndRecoverReorg` before kicking off settlement — i.e., still inside the submit path but *after* the critical section, not in parallel with it.

### E5. `HealthCheck` writes `<dataDir>/health` every 10s

`Sources/LatticeNode/Health/HealthCheck.swift` (57 lines) — only consumed by external probes (k8s / shell scripts). If you don't have one, it's just syscalls on a timer.

RPC already serves `GET /health` (`RPCServer.swift:125,1091`), which is strictly better. Retire the file-writing loop; keep the RPC handler.

### E6. Deposit / Receipt RPC endpoints

`Sources/LatticeNode/RPC/RPCServer.swift:120-122,1017-1087` → `listDeposits` in `LatticeNode+State.swift:116`. These back cross-chain settlement features. If you're not using them, disable by default — every endpoint is a retained path into state.

### E7. Stale `import Tally` in files that don't call Tally APIs

Tally IS used (by `SeedCrawler` for peer reputation). But `LatticeNode+Blocks.swift`, `LatticeNode+Mining.swift`, `LatticeNode.swift`, `ChainNetwork.swift`, `ChainAnnounceData.swift`, `IvyFetcher.swift` all import it without calling it. Cosmetic only, but kills a few `swiftc` dependency edges.

### E8. `SyncStrategy.headersFirst` is unreachable at runtime

`Sources/LatticeNode/Chain/ChainSyncer.swift:9` defines the enum case; `LatticeNode+Sync.swift:41` implements the handler (`performHeadersFirstSync` ~80 LOC). `LatticeNodeConfig.swift:37` defaults `syncStrategy` to `.snapshot`, and a grep across all of `lattice-*` sibling repos finds zero call sites that pass `.headersFirst`. CLI flag to switch it doesn't exist either.

**Fix:** delete the enum case and the handler. ~80 LOC.

### E9. `Wallet.swift` builders are production-unused

`Sources/LatticeNode/Transaction/Wallet.swift:35` (`buildTransfer`) and `:74` (`buildActionTransaction`). Only caller is `Tests/LatticeNodeTests/ModuleTests.swift:16`. `SendCommand` has its own builder inline. Safe to move the whole file to `Tests/` or delete entirely.

### E10. `DNSSeeds.runDig()` subprocess fallback

`Sources/LatticeNode/Network/DNSSeeds.swift:99-139`. 41 LOC that shell out to `/usr/bin/dig` to get TXT records. The A-record POSIX `getaddrinfo` path above it (52-87) already handles resolution. Delete the subprocess path — fragile, slow, unportable.

### E11. CLI subcommands shipped in the daemon binary

All registered in `LatticeCLI.swift:12-16` (verified):

- `InitCommand` (~294 LOC) — generates Swift project scaffolding. Not something a running miner needs.
- `KeysCommand` (~90 LOC) — generate/show/address key utilities. Belongs in a separate `lattice-keygen` binary.
- `QueryCommand` (~80 LOC) — offline chain inspection; RPC endpoints cover it when the daemon is running, and when it's not, you're reading SQLite directly anyway.
- `DevnetCommand` (~128 LOC) — single-node devnet bringup. Keep if you run devnets locally; move to a separate dev-tools binary otherwise.

Combined, a separate `lattice-tools` binary could hold all of these (+ `DiagCommand`, `IdentityCommand`, `ClusterCommand`) and cut ~1,300 LOC from the daemon binary. Every byte you don't ship is a byte that can't crash or leak.

---

## Lattice core library (`/Users/jbao/swiftsrc/lattice`) — cut candidates

### L1. `ChainSpec.bitcoin` / `.ethereum` / `.development` presets

`/Users/jbao/swiftsrc/lattice/Sources/Lattice/Block/ChainSpec.swift:231-262`. Zero production consumers across all `lattice-*` repos — only referenced in the library's own tests and README/docs. Move to a `LatticeTestSupport` target (or into the test file directly). ~30 LOC, plus it stops library users from accidentally starting a chain with a preset.

### L2. ~~`BlockBuilder` genesis/block convenience constructors~~ — **WRONG, do not cut**

Original claim said `BlockBuilder` was dev-only. Re-verification finds extensive production usage: `MinerLoop.swift:223,:238,:562` (every mined block), `NexusGenesis.swift:93`, `RPCServer.swift:582` (chain deploy RPC), `LatticeNode.swift:119`, and `InitCommand.swift` (×5). This is the canonical block/genesis builder. **Keep as-is.**

### L3. `ChainSpec.validateDifficulty/validateTransactionCount/validateStateGrowth`

`/Users/jbao/swiftsrc/lattice/Sources/Lattice/Block/ChainSpec.swift:195-212`. Zero production callers — block validation inlines these checks. Only referenced by `Tests/LatticeTests/ChainSpecTests.swift`. ~15 LOC dead.

### L4. `Block` genesis-only helpers

`Sources/Lattice/Block.swift:62-102` (`getGenesisSize`, `getTotalDeposited`, `getTotalWithdrawn`, `getTotalFees`). Only called during genesis construction and state-delta validation — both infrequent paths. ~40 LOC. Can either stay or move to a Genesis-only utility file.

### L5. `ChainSpec` aggregate reward statistics

`/Users/jbao/swiftsrc/lattice/Sources/Lattice/Block/ChainSpec.swift:54-125`. Keep `rewardAtBlock` (MinerLoop:432) and `premineAmount` (RPCServer:196,560 + NexusGenesis:71). The cut candidates are the three that have **only test callers**: `totalRewards` (63), `totalHalvings` (121), `rewardRange` (214). ~40 LOC removable. (Previous claim lumped `premineAmount` in with these — it's actually production.)

### L6. `CollectionConcurrencyKit` concurrent validation

`Block+Validate.swift:165,173,300` and `TransactionBody.swift:71` use `concurrentMap` for per-tx validation. For a single-operator miner with bounded tx batches, the task-switch overhead often exceeds the serialized cost. Benchmark, then consider swapping to `.map`. Removes an external dependency.

### L7. `Block.version` field

`Block.swift:18` — `version: UInt16` is propagated (BlockBuilder `:22`, MinerLoop `:625`) and exposed via RPC (`RPCServer.swift:260`), but is **never consulted by consensus** (`Block+Validate.swift` doesn't read it). A display-only field on the wire. Safe to delete only at a hard-fork boundary since removal changes wire format. **Do not remove** for now; flag for the next consensus break.

### NOT a cut: JXKit / transaction-action filters

Agent audit flagged these as dead. Verified they are a real feature: the `lattice-app` Foundry UI (`src/pages/Foundry.tsx:676,682`) lets chain creators author JS filters, which flow through RPC (`RPCServer.swift:554-555`) into `ChainSpec`, and `TransactionBody.verifyFilters` checks them on every block. The `.isEmpty` short-circuit means filterless chains pay zero JS cost. Keep.

### NOT a cut: `ReceiptState` / `SettleState`

Cross-chain withdrawal settlement — consensus-critical. Keep.

---

## Ivy (`/Users/jbao/swiftsrc/Ivy`) — cut candidates

For each item, "0 call sites" means zero references across the entire `/Users/jbao/swiftsrc/lattice-node/Sources/` tree.

### I1. `CASBridge` — 0 call sites

`Sources/Ivy/CASBridge.swift` (121 LOC) + `Ivy.swift:1137`. Wraps a local CAS to expose it via Ivy protocol; feature for federated setups. Safe to delete. **~126 LOC**

### I2. Volume-aware fetching — 0 call sites

`Ivy.swift:1599-1770` (`publishVolume`, `fetchVolume`, `volumeRoot`, `providers`) + handlers at `:1507,1523,1538` + message types `.getVolume`, `.announceVolume`, `.pushVolume` in `Message.swift:43-45`. `IvyFetcher` uses single-CID fetches throughout — never batches. **~300 LOC.** Wire-format change: removes three message types.

### I3. `issueMiningChallenge` / `handleMiningSettlement` — 0 call sites

`Ivy.swift:1475,1495` + `.miningChallenge` / `.miningChallengeSolution` message types. A PoW-challenge-for-settlement scheme; lattice-node uses `submitSettlement` directly with a pre-computed block hash. ~95 LOC.

### I4. `offerDirectConnect` — 0 call sites

`Ivy.swift:1425,640` + `.directOffer` message type. Paid direct-connect offer from pinners. Not wired. ~25 LOC.

### I5. Peer Exchange (PEX)

`Ivy.swift:1165-1224` (`startPEX`, `runPEXRound`, `handlePEXRequest`, `handlePEXResponse`) + `.pexRequest`/`.pexResponse` messages + config knobs `enablePEX`, `pexInterval`, `pexMaxPeers`. Zero call sites — lattice-node doesn't drive PEX. ~130 LOC. Note: if bootstrap peers are known and stable, PEX is dead weight; if you ever want a mesh, keep it.

### I6. Zone Sync + Replication loops

`Ivy.swift:914-1003` — `startZoneSync` / `startReplication` run periodic background tasks that query peer CAS inventory and proactively replicate local content. For a single-operator miner that stores locally and announces via pin-announce, these tasks are background noise that burns bandwidth. ~150 LOC + 5 config knobs.

### I7. `LocalDiscovery` (mDNS) — default-on but server-useless

`Sources/Ivy/LocalDiscovery.swift` (61 LOC). `LatticeNodeConfig.enableLocalDiscovery` defaults to `true` (verified). For a headless colo/cloud miner with no local peers, mDNS advertises into the void and burns a goroutine.

**Fix:** flip the default to `false` in `LatticeNodeConfig.swift:30`. Or delete entirely if you know your deployment model. (Low risk, ~75 LOC on full removal.)

### I8. STUN client — conditional cut

`Sources/Ivy/STUNClient.swift` (155 LOC). Public-IP discovery via Google/Cloudflare STUN. If your miner runs with a known static public IP passed in config, this is unused. Verify before removing.

### I9. `PeerHealthMonitor` — optional

`Sources/Ivy/PeerHealthMonitor.swift` (128 LOC). Periodic pings + auto-disconnect on silence. Useful in adversarial mesh networks; overhead for a trusted-bootstrap single-operator setup.

### I10. `SendBudget` reputation-weighted bandwidth

`Sources/Ivy/SendBudget.swift` (94 LOC). Throttles outbound to peers based on reputation/debt. A single-operator miner that only talks to known bootstrap peers can use a fixed rate limit at the socket level.

### I11. Unbounded `pendingRequests` / `pendingVolumeRequests` in Ivy

`Sources/Ivy/Ivy.swift:23,53`. Continuation-keyed by CID. If a timeout path misses cleanup (or a peer goes silent mid-request), entries accumulate forever.

**Fix:** replace with a `BoundedDictionary` (Ivy already has the primitive) capped at 10k, or audit the timeout cleanup path. This is the analog to lattice-node's own P0 growth list but lives inside Ivy — same "runs for weeks and slowly leaks" risk.

### Architectural win: make `submitSettlement` fully async

Currently `LatticeNode+Mining.swift:111-125` (`settleWithCreditors`) loops synchronously inside `submitMinedBlock`. Ivy's `submitSettlement` already queues messages non-blocking; the synchronous wait is imposed by the caller. Lifting the loop to a background task removes an entire RTT from block-submit critical section.

---

## SOTA techniques worth porting

Research summary from modern chains (Geth, reth, Cosmos, Bitcoin Core, libp2p). Full notes at the end of this doc; top 5 picks ranked for a small single-operator IPFS-backed chain:

1. **Bounded gossip seen-set + per-peer INV Bloom.** GossipSub v1.1 uses a 2-minute windowed LRU; Bitcoin Core uses `CRollingBloomFilter` per peer. Single biggest "runs for a month and OOMs" win. Belongs in `ChainNetwork` / sync layer.
2. **CAS mark-and-sweep GC rooted at `{finalized header, last N tips, mempool tx CIDs}`.** IPFS pinning model applied to Ivy/Acorn. Without it, CAS grows monotonically regardless of `state_diffs` pruning. Biggest on-disk win.
3. **Mempool hard caps** — Bitcoin model: `maxBytes`, `maxPerSender`, `expiryHours`. Reth adds `max_account_slots`. Prevents one spammer OOMing the mempool before you have a fee market. Belongs in `NodeMempool`.
4. **Block body archive split + depth-based body pruning** (EIP-4444 / Solana ledger-archive flavor). Keep headers forever in SQLite; move bodies older than `finalityDepth + margin` to a separate append-only file or drop entirely (peers can re-serve). Cuts steady-state disk to headers + recent bodies + live state.
5. **Offline pruner CLI subcommand** (Geth's `snapshot prune-state` model). Single-operator + scheduled restarts makes online pruning overkill. Run during planned downtime, bounds disk between runs.

**Explicitly NOT** worth porting yet: verkle trees, weak statelessness, Portal Network history sharding, checkpoint sync (revisit the day you add a second node), EIP-7736 state expiry.

Cosmos's three-knob pruning config (`keep-recent`, `keep-every`, `interval`) is a clean API to steal for exposing our existing `state_diffs` pruner to operators.

---

## Safety / soundness gaps not in the growth list

The original audit was framed as "what prevents mining from running indefinitely" — a liveness/resource-growth lens. A blockchain-node audit should also cover the Byzantine / soundness surface. These are the gaps:

### S1. Mempool admission DoS

`NodeMempool` is flagged in SOTA #3 for lacking hard caps. Beyond bytes/count, the submitter-facing admission rules are the DoS surface:

- **Per-sender nonce-gap cap.** A peer submitting `nonce = confirmedNonce + 100_000` squats 100_000 logical mempool slots. Bitcoin uses a 25-descendant ancestor limit; Ethereum uses `max_account_slots`. Without either, one sender can pin-evict legit mempool traffic.
- **Minimum fee floor relative to current mempool fullness.** Geth scales the min-accept fee with mempool pressure. Flat floors are gamed the moment the mempool is ≥90% full.
- **Replacement (RBF) rules.** Re-submitting the same nonce with higher fee — allowed, with what bump threshold? Abuse: a sender churns (nonce, fee) pairs to force repeated validation cost without ever committing.
- **Eviction policy on overflow.** FIFO vs fee-priority vs random? Of these, only fee-priority is DoS-resistant; FIFO lets a spam burst flush genuine txs.

Commit `cf23b13` ("Sync mempool confirmedNonce from state before admitting txs") hints this has been partially touched but not systematized. Audit `NodeMempool.swift` for each of the four rules above and document which are enforced.

### S2. PoW verification caching on gossip-recv

`675a801` adds "short-circuit gossip-recv for already-known blocks." Question the audit never asked: does the short-circuit happen *before* or *after* `validateBlockHash(blockHashHex, difficulty)`? If after, a spam sender can flood us with known-CID blocks and force repeated PoW verify on the same hash. If before, check that the "known" set (which is presumably bounded) can't be evicted under adversarial pressure to re-open the check. Read `ChainNetwork.swift` gossip path; the cost should be `O(1)` per duplicate gossip, not `O(UInt256 parse + compare)`.

### S3. Reorg cost not characterized against `retentionDepth`

`state_diffs` pruning at `retentionDepth` (`BackgroundLoops.swift:73`) sets the ceiling on how deep a reorg can be applied — deeper reorgs are unrecoverable because the rewind table has been truncated. This turns `retentionDepth` from a storage-knob into a consensus-safety parameter: pick too low and an honest reorg past that depth is treated as a chain split. Needed:

- State the honest-reorg budget explicitly (e.g. "`retentionDepth` ≥ finality window + slack").
- Fail-loud when a peer-tip reorg exceeds `retentionDepth` rather than silently refusing the new chain.
- Separately: what is the *runtime cost* of a full `retentionDepth`-deep rewind? If it's >`stallThreshold` the watchdog (P2 #9) could fire mid-rewind and make things worse.

### S4. Shared-CAS cross-chain isolation (post-`d4e746a`)

Commit `d4e746a` ("Share one CAS across chains") centralized storage behind `sharedStore` with a single eviction budget. Consequence: a misbehaving child chain (high block rate, bloated merkle trees, or a malicious chain spec) can fill the shared CAS and starve the nexus. Per-chain `BlockchainProtectionPolicy` instances are registered on a `UnionProtectionPolicy`, so *protected* bytes are fine — but the eviction victim pool is global. A child chain that churns unprotected CIDs (intermediate trie nodes, orphan forks) can displace victim bytes the nexus would rather keep.

**Audit ask:** does the eviction policy apply per-chain quotas, or first-come-first-evicted across chains? If the latter, a spec-deploy-as-a-service model (the `deployChildChain` RPC) hands any caller the ability to DoS the nexus by creating a high-churn chain and flooding it.

### S5. PinAnnounce trust / reputation wiring

`publishPinAnnounce(rootCID, selector, expiry, signature, fee)` advertises that we serve `rootCID`. Two gaps:

- **Unverified announces.** Do peers verify we actually have the CID before routing fetches to us? If announce-without-pin is undetectable, a malicious peer can flood announces for CIDs they've never stored and either DoS the fetcher pool or farm reputation on lies.
- **No demotion on fetch-failure.** `IvyFetcher` timeout paths should feed `Tally` — a peer that announced `X` and then 404s on the fetch should take a reputation hit. Grep didn't find that wiring. Without it, repeated liars stay in the fetch pool forever.

### S6. Block timestamp bounds

`block.timestamp` is an input to `calculateEpochDifficulty` (`ChainSpec.swift:188-193`) and is included in the PoW preimage (`MinerLoop.swift:366`). Bitcoin enforces `timestamp > MedianTimePast(last 11 blocks)` and `timestamp < NetworkAdjustedTime + 2h`. These rules prevent (a) grinding attacks on difficulty by predating blocks, and (b) warp attacks where a majority miner fast-forwards timestamps to halve difficulty every 2016 blocks.

Grep `block.timestamp` validation in `Block+Validate.swift` and confirm the corresponding rules exist. If they don't, any miner with >30% hashpower can manipulate difficulty downward over an adjustment window. **This is consensus-critical and needs a test, not a note.**

### S7. SQLite WAL / VACUUM hygiene

`PRAGMA journal_mode=WAL` is set (`SQLiteDatabase.swift:25`). WAL grows until checkpointed; `wal_autocheckpoint` is the default 1000 pages but that's per-connection, not per-commit, and heavy writes can run far ahead. Specific questions:

- Is `PRAGMA wal_checkpoint(TRUNCATE)` ever called? If not, WAL grows without bound during a mining session and `recoverFromCAS` replay cost (P1 #13) is pegged to WAL length at crash time.
- Is `VACUUM` or `PRAGMA auto_vacuum=INCREMENTAL` ever run? `pruneDiffs` deletes rows but doesn't reclaim pages. Over months, DB file size drifts from logical size.
- `PRAGMA optimize` at close (SQLite docs recommend) — not present. Statistics grow stale on long-running DBs.

None are urgent, all are the kind of item a reviewer would ask on the first read of a production chain schema.

### S8. `childBlocks` is PoW preimage — consensus-fragile serialization

`MinerLoop.swift:362` feeds `block.childBlocks.rawCID` into the PoW hash. Any change to child-block Merkle layout, dictionary ordering, or encoding changes every block hash on the chain after the change. Flag in `Block.swift` alongside `version` (L7) as a hard-fork-only surface. Add a serialization-pinning test (serialize a known block, compare to golden hex) so refactors can't silently change the preimage.

### S9. Bootstrap / anchor-peer demotion on misbehavior

`anchorPeers` persists known-good peers across restart. Grep didn't find any path that *removes* a peer from `anchorPeers` based on `Tally` reputation — only `AnchorPeers.update(peers:)` overwrites wholesale. A bootstrap peer that goes Byzantine (serves stale tips, withholds blocks, spams PEX) remains in the bootstrap set forever. At minimum, anchor-peer insertion should be gated on current `Tally` score, and periodic eviction should run on the same cadence as `pinReannounceTask`.

### S10. `maybePersist` cadence trade-off needs numbers

P1 #13's fix is "tighten `maybePersist` cadence on mining-active nodes." Today `persistInterval` defaults to some N-blocks value; tightening to 1 triples per-block IO (persist writes the full tip snapshot as JSON via `ChainStatePersister`). Before shipping, measure:

- Persist wall-cost at current height (JSON encode + fsync).
- Recovery wall-cost per block replayed in `recoverFromCAS`.
- Break-even: if persist is 10ms and recovery is 100ms/block, persist every 10 blocks breaks even on ungraceful-shutdown expected cost.

The audit shouldn't ship a cadence change without those numbers; otherwise you trade "rare slow startup" for "always slow mining."

---

## Updated quick wins in priority order (re-ranked 2026-04-21 post-audit)

Re-ranking principle: **liveness items that fire in bounded time first, then consensus-safety, then growth, then cleanup.** The original ranking conflated "large memory footprint in a year" with "miner deadlocks tomorrow"; those are different severities.

1. **Inner-timeout on `submitMinedBlock` (P2 #9)** — the only item on this list that causes a genuine mining freeze in bounded time. Use the `withThrowingTaskGroup` + sleep-racer pattern (see fix block); do NOT cancel-and-respawn (the code comment warns against it explicitly).
2. **Block timestamp validation (S6)** — if missing, difficulty warp / grinding is possible. Consensus-critical; requires a golden-block test.
3. **Pin-announce / eviction coupling invariant (P0 #4a)** — ship this *before* any LRU on `accountCIDs` (P0 #3), or the LRU turns into a reputation regression.
4. **Timestamp + PoW-short-circuit ordering (S2)** — verify the `675a801` known-block short-circuit happens before `validateBlockHash`, not after.
5. Gate `diagLog` + `[TIMING]` prints behind an env flag; rotate the file. (P0 #1, E1)
6. Call `pruneExpiredRecentBlocks()` from the GC loop (P0 #2) — one-line fix.
7. Mempool admission DoS rules (S1 / SOTA #3) — per-sender nonce-gap cap, min-fee floor, RBF bump threshold.
8. LRU-cap `accountCIDs` + add `tx_history` pruner in GC loop (P0 #3, #4) — coordinate with #3 above.
9. PinAnnounce verification + `Tally` demotion on fetch-failure (S5) — closes a reputation-lying attack.
10. Ivy unbounded request continuations (I11) — `BoundedDictionary` cap on `pendingRequests` / `pendingVolumeRequests`.
11. Shared-CAS per-chain eviction quotas (S4) — matters if `deployChildChain` is exposed to untrusted callers.
12. ~~De-duplicate child-block CAS writes (P1 #5)~~ — **partially fixed** via BufferedStorer skipSet. Remaining: drop the second trie walk.
13. Miner-nonce cache (P1 #8) — **must include reorg invalidation** (see safety note on P1 #8).
14. ~~Skip `backfillBlockIndex` when already populated (P1 #11)~~ — **done**, skip guarded by `StateStore.getBlockIndexCount()`.
15. Bounded gossip seen-set + per-peer Bloom (SOTA #1).
16. CAS mark-and-sweep GC (SOTA #2).
17. SQLite WAL checkpoint + VACUUM schedule (S7).
18. Anchor-peer demotion on `Tally` score drop (S9).
19. Kill the `HealthCheck` file-writer and `[TIMING]` prints (E1, E5).
20. Reorg-depth vs `retentionDepth` fail-loud (S3).
21. Incremental mempool fetcher cache (P1 #6); parallelize `pinAccountData` (P1 #7) — round out per-block CPU.
22. Lifecycle cleanup for per-chain maps (P1 #14-15) — promoted if `deployChildChain` RPC is user-facing; demoted for static-topology deployments.
23. `maybePersist` cadence — **measure before tightening** (S10).
24. Flip `enableLocalDiscovery` default to `false` in server deployments (I7).
25. Pin serialization-round-trip tests on `childBlocks` + `Block.version` (S8, L7) — catches accidental hard-forks.

---

## Testing plan — validating lattice-node as a global blockchain node

Grounded to this codebase, not generic. Where the plan calls out a missing harness piece, the gap is flagged explicitly.

### Principles

1. **No single-box test can prove global behavior** — latency, clock skew, asymmetric routes, and NAT variety only show up on real infra. Budget real cloud multi-region time.
2. **Every consensus-critical rule needs a golden test** — serialization, difficulty, timestamp bounds, reorg depth. Regressions here are silent and irreversible.
3. **Liveness is measured, not asserted** — "the miner didn't stall" is a pass-fail metric on wall-clock block cadence under load, not a unit assertion.
4. **Adversarial first, happy-path last** — a Byzantine harness that can lie, withhold, and spam is required to test anything a real public network will do.

### Harness requirements (build these before running the plan)

- **Multi-node orchestrator.** The existing `MultiNodeClient` + `ClusterCommand` is the right seed. Extend to: deterministic spawn order, pinned chain specs, scriptable chaos (kill/restart/partition peer N at time T), per-node RPC scraping.
- **Byzantine peer shim.** A modified lattice-node variant that can: serve stale tips, refuse to serve announced CIDs, spam PEX with fake endpoints, withhold mined blocks for N seconds, timestamp-warp blocks. ~300 LOC of harness code reused across every adversarial phase.
- **Clock control.** Currently `block.timestamp = Int64(Date().timeIntervalSince1970)` — the test harness needs a clock injection point to validate S6 (timestamp bounds) deterministically.
- **Network chaos.** `tc qdisc` + `netem` for latency/loss/jitter; `iptables` for partitions; `toxiproxy` for protocol-level mangling. Wrap in a test DSL (`partition(A, B, duration: 30s)`).
- **Determinism harness.** Replay a fixed set of blocks/txs against two builds; diff resulting state root + tip hash. Catches any accidental wire-format change.
- **Telemetry sink.** RPC `/metrics` already emits Prometheus. Stand up a dockerized Grafana with the canonical dashboard (block cadence, mempool depth, peer count, CAS disk bytes, actor-queue depth) so every phase is watchable, not just pass/fail.

### Phase 1 — protocol unit / integration (one box, in-process)

Goal: catch obvious breakage before paying for cloud time.

- Handshake + Kademlia routing (`Router`, `PeerConnection`): expected k-bucket convergence, eviction rules.
- Block gossip: mine on A, assert tip on B within 1× block time; mutate block-in-flight and assert rejection.
- Tx gossip including body-inline (commit `0760335`): mempool convergence between two nodes.
- PinAnnounce flow: announce → peer resolves via CID → debit is recorded on ledger (`CreditLineLedger`).
- CAS fetch miss → provider lookup → fetch → store → re-emit as available (end-to-end).
- `processBlockAndRecoverReorg` path: feed a deeper sibling chain, assert rewind + apply.
- Merged-mining commit: nexus accepts → children applied (`applyChildBlockStates`) → rejecting either should not leave a partial commit (invariant test).

**Pass criteria:** all CI-green, plus a golden-block JSON file checked into tree that any future code change must reproduce bit-identical.

### Phase 2 — small cluster (3–10 nodes, one box)

- **Single-writer convergence:** 1 miner, 3 followers. Assert followers' tip lags ≤ 2 blocks at steady state.
- **Two competing miners:** equal hashpower. Expect frequent reorgs at depth 1. Instrument reorg-depth histogram; assert 99p ≤ 3.
- **Three-way partition + merge:** split {A}{B}{C}, let each mine alone for 10 blocks, merge. Expect convergence on longest chain within 1× adjustment window.
- **Late-joiner sync:** run mining 200 blocks ahead, start a new node. Time-to-tip via `snapshot` sync path. Re-run with `headersFirst` if kept (E8) or remove if cut.
- **Graceful vs ungraceful restart:** crash a miner mid-submit (P2 #9 concern). On restart, `recoverFromCAS` walks back. Assert no double-submit and tip matches SQLite.
- **Deep reorg near `retentionDepth`:** engineer a reorg at `retentionDepth - 1` (should succeed) and `retentionDepth + 1` (should fail loud per S3).

### Phase 3 — network-hostile (single box, tc/netem)

- Latency matrix: 0/50/200/500/1000 ms × loss 0/1/5/20%. Measure: tip convergence time, mempool propagation time, reorg rate.
- Asymmetric bandwidth (1Mbps up / 100Mbps down) to stress `SendBudget` (I10).
- Partition durations: 10s / 60s / 10min / 1h. Longer partitions should exercise `retentionDepth`-bounded reorg merge.
- NAT: symmetric, full-cone, carrier-grade. Validates `STUNClient` + `ObservedAddress` path under each.
- Clock skew: ±30s, ±5min, ±2h between peers (once S6 bounds are in place).

**Pass criteria:** zero stuck-miner events in 24h; block cadence drift ≤ 10% from no-chaos baseline; no CAS divergence.

### Phase 4 — adversarial / Byzantine

Each uses the Byzantine peer shim:

- **Eclipse attempt:** fill k-buckets with Sybil peers. Assert honest peers remain reachable (requires anchor-peer pinning + Tally reputation gating — a gap per S9).
- **Selfish mining:** withhold blocks for 2× block time; release. Measure orphan rate on the honest miner. Baseline selfish-mining impact.
- **PinAnnounce liar:** announce CIDs peer doesn't hold. Assert fetcher detects timeout and peer is `Tally`-demoted (currently a gap, S5 — this test will fail today; it's the validation of the fix).
- **Timestamp warp:** submit block with `timestamp = parent + 24h`. Assert rejection (S6 — will fail today).
- **Mempool nonce-gap spam:** single attacker submits `nonce = confirmedNonce + 100_000`. Assert pool evicts or refuses admission per S1.
- **Fork-choice equal-work race:** two miners, identical difficulty, simultaneous block at same height. Assert deterministic tiebreaker.
- **Malicious child chain (post-`d4e746a`):** deploy a high-churn child that floods unprotected CIDs. Assert nexus CAS is not starved (S4 — will fail without per-chain eviction quotas).

### Phase 5 — global scale (multi-region cloud, 30+ days)

- 50–100 nodes across ≥4 regions (us-east, us-west, eu, ap). Mix of miners (20%) and followers (80%).
- Continuous low-grade chaos: 1% packet loss, 5% daily peer restart, one 30-min regional partition/week.
- Sustained load: inject a synthetic tx stream at 50% of `maxNumberOfTransactionsPerBlock` average, with occasional bursts to 150% (tests mempool caps).
- **Stall detection:** alert if any miner produces zero blocks for > 3× expected block time. Prod-shaped version of the P2 #9 bug.
- **Growth curves (validates this audit):** plot RSS, CAS disk, SQLite size, mempool size per node over 30 days. Any monotonic curve that doesn't flatten is a fail. Directly targets P0 #1-#4, I11.
- **Cross-version compat:** in week 3, upgrade half the fleet to a newer build. Assert no chain split, no block rejection storms.

### Phase 6 — production rollout playbook

- **Canary tier:** new build runs as non-mining follower for 7 days before any miner upgrade. Watch peer-count, block-accept rate, RPC error rate.
- **Mining canary:** 1 miner of N upgraded at a time; watch for orphan rate spike vs baseline.
- **Tripwires (kill-switch conditions):** (a) sustained chain-height divergence between canary and fleet, (b) reorg depth > `retentionDepth / 2`, (c) PoW verify rate > 10× baseline (suggests spam or a cache miss), (d) memory RSS growth > 20% over 24h.
- **Forensic logs off by default, on by flag.** Once `diagLog` (P0 #1) is gated, wire the env flag into the canary-node config so incident response can flip it without redeploying.
- **Documented rollback.** Binary symlink + `systemd` unit revert, tested quarterly.

### Signals / exit criteria per phase

| Phase | Exit criterion | Observability needed |
| --- | --- | --- |
| 1 | CI green + golden-block bit-identity | unit test output |
| 2 | 10-node cluster runs 48h w/o stall, no state divergence | Grafana: tip-height per node, reorg histogram |
| 3 | All matrix cells complete; no stall > 3× block time | + tc config capture per run |
| 4 | Every adversarial test has a pass *or* a tracked bug-ticket | + Byzantine peer action log |
| 5 | 30-day run, all growth curves flatten, no manual intervention | + alerting, PagerDuty integration |
| 6 | Three successful canary→full rollouts with clean metrics | + SRE runbook sign-off |

### What this plan intentionally skips

- Fuzzing the full message parser (good idea, separate workstream — `swift-fuzzilli`-style).
- Formal verification of consensus (overkill for this stage).
- Smart-contract / filter fuzzing (JXKit filters — the audit explicitly kept; defer until a second chain actually uses them).
- Mobile / embedded peer testing (not a current deployment target).

### Cost-to-value ranking

If budget is short: **Phase 1 + 2 + targeted Phase 4 subset (timestamp, pin-lie, mempool-spam)** catches 80% of the high-severity defects. **Phase 3 + 5** catch the long-tail "it crashes after 3 weeks" and "it deadlocks when the continent goes through a bad BGP day" classes. Phase 5 is cloud spend — run it once per release train, not per PR.

### Harness backlog (items not yet in tree)

Concrete code-level gaps that block this plan:

1. Clock injection point in `BlockBuilder` / `MinerLoop` (for S6 tests).
2. Byzantine peer variant — fork of lattice-node with toggleable misbehaviors behind a config flag.
3. Network-chaos test DSL wrapping `tc`/`iptables`.
4. Determinism harness (`replay-and-diff` binary, reading a golden fixture of blocks).
5. Grafana dashboard JSON checked into repo (lives with the `/metrics` endpoint).
6. Forensic-log env flag plumbing (tied to the P0 #1 fix).

Items 1, 4, and 5 are the cheapest; 2 is the most valuable per LOC and gates most of Phase 4.
