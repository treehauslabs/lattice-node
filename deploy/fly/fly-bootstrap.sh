#!/bin/bash
set -euo pipefail

# Deploy and wire together Lattice testnet bootstrap nodes on Fly.io.
#
# Uses the pre-built ghcr.io image (built by CI on push to main).
# Do NOT use Dockerfile builds — Package.swift has local path deps.
#
# Usage:
#   ./deploy/fly/fly-bootstrap.sh deploy [COUNT] [REGIONS]
#   ./deploy/fly/fly-bootstrap.sh status
#   ./deploy/fly/fly-bootstrap.sh peer
#   ./deploy/fly/fly-bootstrap.sh codegen [--apply]
#   ./deploy/fly/fly-bootstrap.sh destroy
#
# Examples:
#   ./deploy/fly/fly-bootstrap.sh deploy 3 "ord,ams,sin"
#   ./deploy/fly/fly-bootstrap.sh deploy 5 "ord,ams,sin,syd,gru"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTNET_CONFIG="$SCRIPT_DIR/fly-testnet.toml"
BOOTSTRAP_FILE="$ROOT_DIR/Sources/LatticeNode/Network/BootstrapPeers.swift"
APP_PREFIX="lattice-testnet"
DEFAULT_COUNT=3
DEFAULT_REGIONS="ord,ams,sin"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  deploy [N] [REGIONS]   Deploy N testnet nodes (default: 3, ord/ams/sin)"
    echo "  status                 Show all nodes, IPs, and public keys"
    echo "  peer                   Print --peer flags for connecting to all seeds"
    echo "  codegen [--apply]      Print (or write) BootstrapPeers.testnet entries"
    echo "  destroy                Tear down all testnet apps"
    echo ""
    echo "Regions: https://fly.io/docs/reference/regions/"
    exit 1
}

get_apps() {
    fly apps list -j 2>/dev/null | jq -r ".[] | select(.Name | startswith(\"$APP_PREFIX\")) | .Name" | sort
}

get_pubkey() {
    local app=$1
    fly ssh console -a "$app" -C "cat /data/identity.json 2>/dev/null" 2>/dev/null \
        | jq -r '.publicKey' 2>/dev/null || echo ""
}

get_ipv4() {
    local app=$1
    fly ips list -a "$app" -j 2>/dev/null \
        | jq -r '.[] | select(.Type == "v4") | .Address' 2>/dev/null | head -1 || echo ""
}

