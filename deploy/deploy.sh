#!/bin/bash
set -euo pipefail

# Deploy a Lattice bootstrap node to Fly.io
# Usage: ./deploy.sh <app-name>
# Example: ./deploy.sh lattice-bootstrap-1

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$DEPLOY_DIR")"
APP="${1:?Usage: $0 <app-name>}"
NODE_DIR="$DEPLOY_DIR/$APP"

if [ ! -f "$NODE_DIR/fly.toml" ]; then
    echo "ERROR: $NODE_DIR/fly.toml not found"
    echo "Run setup-testnet.sh --configure <ip1> <ip2> <ip3> first"
    exit 1
fi

echo "=== Deploying $APP ==="

# Deploy from project root (Dockerfile context)
cd "$PROJECT_DIR"
fly deploy --config "$NODE_DIR/fly.toml" --app "$APP"

# Check if identity needs to be uploaded
if [ -f "$NODE_DIR/identity.json" ]; then
    echo ""
    echo "Checking if identity is already on the node..."
    IDENTITY_EXISTS=$(fly ssh console -a "$APP" -C "test -f /data/identity.json && echo yes || echo no" 2>/dev/null || echo "no")
    if [ "$IDENTITY_EXISTS" = "no" ]; then
        echo "Uploading identity..."
        fly ssh console -a "$APP" -C "mkdir -p /data"
        cat "$NODE_DIR/identity.json" | fly ssh console -a "$APP" -C "cat > /data/identity.json && chmod 600 /data/identity.json"
        echo "Identity uploaded. Restarting..."
        fly machines restart -a "$APP"
    else
        echo "Identity already present."
    fi
fi

echo ""
echo "=== $APP deployed ==="
echo "  P2P:  $APP.fly.dev:4001"
echo "  RPC:  https://$APP.fly.dev/api/chain/info"
echo ""
echo "Check status:"
echo "  fly status -a $APP"
echo "  fly logs -a $APP"
echo "  curl https://$APP.fly.dev/api/chain/info"
