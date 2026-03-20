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
| `--subscribe <path>` | Nexus | Subscribe to chain path, e.g. `Nexus/Payments` (repeatable) |
| `--no-discovery` | enabled | Disable mDNS local discovery |

## Interactive Commands

| Command | Description |
|---------|-------------|
| `mine start [chain]` | Start mining (default: Nexus) |
| `mine stop [chain]` | Stop mining |
| `mine list` | Show which chains are being mined |
| `status` | Chain heights, tips, mining status, mempool counts |
| `chains` | List registered chain directories |
| `subscribe <path>` | Subscribe to a chain path (e.g. `Nexus/Payments`) |
| `unsubscribe <path>` | Unsubscribe from a chain path |
| `subscriptions` | List subscribed chain paths |
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

## Deployment

### Docker (recommended)

```bash
# Build and run a single miner
docker build -t lattice-node .
docker run -d --name lattice-miner \
  -p 4001:4001 \
  -v lattice-data:/home/lattice/.lattice \
  lattice-node

# Run 3 bootstrap miners
docker compose up -d
```

The Docker image uses a multi-stage build: Swift 6 compiles a static binary, which runs on a minimal Ubuntu 22.04 runtime image.

### Bare metal (Linux)

```bash
# Install Swift 6 (https://swift.org/install)
git clone https://github.com/treehauslabs/lattice-node.git
cd lattice-node
swift build -c release
sudo cp .build/release/LatticeNode /usr/local/bin/lattice-node

# Create service user and data directory
sudo useradd -r -s /bin/false lattice
sudo mkdir -p /var/lib/lattice
sudo chown lattice:lattice /var/lib/lattice

# Install and start systemd service
sudo cp deploy/lattice-node.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable lattice-node
sudo systemctl start lattice-node

# Check logs
journalctl -u lattice-node -f
```

### Bootstrap network

Run 2-3 nodes on different servers. Once the first node starts, note its public key (printed at boot). Connect additional nodes:

```bash
# Node 2 connects to Node 1
lattice-node --mine Nexus --port 4001 \
  --peer <node1-pubkey>@<node1-ip>:4001

# Node 3 connects to both
lattice-node --mine Nexus --port 4001 \
  --peer <node1-pubkey>@<node1-ip>:4001 \
  --peer <node2-pubkey>@<node2-ip>:4001
```

### Chain subscriptions

Subscribe to specific chains in the hierarchy:

```bash
# Mine nexus and participate in Payments chain
lattice-node --mine Nexus \
  --subscribe Nexus/Payments \
  --subscribe Nexus/Payments/US
```

## Dependencies

All from [treehauslabs](https://github.com/treehauslabs):

- **Lattice** — Core blockchain protocol
- **Ivy** — Trust-line DHT P2P networking
- **Acorn** — Content-addressed storage
- **AcornDiskWorker** — Persistent disk CAS
- **Tally** — Peer reputation scoring
- **cashew** — Merkle data structures
