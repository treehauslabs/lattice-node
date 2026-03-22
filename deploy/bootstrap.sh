#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
P2P_PORT=4001
MAX_WAIT=180
POLL_INTERVAL=5
SOURCE_FILE="$SCRIPT_DIR/../Sources/LatticeNode/Network/BootstrapPeers.swift"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  deploy     Run terraform apply, wait for nodes, peer them together"
    echo "  peer       Extract keys and peer existing nodes together"
    echo "  status     Show status of all bootstrap nodes"
    echo "  codegen    Print BootstrapPeers.swift with current node keys/IPs"
    echo "  update     Pull latest image and restart all nodes"
    echo "  destroy    Tear down all bootstrap nodes"
    echo ""
    echo "Environment:"
    echo "  TF_VAR_hcloud_token   Hetzner Cloud API token (required for deploy/destroy)"
    exit 1
}

get_ips() {
    cd "$TERRAFORM_DIR"
    terraform output -json node_ips 2>/dev/null | jq -r 'to_entries[] | "\(.key) \(.value)"'
}

wait_for_ssh() {
    local ip=$1
    local name=$2
    local waited=0
    echo "  Waiting for $name ($ip) to accept SSH..."
    while ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$ip" true 2>/dev/null; do
        waited=$((waited + POLL_INTERVAL))
        if [ $waited -ge $MAX_WAIT ]; then
            echo "  TIMEOUT: $name ($ip) not reachable after ${MAX_WAIT}s"
            return 1
        fi
        sleep $POLL_INTERVAL
    done
    echo "  $name ($ip) ready"
}

wait_for_node() {
    local ip=$1
    local name=$2
    local waited=0
    echo "  Waiting for $name miner to start..."
    while ! ssh -o StrictHostKeyChecking=no "root@$ip" "docker logs lattice-miner 2>&1 | grep -q 'Public key'" 2>/dev/null; do
        waited=$((waited + POLL_INTERVAL))
        if [ $waited -ge $MAX_WAIT ]; then
            echo "  TIMEOUT: $name miner not ready after ${MAX_WAIT}s"
            return 1
        fi
        sleep $POLL_INTERVAL
    done
}

get_pubkey() {
    local ip=$1
    ssh -o StrictHostKeyChecking=no "root@$ip" \
        "docker logs lattice-miner 2>&1 | grep 'Public key' | head -1 | sed 's/.*Public key:  //' | sed 's/\.\.\.$//'"
}

cmd_deploy() {
    echo "=== Deploying bootstrap miners ==="
    echo ""

    cd "$TERRAFORM_DIR"
    terraform init -input=false
    terraform apply -auto-approve

    echo ""
    cmd_peer
}

cmd_peer() {
    echo "=== Peering bootstrap nodes ==="
    echo ""

    declare -A IPS KEYS
    local NAMES=()

    while read -r name ip; do
        NAMES+=("$name")
        IPS[$name]=$ip
    done < <(get_ips)

    if [ ${#NAMES[@]} -eq 0 ]; then
        echo "No nodes found. Run '$0 deploy' first."
        exit 1
    fi

    echo "Found ${#NAMES[@]} nodes:"
    for name in "${NAMES[@]}"; do
        echo "  $name -> ${IPS[$name]}"
    done
    echo ""

    echo "Waiting for nodes to be reachable..."
    for name in "${NAMES[@]}"; do
        wait_for_ssh "${IPS[$name]}" "$name"
    done
    echo ""

    echo "Waiting for miners to start..."
    for name in "${NAMES[@]}"; do
        wait_for_node "${IPS[$name]}" "$name"
    done
    echo ""

    echo "Extracting public keys..."
    for name in "${NAMES[@]}"; do
        KEYS[$name]=$(get_pubkey "${IPS[$name]}")
        echo "  $name: ${KEYS[$name]:0:32}..."
    done
    echo ""

    echo "Connecting nodes to each other..."
    for name in "${NAMES[@]}"; do
        local peer_flags=""
        for other in "${NAMES[@]}"; do
            if [ "$other" != "$name" ]; then
                peer_flags="$peer_flags --peer ${KEYS[$other]}@${IPS[$other]}:${P2P_PORT}"
            fi
        done
        echo "  Restarting $name with ${#NAMES[@]}-1 peers..."
        ssh -o StrictHostKeyChecking=no "root@${IPS[$name]}" "lattice-update $peer_flags" >/dev/null 2>&1
    done
    echo ""

    echo "=== Bootstrap network is live ==="
    echo ""
    cmd_codegen_inner
}

cmd_status() {
    while read -r name ip; do
        echo "=== $name ($ip) ==="
        ssh -o StrictHostKeyChecking=no "root@$ip" "lattice-status" 2>/dev/null || echo "  (unreachable)"
        echo ""
    done < <(get_ips)
}

cmd_codegen_inner() {
    declare -A IPS KEYS
    local NAMES=()

    while read -r name ip; do
        NAMES+=("$name")
        IPS[$name]=$ip
    done < <(get_ips)

    for name in "${NAMES[@]}"; do
        KEYS[$name]=$(get_pubkey "${IPS[$name]}" 2>/dev/null || echo "UNKNOWN")
    done

    echo "Add this to Sources/LatticeNode/Network/BootstrapPeers.swift:"
    echo ""
    echo "    public static let nexus: [PeerEndpoint] = ["
    for name in "${NAMES[@]}"; do
        echo "        PeerEndpoint(publicKey: \"${KEYS[$name]}\", host: \"${IPS[$name]}\", port: ${P2P_PORT}),"
    done
    echo "    ]"
    echo ""
    echo "Or run '$0 codegen --apply' to write it automatically."
}

cmd_codegen() {
    if [ "${1:-}" = "--apply" ]; then
        declare -A IPS KEYS
        local NAMES=()

        while read -r name ip; do
            NAMES+=("$name")
            IPS[$name]=$ip
        done < <(get_ips)

        for name in "${NAMES[@]}"; do
            KEYS[$name]=$(get_pubkey "${IPS[$name]}")
        done

        local PEERS=""
        for name in "${NAMES[@]}"; do
            PEERS="$PEERS        PeerEndpoint(publicKey: \"${KEYS[$name]}\", host: \"${IPS[$name]}\", port: ${P2P_PORT}),\n"
        done

        cat > "$SOURCE_FILE" << SWIFT
import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
$(for name in "${NAMES[@]}"; do
    echo "        PeerEndpoint(publicKey: \"${KEYS[$name]}\", host: \"${IPS[$name]}\", port: ${P2P_PORT}),"
done)
    ]

    public static let maxPeerConnections: Int = 128
}
SWIFT

        echo "Updated $SOURCE_FILE with ${#NAMES[@]} bootstrap peers."
        echo "Run 'swift build' to verify, then commit and push."
    else
        cmd_codegen_inner
    fi
}

cmd_update() {
    echo "=== Updating all bootstrap nodes ==="
    echo ""
    while read -r name ip; do
        echo "Updating $name ($ip)..."
        ssh -o StrictHostKeyChecking=no "root@$ip" "lattice-update" 2>&1 | tail -1
    done < <(get_ips)
    echo ""
    echo "Done. Wait ~30s then run '$0 status' to verify."
}

cmd_destroy() {
    echo "=== Tearing down bootstrap miners ==="
    cd "$TERRAFORM_DIR"
    terraform destroy
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
