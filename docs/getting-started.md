# Getting Started with Lattice Node

## Installation

### From Source (macOS)

```bash
git clone https://github.com/treehauslabs/lattice-node.git
cd lattice-node
swift build -c release
```

The binary is at `.build/release/LatticeNode`.

### Docker

```bash
docker pull ghcr.io/treehauslabs/lattice-node:main
docker run -v lattice-data:/home/lattice/.lattice ghcr.io/treehauslabs/lattice-node:main
```

## Quick Start

### Run a Node

```bash
# Join the Nexus network and start mining
lattice-node --mine Nexus --autosize

# Or with explicit resource settings
lattice-node --mine Nexus --memory 0.5 --disk 20 --rpc-port 8080
```

The node will:
1. Generate a keypair (stored in `~/.lattice/identity.json`)
2. Connect to bootstrap peers
3. Sync the chain
4. Start mining

### Generate Keys

```bash
# Generate a new keypair
lattice-node keys generate

# Save to file
lattice-node keys generate --output my-key.json

# Derive address from public key
lattice-node keys address <public-key-hex>
```

### Local Development Network

```bash
# Start a single-node devnet with fast blocks
lattice-node devnet --mining --block-time 1000 --rpc-port 8080

# Start a 3-node cluster
lattice-node cluster --nodes 3 --mine Nexus --base-port 4001
```

### Query the Chain

```bash
# Chain status
curl http://localhost:8080/api/chain/info

# Account balance
curl http://localhost:8080/api/balance/<address>

# Latest block
curl http://localhost:8080/api/block/latest

# Fee estimate
curl http://localhost:8080/api/fee/estimate?target=5

# Prometheus metrics
curl http://localhost:8080/metrics
```

### Submit a Transaction

```bash
curl -X POST http://localhost:8080/api/transaction \
  -H "Content-Type: application/json" \
  -d '{"signatures": {"<pubkey>": "<sig>"}, "bodyCID": "<cid>", "bodyData": "<hex>"}'
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `lattice-node` | Run the node daemon (default) |
| `lattice-node node [options]` | Run with explicit options |
| `lattice-node devnet [options]` | Local development network |
| `lattice-node cluster [options]` | Multi-node cluster |
| `lattice-node keys generate` | Generate keypair |
| `lattice-node keys show <file>` | Show key info |
| `lattice-node keys address <pubkey>` | Derive address |
| `lattice-node status` | Show persisted chain status |
| `lattice-node query <expr>` | Query chain state |
| `lattice-node init <name>` | Scaffold new project |

### Node Options

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | 4001 | P2P listen port |
| `--data-dir` | ~/.lattice | Storage directory |
| `--peer <key@host:port>` | — | Bootstrap peer (repeatable) |
| `--mine <chain>` | — | Mine chain on boot (repeatable) |
| `--rpc-port <port>` | — | Enable RPC server |
| `--rpc-auth` | off | Cookie-based RPC authentication |
| `--autosize` | off | Auto-detect system resources |
| `--memory <GB>` | 0.25 | CAS memory cache |
| `--disk <GB>` | 1.0 | CAS disk storage |
| `--no-discovery` | off | Disable mDNS |
| `--no-dns-seeds` | off | Disable DNS seed resolution |
| `--tor` | off | Route P2P through Tor |

## Data Directory

```
~/.lattice/
├── identity.json          # Node keypair
├── peers.json             # Known peers
├── anchors.json           # Anchor peers for eclipse protection
├── mempool.json           # Persisted pending transactions
├── .cookie                # RPC auth token (if --rpc-auth)
├── health                 # Health status file
└── Nexus/
    ├── chain_state.json   # Chain consensus state
    ├── state.db           # PBSS SQLite database
    └── disk-worker/       # CAS block/state storage
```
