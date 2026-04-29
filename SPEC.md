# Lattice Blockchain — Complete System Specification

This document specifies the full Lattice blockchain stack in enough detail to reimplement it from scratch in any language. It covers five layers: cashew (Merkle/CAS), Ivy (P2P), VolumeBroker (storage), Lattice (consensus), and lattice-node (application).

The existing smoke test suite (49 scenarios) serves as the acceptance harness — a correct reimplementation must pass all tests unchanged.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Layer 1: cashew — Content-Addressed Merkle Structures](#2-cashew)
3. [Layer 2: Ivy — P2P Networking](#3-ivy)
4. [Layer 3: VolumeBroker — Local Storage](#4-volumebroker)
5. [Layer 4: Lattice — Consensus & Chain Management](#5-lattice)
6. [Layer 5: lattice-node — Application Integration](#6-lattice-node)
7. [Cross-Chain Swap Protocol](#7-cross-chain-swap-protocol)
8. [Test Harness](#8-test-harness)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────┐
│              lattice-node (Application)          │
│  RPC API · Mining · Mempool · State · Bootstrap  │
├─────────────────────────────────────────────────┤
│              Lattice (Consensus)                 │
│  Block validation · Fork choice · Merged mining  │
│  ChainState · ChainLevel · Cross-chain swaps     │
├──────────────────┬──────────────────────────────┤
│  Ivy (P2P)       │  VolumeBroker (Storage)       │
│  Kademlia DHT    │  Memory → Disk → Network      │
│  Volume fetch    │  Pin lifecycle · SQLite        │
│  Gossip · Tally  │  BrokerStorer · BrokerFetcher  │
├──────────────────┴──────────────────────────────┤
│              cashew (Merkle/CAS)                 │
│  Header/Volume · RadixTrie · Resolution          │
│  CID computation · Store/Fetch protocols         │
└─────────────────────────────────────────────────┘
```

**Key invariant:** Data is always addressed by content (CID = SHA-256 hash of serialized bytes). Volumes are the unit of network transfer and storage grouping. The chain is a DAG of Volumes referencing each other by CID.

---

## 2. cashew — Content-Addressed Merkle Structures {#2-cashew}

### 2.1 CID Computation

1. Serialize node to JSON (deterministic: sorted keys via `JSONEncoder`)
2. SHA-256 hash the bytes
3. Construct CID v1 with codec `dag-json` (0x0129)
4. Encode as multibase base32lower string (prefix `b`)

### 2.2 Type Hierarchy

```
Header<NodeType>          — CID + optional resolved node
├── HeaderImpl<T>         — Concrete, non-Volume boundary
└── Volume<NodeType>      — CID + node, marks a Volume boundary
    └── VolumeImpl<T>     — Concrete Volume boundary

Node                      — Tree-internal node with children
├── Scalar                — Leaf (no children)
├── RadixNode<V>          — Compressed radix trie internal node
│   ├── RadixNodeImpl<V>
│   └── VolumeRadixNodeImpl<V>  — Volume boundary at each trie node
└── MerkleDictionary<V>   — Root of a radix trie key-value store
    ├── MerkleDictionaryImpl<V>
    ├── VolumeMerkleDictionaryImpl<V>
    ├── MerkleArrayImpl<V>  — Append-only (keys = binary index strings)
    └── MerkleSetImpl       — Keys only, empty string values
```

### 2.3 RadixTrie (MerkleDictionary)

Persistent, content-addressed key-value store. Keys are strings; values are generic.

**RadixNode fields:**
- `prefix: String` — compressed edge label
- `value: V?` — stored value (if terminal)
- `children: [Character: RadixHeader<V>]` — child headers keyed by next character

**Operations:** `get(key)`, `inserting(key, value)`, `deleting(key)`, `mutating(key, value)`, `allKeys()`, `allKeysAndValues()`, `sortedKeys(limit, after)`

**Path compression:** Single-child internal nodes are collapsed with their child (prefix concatenation).

### 2.4 Resolution Strategies

```
enum ResolutionStrategy {
    case targeted      // Resolve single header
    case recursive     // Resolve entire subtree
    case list          // Resolve trie structure, keep leaf values lazy
    case range(after: String, limit: Int)  // Sorted key window
}
```

Paths are specified as `ArrayTrie<ResolutionStrategy>` mapping trie paths to strategies.

### 2.5 Volume Boundaries

A Volume marks a semantic boundary in the DAG. When resolving:
- `VolumeAwareFetcher.enterVolume(rootCID, paths)` is called before entering
- `VolumeAwareFetcher.exitVolume(rootCID)` is called after exiting

This enables per-Volume peer discovery, storage grouping, and independent pinning.

### 2.6 Storage Protocol

```
protocol Storer {
    func store(rawCid: String, data: Data) throws
    func contains(rawCid: String) -> Bool  // default: false
}

protocol VolumeAwareStorer: Storer {
    func enterVolume(rootCID: String) throws
    func exitVolume(rootCID: String) throws
}
```

`storeRecursively` walks the tree depth-first, calling enter/exit at Volume boundaries. The BrokerStorer buffers writes per-scope and flushes as VolumePayloads.

### 2.7 Fetcher Protocol

```
protocol Fetcher {
    func fetch(rawCid: String) async throws -> Data
}

protocol VolumeAwareFetcher: Fetcher {
    func enterVolume(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws
    func exitVolume(rootCID: String) async
}
```

---

## 3. Ivy — P2P Networking {#3-ivy}

### 3.1 Wire Protocol

Messages are framed with a **4-byte big-endian length prefix**. Max frame: 4MB. Strings are UTF-8 with UInt16 length prefix (max 8192 bytes). Data fields use UInt32 length prefix.

**Key message types (tag-based enum):**

| Tag | Name | Purpose |
|-----|------|---------|
| 0/1 | ping/pong | Keepalive (UInt64 nonce) |
| 3 | block | Single block response (cid + data) |
| 5/6 | findNode/neighbors | DHT peer lookup |
| 7 | announceBlock | Gossip block availability |
| 8 | identify | Peer identity + observed address |
| 16 | dhtForward | Recursive DHT content lookup (ttl hops) |
| 40/41 | findPins/pins | DHT provider discovery |
| 42/43 | pinAnnounce/pinStored | Announce pin storage |
| 50 | blocks | Volume response (rootCID + items[]) |
| 53 | getVolume | Volume fetch request |
| 54 | announceVolume | Volume availability gossip |
| 55 | pushVolume | Proactive Volume push to high-rep peers |

### 3.2 Kademlia DHT

- 256 k-buckets, default k=20
- XOR distance metric on SHA-256 hashes
- `closestPeers(target, count)` — spiral from target bucket outward

### 3.3 Volume Protocol

`fetchVolume(rootCID)` flow:
1. Check local dataSource
2. Try recorded providers (from past announces/fetches)
3. Try stored pin announcements
4. DHT findPins if < 2 candidates
5. Fallback: closest peers by XOR
6. Race all candidates in parallel — first non-empty response wins

### 3.4 Credit/Tally System

- **Tally:** Per-peer bandwidth tracking with exponential decay (half-life 3600s). Reputation = weighted(reciprocity, latency, successRate, challenges). `shouldAllow(peer)` gates serving based on pressure + reputation.
- **CreditLine:** Per-peer balance tracking for fee settlement. `hasCreditCapacity` blocks serving when debt exceeds threshold.
- **Default relay fee: 0** (credit system wired but inactive until fee settlement implemented)

### 3.5 Pin System

- `publishPinAnnounce(rootCID, expiry, signature)` — sign with Curve25519, send to K closest peers
- `storedPinAnnouncements` — bounded dict (10k roots), LRU eviction
- `evictExpiredPins()` / `evictExpiredProviders()` — cleanup on configurable interval

### 3.6 IvyConfig Defaults

| Parameter | Default |
|-----------|---------|
| listenPort | 4001 |
| kBucketSize | 20 |
| requestTimeout | 15s |
| relayFee | 0 |
| maxPendingRequests | 4096 |
| highBandwidthPeers | 3 |
| keepaliveInterval | 60s |
| staleTimeout | 180s |

### 3.7 Cryptography

- **Key scheme:** Curve25519 (EdDSA for signing)
- **Signatures:** identify, pinAnnounce, NodeRecord — all signed with Curve25519 private key
- **Transaction signatures:** secp256k1 ECDSA (compact 64-byte)

---

## 4. VolumeBroker — Local Storage {#4-volumebroker}

### 4.1 VolumePayload

```
struct VolumePayload {
    root: String              // Volume root CID
    entries: [String: Data]   // CID → raw bytes
}
```

### 4.2 Broker Chain

```
MemoryBroker (LRU cache) → DiskBroker (SQLite) → IvyBroker (network)
          near                    self                    far
```

Read-through: `fetchVolume(root)` tries local → near → far.

### 4.3 DiskBroker SQLite Schema

```sql
cas_data      (cid TEXT PK, data BLOB)
volume_entries(root TEXT, cid TEXT, PK(root,cid))
volume_pins   (root TEXT, owner TEXT, count INT, expires_at TEXT, PK(root,owner))
volume_metadata(root TEXT PK, stored_at TEXT)
```

- WAL mode, synchronous=NORMAL
- Pin merging: count adds, expires_at uses max (NULL = permanent)
- `evictUnpinned()`: delete expired pins, then delete unpinned volumes + CAS data

### 4.4 BrokerStorer

Implements `VolumeAwareStorer`. Buffers writes per Volume scope:
- `enterVolume(rootCID)` → push scope
- `store(rawCid, data)` → write to current scope buffer
- `exitVolume(rootCID)` → pop scope, create VolumePayload if non-empty
- `contains(rawCid)` → checks **current scope only** (per-Volume dedup)
- `flush()` → write all payloads to broker

---

## 5. Lattice — Consensus & Chain Management {#5-lattice}

### 5.1 Block Structure

```
Block {
    version: UInt16 (1)
    previousBlock: VolumeImpl<Block>?
    transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>
    difficulty: UInt256
    nextDifficulty: UInt256
    spec: VolumeImpl<ChainSpec>
    parentHomestead: LatticeStateHeader
    homestead: LatticeStateHeader
    frontier: LatticeStateHeader
    childBlocks: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>
    index: UInt64
    timestamp: Int64 (ms since epoch)
    nonce: UInt64
}
```

### 5.2 Difficulty Hash

```
SHA-256(previousBlockCID || transactions.rawCID || difficulty.hex || 
       nextDifficulty.hex || spec.rawCID || parentHomestead.rawCID || 
       homestead.rawCID || frontier.rawCID || childBlocks.rawCID || 
       index || timestamp || nonce)
```

Block is valid when `difficulty >= difficultyHash`.

### 5.3 Difficulty Adjustment

- Pair-based: if actual_time < target → halve difficulty, if > target → double
- Windowed: at epoch boundaries (every `difficultyAdjustmentWindow` blocks), average timestamps in window
- Change factor capped at 2x per adjustment

### 5.4 Fork-Choice Rule

1. Earlier parent-chain anchor index wins (lower = more accumulated parent work)
2. Higher cumulative work wins
3. No parent anchor beats parent anchor

### 5.5 ChainState

Actor managing all known blocks and fork choice:
- `submitBlock(parentBlockHeaderAndIndex, blockHeader, block)` → SubmissionResult
- `resetFrom(persisted, retentionDepth)` — bulk chain replacement (sync)
- `propagateParentReorg(reorg)` → child Reorganization
- Retention: prune blocks older than `retentionDepth` behind tip

### 5.6 Merged Mining (ChainLevel)

```
Nexus (ChainLevel)
├── Child1 (ChainLevel)
│   └── Grandchild1 (ChainLevel)
└── Child2 (ChainLevel)
```

`acceptChildBlockTree` walks each child block embedded in `childBlocks`:
- New directory at genesis → `subscribe(to:, genesisBlock:)`
- Existing directory → `validateChildBlock` + `submitBlock`
- Always recurse into child's own childBlocks (grandchildren may pass their level's difficulty)

### 5.7 Transaction Structure

```
Transaction {
    signatures: [pubkey_hex: signature_hex]  // secp256k1 ECDSA
    body: HeaderImpl<TransactionBody>
}

TransactionBody {
    accountActions: [AccountAction]      // {owner, delta: Int64}
    depositActions: [DepositAction]      // {nonce: UInt128, demander, amountDemanded, amountDeposited}
    withdrawalActions: [WithdrawalAction] // {withdrawer, nonce, demander, amountDemanded, amountWithdrawn}
    receiptActions: [ReceiptAction]      // {withdrawer, nonce, demander, amountDemanded, directory}
    actions: [Action]                    // {key, oldValue?, newValue?} general state
    genesisActions: [GenesisAction]      // {directory, block} child chain deployment
    signers: [String]
    fee: UInt64
    nonce: UInt64
    chainPath: [String]
}
```

### 5.8 LatticeState (Frontier/Homestead)

```
LatticeState {
    accountState: MerkleDictionary<UInt64>     // address → balance
    generalState: MerkleDictionary<String>     // key → value
    depositState: MerkleDictionary<UInt64>     // deposit_key → amountDeposited
    genesisState: MerkleDictionary<Block>      // directory → genesis block
    receiptState: MerkleDictionary<PublicKey>   // receipt_key → withdrawer pubkey
}
```

State continuity: `previousBlock.frontier == block.homestead`

### 5.9 Validation Pipeline

**Nexus:** resolve previous → validate spec/state/index continuity → timestamp checks (> previous, < now+2h, > median(11 ancestors)) → difficulty adjustment → transaction validation → filter checks → balance conservation → frontier state replay

**Child:** same + timestamp must match parent + parentHomestead must match parent's homestead + ancestral filter validation

**Balance conservation:** `totalCredits ≤ totalDebits + reward + fees + withdrawn - deposited`

### 5.10 Key Invariants

1. Block index continuity: `previousBlock.index + 1 == block.index`
2. State continuity: `previousBlock.frontier.rawCID == block.homestead.rawCID`
3. Spec invariance: `previousBlock.spec == block.spec`
4. Nonce continuity: per-signer-group nonces strictly ascending
5. Deposit-withdrawal matching: amounts and nonces must correspond
6. Address computation: `"1" + doubleSHA256(publicKey).prefix(32)`

---

## 6. lattice-node — Application Integration {#6-lattice-node}

### 6.1 Block Processing Flow

1. Dedup (chain.contains + inFlightBlockCIDs)
2. Build CompositeFetcher (nexus primary + child fallbacks)
3. `lattice.processBlockHeader` (Lattice-level validation + child tree walk)
4. Resolve block, bind peer as pinner
5. Apply state (StateStore, receipts, tx history, mempool nonce updates)
6. Apply child block states (cascade to children)
7. Receipt promotion + deposit eviction hooks
8. Reorg recovery if tip changed

### 6.2 Sync

- Trigger: height gap > 5 blocks
- ChainSyncer walks chain backward from peer tip, validates PoW
- `finalizeSyncResult`: resetFrom → resetChildChainsToGenesis → reprocessSyncedBlocksForChildChains (processChildBlockTree + applyChildBlockStates per block) → reconcileChildChainStatesAfterSync

### 6.3 Child Chain Bootstrap

`bootstrapChildChain`: walk parent backward → walk child forward to genesis → validate every block against its anchor → subscribe at Lattice level → submit historical blocks → register network → backfill state

### 6.4 Mining

MinerLoop: resolve tip → select mempool txs → build child blocks → construct coinbase → compute difficulty → parallel nonce search (batches of 10k, lock-free tip check per batch) → submit block

### 6.5 Mempool

- Valid pool (selectable) + pending pool (awaiting parent receipts)
- Admission: dedup → fee floor → nonce bounds (gap ≤ 64) → state-key conflict → per-account limit (64) → RBF → capacity eviction
- Receipt promotion: after parent block with new receipts, recheck pending entries

### 6.6 RPC API

49 endpoints covering: chain info, block queries, balance/nonce, transaction submit/prepare, mempool, proofs, deposits/receipts, fee estimation, mining control, peers, finality, historical state, health, metrics, SSE events.

Rate limited: 50 req/s per IP, burst 100.

### 6.7 StateStore SQLite

Tables: `state` (meta KV), `tx_history` (address index), `block_index` (height→hash), `block_stored_roots`, `block_replaced_roots`, `validator_pins`

### 6.8 Configuration

CLI flags + JSON config file + environment variables. Key env vars: `RETENTION_DEPTH`, `PIN_ANNOUNCE_EXPIRY`, `REANNOUNCE_INTERVAL`, `EVICTION_INTERVAL`.

---

## 7. Cross-Chain Swap Protocol {#7-cross-chain-swap-protocol}

```
Child Chain (deposit)  ──→  Parent Chain (receipt)  ──→  Child Chain (withdrawal)

Step 1: User deposits on child chain
  DepositAction(nonce, demander, amountDemanded=500, amountDeposited=500)
  Child balance: user -501 (500 + 1 fee)
  depositState[demander/500/nonce] = 500

Step 2: Anyone creates receipt on parent chain
  ReceiptAction(withdrawer, nonce, demander, amountDemanded=500, directory=child)
  Parent balance: demander -500, withdrawer +500
  receiptState[child/demander/500/nonce] = withdrawer

Step 3: Withdrawer completes on child chain
  WithdrawalAction(withdrawer, nonce, demander, amountDemanded=500, amountWithdrawn=500)
  Validates receipt exists on parent (via parentHomestead)
  Child balance: withdrawer +500
  Delete depositState[demander/500/nonce]
```

---

## 8. Test Harness {#8-test-harness}

### 8.1 Acceptance Criteria

A correct reimplementation must pass all 49 smoke tests in `SmokeTests/` unchanged. The tests are language-agnostic JavaScript (Node.js) that interact with the node exclusively through:
- **RPC API** (HTTP JSON on configurable port)
- **CLI** (binary with `--port`, `--rpc-port`, `--data-dir`, `--peer`, `--subscribe`, `--mine`, `--finality-confirmations`, `--no-dns-seeds` flags)
- **Process signals** (SIGTERM for graceful shutdown)
- **Data directory** (identity.json file for key discovery)

### 8.2 Test Categories

| Category | Count | Tests |
|----------|-------|-------|
| Network | 6 | multinode-convergence, sync, late-joiner, partition, multichain-late-joiner, concurrent-mining |
| Follower | 3 | parent-dependency, stateless-cli, stateless-follower |
| Persistence | 5 | restart-resilience, graceful-shutdown, sigterm-under-load, restart-with-children, retention-pruning |
| Swap | 4 | swap, variable-rate-swap, grandchild-swap, multidepth-swap |
| Safety | 16 | bad-signature, double-spend, nonce-edge-cases, rpc-idempotency, swap-violations, fee-bounds, balance-overdraft, supply-conservation, mempool-propagation, cross-chain-conservation, mempool-eviction, concurrent-senders, premine-correctness, large-block, deploy-under-load, reorg-state-rollback, timestamp-rejection, cross-chain-reorg |
| RPC | 12 | finality, fee-and-rbf, health-and-metrics, block-explorer, transaction-history, chain-spec, balance-proof, difficulty-adjustment, websocket-events, historical-balance, operational-endpoints |
| Liveness | 2 | pin-lifecycle, stability-multichain (gated) |

### 8.3 Running Tests

```bash
# Build the node binary
swift build  # or equivalent for target language

# Run all tests (binary must be at .build/debug/LatticeNode)
node SmokeTests/run.mjs

# Run specific test
SMOKE_FILTER=swap node SmokeTests/run.mjs

# Run stability soak (35 min)
SMOKE_STABILITY=1 node SmokeTests/run.mjs
```

### 8.4 Test Infrastructure

Tests use these shared libraries:
- `lib/env.mjs` — port allocation (deterministic seeds), binary discovery
- `lib/node.mjs` — Node/Network classes (start/stop/restart, RPC, identity)
- `lib/chain.mjs` — chain introspection (chainInfo, tipInfo, mining control, deployChild, mineBurst)
- `lib/tx.mjs` — transaction submission (sign + prepare + submit)
- `lib/wallet.mjs` — keypair generation (secp256k1), address computation
- `lib/waitFor.mjs` — polling with timeout
- `lib/probe.mjs` — peer count queries

### 8.5 Port Allocation

Each test gets a unique port seed. Ports are computed as:
- P2P: `4100 + seed * 100 + nodeIndex`
- RPC: `8200 + seed * 100 + nodeIndex`

Child chain ports: `basePort + 1 + (hash(directory) % 1000)` where hash is `directory.utf8.reduce(0) { ($0 &* 31) &+ UInt16($1) }`.

### 8.6 Minimum Viable Implementation Order

For incremental development, implement in this order:

1. **cashew** — CID computation, JSON serialization, Header/Volume types, RadixTrie, resolution
2. **VolumeBroker** — DiskBroker (SQLite), MemoryBroker (LRU), BrokerStorer
3. **Lattice** — Block, ChainSpec, ChainState (fork choice), Transaction validation, LatticeState, BlockBuilder
4. **Ivy** — TCP framing, message serialize/deserialize, connection management, DHT, Volume fetch, pin system
5. **lattice-node** — Genesis, RPC API, block processing, sync, mining, mempool, child chain bootstrap

**First milestone tests:** bad-signature, double-spend, nonce-edge-cases (single-node, no networking)
**Second milestone:** sync, late-joiner, multinode-convergence (networking)
**Third milestone:** swap, variable-rate-swap (cross-chain)
**Fourth milestone:** all remaining tests
