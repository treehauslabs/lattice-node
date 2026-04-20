# Storage Layer Migration: Decouple Warming, Batch at the Volume Boundary

**Status:** proposed
**Owner:** jbao
**Written:** 2026-04-20
**Scope:** Acorn (`AcornCASWorker` default extension, `CompositeCASWorker`), Ivy (`ProfitWeightedStore`), LatticeNode (`BufferedStorer`, `ChainNetwork.storeBatch`, `IvyFetcher`)

## 1. Problem

Mining is unstable. Under sustained load the node produces ~1.2s block times for roughly 1,200–1,250 blocks and then stalls — last observed at Nexus index 1245 (`/tmp/lattice-diag.log` line 53), where `submitMinedBlock` enters but never returns. The previous stall at ~1244 blocks was reproduced after the in-flight-CID duplicate-validation fix landed (`LatticeNode+Blocks.swift`), so that fix was necessary but not sufficient.

The pattern — steady-state mining that cliffs at a specific block count — is a characteristic signature of a storage-layer cost function that scales with cache population rather than throughput. Every mined block writes a merkle subtree; the cost of each write does not change until a hidden threshold is crossed, then writes become blocking.

The goal of this migration is to remove the class of bug, not patch this instance. After the migration, we should not be able to stall mining by running the node long enough.

## 2. Root cause

Three independent mechanisms compound on every block, and the compounded cost is unbounded over time.

### 2.1 Read-through cache warming is baked into the protocol

`AcornCASWorker.swift:14-43` defines the default extension:

```swift
func get(cid: ContentIdentifier) async -> Data? {
    if let near {
        if let data = await near.get(cid: cid) {
            await self.storeLocal(cid: cid, data: data)   // ← write on read
            return data
        }
    }
    return await withOptionalTimeout(timeout) {
        if let data = await self.getLocal(cid: cid) {
            await self.near?.store(cid: cid, data: data)  // ← write on read
            return data
        }
        return nil
    }
}
```

Every read that misses the nearest tier triggers a write back toward that tier. The warming is invisible to callers — there is no opt-out. The Lattice architecture doc (`architecture.html`, Data Flow: Get) describes this as intentional: "When data is found at a slow tier, it automatically backfills toward the fast end." That is fine for a caching layer in isolation; it is not fine when the call path for a single mined block does hundreds of such reads through a chain whose terminal tier is an on-disk POSIX write.

### 2.2 `CompositeCASWorker.getLocal` calls inner `get`, not inner `getLocal`

`CASChain.swift:35-38`:

```swift
public func getLocal(cid: ContentIdentifier) async -> Data? {
    guard let last = order.last, let worker = workers[last] else { return nil }
    return await worker.get(cid: cid)    // ← not getLocal
}
```

`getLocal` is supposed to mean "don't walk the chain." But the composite's `getLocal` walks the inner worker's full chain, which means warming fires. Any caller that explicitly asked for a local-only read still pays full backfill cost. `IvyFetcher.fetch` (`IvyFetcher.swift:50-74`) goes through the composite's `get`, which calls this `getLocal`, which calls the terminal worker's `get`, which re-enters the warming path at the terminal tier.

### 2.3 `ProfitWeightedStore.findLeastProfitable` is O(N) under capacity pressure

`ProfitWeightedStore.swift:168-190` is called on every `storeLocal` once `cidProfit.count >= maxEntries`. The default `maxEntries` is 100,000. Inside:

```swift
let allKeys = Array(cidProfit.keys)           // O(N) allocation
let sampleSize = min(max(Int(Double(allKeys.count).squareRoot()), 16), ...)
let sampledKeys = allKeys.shuffled().prefix(sampleSize)    // O(N) shuffle
```

`shuffled()` is Fisher-Yates over the full 100k-entry array — every store at capacity does a ~100k-operation shuffle, then throws most of it away. At steady state of roughly 40–80 new unique CIDs per block (header + radix subtree + tx bodies), the store crosses `maxEntries=100_000` somewhere around block 1,200–1,300. The observed cliff at 1,244 matches.

