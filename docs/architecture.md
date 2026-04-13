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
│  Mining  │  Storage │  Config   │  Health           │
│  PoW     │  PBSS    │  NodeConf │  Logger           │
│  Merged  │  SQLite  │  Protocol │  Metrics          │
│  Parallel│  CAS     │  Version  │                   │
├──────────┴──────────┴───────────┴───────────────────┤
│  Lattice (external): Consensus, ChainState, Blocks,   │
│    Exchange (Order Book, Matching, Swap/Settle/Claim)  │
│  Ivy (external): P2P, DHT, Tally                     │
│  Acorn (external): Content-Addressed Storage          │
│  cashew (external): Merkle trees, CAS diffing         │
└─────────────────────────────────────────────────────┘
```

## CAS-First Principle

The Content-Addressed Storage (CAS) is the single source of truth. All other storage is derived:

| Layer | What it stores | Derived from |
|-------|---------------|--------------|
| CAS (Acorn) | Blocks, transactions, state trees | Original data |
| PBSS (SQLite) | Account balances, block index | CAS frontier state |
| Mempool persistence | Transaction CIDs | CAS tx bodies |
| Receipt index | txCID → blockHash | CAS block data |

## Data Flow

### Block Acceptance
```
Block received (CID announcement or full push)
  → CAS resolution (memory → disk → network)
  → PoW validation
  → State update via CAS diff (homestead → frontier)
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
  → CAS diff each orphaned block (frontier → homestead)
  → Roll back StateStore account balances
  → Collect new chain's confirmed tx CIDs
  → Remove confirmed txs from both mempools
  → Re-validate orphaned txs against new state
  → Add valid txs to both mempools
```

## Key Design Decisions

1. **CAS diffing over transaction replay**: State changes derived from merkle tree diffs, not by re-executing transactions. Correct by construction.

2. **Hybrid block propagation**: Full push to direct peers (availability), CID-only for relay (bandwidth).

3. **Two-tier receipts**: Full receipt for recent blocks, CAS-derived for historical.

4. **Dual mempool**: NodeMempool (fee-ordered, for mining) alongside Ivy Mempool (for network compatibility). Both kept in sync.

5. **PBSS as cache**: SQLite provides O(1) reads; CAS is authoritative. PBSS rebuilt from CAS after sync.
