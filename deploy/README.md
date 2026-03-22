# Deploying Lattice Bootstrap Miners

Two deployment options: **Fly.io** (recommended) or **Hetzner Cloud**.

## Option A: Fly.io (recommended)

3 nodes across US-East, EU, US-West. Volumes auto-grow from 1GB to 10GB as the chain grows.

| | Per node | 3 nodes |
|---|---|---|
| shared-cpu-1x, 512MB | $3.57/mo | $10.71 |
| Volume (1-10GB auto) | $0.15-1.50/mo | $0.45-4.50 |
| **Total** | | **~$11-15/mo** |

### Prerequisites

1. [flyctl](https://fly.io/docs/flyctl/install/) installed
2. `fly auth login`
3. `jq` installed

### Deploy

```bash
./deploy/fly/bootstrap-fly.sh deploy
```

### Full launch sequence

```bash
# 1. Deploy bootstrap miners
./deploy/fly/bootstrap-fly.sh deploy

# 2. Write bootstrap peers into source
./deploy/fly/bootstrap-fly.sh codegen --apply

# 3. Build, test, commit, push (triggers Docker image rebuild)
swift build && swift test
git add Sources/LatticeNode/Network/BootstrapPeers.swift
git commit -m "Add bootstrap peers for mainnet launch"
git push origin main

# 4. Wait for GitHub Actions to build the new Docker image (~5 min)
gh run watch

# 5. Update all miners to image with hardcoded peers
./deploy/fly/bootstrap-fly.sh update

# 6. Verify
./deploy/fly/bootstrap-fly.sh status
```

### Commands

| Command | Description |
|---------|-------------|
| `bootstrap-fly.sh deploy` | Create 3 miners, wait for boot, print peer info |
| `bootstrap-fly.sh peer` | Show keys and IPs of existing nodes |
| `bootstrap-fly.sh status` | Show status of all nodes |
| `bootstrap-fly.sh codegen` | Print BootstrapPeers.swift snippet |
| `bootstrap-fly.sh codegen --apply` | Write BootstrapPeers.swift directly |
| `bootstrap-fly.sh update` | Deploy latest Docker image to all nodes |
| `bootstrap-fly.sh destroy` | Delete all nodes |

---

## Option B: Hetzner Cloud

3 dedicated VPS nodes. More RAM but no auto-growing volumes.

| | Per node | 3 nodes |
|---|---|---|
| cpx11 (2 vCPU, 2GB RAM, 40GB) | $4.50/mo | $13.50 |

### Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) installed
2. [Hetzner Cloud account](https://console.hetzner.cloud) with an API token
3. SSH key pair (`~/.ssh/id_ed25519.pub`)
4. `jq` installed

### Deploy

```bash
export TF_VAR_hcloud_token="your-token"
./deploy/bootstrap.sh deploy
```

### Commands

| Command | Description |
|---------|-------------|
| `bootstrap.sh deploy` | Terraform apply + wait + peer nodes |
| `bootstrap.sh peer` | Re-extract keys and reconnect nodes |
| `bootstrap.sh status` | Show status of all nodes |
| `bootstrap.sh codegen` | Print BootstrapPeers.swift snippet |
| `bootstrap.sh codegen --apply` | Write BootstrapPeers.swift directly |
| `bootstrap.sh update` | Pull latest image on all nodes |
| `bootstrap.sh destroy` | Tear down all nodes |

---

## After deployment

Once bootstrap peers are hardcoded and pushed, anyone can join with:

```bash
lattice-node --mine Nexus --autosize
```

No `--peer` flags needed.
