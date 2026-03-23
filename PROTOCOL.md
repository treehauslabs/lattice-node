# Lattice Protocol Specification v0.1.0

## Abstract

Lattice is a proof-of-work blockchain with native multi-chain support via merged mining. The Nexus chain serves as the root of a tree of child chains, each with independent state, transaction throughput, and economic parameters, while sharing the parent's security through merged mining. State is stored path-based (PBSS) in SQLite for O(1) lookups, with content-addressed storage (CAS) for block/transaction data and peer-to-peer distribution.

---

## 1. Data Structures

### 1.1 Block

| Field | Type | Description |
|-------|------|-------------|
| previousBlock | CID? | Reference to parent block (nil for genesis) |
| transactions | CID → Transaction | Merkle dictionary of transactions |
| difficulty | UInt256 | Target difficulty for this block's PoW |
| nextDifficulty | UInt256 | Computed difficulty for the next block |
| spec | CID | Chain specification reference |
| homestead | CID | State root BEFORE this block's transactions |
| frontier | CID | State root AFTER this block's transactions |
| parentHomestead | CID | Parent chain's state (for child chains) |
| childBlocks | CID → Block | Merged-mined child chain blocks |
| index | UInt64 | Block height (0 = genesis) |
| timestamp | Int64 | Milliseconds since Unix epoch |
| nonce | UInt64 | Proof-of-work nonce |

### 1.2 Transaction

| Field | Type | Description |
|-------|------|-------------|
| signatures | [PublicKeyHex: SignatureHex] | P256 ECDSA signatures |
| body | CID → TransactionBody | Reference to transaction body |

### 1.3 TransactionBody

| Field | Type | Description |
|-------|------|-------------|
| accountActions | [AccountAction] | Balance transfers |
| actions | [Action] | General state changes |
| swapActions | [SwapAction] | Atomic swap initiations |
| swapClaimActions | [SwapClaimAction] | Atomic swap claims |
| genesisActions | [GenesisAction] | Genesis-only operations |
| peerActions | [PeerAction] | Peer registration |
| settleActions | [SettleAction] | Settlement operations |
| signers | [Address] | Required signers |
| fee | UInt64 | Transaction fee |
| nonce | UInt64 | Height-based replay protection |

### 1.4 AccountAction

| Field | Type | Description |
|-------|------|-------------|
| owner | Address | Account address (CID of public key) |
| oldBalance | UInt64 | Claimed current balance (verified against state) |
| newBalance | UInt64 | New balance after action |

### 1.5 ChainSpec

| Field | Type | Description |
|-------|------|-------------|
| directory | String | Chain identifier (e.g., "Nexus") |
| maxNumberOfTransactionsPerBlock | UInt64 | Block capacity |
| maxStateGrowth | Int | Max state bytes per block |
| maxBlockSize | Int | Max serialized block bytes |
| premine | UInt64 | Premine block count |
| targetBlockTime | UInt64 | Target milliseconds between blocks |
| initialReward | UInt64 | Mining reward at genesis |
| halvingInterval | UInt64 | Blocks between reward halvings |
| difficultyAdjustmentWindow | UInt64 | Blocks for difficulty recalculation |

---

## 2. Consensus

### 2.1 Proof of Work

The PoW hash is computed as:
```
prefix = previousBlockCID || transactionsCID || difficulty.hex || nextDifficulty.hex
       || specCID || parentHomesteadCID || homesteadCID || frontierCID
       || childBlocksCID || blockIndex || timestamp
hash = UInt256.hash(prefix + nonce)
```

A block is valid when `difficulty >= hash`.

### 2.2 Chain Selection

The heaviest chain (most cumulative work) is canonical. Work for a block is `UInt256.max / difficulty`. On receiving a block that creates a fork, the node switches to the chain with more cumulative work.

### 2.3 Difficulty Adjustment

Difficulty adjusts every block using the `difficultyAdjustmentWindow` (default: 120 blocks for Nexus). If blocks are faster than `targetBlockTime`, difficulty increases; if slower, it decreases. The adjustment rate is bounded to prevent extreme swings.

### 2.4 Block Reward

```
reward(height) = initialReward >> (height / halvingInterval)
```

The coinbase transaction has fee=0 and nonce=blockHeight. It credits the miner's address with `reward + sum(fees)`.

### 2.5 Merged Mining

