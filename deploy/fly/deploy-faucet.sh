#!/bin/bash
set -euo pipefail
# Deploy the testnet faucet to Fly.io
# Usage: ./deploy-faucet.sh

FAUCET_KEY="${LATTICE_FAUCET_KEY:-19cda640794d333f4b254a9536b4608f35e10480deb216a69ead5831c95727e8}"

echo "=== Deploying lattice-faucet ==="

# Create app if needed
fly apps create lattice-faucet 2>/dev/null || echo "  App already exists"

# Set the faucet private key as a secret
fly secrets set LATTICE_FAUCET_KEY="$FAUCET_KEY" -a lattice-faucet
echo "  Faucet key set as secret"

# Deploy
fly deploy --config "$(dirname "$0")/fly-faucet.toml" -a lattice-faucet --wait-timeout 120
echo ""
echo "=== Faucet deployed ==="
echo "  POST https://lattice-faucet.fly.dev/faucet"
echo "  Body: {\"address\":\"<your_address>\"}"
