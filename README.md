# LatticeNode

A full node for the Lattice blockchain — a hierarchical multi-chain network where a single proof-of-work secures every chain in the tree.

## Why Lattice exists

Most blockchains force a choice: one chain with high security and congestion, or many chains with fragmented hash power and weak guarantees. Lattice eliminates this tradeoff through a chain hierarchy. A root chain called Nexus sits at the top. Any transaction on Nexus can spawn a child chain, and those children can spawn their own. Every chain in the tree inherits the proof-of-work of its ancestors through merged mining — one hash search, performed once, secures the entire hierarchy.

This means new chains are cheap to create, require zero additional mining infrastructure, and are secured from block one by the full weight of the Nexus hash rate.

## Design decisions

### Merged mining over sharding

Sharded architectures split validators across partitions, weakening each shard's security proportionally. Lattice takes the opposite approach: every miner searches a single nonce space, and any valid proof is applied to every chain whose difficulty target it satisfies. A block that doesn't meet Nexus difficulty may still meet a child chain's lower target, so no work is wasted. The security of every chain is bounded by the total network hash rate, not a fraction of it.

### Dynamic child chain discovery

Child chains are not hardcoded. When a `GenesisAction` appears in a Nexus block, each node detects the new chain directory (polled every 5 seconds), assigns it a deterministic P2P port, and begins participating in gossip — no restart, no configuration change. This makes chain creation a protocol-level primitive rather than a governance event.

### Content-addressed storage throughout

Blocks and transactions are stored and referenced by their content hash (CID), not by location. This makes the storage layer naturally deduplicating and verifiable: if you have a CID, you can fetch the data from any peer and prove it's correct without trusting the source. The node uses a three-tier CAS hierarchy — memory, disk, then network — so hot data stays fast and cold data is still reachable.

### Actor-based concurrency

The node is built on Swift's structured concurrency model. `LatticeNode`, `ChainNetwork`, and `MinerLoop` are all actors with isolated state. There are no locks, no shared mutable memory, and no thread pools to tune. Each chain gets its own network actor and its own storage pipeline, so chains cannot block each other.

### Reputation-aware networking

Peers are not treated equally. The Ivy P2P layer tracks trust lines, and Tally scores peer behavior over time. Misbehaving peers — those sending invalid blocks, flooding announcements, or failing to serve data — are rate-limited and eventually disconnected. This makes the network protocol itself resistant to eclipse attacks and resource exhaustion without requiring proof-of-stake or bonding.

### Cross-chain replay protection

Every transaction includes a `chainPath` — a list of directory names from the nexus root to the target chain (e.g., `["Nexus"]` or `["Nexus", "Payments"]`). Since the chain path is part of the content-addressed transaction body, it is implicitly covered by the signature. The node rejects any transaction whose `chainPath` does not match the validating chain's position in the hierarchy. This prevents a transaction valid on one chain from being replayed on another.

### Sequential nonce enforcement

Transactions carry a `nonce` field. Transactions from the same signer group must use sequential nonces starting from 0, with no gaps. The consensus layer tracks the latest confirmed nonce per signer group in the transaction state merkle tree. The mempool applies a softer check, allowing a bounded window of future nonces to support concurrent submission.

### Resource-aware by default

The node autosizes to its host. On startup, it inspects available RAM and disk, then allocates 25% of memory and 50% of free disk across all subscribed chains. Operators on constrained hardware don't need to calculate buffer sizes — the node adapts. Explicit resource presets (`light`, `default`, `heavy`) and per-resource flags are available when fine-grained control is needed.

## Quick start

```bash
swift build -c release

# Run a mining node
swift run LatticeNode --mine Nexus

# Join an existing network
swift run LatticeNode --port 4002 --peer <pubkey>@192.168.1.10:4001 --mine Nexus
```

## How it works

LatticeNode boots from a hardcoded Nexus genesis block and connects to the network via Ivy P2P. From there:

1. **Mining.** `MinerLoop` assembles a candidate block from mempool transactions (up to 5,000 per block), embeds pending child-chain blocks, and searches for a nonce satisfying the difficulty target. When a valid proof is found, the block is published to the network. If the proof doesn't meet Nexus difficulty but satisfies a child chain's lower target, it is submitted to that child chain instead.

2. **Block validation.** Incoming blocks are checked for valid proof-of-work (with 0x00 field-separated hash inputs), timestamp bounds (within 2 hours of median-time-past), size limits (10 MB), secp256k1 ECDSA signature authenticity, sequential nonce ordering per signer group, and chain path correctness. Peer reputation gates how many blocks are accepted per time window.

3. **Chain reorganization.** When a longer valid chain is observed, orphaned blocks are detected and their fee-paying transactions are recovered to the mempool. Coinbase transactions are discarded since they're only valid in their original block context.

4. **Synchronization.** When a peer is more than 2,000 blocks ahead, the node triggers a sync. Two strategies are available: full sync (download every block) and snapshot sync (download recent state only). Strategy selection is automatic based on how far behind the node is.

5. **Persistence.** Chain state is serialized to `<data-dir>/<chain>/chain_state.json` every 100 blocks and on graceful shutdown. The SQLite state store (`state.db`) is updated on every block and is crash-safe via WAL. CAS files are written to disk immediately. On restart, the node walks the data directory and restores all chains — including children discovered in prior sessions. If the node crashed, CAS-based recovery detects any gap between the stale `chain_state.json` and the authoritative SQLite tip, then replays the missing blocks from CAS to bring the chain state current.

6. **Peer sync on connect.** When a new peer connects, the node announces its chain tip for each subscribed chain. If the peer is behind, this triggers synchronization without waiting for the next mined block.

