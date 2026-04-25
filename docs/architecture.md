# Lattice Node Architecture

## Overview

Lattice is a proof-of-work blockchain with native multi-chain support. The Nexus chain is the root of a tree of child chains, each with independent state and economics, sharing security through merged mining.

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
│  Persist │  RBF     │  Anchors  │  Receipts         │
├──────────┼──────────┼───────────┼───────────────────┤
│  Mining  │  Storage      │  Config   │  Health           │
│  PoW     │  DiskBroker   │  NodeConf │  Logger           │
│  Merged  │  MemoryBroker │  Protocol │  Metrics          │
│  Parallel│  SQLite/PBSS  │  Version  │                   │
├──────────┴───────────────┴───────────┴───────────────────┤
│  Lattice (external): Consensus, ChainState, Blocks,       │
│    Exchange (Order Book, Matching, Swap/Settle/Claim)      │
│  Ivy (external): P2P, DHT, Tally                         │
│  VolumeBroker (external): DiskBroker, MemoryBroker, Pins  │
│  cashew (external): Merkle trees, BrokerStorer/Fetcher    │
└───────────────────────────────────────────────────────────┘
```

## CAS-First Principle

The Content-Addressed Storage (CAS) is the single source of truth. All other storage is derived.

The broker cascade for each chain is: per-chain **MemoryBroker** (LRU) -> shared **DiskBroker** (SQLite, Volume-granular) -> **IvyBroker** (network). The DiskBroker is shared across all chains; each chain only has its own MemoryBroker. Pins are ref-counted with owner tags (e.g., `chain:height`), and two retention policies control when data is unpinned:

- **BlockRetention** (tip / retention / historical) -- governs block data lifetime.
- **StorageMode** (stateless / stateful / historical) -- governs state root lifetime via StateDiff.

| Layer | What it stores | Derived from |
|-------|---------------|--------------|
| MemoryBroker (per-chain LRU) | Hot blocks, recent state | DiskBroker |
| DiskBroker (shared SQLite) | All pinned blocks, transactions, state trees | Original data |
| IvyBroker (network) | Remote block/state data | Peers |
| PBSS (SQLite) | Account balances, block index | DiskBroker frontier state |
| Mempool persistence | Transaction CIDs | DiskBroker tx bodies |
| Receipt index | txCID -> blockHash | DiskBroker block data |

## Data Flow

### Block Acceptance
```
Block received (inline via topic message)
  → Broker resolution (MemoryBroker → DiskBroker → IvyBroker)
  → PoW validation
  → State update via CAS diff (homestead → frontier)
  → Pin block data in DiskBroker with owner tag
  → Unpin replaced state roots per StorageMode (StateDiff)
  → PBSS StateStore updated
  → Receipt index written
  → Metrics incremented
  → Subscription events emitted
  → Peer reputation updated (Tally)
```

### Transaction Lifecycle
```
Submit via RPC
  → Validate (signatures, fees, nonces, balances)
  → Add to NodeMempool (fee-ordered) + Mempool (Ivy)
  → Store tx body in CAS
  → Announce CID to peers
  → Selected by miner (highest fee first)
  → Included in block → confirmed
  → Removed from both mempools
```

### Reorg Recovery
```
New tip diverges from old tip
  → Walk back to common ancestor
  → CAS diff each orphaned block via DiskBroker (frontier → homestead)
  → Roll back StateStore account balances
  → Unpin orphaned block data; pin new chain's blocks
  → Collect new chain's confirmed tx CIDs
  → Remove confirmed txs from both mempools
  → Re-validate orphaned txs against new state
  → Add valid txs to both mempools
```

## Key Design Decisions

1. **CAS diffing over transaction replay**: State changes derived from merkle tree diffs, not by re-executing transactions. Correct by construction.

2. **Inline block propagation**: Block data is sent inline via topic messages, eliminating the round-trip fetch peers previously needed.

3. **Two-tier receipts**: Full receipt for recent blocks, CAS-derived for historical.

4. **Dual mempool**: NodeMempool (fee-ordered, for mining) alongside Ivy Mempool (for network compatibility). Both kept in sync.

5. **PBSS as cache**: SQLite provides O(1) reads; the shared DiskBroker is authoritative. PBSS rebuilt from DiskBroker after sync.

### Crash Recovery
```
Node starts with existing data directory
  → Restore chain state from chain_state.json (may be stale)
  → Read authoritative tip from SQLite (crash-safe via WAL)
  → If SQLite tip > chain state tip:
      Walk backwards through DiskBroker from SQLite tip to chain state tip
      Replay missing blocks forward via processBlockHeader
      Persist recovered chain state
  → Resume normal operation at full height
```

Pinned data in the shared DiskBroker is crash-safe (SQLite WAL), and the PBSS state store updates on every block acceptance. Only `chain_state.json` can be stale (written every `persistInterval` blocks). This means any blocks confirmed between the last persist and an ungraceful shutdown are recoverable from the DiskBroker without peers.