A Nexus block may contain child chain blocks in its `childBlocks` field. Child blocks inherit the Nexus block's proof-of-work — no additional mining is required. Each child chain has its own ChainSpec, state, and difficulty. Child blocks reference the Nexus block as their parent via `parentHomestead`.

---

## 3. Transaction Validation

A transaction is valid if ALL of the following hold:

1. **Signatures**: Every address in `signers` has a valid P256 ECDSA signature over `body.rawCID`
2. **Fee bounds**: `MINIMUM_TRANSACTION_FEE (1) <= fee <= MAX_TRANSACTION_FEE (1,000,000,000,000)`
3. **Nonce**: `currentHeight - 600 <= nonce <= currentHeight + 600` (height-based replay protection)
4. **Size**: Serialized body ≤ 102,400 bytes
5. **Balance claims**: For each AccountAction, `oldBalance` matches the on-chain balance
6. **Conservation**: `sum(debits) == sum(credits) + fee` (no value created or destroyed)
7. **Signer authorization**: Swap/settle action senders must be in `signers`

### 3.1 Mempool Admission

Beyond validity, mempool admission requires:
- Global mempool not full (max 10,000 transactions)
- Per-account limit not reached (max 64 pending per sender)
- If same sender+nonce exists: replacement requires fee ≥ old_fee × 1.1 + 1 (10% bump)
- If mempool full: new tx fee must exceed lowest existing fee

### 3.2 Transaction Selection (Block Building)

Transactions are selected by fee descending. The miner includes up to `maxNumberOfTransactionsPerBlock - 1` fee-paying transactions, plus one coinbase transaction at index 0.

---

## 4. State Model

### 4.1 Content-Addressed Storage (CAS)

All blocks, transactions, and state objects are stored by their content identifier (CID). The CAS has three tiers:
1. **Memory**: In-process LRU cache
2. **Disk**: Persistent key-value store (Acorn DiskCASWorker)
3. **Network**: Peer-to-peer fetch via Ivy protocol

### 4.2 Path-Based State Storage (PBSS)

Current state is indexed by path in SQLite for O(1) lookups:

| Path | Value | Description |
|------|-------|-------------|
| `account:<address>` | `{balance, nonce}` | Account state |
| `general:<key>` | bytes | General state (orders, etc.) |
| `meta:chain-tip` | CID | Current chain tip |
| `meta:height` | UInt64 | Current block height |
| `meta:state-root` | CID | Current frontier CID |

### 4.3 CAS State Diffing

State changes are derived by structurally diffing the CAS merkle trees rather than replaying transactions. Each block's `homestead` (pre-execution state root) and `frontier` (post-execution state root) are diffed using cashew's `CashewDiff`:

```
diff = frontier.accountState.diff(from: homestead.accountState, fetcher: fetcher)
diff.inserted  → new accounts (address → balance)
diff.deleted   → removed accounts
diff.modified  → changed accounts (old balance → new balance)
```

This is used for:
- **Block acceptance**: Extract account changes to update PBSS StateStore
- **Reorg recovery**: Invert diffs (swap old/new) to roll back orphaned blocks' state changes
- **Sync state rebuild**: Resolve tip frontier directly instead of replaying blocks

Advantages over transaction replay: correct by construction (captures all state changes including implicit ones from child chains), O(changed accounts) instead of O(transactions × actions), and independent of transaction execution logic.

### 4.4 State Expiry

Accounts inactive for >1,000,000 blocks are moved from `account:<address>` to `expired:<address>`. They can be revived by providing the account data. Expired accounts retain their balance and nonce.

### 4.5 Transaction Receipts

On block acceptance, a receipt is generated per transaction:

| Field | Type |
|-------|------|
| txCID | String |
| blockHash | String |
| blockHeight | UInt64 |
| timestamp | Int64 |
| fee | UInt64 |
| sender | String |
| status | "confirmed" |
| accountActions | [{owner, oldBalance, newBalance}] |

---

## 5. Networking

### 5.1 P2P Protocol (Ivy)

Nodes communicate via the Ivy protocol, which provides:
- **Kademlia DHT** for peer discovery
- **Tally** reputation system for peer scoring
- **k-bucket routing** for peer management
- **Block announcement**: broadcast block CID to peers
- **Block fetch**: retrieve block data by CID
- **mDNS**: local network peer discovery (optional)

### 5.2 Peer Discovery