## Architecture

```
LatticeNode (CLI entry point)
  └─ LatticeNode (actor — coordinator)
       ├─ Lattice (actor — chain hierarchy)
       │    └─ ChainLevel: Nexus
       │         ├─ ChainState
       │         └─ children
       │              ├─ ChainLevel: Payments
       │              └─ ChainLevel: Identity
       ├─ ChainNetwork (actor — one per chain)
       │    ├─ Ivy         — P2P gossip and DHT routing
       │    ├─ AcornFetcher — CAS: memory → disk → network
       │    ├─ Mempool     — pending transactions
       │    └─ Tally       — peer reputation scoring
       ├─ MinerLoop (actor — one per mined chain)
       └─ ChainStatePersister (one per chain)
```

## RPC API

The node exposes a JSON API over HTTP (default port 8080) for programmatic access.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chain/info` | GET | Chain height, tip hash, difficulty |
| `/api/chain/spec` | GET | Genesis parameters |
| `/api/block/latest` | GET | Most recent block |
| `/api/block/{index\|hash}` | GET | Block by height or hash |
| `/api/balance/{address}` | GET | Account balance |
| `/api/proof/{address}` | GET | Sparse Merkle proof for light clients |
| `/api/transaction` | POST | Submit a signed transaction |
| `/api/mempool` | GET | Pending transaction pool |
| `/api/swaps` | GET | Active swap state |
| `/api/peers` | GET | Connected peer count |

## CLI reference

### Startup flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port <N>` | 4001 | P2P listen port |
| `--rpc-port <N>` | 8080 | HTTP API port |
| `--data-dir <path>` | `~/.lattice` | Storage directory |
| `--peer <pubKey@host:port>` | — | Bootstrap peer (repeatable) |
| `--mine <chain>` | — | Begin mining on boot (repeatable) |
| `--subscribe <path>` | Nexus | Subscribe to a chain path, e.g. `Nexus/Payments` (repeatable) |
| `--autosize` | off | Auto-allocate memory and disk based on host capacity |
| `--memory <MB>` | 256 | Memory budget |
| `--disk <MB>` | 1024 | Disk budget |
| `--no-discovery` | — | Disable mDNS local peer discovery |

### Interactive commands

| Command | Description |
|---------|-------------|
| `mine start [chain]` | Start mining (default: Nexus) |
| `mine stop [chain]` | Stop mining |
| `mine list` | Show active miners |
| `status` | Chain heights, tips, mining state, mempool depth |
| `chains` | List all registered chain paths |
| `subscribe <path>` | Subscribe to a chain |
| `unsubscribe <path>` | Unsubscribe from a chain |
| `subscriptions` | List current subscriptions |
| `peers` | Connected peer count |
| `quit` | Persist state and shut down |

## Deployment

### Docker

```bash
docker build -t lattice-node .
docker run -d --name lattice-miner \
  -p 4001:4001 -p 8080:8080 \
  -v lattice-data:/home/lattice/.lattice \
  lattice-node
```

The image uses a multi-stage build: Swift 6 compiles a static binary, which runs in a minimal Ubuntu 22.04 runtime. A built-in health check monitors `<data-dir>/health` for block recency.

For a 3-node bootstrap cluster:

```bash
docker compose up -d
```

### Bare metal (Linux)

```bash
# Install Swift 6: https://swift.org/install
git clone https://github.com/treehauslabs/lattice-node.git
cd lattice-node
swift build -c release
sudo cp .build/release/LatticeNode /usr/local/bin/lattice-node

sudo useradd -r -s /bin/false lattice
sudo mkdir -p /var/lib/lattice
sudo chown lattice:lattice /var/lib/lattice

sudo cp deploy/lattice-node.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lattice-node
```

### Fly.io

A `deploy/fly/fly.toml` is included for single-command deployment to Fly.io with auto-extending persistent volumes.

### Terraform

`deploy/terraform/` contains Hetzner Cloud infrastructure definitions with cloud-init bootstrapping for automated multi-node provisioning.

### Bootstrapping a network

Start the first node and note its public key (printed at boot). Connect additional nodes by passing `--peer`:

```bash
# Node 1 (first miner)
lattice-node --mine Nexus

# Node 2
lattice-node --mine Nexus --peer <node1-pubkey>@<node1-ip>:4001

# Node 3
lattice-node --mine Nexus \
  --peer <node1-pubkey>@<node1-ip>:4001 \
  --peer <node2-pubkey>@<node2-ip>:4001
```

Nodes discover additional peers through the DHT after initial bootstrap.

## Nexus genesis parameters

| Parameter | Value |
|-----------|-------|
| Block time target | 10 seconds |
| Max transactions per block | 5,000 |
| Max block size | 10 MB |
| Initial block reward | 2^20 (1,048,576) |
| Halving interval | 2^44 blocks |
| Difficulty adjustment window | 120 blocks |
| State growth limit | 3 MB per block |

## Dependencies

All from [treehauslabs](https://github.com/treehauslabs):

| Library | Role |
|---------|------|
| **Lattice** | Core blockchain protocol — chain state, block validation, consensus rules, secp256k1 ECDSA |
| **Ivy** | Trust-line DHT for peer discovery, gossip, and authenticated routing |
| **Acorn** | Content-addressed storage interface |
| **AcornDiskWorker** | Persistent on-disk CAS backend |
| **Tally** | Peer reputation scoring and rate limiting |
| **cashew** | Merkle tree and sparse Merkle proof construction |

Additional: [swift-nio](https://github.com/apple/swift-nio) for the HTTP transport layer.
