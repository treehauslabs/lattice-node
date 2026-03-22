#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PREFIX="lattice-bootstrap"
REGIONS=("iad" "ams" "sjc")
REGION_NAMES=("US-East" "EU" "US-West")
IMAGE="ghcr.io/treehauslabs/lattice-node:main"
P2P_PORT=4001
SOURCE_FILE="$SCRIPT_DIR/../../Sources/LatticeNode/Network/BootstrapPeers.swift"
MAX_WAIT=180
POLL_INTERVAL=5

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  deploy     Create 3 bootstrap miners across regions"
    echo "  peer       Extract keys and print peer connection info"
    echo "  status     Show status of all bootstrap apps"
    echo "  codegen    Print BootstrapPeers.swift with current node keys/IPs"
    echo "  update     Deploy latest image to all nodes"
    echo "  destroy    Delete all bootstrap apps"
    echo ""
    echo "Prerequisites: flyctl installed and authenticated (fly auth login)"
    exit 1
}

app_name() {
    echo "${APP_PREFIX}-${1}"
}

get_ip() {
    local app=$1
    fly ips list --app "$app" --json 2>/dev/null | jq -r '.[] | select(.type == "v4") | .address' | head -1
}

get_pubkey() {
    local app=$1
    fly logs --app "$app" --no-tail 2>/dev/null | grep "Public key" | head -1 | sed 's/.*Public key:  //' | sed 's/\.\.\.$//'
}

wait_for_app() {
    local app=$1
    local waited=0
    echo "  Waiting for $app..."
    while true; do
        local status
        status=$(fly status --app "$app" --json 2>/dev/null | jq -r '.Machines[0].state // "unknown"') || true
        if [ "$status" = "started" ]; then
            break
        fi
        waited=$((waited + POLL_INTERVAL))
        if [ $waited -ge $MAX_WAIT ]; then
            echo "  TIMEOUT: $app not ready after ${MAX_WAIT}s (state: $status)"
            return 1
        fi
        sleep $POLL_INTERVAL
    done
    echo "  $app running"
}

wait_for_pubkey() {
    local app=$1
    local waited=0
    while true; do
        local key
        key=$(get_pubkey "$app" 2>/dev/null) || true
        if [ -n "$key" ] && [ "$key" != "" ]; then
            return 0
        fi
        waited=$((waited + POLL_INTERVAL))
        if [ $waited -ge $MAX_WAIT ]; then
            echo "  TIMEOUT: $app public key not found after ${MAX_WAIT}s"
            return 1
        fi
        sleep $POLL_INTERVAL
    done
}

cmd_deploy() {
    echo "=== Deploying bootstrap miners on Fly.io ==="
    echo "    3x shared-cpu-1x / 512MB / 1-10GB auto-grow volume"
    echo ""

    for i in "${!REGIONS[@]}"; do
        local region="${REGIONS[$i]}"
        local name="${REGION_NAMES[$i]}"
        local app
        app=$(app_name "$region")

        echo "[$name] Creating $app in $region..."

        if fly status --app "$app" &>/dev/null; then
            echo "  Already exists, skipping"
        else
            fly apps create "$app" --org personal 2>/dev/null || true

            fly volumes create lattice_data \
                --app "$app" \
                --region "$region" \
                --size 1 \
                --yes 2>/dev/null

            fly ips allocate-v4 --shared --app "$app" 2>/dev/null || true

            fly deploy \
                --app "$app" \
                --image "$IMAGE" \
                --primary-region "$region" \
                --vm-memory 512 \
                --vm-cpus 1 \
                --vm-cpu-kind shared \
                --ha=false \
                --config "$SCRIPT_DIR/fly.toml" \
                --yes
        fi
        echo ""
    done

    echo "Waiting for nodes to start..."
    for i in "${!REGIONS[@]}"; do
        wait_for_app "$(app_name "${REGIONS[$i]}")"
    done
    echo ""

    echo "Waiting for public keys..."
    for i in "${!REGIONS[@]}"; do
        local app
        app=$(app_name "${REGIONS[$i]}")
        wait_for_pubkey "$app"
        echo "  $app ready"
    done
    echo ""

    echo "=== Bootstrap network deployed ==="
    echo ""
    print_info
}

