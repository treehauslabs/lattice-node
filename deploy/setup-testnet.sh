#!/bin/bash
set -euo pipefail

# Lattice Testnet Setup for Fly.io
# Generates 3 bootstrap node identities and creates fly.toml configs

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$DEPLOY_DIR")"
KEYS_DIR="$DEPLOY_DIR/keys"
REGIONS=("ord" "lax" "ewr")
APPS=("lattice-bootstrap-1" "lattice-bootstrap-2" "lattice-bootstrap-3")

echo "=== Lattice Testnet Setup ==="
echo ""

# Step 1: Build the binary to generate keys
echo "Building lattice-node..."
cd "$PROJECT_DIR"
swift build -c release 2>/dev/null
BINARY=".build/release/LatticeNode"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed. Cannot find $BINARY"
    exit 1
fi

# Step 2: Generate 3 node identities
mkdir -p "$KEYS_DIR"
echo "Generating node identities..."

for i in 0 1 2; do
    KEY_FILE="$KEYS_DIR/node$((i+1)).json"
    if [ -f "$KEY_FILE" ]; then
        echo "  Node $((i+1)): already exists ($(basename $KEY_FILE))"
    else
        $BINARY keys generate --output "$KEY_FILE"
        echo "  Node $((i+1)): generated"
    fi
done

echo ""

# Step 3: Extract public keys
PUB_KEYS=()
for i in 0 1 2; do
    KEY_FILE="$KEYS_DIR/node$((i+1)).json"
    PUB_KEY=$(python3 -c "import json; print(json.load(open('$KEY_FILE'))['publicKey'])")
    PUB_KEYS+=("$PUB_KEY")
    echo "Node $((i+1)) public key: ${PUB_KEY:0:32}..."
done

echo ""
echo "=== Fly.io Deployment ==="
echo ""
echo "Run the following commands to deploy:"
echo ""

# Step 4: Print Fly commands
for i in 0 1 2; do
    APP="${APPS[$i]}"
    REGION="${REGIONS[$i]}"
    echo "# --- ${APP} (${REGION}) ---"
    echo "fly apps create ${APP} --org your-org"
    echo "fly ips allocate-v4 --shared -a ${APP}"
    echo "fly volumes create lattice_data --size 10 --region ${REGION} -a ${APP}"
    echo ""
done

echo ""
echo "After creating apps and getting IPs, run:"
echo "  $0 --configure <ip1> <ip2> <ip3>"
echo ""
echo "This will generate fly.toml files and update BootstrapPeers.swift"
echo ""

# Step 5: If --configure flag with IPs, generate configs
if [ "${1:-}" = "--configure" ] && [ $# -eq 4 ]; then
    IP1="$2"
    IP2="$3"
    IP3="$4"
    IPS=("$IP1" "$IP2" "$IP3")

    echo "Configuring with IPs: $IP1, $IP2, $IP3"
    echo ""

    # Generate fly.toml for each node
    for i in 0 1 2; do
        APP="${APPS[$i]}"
        REGION="${REGIONS[$i]}"
        NODE_DIR="$DEPLOY_DIR/${APP}"
        mkdir -p "$NODE_DIR"

        # Build --peer args for the OTHER two nodes
        PEER_ARGS=""
        for j in 0 1 2; do
            if [ $j -ne $i ]; then
                PEER_ARGS="$PEER_ARGS --peer ${PUB_KEYS[$j]}@${IPS[$j]}:4001"
            fi
        done

        cat > "$NODE_DIR/fly.toml" << EOF
app = "${APP}"
primary_region = "${REGION}"

[build]
  dockerfile = "../Dockerfile"

[env]
  LATTICE_DATA_DIR = "/data"

[mounts]
  source = "lattice_data"
  destination = "/data"

[[services]]
  internal_port = 4001
  protocol = "tcp"
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1
  [[services.ports]]
    port = 4001

[[services]]
  internal_port = 8080
  protocol = "tcp"
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1
  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]
  [[services.ports]]
    port = 80
    handlers = ["http"]

[processes]
  app = "node --mine Nexus --port 4001 --rpc-port 8080 --rpc-bind 0.0.0.0 --data-dir /data --autosize${PEER_ARGS}"

[[vm]]
  size = "shared-cpu-2x"
  memory = "1gb"
EOF
        echo "  Created $NODE_DIR/fly.toml"

        # Copy identity file
        cp "$KEYS_DIR/node$((i+1)).json" "$NODE_DIR/identity.json"
        echo "  Copied identity to $NODE_DIR/identity.json"
    done

    echo ""

    # Update BootstrapPeers.swift
    BOOTSTRAP_FILE="$PROJECT_DIR/Sources/LatticeNode/Network/BootstrapPeers.swift"
    cat > "$BOOTSTRAP_FILE" << EOF
import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "${PUB_KEYS[0]}", host: "${IPS[0]}", port: 4001),
        PeerEndpoint(publicKey: "${PUB_KEYS[1]}", host: "${IPS[1]}", port: 4001),
        PeerEndpoint(publicKey: "${PUB_KEYS[2]}", host: "${IPS[2]}", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
}
EOF
    echo "  Updated BootstrapPeers.swift with IPs"

    echo ""
    echo "=== Ready to Deploy ==="
    echo ""
    echo "For each node:"
    echo ""
    for i in 0 1 2; do
        APP="${APPS[$i]}"
        NODE_DIR="$DEPLOY_DIR/${APP}"
        echo "  # Deploy ${APP}"
        echo "  cd $NODE_DIR"
        echo "  fly deploy"
        echo "  # Copy identity (first deploy only):"
        echo "  fly ssh console -a ${APP} -C 'mkdir -p /data'"
        echo "  cat identity.json | fly ssh console -a ${APP} -C 'cat > /data/identity.json'"
        echo ""
    done

    echo "After all 3 are running, verify:"
    echo "  curl https://${APPS[0]}.fly.dev/api/chain/info"
    echo "  curl https://${APPS[1]}.fly.dev/api/chain/info"
    echo "  curl https://${APPS[2]}.fly.dev/api/chain/info"
fi
