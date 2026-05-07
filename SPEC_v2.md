# Lattice v2 — Revised System Specification

This is a proposed redesign of the Lattice blockchain. It preserves the core ideas (content-addressed Merkle structures, merged mining, cross-chain swaps, Volume-based networking) while eliminating the complexity that caused the majority of production bugs.

Every change is motivated by a specific bug or class of bugs encountered during the v1 stabilization.

---

## Design Principles

1. **One path for every block.** Sync and gossip feed the same validation pipeline. No `resetFrom` + reprocess. No divergent code paths.
2. **Volumes are implicit, not managed.** The system fetches Volumes automatically when resolving CIDs. No enter/exit scope stack. No scope leaks.
3. **One key scheme.** Ed25519 for everything — P2P identity, transaction signing, address derivation.
4. **Names say what they mean.** `prevState`/`postState`/`parentState` instead of homestead/frontier/parentHomestead.


### 1.1 Serialization: CBOR, not JSON

**v1 problem:** JSON serialization depends on `JSONEncoder`'s sorted-key behavior, which varies across languages and library versions. JSON is also verbose — block serialization is 2-3x larger than necessary.

**v2:** Use [dag-cbor](https://ipld.io/specs/codecs/dag-cbor/spec/) (CBOR with deterministic map key ordering). The CBOR spec defines canonical encoding: map keys sorted by length then lexicographically. This is language-independent and compact.

CID computation:
1. Serialize to canonical dag-cbor bytes
2. SHA-256 hash
3. CID v1 with codec `dag-cbor` (0x71)
4. Multibase base32lower encoding (prefix `b`)

### 1.2 Volumes: Implicit Resolution

**v1 problem:** The `VolumeAwareFetcher` enter/exit scope pattern caused scope leaks, stack corruption, and required `CompositeFetcher` hacks when child block data lived in a different broker than the resolving fetcher.

**v2:** Volumes are still the unit of network transfer, but scope management is implicit. When any CID is resolved:

```
resolve(cid) {
    if local_store.has(cid): return local_store.get(cid)
    volume = network.fetch_volume(cid)   // fetches the containing Volume
    local_store.put_volume(volume)        // cache locally
    return volume.entries[cid]
}
```

No enter/exit. No scope stack. No `VolumeAwareFetcher` protocol. The resolver handles Volume boundaries transparently.

**Volume storage:** Each Volume is stored as a single row in SQLite:

```sql
volumes (
    root_cid TEXT PRIMARY KEY,
    entries  BLOB NOT NULL,     -- CBOR-encoded {cid: bytes, ...}
    pinned   INTEGER DEFAULT 0, -- reference count
    expires  INTEGER            -- unix seconds, NULL = permanent
)
```

One table replaces `cas_data` + `volume_entries` + `volume_pins` + `volume_metadata`. CID→data lookups scan the `entries` CBOR inline (fast for small Volumes, which they always are — one trie node or one block).

### 1.3 Radix Trie (unchanged semantics, simplified types)

The Merkle dictionary is the same compressed radix trie. But the type hierarchy collapses:

```
Header<T>    — CID + optional resolved T (was HeaderImpl + VolumeImpl)
Node         — trait: properties(), get(), set()
├── Scalar   — leaf
├── RadixNode<V>  — trie internal node
└── Dict<V>  — trie root (count + children)
```

No separate `Volume` vs `Header` types. Every `Header<T>` is a potential Volume boundary. The resolver decides based on whether the CID is a Volume root in the store.

**Resolution strategies** remain the same: `targeted`, `recursive`, `list`, `range(after, limit)`.

### 1.4 Unified Storage (one SQLite per chain)

**v1 problem:** Two separate SQLite databases (DiskBroker for CAS, StateStore for indices) with independent schemas, migrations, and transaction boundaries. Cross-database consistency required careful coordination.

**v2:** One SQLite database per chain with unified schema:

```sql
-- Volume storage (replaces cas_data, volume_entries, volume_pins, volume_metadata)
volumes (root_cid, volume_cid, TEXT PK, entries BLOB, pinned INT DEFAULT 0, expires INT)

-- Chain index (replaces block_index, state meta keys)
chain_index (height INT PK, block_cid TEXT, state_root TEXT, timestamp INT)

-- Transaction history
tx_history (address TEXT, tx_cid TEXT, block_cid TEXT, height INT, PK(address, tx_cid))

-- Pin ownership (for pruning)
pin_owners (volume_cid TEXT, owner TEXT, PK(root_cid, owner))
```


## Layer 2: Network

### 2.1 Wire Protocol (unchanged)

Same 4-byte length-prefixed framing. Same message types. The protocol is mature and doesn't need changes.

**One simplification:** Remove message types 47/48 (balanceCheck/balanceLog) and 44/51 (feeExhausted/settlementProof). These are part of the fee settlement system that isn't implemented. Add them back when fee settlement is real.

### 2.2 One Key Scheme: Ed25519

**v1 problem:** Curve25519 for P2P identity, secp256k1 for transaction signing. Two crypto implementations, two key formats, two address derivations.

**v2:** Ed25519 everywhere.
- P2P identity: Ed25519 public key (32 bytes, hex-encoded)
- Transaction signing: Ed25519 signatures (64 bytes)
- Address: `SHA-256(public_key)[0:20]` hex-encoded (40 chars)
- Pin announcements: Ed25519 signature

This eliminates the secp256k1 dependency and unifies key management.

### 2.3 Remove Credit/Tally Gating from Volume Serving

**v1 problem:** The credit ledger accumulated debt during normal block exchange. After restart, `hasCreditCapacity` returned false for all peers, blocking `handleGetVolume` and preventing sync. Fixed by setting relay fee to 0, which effectively disabled the system.

**v2:** Volume serving (`handleGetVolume`) is never gated by credit. Serving requested data is essential for chain health. Credit/tally gates relay and forwarding only (DHT hops where you're doing work for someone else, not serving your own data to a direct peer).

The tally reputation system for `shouldAllow` remains — it gates bandwidth-heavy operations like gossip relay and DHT forwarding. But direct data serving to a connected peer that asked for a specific CID is always allowed.

### 2.4 Child Chain Port Discovery

**v1 problem:** `registerChainNetworkUsingNodeConfig` bootstrapped child Ivy with parent peer endpoints (nexus port), but child Ivy listens on a different deterministic port. The child Ivy connected to peers' nexus Ivy instead of their child Ivy.

**v2:** Each peer advertises all its chain ports in the `identify` message:

```
identify {
    publicKey, observedHost, observedPort,
    chainPorts: {directory: port, ...},   // NEW
    signature
}
```

When creating a child network, bootstrap peers come from the `chainPorts` map of connected nexus peers. No port remapping needed.

---

## Layer 3: Chain

### 3.1 Block Structure (clearer names)

```
Block {
    version: u16
    parent: Header<Block>?          // was previousBlock
    transactions: Header<Dict<Header<Transaction>>>
    children: Header<Dict<Header<Block>>>   // was childBlocks
    spec: Header<ChainSpec>
    prevState: Header<State>        // was homestead (state BEFORE this block)
    postState: Header<State>        // was frontier (state AFTER this block)
    parentState: Header<State>      // was parentHomestead (parent chain's state)
    difficulty: u256
    nextDifficulty: u256
    height: u64                     // was index
    timestamp: i64
    nonce: u64
}
```

**Naming rationale:**
- `prevState` = the state inherited from the previous block. Validators check `parent.postState == this.prevState`.
- `postState` = the state produced by applying this block's transactions. This is what the next block inherits.
- `parentState` = the parent chain's state snapshot. Child chain transactions validate cross-chain operations against this.

### 3.2 One Processing Path (sync = fast gossip)

**v1 problem:** Sync used `resetFrom` + `reprocessSyncedBlocksForChildChains` — a completely separate code path from gossip (`processBlockAndRecoverReorg`). This caused multiple bugs: `processBlockHeader` returned early on dedup, child chains weren't discovered, tipSnapshots weren't updated, child chain state wasn't rolled back.

**v2:** There is only `processBlock(header, fetcher)`. Sync feeds blocks through the same function:

```
sync(peer_tip_cid, fetcher):
    // Walk backward from peer tip to find common ancestor
    chain = walk_back(peer_tip_cid, fetcher)
    
    // Feed blocks forward through the SAME pipeline as gossip
    for block in chain.from_common_ancestor():
        processBlock(block.header, fetcher)
```

`processBlock` handles:
- Dedup (already in chain)
- Validation (PoW, state, timestamps)
- Fork choice (extends or reorgs)
- Child chain discovery and state application
- Reorg recovery (orphan tx re-admission, child state rollback)

No `resetFrom`. No `reprocessSyncedBlocksForChildChains`. No `reconcileChildChainStatesAfterSync`. One path.

**Trade-off:** This is slower for large syncs (processing 10k blocks one at a time vs. bulk reset). Acceptable because sync happens once per node lifecycle and correctness matters more than sync speed.

### 3.7 Mempool (simplified)

Remove the pending pool entirely. With automatic receipts, there's no need for a staging area for transactions awaiting parent-chain receipts.

The mempool is just:
- Fee-ordered priority queue
- Per-sender nonce tracking
- RBF (replace-by-fee)
- Capacity limit with lowest-fee eviction
- Dedup by CID

### 3.8 Mining (unchanged)

The mining loop is clean. Keep it as-is: resolve tip → select txs → build child commitments → compute difficulty → parallel nonce search → submit.

### 3.9 RPC API (unchanged)

The RPC API is comprehensive and well-tested. Keep the same endpoints. The test suite validates them.