cmd_deploy() {
    local count=${1:-$DEFAULT_COUNT}
    local regions_str=${2:-$DEFAULT_REGIONS}
    IFS=',' read -ra REGIONS <<< "$regions_str"

    echo "Deploying $count testnet nodes across: ${REGIONS[*]}"
    echo ""

    for i in $(seq 1 "$count"); do
        local app="${APP_PREFIX}-${i}"
        local region="${REGIONS[$(( (i - 1) % ${#REGIONS[@]} ))]}"

        echo "=== $app (region: $region) ==="

        if ! fly apps list -j 2>/dev/null | jq -e ".[] | select(.Name == \"$app\")" > /dev/null 2>&1; then
            fly apps create "$app"
            echo "  Created app"
        else
            echo "  App exists"
        fi

        local vol_count
        vol_count=$(fly volumes list -a "$app" -j 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [ "$vol_count" = "0" ]; then
            fly volumes create lattice_data --region "$region" --size 1 -a "$app" -y
            echo "  Created volume in $region"
        else
            echo "  Volume exists"
        fi

        # Write per-app fly.toml with correct app name and region
        local tmp_toml
        tmp_toml=$(mktemp /tmp/fly-testnet-XXXX.toml)
        sed -e "s/lattice-testnet-REPLACE/$app/" \
            -e "s/primary_region = \"REPLACE\"/primary_region = \"$region\"/" \
            "$TESTNET_CONFIG" > "$tmp_toml"

        fly deploy --config "$tmp_toml" -a "$app" --wait-timeout 120
        rm -f "$tmp_toml"
        echo "  Deployed"

        local ipv4
        ipv4=$(get_ipv4 "$app")
        if [ -z "$ipv4" ]; then
            fly ips allocate-v4 -a "$app" --yes
            ipv4=$(get_ipv4 "$app")
            echo "  Allocated IP: $ipv4"
        else
            echo "  IP: $ipv4"
        fi

        local pubkey
        pubkey=$(get_pubkey "$app")
        if [ -z "$pubkey" ]; then
            echo "  Waiting for identity..."
            sleep 10
            pubkey=$(get_pubkey "$app")
        fi
        echo "  Public key: ${pubkey:0:40}..."
        echo ""
    done

    echo "=== All nodes deployed ==="
    echo ""
    echo "Next steps:"
    echo "  1. Run '$0 codegen --apply' to write BootstrapPeers.testnet"
    echo "  2. Capture genesis hash from logs: fly logs -a ${APP_PREFIX}-1 | grep Genesis"
    echo "  3. Hardcode expectedBlockHash in TestnetGenesis.swift"
    echo "  4. Push, wait for CI, then redeploy: '$0 deploy $count $regions_str'"
}

cmd_status() {
    local apps
    apps=$(get_apps)
    if [ -z "$apps" ]; then
        echo "No testnet apps found."
        exit 0
    fi

    echo "Lattice testnet nodes:"
    echo ""
    for app in $apps; do
        local ipv4 region state pubkey
        ipv4=$(get_ipv4 "$app")
        region=$(fly status -a "$app" -j 2>/dev/null | jq -r '.Machines[0].Region // "?"' 2>/dev/null || echo "?")
        state=$(fly status -a "$app" -j 2>/dev/null | jq -r '.Machines[0].State // "?"' 2>/dev/null || echo "?")
        pubkey=$(get_pubkey "$app")

        echo "  $app"
        echo "    Region:     $region"
        echo "    State:      $state"
        echo "    IP:         ${ipv4:-none}"
        echo "    Public key: ${pubkey:0:40}..."
        echo "    RPC:        https://$app.fly.dev/api/chain/info"
        echo ""
    done
}

cmd_peer() {
    for app in $(get_apps); do
        local ipv4 pubkey
        ipv4=$(get_ipv4 "$app")
        pubkey=$(get_pubkey "$app")
        if [ -n "$pubkey" ] && [ -n "$ipv4" ]; then
            echo "--peer ${pubkey}@${ipv4}:4001"
        fi
    done
}

cmd_codegen() {
    local apply=${1:-}
    local apps
    apps=$(get_apps)

    local entries=""
    for app in $apps; do
        local ipv4 pubkey
        ipv4=$(get_ipv4 "$app")
        pubkey=$(get_pubkey "$app")
        if [ -n "$pubkey" ] && [ -n "$ipv4" ]; then
            entries="$entries        PeerEndpoint(publicKey: \"$pubkey\", host: \"$ipv4\", port: 4001),\n"
        fi
    done

    if [ "$apply" = "--apply" ]; then
        EXISTING_NEXUS=$(awk '/nexus:/,/\]/' "$BOOTSTRAP_FILE" | grep PeerEndpoint || true)
        cat > "$BOOTSTRAP_FILE" << SWIFT
import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
$(echo "$EXISTING_NEXUS")
    ]

    public static let testnet: [PeerEndpoint] = [
$(printf "%b" "$entries")
    ]

    public static let maxPeerConnections: Int = 128
    public static let maxPeerConnectionsDiscovery: Int = 512
}
SWIFT
        echo "Wrote BootstrapPeers.swift. Run 'swift build' to verify, then commit and push."
    else
        echo "Add to Sources/LatticeNode/Network/BootstrapPeers.swift:"
        echo ""
        echo "    public static let testnet: [PeerEndpoint] = ["
        printf "%b" "$entries"
        echo "    ]"
    fi
}

cmd_destroy() {
    local apps
    apps=$(get_apps)
    if [ -z "$apps" ]; then
        echo "No testnet apps found."
        exit 0
    fi

    echo "Destroying testnet apps:"
    for app in $apps; do
        echo "  $app"
        fly apps destroy "$app" --yes
    done
    echo "Done."
}

case "${1:-}" in
    deploy)  cmd_deploy "${2:-}" "${3:-}" ;;
    status)  cmd_status ;;
    peer)    cmd_peer ;;
    codegen) cmd_codegen "${2:-}" ;;
    destroy) cmd_destroy ;;
    *)       usage ;;
esac
