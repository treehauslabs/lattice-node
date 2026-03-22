# Deploying Lattice Bootstrap Miners

## Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) installed
2. [Hetzner Cloud account](https://console.hetzner.cloud) with an API token
3. SSH key pair (`~/.ssh/id_ed25519.pub`)
4. `jq` installed (`brew install jq`)

## Quick Start (one command)

```bash
export TF_VAR_hcloud_token="your-hetzner-token"
./deploy/bootstrap.sh deploy
```

This will:
1. Create 3 servers across US-East, EU, and US-West (~$4.50/mo each)
2. Wait for Docker and the miner to start on each node
3. Extract each node's public key
4. Restart each node with `--peer` flags pointing to the others
5. Print the `BootstrapPeers.swift` code to hardcode into the binary

## Commands

| Command | Description |
|---------|-------------|
| `bootstrap.sh deploy` | Full deploy: terraform + wait + peer |
| `bootstrap.sh peer` | Re-extract keys and reconnect existing nodes |
| `bootstrap.sh status` | Show status of all nodes |
| `bootstrap.sh codegen` | Print BootstrapPeers.swift snippet |
| `bootstrap.sh codegen --apply` | Write BootstrapPeers.swift directly |
| `bootstrap.sh update` | Pull latest Docker image on all nodes |
| `bootstrap.sh destroy` | Tear down all nodes |

## Full Launch Sequence

```bash
# 1. Deploy and peer the bootstrap miners
export TF_VAR_hcloud_token="your-token"
./deploy/bootstrap.sh deploy

# 2. Write the bootstrap peers into source code
./deploy/bootstrap.sh codegen --apply

# 3. Build, test, push — triggers new Docker image with hardcoded peers
swift build && swift test
git add Sources/LatticeNode/Network/BootstrapPeers.swift
git commit -m "Add bootstrap peers for mainnet launch"
git push origin main

# 4. Update all miners to the new image with hardcoded peers
./deploy/bootstrap.sh update

# 5. Verify
./deploy/bootstrap.sh status
```

## Customize

Edit `terraform/variables.tf` to change:

| Variable | Default | Description |
|----------|---------|-------------|
| `nodes` | 3 nodes (US-East, EU, US-West) | Node names and locations |
| `server_type` | `cpx11` ($4.50/mo) | Hetzner instance size |
| `image` | `ghcr.io/treehauslabs/lattice-node:main` | Docker image |
| `p2p_port` | 4001 | P2P listen port |

## Costs

| Component | Monthly |
|-----------|---------|
| 3x cpx11 (2 vCPU, 2GB RAM) | ~$13.50 |
| Network traffic (included) | $0 |
| **Total** | **~$13.50/mo** |

## Tear down

```bash
./deploy/bootstrap.sh destroy
```