On startup, peers are discovered from (in order):
1. Persisted peers (`peers.json` from previous session)
2. Hardcoded bootstrap nodes (`BootstrapPeers.nexus`)
3. DNS seeds (TXT records at seed hostnames)
4. DHT peer refresh (every 60 seconds)

### 5.3 Peer Diversity (Eclipse Protection)

- Max 2 outbound connections per /16 subnet
- Target 8 outbound + 2 block-relay-only connections
- 2 anchor peers persisted across restarts
- Overrepresented subnets pruned during refresh

### 5.4 Block Propagation

Blocks are propagated as full block data. A CompactBlock module exists for future bandwidth optimization using short transaction IDs and mempool reconstruction (BIP 152-style).

### 5.5 Rate Limiting

Per-peer: max 20 blocks per 10-second window. Peer reputation managed by the Tally system — peers delivering invalid blocks, timing out, or exceeding rate limits are penalized and eventually disconnected.

---

## 6. Synchronization

### 6.1 Sync Trigger

Sync is triggered when a peer announces a block with height gap > `retentionDepth` from local chain tip.

### 6.2 Strategies

**Snapshot Sync** (default): Download `retentionDepth` recent blocks. Validate PoW on each. Verify cumulative work exceeds local chain. Restore chain state from downloaded blocks.

**Full Sync**: Download entire chain from genesis. Validate every block's PoW. Highest integrity but slowest.

**Headers-First Sync**: Three phases:
1. Download all block headers (fast, validate PoW per header)
2. Parallel full block download (8 concurrent workers)
3. Verify tip block's state root, then apply chain state

### 6.3 Post-Sync Verification

After sync, query multiple peers to confirm the synced chain tip is recognized by the network. Log warning if fewer than 2 peers confirm.

### 6.4 State Rebuild

After sync, the PBSS StateStore is rebuilt directly from the tip block's frontier state root via CAS resolution:

1. Resolve tip block's `frontier` → `LatticeState`
2. Resolve `accountState` MerkleDictionary recursively
3. Enumerate all key-value pairs (address → balance)
4. Bulk-write to StateStore's `account:` paths
5. Populate block index from persisted block metadata

This is O(accounts) — resolving the final state once — rather than O(blocks × changes) from replaying every block's changeset. Falls back to block-by-block replay if CAS resolution fails.

---

## 7. Mining

### 7.1 Block Template Construction

1. Resolve current chain tip
2. Select up to `maxTransactionsPerBlock - 1` transactions from mempool (fee descending)
3. Build coinbase transaction (reward + fees → miner address)
4. Build child chain blocks for merged mining
5. Compute next difficulty
6. Assemble block template with nonce=0

### 7.2 Proof-of-Work Search

Parallel nonce search using `(CPU cores - 1)` workers. Each worker searches a disjoint nonce range. First valid nonce cancels all other workers. Nonce offset advances monotonically across rounds.

### 7.3 Block Submission

On finding valid nonce:
1. Store block recursively in CAS
2. Publish to network
3. Process locally (update chain state)
4. Remove confirmed transactions from both mempools
5. Update block index and StateStore
6. Persist chain state if interval reached

---

## 8. RPC API

### 8.1 Chain

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chain/info` | GET | Chain status (height, tip, mining, mempool) |
| `/api/chain/spec` | GET | Chain specification parameters |

### 8.2 Accounts

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/balance/{address}` | GET | Account balance |
| `/api/nonce/{address}` | GET | Account nonce |
| `/api/proof/{address}` | GET | Merkle balance proof |

### 8.3 Blocks

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/block/latest` | GET | Latest block info |
| `/api/block/{id}` | GET | Block by hash or height |

### 8.4 Transactions

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/transaction` | POST | Submit transaction |
| `/api/receipt/{txCID}` | GET | Transaction receipt |
| `/api/mempool` | GET | Mempool stats |

### 8.5 Fee Market

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/fee/estimate?target=N` | GET | Fee estimate for N-block confirmation |
| `/api/fee/histogram` | GET | Fee distribution histogram |

### 8.6 DEX (Batch Auction)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/orders` | GET | Active orders |
| `/api/orders` | POST | Place order |
| `/api/orders/commit` | POST | Commit order hash (MEV protection) |
| `/api/orders/reveal` | POST | Reveal committed order |

### 8.7 Light Client

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/light/headers?from=X&to=Y` | GET | Block headers for sync |
| `/api/light/proof/{address}` | GET | Account proof with chain context |

### 8.8 Network

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/peers` | GET | Connected peer list |

