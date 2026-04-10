#!/bin/bash
set -euo pipefail

# Deploy and wire together Lattice bootstrap nodes on Fly.io.
#
# Usage:
#   ./deploy/fly/fly-bootstrap.sh deploy [COUNT] [REGIONS]
#   ./deploy/fly/fly-bootstrap.sh status
#   ./deploy/fly/fly-bootstrap.sh destroy
#
# Examples:
#   ./deploy/fly/fly-bootstrap.sh deploy 3 "ord,ams,sin"
#   ./deploy/fly/fly-bootstrap.sh deploy 5 "ord,ams,sin,syd,gru"
#   ./deploy/fly/fly-bootstrap.sh status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEED_CONFIG="$SCRIPT_DIR/fly-seed.toml"
APP_PREFIX="lattice-seed"
DEFAULT_COUNT=3
DEFAULT_REGIONS="ord,ams,sin"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  deploy [N] [REGIONS]   Deploy N seed nodes across regions (default: 3, ord/ams/sin)"
    echo "  status                 Show all seed nodes, IPs, and public keys"
    echo "  peer                   Print --peer flags for connecting to all seeds"
    echo "  codegen                Print BootstrapPeers.swift entries"
    echo "  destroy                Tear down all seed apps"
    echo ""
    echo "Regions: https://fly.io/docs/reference/regions/"
    exit 1
}

get_apps() {
    fly apps list -j 2>/dev/null | jq -r ".[] | select(.Name | startswith(\"$APP_PREFIX\")) | .Name" | sort
}

cmd_deploy() {
    local count=${1:-$DEFAULT_COUNT}
    local regions_str=${2:-$DEFAULT_REGIONS}
    IFS=',' read -ra REGIONS <<< "$regions_str"

    echo "Deploying $count seed nodes across: ${REGIONS[*]}"
    echo ""

    local pubkeys=()
    local ips=()
    local apps=()

    for i in $(seq 1 "$count"); do
        local app="${APP_PREFIX}-${i}"
        local region="${REGIONS[$(( (i - 1) % ${#REGIONS[@]} ))]}"
        apps+=("$app")

        echo "=== $app (region: $region) ==="

        # Create app if it doesn't exist
        if ! fly apps list -j 2>/dev/null | jq -e ".[] | select(.Name == \"$app\")" > /dev/null 2>&1; then
            fly apps create "$app" --org personal
            echo "  Created app"
        else
            echo "  App exists"
        fi

        # Create volume if it doesn't exist
        local vol_count
        vol_count=$(fly volumes list -a "$app" -j 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [ "$vol_count" = "0" ]; then
            fly volumes create lattice_data --region "$region" --size 1 -a "$app" -y
            echo "  Created volume in $region"
        else
            echo "  Volume exists"
        fi

        # Deploy
        fly deploy --config "$SEED_CONFIG" -a "$app" --regions "$region" --wait-timeout 120
        echo "  Deployed"

        # Allocate IPv4 if needed
        local ipv4
        ipv4=$(fly ips list -a "$app" -j 2>/dev/null | jq -r '.[] | select(.Type == "v4") | .Address' | head -1)
        if [ -z "$ipv4" ]; then
            fly ips allocate-v4 -a "$app" --yes
            ipv4=$(fly ips list -a "$app" -j 2>/dev/null | jq -r '.[] | select(.Type == "v4") | .Address' | head -1)
            echo "  Allocated IP: $ipv4"
        else
            echo "  IP: $ipv4"
        fi
        ips+=("$ipv4")

        # Get public key from identity
        local pubkey
        pubkey=$(fly ssh console -a "$app" -C "cat /data/identity.json" 2>/dev/null | jq -r '.publicKey' 2>/dev/null || echo "")
        if [ -z "$pubkey" ]; then
            echo "  Waiting for identity generation..."
            sleep 5
            pubkey=$(fly ssh console -a "$app" -C "cat /data/identity.json" 2>/dev/null | jq -r '.publicKey' 2>/dev/null || echo "pending")
        fi
        pubkeys+=("$pubkey")
        echo "  Public key: ${pubkey:0:32}..."
        echo ""
    done

    echo "=== Bootstrap nodes deployed ==="
    echo ""
    echo "To connect a new node to these seeds:"
    for i in $(seq 0 $((count - 1))); do
        echo "  --peer ${pubkeys[$i]}@${ips[$i]}:4001"
    done
    echo ""
    echo "Run '$0 codegen' to get BootstrapPeers.swift entries."
}

cmd_status() {
    local apps
    apps=$(get_apps)
    if [ -z "$apps" ]; then
        echo "No seed apps found."
        exit 0
    fi

    echo "Lattice seed nodes:"
    echo ""
    for app in $apps; do
        local ipv4
        ipv4=$(fly ips list -a "$app" -j 2>/dev/null | jq -r '.[] | select(.Type == "v4") | .Address' | head -1 || echo "none")
        local region
        region=$(fly status -a "$app" -j 2>/dev/null | jq -r '.Machines[0].Region // "unknown"' 2>/dev/null || echo "?")
        local state
        state=$(fly status -a "$app" -j 2>/dev/null | jq -r '.Machines[0].State // "unknown"' 2>/dev/null || echo "?")
        local pubkey
        pubkey=$(fly ssh console -a "$app" -C "cat /data/identity.json" 2>/dev/null | jq -r '.publicKey' 2>/dev/null || echo "unknown")

        echo "  $app"
        echo "    Region:     $region"
        echo "    State:      $state"
        echo "    IP:         $ipv4"
        echo "    Public key: ${pubkey:0:40}..."
        echo ""
    done
}

cmd_peer() {
    local apps
    apps=$(get_apps)
    for app in $apps; do
        local ipv4
        ipv4=$(fly ips list -a "$app" -j 2>/dev/null | jq -r '.[] | select(.Type == "v4") | .Address' | head -1 || echo "")
        local pubkey
        pubkey=$(fly ssh console -a "$app" -C "cat /data/identity.json" 2>/dev/null | jq -r '.publicKey' 2>/dev/null || echo "")
        if [ -n "$pubkey" ] && [ -n "$ipv4" ]; then
            echo "--peer ${pubkey}@${ipv4}:4001"
        fi
    done
}

cmd_codegen() {
    local apps
    apps=$(get_apps)
    echo "    public static let nexus: [PeerEndpoint] = ["
    for app in $apps; do
        local ipv4
        ipv4=$(fly ips list -a "$app" -j 2>/dev/null | jq -r '.[] | select(.Type == "v4") | .Address' | head -1 || echo "")
        local pubkey
        pubkey=$(fly ssh console -a "$app" -C "cat /data/identity.json" 2>/dev/null | jq -r '.publicKey' 2>/dev/null || echo "")
        if [ -n "$pubkey" ] && [ -n "$ipv4" ]; then
            echo "        PeerEndpoint(publicKey: \"$pubkey\", host: \"$ipv4\", port: 4001),"
        fi
    done
    echo "    ]"
}

cmd_destroy() {
    local apps
    apps=$(get_apps)
    if [ -z "$apps" ]; then
        echo "No seed apps found."
        exit 0
    fi

    echo "Destroying seed apps:"
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
    codegen) cmd_codegen ;;
    destroy) cmd_destroy ;;
    *)       usage ;;
esac