The sampling algorithm is fine. The implementation is not.

### 2.4 No dedup between block writes

`BufferedStorer.swift:4-18` appends every `(cid, data)` pair with no deduplication:

```swift
func store(rawCid: String, data: Data) throws {
    entries.append((rawCid, data))
}
```

Cashew's `storeRecursively` (see `cashew.html` MerkleDictionary section and `RadixNode+storeRecursively.swift`) descends through the entire merkle subtree rooted at a Block. Adjacent blocks share most of their radix state — typically >90% of the subtree CIDs are identical between block N and block N+1 (only touched accounts/state change). The storer buffers duplicates, then `ChainNetwork.storeBatch` (`ChainNetwork.swift:129-134`) replays them sequentially:

```swift
public func storeBatch(_ entries: [(String, Data)]) async {
    for (cid, data) in entries {
        let contentId = ContentIdentifier(rawValue: cid)
        await localCAS.store(cid: contentId, data: data)
    }
}
```

Each iteration is a separate `store` through the CAS chain. The chain's `store` default extension cascades: `storeLocal` at memory, then `near.store` → shared → inner disk, each with its own actor hop. An already-present CID still walks the full chain. Writing the same merkle subtree N times across N blocks is the architectural error the CAS layer was meant to avoid — but at this layer, every write is a fresh call.

### 2.5 The interaction

Per-block steady state:

1. `storeRecursively(block)` visits ~50–300 CIDs including the full merkle subtree.
2. BufferedStorer keeps every one, including duplicates of prior-block CIDs.
3. `storeBatch` iterates serially; each entry walks memory → shared → inner disk.
4. Each memory `store` may evict; each shared `storeLocal` runs `findLeastProfitable` once cap is hit.
5. Each disk `storeLocal` does bloom update + temp-write + `rename(2)`.
6. Reads during block validation (IvyFetcher → localWorker.get → chain default) also warm, doubling per-block disk writes.

Before capacity: the per-block cost is bounded by subtree size and disk latency, producing stable ~1.2s blocks. After capacity: every store incurs an O(N) shuffle in the shared store's actor, which serializes against every other access to `sharedStore` across *every subscribed chain* (mempool gossip, IvyFetcher reads, peer serves, pin-announce handlers). At that point, one chain's mining loop can be indefinitely delayed by another chain's pin-request handler waiting on `sharedStore`.

The diag log's final line shows `submitMinedBlock Nexus index=1245` followed by `processBlockHeader enter` — and nothing after. The next step is `lattice.processBlockHeader`, which resolves the block subtree via IvyFetcher, which calls `localWorker.get`, which calls `sharedStore.get` (through the composite), which contends on the shared actor against whatever else holds it.

## 3. Reference points from other systems

Mainstream blockchain implementations do not let per-CID writes hit disk in the hot path.

- **Bitcoin Core.** UTXO updates accumulate in `CCoinsViewCache`; `FlushStateToDisk` commits them to LevelDB in batches. The default batch size was raised from 16 MiB to 32 MiB in PR #31645 specifically because small-batch commits amplified compaction overhead. No UTXO write goes directly to disk during block validation.
- **Reth (Ethereum).** Per the Paradigm Reth 2.0 release notes (April 2026), MDBX commits at the end of block execution take "several tens of milliseconds" even at their optimized state, and a major 2.0 improvement was Partial Proofs — caching sparse-trie paths across payload validations to avoid redundant trie reconstruction on every `newPayload`. They also moved historical state out of MDBX into an append-only static-file store. The mental model: commit once per block, keep the hot path in memory.
- **Geth Path-Based Storage (PBSS).** Cited in our own whitepaper §10, reference [8]. Replaced per-CID hashed storage with a path-indexed flat layout to reduce write amplification.

