# Lattice Node Operations Runbook

## Health Monitoring

### Endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Liveness check: status, height, peers, syncing, uptime |
| `GET /metrics` | Prometheus-format metrics for Grafana/alerting |
| `GET /api/chain/info` | Full chain state: all chains, heights, tips |

### Key Metrics (Prometheus)

| Metric | Type | Alert When |
|--------|------|------------|
| `lattice_chain_height{chain="..."}` | gauge | Stale > 5 min |
| `lattice_peer_count` | gauge | < 1 (isolated) |
| `lattice_sync_active` | gauge | = 1 for > 10 min |
| `lattice_mempool_size{chain="..."}` | gauge | > 10000 (backlog) |
| `lattice_blocks_accepted_total` | counter | Rate = 0 for > 5 min |
| `lattice_chain_count` | gauge | Decreases unexpectedly |

### Health Check Status Values

- `ok` — at least 1 connected peer
- `degraded` — 0 peers (cannot receive or send blocks)

## RPC Rate Limiting

Built-in token-bucket rate limiter: 50 req/s per IP, burst of 100.
Uses `X-Forwarded-For` or `X-Real-IP` headers behind a reverse proxy.
Returns HTTP 429 with `Retry-After: 1` when exceeded.

## Common Operations

### Start a Node

```bash
LatticeNode node \
  --port 4001 \
  --rpc-port 8080 \
  --data-dir /data/lattice \
  --peer pubkey@host:port
```

### Subscribe to a Child Chain

```bash
LatticeNode node --subscribe Nexus/Payments ...
```

### Deploy a Child Chain

```bash
curl -X POST http://localhost:8080/api/chain/deploy \
  -H 'Content-Type: application/json' \
  -d '{"directory":"Payments","parentDirectory":"Nexus",...}'
```

## Recovery Procedures

### Symptom: Node Won't Start (Corrupt State)

1. Stop the node
2. Back up the data directory: `cp -r /data/lattice /data/lattice.bak`
3. Delete the chain state file (preserves CAS data):
   ```bash
   rm /data/lattice/Nexus/chain_state.json
   rm /data/lattice/*/chain_state.json  # child chains
   ```
4. Restart — the node restores chain state from CAS by walking blocks backward from the SQLite tip

### Symptom: Node Stuck Syncing

1. Check `/health` — is `syncing: true`?
2. Check `/metrics` — is `lattice_sync_active` stuck at 1?
3. Check logs for `Sync failed` or `notFound` errors
4. If peers are connected but sync fails, the peer may have pruned the blocks. Try adding more peers.
5. If no peers: verify port is reachable, check `--peer` arguments

### Symptom: Chain Height Stalled

1. Check if mining is active: `lattice_mining_active` metric
2. Check peer count — mining requires at least 1 peer for block propagation
3. Check mempool: if full (`lattice_mempool_size` at cap), transactions may be rejected
4. If mining is active but height doesn't advance, check difficulty — initial difficulty may be too high

### Full Wipe and Resync

Use when the node's state is unrecoverable:

```bash
# Stop the node
kill $(pgrep LatticeNode)

# Remove all data (chain state + CAS + SQLite)
rm -rf /data/lattice

# Restart with a bootstrap peer — the node will sync from genesis
LatticeNode node --data-dir /data/lattice --peer pubkey@host:port
```

The node creates a fresh genesis, syncs from the peer, and rebuilds all state.
For child chains, add `--subscribe Nexus/ChildName` to discover and sync them.

### Partial State Rebuild (Preserve CAS)

If SQLite is corrupted but the CAS (Volume broker) is intact:

```bash
# Back up
cp -r /data/lattice /data/lattice.bak

# Remove only SQLite state stores (preserve the broker.db)
rm /data/lattice/state_*.db
rm /data/lattice/*/chain_state.json

# Restart — CAS recovery replays blocks from broker
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RETENTION_DEPTH` | 1000 | Blocks kept before pruning |
| `PIN_ANNOUNCE_EXPIRY` | 86400 | Pin announcement TTL (seconds) |
| `REANNOUNCE_INTERVAL` | 86400 | Reannounce pinned CIDs interval (seconds) |
| `EVICTION_INTERVAL` | 21600 | Expired pin eviction interval (seconds) |

## Security

- Enable RPC auth for production: `--rpc-auth` (generates cookie file)
- Rate limiting is always active (50 req/s per IP)
- Place behind a reverse proxy (nginx/caddy) for TLS
- P2P port (default 4001) should be open; RPC port should be firewalled to trusted IPs
