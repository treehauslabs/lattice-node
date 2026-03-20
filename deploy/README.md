# Deploying Lattice Bootstrap Miners

## Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) installed
2. [Hetzner Cloud account](https://console.hetzner.cloud) with an API token
3. SSH key pair (`~/.ssh/id_ed25519.pub`)

## Deploy

```bash
cd deploy/terraform

# Set your Hetzner API token
export TF_VAR_hcloud_token="your-token-here"

# Deploy 3 bootstrap miners
terraform init
terraform apply
```

This creates 3 servers across US-East, EU, and US-West, each running a Lattice miner node in Docker.

## Manage

```bash
# Check node IPs
terraform output node_ips

# SSH into a node
ssh root@<ip>

# On the node: check status
lattice-status

# On the node: update to latest image
lattice-update

# On the node: view live logs
docker logs -f lattice-miner
```

## Connect a new node to the bootstrap network

After deploying, get the public keys from each node:

```bash
ssh root@<ip> "docker logs lattice-miner 2>&1 | grep 'Public key'"
```

Then connect new nodes:

```bash
lattice-node --mine Nexus \
  --peer <key1>@<ip1>:4001 \
  --peer <key2>@<ip2>:4001 \
  --peer <key3>@<ip3>:4001
```

## Customize

Edit `variables.tf` to change:

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
terraform destroy
```