The Lattice whitepaper §2.2 already adopts this model in principle: "When a CID is requested, the system checks each tier in order." The implementation diverges from the principle because the protocol's default `get()` quietly materializes each read as a fan-out write.

## 4. Proposed design

Three phases. Phase 1 is sufficient to prevent the observed stall; phases 2 and 3 address the systemic issues the whitepaper already implies we should have.

### Phase 1 — Decouple warming from reads, fix the obvious bugs

**P1.1. Remove warming from the `AcornCASWorker` protocol default.**

Change `AcornCASWorker.swift:21-36` so the default `get` does not write. Warming becomes an explicit method:

```swift
func get(cid: ContentIdentifier) async -> Data? {
    if let near, let data = await near.get(cid: cid) { return data }
    return await withOptionalTimeout(timeout) { await self.getLocal(cid: cid) }
}

func promote(cid: ContentIdentifier, data: Data) async {
    await storeLocal(cid: cid, data: data)
}
```

Callers that actually benefit from backfill (e.g., long-lived peer-fetched blocks that will be served again) opt in by calling `promote` after the read. The vast majority of reads in the mining hot path — state resolution during block validation — do not need warming because the data is about to be committed through the normal store path anyway.

**P1.2. Fix `CompositeCASWorker.getLocal`.**

`CASChain.swift:37` calls `worker.get`, which is wrong even by the protocol's own intent. Change to `worker.getLocal`. After P1.1, this no longer warms; after this fix, `getLocal` also no longer walks the inner worker's chain.

**P1.3. Fix `ProfitWeightedStore.findLeastProfitable` sampling cost.**

`ProfitWeightedStore.swift:169-190` must not touch all keys. Options, in order of preference:

- **Index-based sampling.** `BoundedDictionary` stores keys in order; keep a parallel `ContiguousArray<String>` aligned with insertion order (with swap-remove on eviction). Sample `sampleSize` random indices in O(sampleSize) without any full-array work. This preserves the statistical properties of the sampling policy.
- **Reservoir maintenance.** Keep a fixed-size sample of "cold candidates" updated on eviction; refresh lazily. More code; same asymptotic behavior; harder to reason about.

Pick index-based sampling. The O(1) invariants the LFUDecayCache already achieves for the memory worker are what we want here — the docs (`architecture.html`, Eviction Strategy section) already claim "O(k) where k = sample size."

**P1.4. Short-circuit re-stores.**

`CompositeCASWorker.storeLocal` (`CASChain.swift:51-54`) currently always delegates. Add a fast-path `has`-check before the store cascade: if the memory worker already has the CID and the shared store already has it, don't re-enter either `storeLocal`. Memory `syncHas` is 3–11ns per the Acorn docs, so this is strictly cheaper than the current path.

**Phase 1 expected outcome:** eliminates the read-triggered write amplification (50–90% disk write reduction on the mining hot path), removes the O(N) eviction penalty that produces the cliff at ~1,250 blocks. Mining should remain stable through capacity pressure.

### Phase 2 — Batch at the Volume boundary

Phase 1 stops the bleeding. Phase 2 addresses the architectural mismatch: the Volume is the natural commit unit but nothing in the pipeline treats it as one.

**P2.1. Deduplicate `BufferedStorer`.**

Replace the `[(String, Data)]` with `OrderedDictionary<String, Data>` keyed on rawCID. Overlapping subtrees between blocks N and N+1 collapse to a single entry per unique CID. Preserves insertion order for deterministic flush.

```swift
private var entries: OrderedDictionary<String, Data> = [:]

func store(rawCid: String, data: Data) throws {
    if entries[rawCid] == nil { entries[rawCid] = data }
}
```

**P2.2. True batch API through the CAS chain.**

Add to `AcornCASWorker`:

```swift
func storeLocalBatch(_ entries: [(ContentIdentifier, Data)]) async
```