print_info() {
    local apps=()
    declare -A IPS KEYS

    for i in "${!REGIONS[@]}"; do
        local app
        app=$(app_name "${REGIONS[$i]}")
        apps+=("$app")
        IPS[$app]=$(get_ip "$app" 2>/dev/null || echo "pending")
        KEYS[$app]=$(get_pubkey "$app" 2>/dev/null || echo "pending")
    done

    echo "Nodes:"
    for app in "${apps[@]}"; do
        echo "  $app  ${IPS[$app]}  ${KEYS[$app]:0:32}..."
    done
    echo ""

    echo "Connect a local node:"
    local peer_flags=""
    for app in "${apps[@]}"; do
        peer_flags="$peer_flags --peer ${KEYS[$app]}@${IPS[$app]}:${P2P_PORT}"
    done
    echo "  lattice-node --mine Nexus $peer_flags"
    echo ""

    echo "BootstrapPeers.swift:"
    echo "    public static let nexus: [PeerEndpoint] = ["
    for app in "${apps[@]}"; do
        echo "        PeerEndpoint(publicKey: \"${KEYS[$app]}\", host: \"${IPS[$app]}\", port: ${P2P_PORT}),"
    done
    echo "    ]"
    echo ""
    echo "Run '$0 codegen --apply' to write it automatically."
}

cmd_peer() {
    echo "=== Bootstrap peer info ==="
    echo ""
    print_info
}

cmd_status() {
    for i in "${!REGIONS[@]}"; do
        local app
        app=$(app_name "${REGIONS[$i]}")
        echo "=== $app (${REGION_NAMES[$i]}) ==="
        fly status --app "$app" 2>/dev/null || echo "  (not found)"
        local ip
        ip=$(get_ip "$app" 2>/dev/null) || true
        [ -n "$ip" ] && echo "  Public IP: $ip"
        local key
        key=$(get_pubkey "$app" 2>/dev/null) || true
        [ -n "$key" ] && echo "  Key: ${key:0:32}..."
        echo ""
    done
}

cmd_codegen() {
    if [ "${1:-}" = "--apply" ]; then
        local apps=()
        declare -A IPS KEYS

        for i in "${!REGIONS[@]}"; do
            local app
            app=$(app_name "${REGIONS[$i]}")
            apps+=("$app")
            IPS[$app]=$(get_ip "$app")
            KEYS[$app]=$(get_pubkey "$app")
        done

        cat > "$SOURCE_FILE" << SWIFT
import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
$(for app in "${apps[@]}"; do
    echo "        PeerEndpoint(publicKey: \"${KEYS[$app]}\", host: \"${IPS[$app]}\", port: ${P2P_PORT}),"
done)
    ]

    public static let maxPeerConnections: Int = 128
}
SWIFT

        echo "Updated $SOURCE_FILE with ${#apps[@]} bootstrap peers."
        echo "Run 'swift build' to verify, then commit and push."
    else
        print_info
    fi
}

cmd_update() {
    echo "=== Updating all bootstrap nodes ==="
    echo ""
    for i in "${!REGIONS[@]}"; do
        local app
        app=$(app_name "${REGIONS[$i]}")
        echo "Deploying to $app..."
        fly deploy \
            --app "$app" \
            --image "$IMAGE" \
            --config "$SCRIPT_DIR/fly.toml" \
            --yes 2>&1 | tail -1
    done
    echo ""
    echo "Done. Run '$0 status' to verify."
}

cmd_destroy() {
    echo "=== Destroying bootstrap miners ==="
    for i in "${!REGIONS[@]}"; do
        local app
        app=$(app_name "${REGIONS[$i]}")
        echo "Deleting $app..."
        fly apps destroy "$app" --yes 2>/dev/null || echo "  (not found)"
    done
    echo "Done."
}

case "${1:-}" in
    deploy)  cmd_deploy ;;
    peer)    cmd_peer ;;
    status)  cmd_status ;;
    codegen) cmd_codegen "${2:-}" ;;
    update)  cmd_update ;;
    destroy) cmd_destroy ;;
    *)       usage ;;
esac
