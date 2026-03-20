# LatticeNode

Multi-chain node client for the Lattice blockchain with merged mining.

## Quick Start

```bash
# Build
swift build -c release

# Run with mining enabled
swift run LatticeNode --mine Nexus

# Run with custom port and bootstrap peer
swift run LatticeNode --port 4002 --peer <pubkey>@192.168.1.10:4001 --mine Nexus
```

## How It Works

LatticeNode boots from the hardcoded nexus genesis block and participates in the Lattice network via Ivy P2P. A single mining loop on the nexus chain produces blocks that automatically benefit all child chains through merged mining — no separate miner per chain.

### Merged Mining

1. The MinerLoop mines blocks against the nexus difficulty target
2. When a block is found, `Lattice.processBlockHeader` checks if it meets nexus difficulty
3. If accepted on nexus, embedded child blocks are extracted and submitted to their chains
4. If the block doesn't meet nexus difficulty but meets a child's lower target, it's offered to child chains

One hash search, every chain benefits.

### Child Chain Discovery

When a `GenesisAction` in a nexus block creates a new child chain, the node automatically:
1. Detects the new directory in the chain hierarchy (polled every 5 seconds)
2. Registers a new P2P network on the next available port
3. Begins participating in that child chain's gossip

### Persistence

Chain state is persisted to disk every 100 blocks and on graceful shutdown. On restart, the node restores all chain states from `<data-dir>/<chain>/chain_state.json`.

## CLI Options

| Flag | Default | Description |
|------|---------|-------------|
| `--port <N>` | 4001 | P2P listen port |
| `--data-dir <path>` | `~/.lattice` | Storage directory |
| `--peer <pubKey@host:port>` | none | Bootstrap peer (repeatable) |
| `--mine <chain>` | none | Start mining chain on boot (repeatable) |
| `--no-discovery` | enabled | Disable mDNS local discovery |

## Interactive Commands

| Command | Description |
|---------|-------------|
| `mine start [chain]` | Start mining (default: Nexus) |
| `mine stop [chain]` | Stop mining |
| `mine list` | Show which chains are being mined |
| `status` | Chain heights, tips, mining status, mempool counts |
| `chains` | List registered chain directories |
| `peers` | Connected peer count |
| `quit` | Graceful shutdown with state persistence |

## Architecture

```
LatticeNode (CLI)
  └─ LatticeNode (actor)
       ├─ Lattice (actor)
       │    └─ ChainLevel: Nexus
       │         ├─ ChainState
       │         └─ children
       │              ├─ ChainLevel: Child1
       │              └─ ChainLevel: Child2
       ├─ ChainNetwork per chain
       │    ├─ Ivy (P2P)
       │    ├─ AcornFetcher (CAS)
       │    └─ Mempool
       ├─ MinerLoop per mining chain
       └─ ChainStatePersister per chain
```

## Dependencies

All from [treehauslabs](https://github.com/treehauslabs):

- **Lattice** — Core blockchain protocol
- **Ivy** — Trust-line DHT P2P networking
- **Acorn** — Content-addressed storage
- **AcornDiskWorker** — Persistent disk CAS
- **Tally** — Peer reputation scoring
- **cashew** — Merkle data structures