With a default implementation that falls back to the per-CID path (so non-hot workers don't need to care), and specialized implementations at the tiers that benefit:

- **Memory worker.** One actor hop; one pass over the LFU cache; one eviction pass that amortizes sample-and-evict across the whole batch.
- **ProfitWeightedStore.** One capacity check across the whole batch; eviction runs once regardless of batch size; single pass over Volume membership updates.
- **DiskCASWorker.** One bloom-filter update pass; one eviction pass; one fsync at the end of the batch (the atomic-rename pattern already gives us per-file durability, but an `fsync` on the shard directory *once per batch* is what gives us crash-safe commit without per-file `fsync`). Matches the Bitcoin `FlushStateToDisk` pattern.

`ChainNetwork.storeBatch` (`ChainNetwork.swift:129-134`) becomes one call instead of a loop.

**P2.3. Volume-aware commit.**

`BufferedStorer.flush` should pass the block CID and Volume root CIDs (frontier, homestead, transactions, childBlocks) alongside the batch. `ProfitWeightedStore.storeVolumeBlock` already knows how to register a Volume (`ProfitWeightedStore.swift:90-128`); it's just not being used from the mining flush path. Connect them.

This also fixes a latent correctness issue: `volumeMembership` is currently populated only when `storeVolumeBlock` is called, but normal `storeLocal` calls bypass it, so most written blocks have no Volume membership and can't be evicted as a group.

**Phase 2 expected outcome:** per-block disk write count drops from O(subtree-size) to O(unique-new-CIDs-per-block), typically a 10–20× reduction. fsync rate drops from O(unique writes) to O(blocks).

### Phase 3 — Pay for what matters, on purpose

Phase 3 formalizes what Phase 2 hints at.

**P3.1. Explicit `TieredCASWorker` wrapper.**

Replace `CompositeCASWorker`'s behavior with a `TieredCASWorker` that owns tiering as a first-class concern — knows which tier is memory vs. durable, warming is a named public method, batch vs. individual paths are explicit, and `getLocal` means exactly "don't cross tiers." Composite keeps its role as a named-worker lookup table (subscript access, metrics aggregation). Splitting these responsibilities matches the rest of the Acorn design, where the near/far relationship is explicit.

**P3.2. Drop the `verifyReads` default at the disk tier.**

`DiskCASWorker` (per `disk-worker.html`) defaults to `verifyReads: true` — SHA-256 over every read. The CAS layer is already content-addressed; the only thing verifyReads catches is disk corruption, which should be a startup scrub + periodic background task, not a per-read synchronous cost. Default off; provide an explicit `scrub()` method for the cases that matter.

**Phase 3 expected outcome:** cleaner protocol surface; callers can't accidentally warm or verify; future storage-layer work has obvious landing zones.

## 5. Non-goals

- **No new storage backend.** Phase 2 is a code-path change, not a DB change. POSIX file + rename stays.
- **No protocol-level changes.** Wire format, CID format, and block structure are untouched.
- **No change to the chain-state JSON snapshot cadence.** `LatticeNodeConfig.persistInterval` defaults to 100 blocks (`Sources/LatticeNode/Config/LatticeNodeConfig.swift:31`); crash-recovery semantics documented in `PROTOCOL.md:265`. That layer is already batched correctly.
- **No change to SQLite state cache.** WAL + per-block update is the right pattern for the path-indexed cache.

## 6. Test plan

Local reproduction of the stall is already established: steady-state mining to block 1,245 reliably stalls on the current code.

- **Unit.** `AcornCASWorker` extension tests assert `get` does not invoke `storeLocal` or `near.store` after P1.1. `ProfitWeightedStore.findLeastProfitable` benchmark asserts per-call cost is independent of N (N in {1k, 10k, 100k, 1M}, ±15%).
- **Integration.** `BufferedStorer` dedup test: store same CID 10 times, flush, assert exactly one call through `storeLocalBatch`.
- **End-to-end.** Run standalone `LatticeNode` debug build with `maxEntries=100_000`, mine through 5,000 blocks; assert block time p99 remains under 2s; assert no `submitMinedBlock` latency spike at any capacity-crossing boundary.
- **Regression.** Verify peer block-serve still works: second node fetches a block range (`getBlockRange`) from first node after first node has pressed its shared store.

The existing in-flight CID guard in `LatticeNode.swift` / `LatticeNode+Blocks.swift` stays — it's correct, independent of this migration, and protects a different race.

## 7. Risks and open questions

- **Warming removal may hurt peer-serve latency.** If we strip automatic warming, cold pin-request handlers will hit disk instead of memory on second/third peer requests. Mitigation: `announceStoredBlock` already runs after every block; we can `promote` Volume roots into memory at that callsite. Measure and decide per-tier — memory may still want warm-on-read; disk definitely does not.
- **Phase 2 batch commit changes fsync semantics.** Today, every CID is independently crash-safe by virtue of per-file rename. Under batched commit, a crash mid-batch leaves a partially-flushed block. We already accept this at the chain-state JSON layer (snapshot every `persistInterval` blocks, default 100); the block itself is recoverable from peers, so the worst case is re-fetching the last block after a crash. Document it.
- **`findLeastProfitable` sampling index maintenance.** If we go with the parallel-array approach in P1.3, every `removeValue` becomes O(1) swap-remove in the key array. `BoundedDictionary`'s own eviction must stay in sync. Need to audit `BoundedDictionary` or wrap it.
- **The shared store is cross-chain.** A slow operation in one chain's pin handler still blocks all other chains' mining. Phase 2 reduces the *frequency* of slow operations but doesn't change the sharing model. Separating per-chain caches from the shared pinning store is a Phase 4 conversation, not in scope here.

## 8. Rollout

Each phase is independently landable and independently testable.

1. **Phase 1 lands first.** Three small PRs (P1.1 in Acorn, P1.2 in Acorn, P1.3 in Ivy) and a dependency bump in lattice-node. Acorn and Ivy are HubSpot-external packages owned by treehauslabs; we upstream or fork per our existing pattern.
2. **Phase 2 is a lattice-node change plus an Acorn protocol addition.** `storeLocalBatch` default preserves current behavior; specialized implementations land alongside.
3. **Phase 3 is a refactor.** Behind a new type; the old `CompositeCASWorker` shim remains until we've migrated the callsites.

## 9. References

- In-tree code: `AcornCASWorker.swift:21-36`, `CASChain.swift:35-38`, `ProfitWeightedStore.swift:168-190`, `BufferedStorer.swift:7-9`, `ChainNetwork.swift:129-134`, `IvyFetcher.swift:50-74`, `LatticeNode+Blocks.swift` (in-flight guard, already landed).
- Local docs: `/Users/jbao/swiftsrc/lattice-docs/architecture.html` (Data Flow: Get, Storage Tiers, Eviction Strategy), `/Users/jbao/swiftsrc/lattice-docs/acorn.html` (AcornCASWorker protocol, "Implement three, get five"), `/Users/jbao/swiftsrc/lattice-docs/disk-worker.html` (verifyReads, atomic writes), `/Users/jbao/swiftsrc/lattice-docs/cashew.html` (storeRecursively, merkle structure sharing), `/Users/jbao/swiftsrc/lattice-docs/whitepaper.md` §2.2 (three-tier resolution), §10 ref [8] (Geth PBSS).
- External: Paradigm, "Releasing Reth 2.0" (April 2026) — sparse-trie caching, MDBX commit cost, Partial Proofs. Bitcoin Core PR #31645 — UTXO flush batch size 16→32 MiB. `FlushStateToDisk` is the pattern to follow.
- Diag evidence: `/tmp/lattice-diag.log` — steady ~1.18s per block through index 1244, stall at 1245.