### 8.9 Observability

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/metrics` | GET | Prometheus metrics |
| `/ws` | GET | WebSocket subscriptions (planned) |

### 8.10 Authentication

When `--rpc-auth` is enabled, a random 32-byte hex token is written to `<dataDir>/.cookie`. All requests must include `Authorization: Bearer <token>`.

---

## 9. Nexus Chain Parameters

| Parameter | Value |
|-----------|-------|
| Directory | Nexus |
| Target block time | 10,000 ms (10 seconds) |
| Initial reward | 1,048,576 |
| Halving interval | 17,592,186,044,416 blocks |
| Max transactions/block | 5,000 |
| Max state growth | 3,000,000 bytes/block |
| Max block size | 10,000,000 bytes |
| Premine | 3,518,437,208,883 blocks (~10% of total supply) |
| Difficulty adjustment window | 120 blocks (~20 minutes) |
| Genesis timestamp | 1,742,601,600,000 (March 22, 2025 UTC) |
| Genesis hash | `baguqeeraaw3cs4er3kqa5l3vng4hohn5axtnu2bl77mndbjz7vnf3q3wa5qa` |

---

## 10. Security Considerations

### 10.1 Replay Protection
Nonce must be within ±600 blocks of current height. Transactions expire from mempool after 600 seconds.

### 10.2 Balance Verification
Every AccountAction claims an `oldBalance` that is verified against current state. Conservation law enforced: debits = credits + fee.

### 10.3 Overflow Protection
All fee/balance arithmetic uses overflow-checking operations. Overflow returns validation failure.

### 10.4 Fee Bounds
Min fee: 1. Max fee: 1,000,000,000,000. Prevents both spam (min) and overflow attacks (max).

### 10.5 Block Rate Limiting
Max 20 blocks per peer per 10-second window. Oversized blocks (> maxBlockSize) rejected with reputation penalty.

### 10.6 Timestamp Validation
Block timestamps must be within ±2 hours of node's local time.

### 10.7 MEV Protection
The batch auction mechanism prevents front-running of DEX orders through commit-reveal with a 3-block auction window. Orders are committed as hashes, revealed after the window, and settled at midpoint prices.

---

## 11. Node Architecture

```
┌─────────────────────────────────────────────────────┐
│  CLI (swift-argument-parser)                         │
│  node | devnet | cluster | keys | status | query     │
├─────────────────────────────────────────────────────┤
│  Daemon                                              │
│  Signal handling, background loops, lifecycle        │
├──────────┬──────────┬───────────┬───────────────────┤
│  Chain   │  Mempool │  Network  │  RPC              │
│  Blocks  │  NodeMem │  Ivy P2P  │  Hummingbird HTTP │
│  Sync    │  Validat │  Peers    │  Auth             │
│  State   │  Persist │  Diversity│  Prometheus       │
│  Persist │  RBF     │  Anchors  │  WebSocket (plan) │
├──────────┼──────────┼───────────┼───────────────────┤
│  Mining  │  Storage │  Config   │  Health           │
│  PoW     │  PBSS    │  NodeConf │  Logger           │
│  Merged  │  SQLite  │  Resource │  Metrics          │
│  Parallel│  CAS     │           │                   │
├──────────┴──────────┴───────────┴───────────────────┤
│  Lattice (external): Consensus, ChainState, Blocks   │
│  Ivy (external): P2P, DHT, Tally                     │
│  Acorn (external): Content-Addressed Storage          │
└─────────────────────────────────────────────────────┘
```

---

## 12. Future Considerations

- **Per-account sequential nonces**: Replace height-based nonces with account-sequential for proper replay protection
- **EIP-1559 dynamic fee market**: Algorithmic base fee with priority tip and fee burning
- **Block DAG**: Process orphan blocks (GhostDAG/DAGKnight) instead of discarding them
- **Cluster mempool**: Group related transactions for optimal block building
- **Erasure-coded propagation**: Reed-Solomon encoding for bandwidth-efficient block relay
- **Verkle tree state proofs**: Smaller proofs for stateless client verification
- **WebSocket subscriptions**: Real-time block/transaction event streaming
- **Formal verification**: Model consensus rules in proof assistant

---

*Protocol Version: 1*
*Specification Version: 0.1.0*
*Last Updated: March 2026*
