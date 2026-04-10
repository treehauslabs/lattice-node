#!/bin/bash
set -euo pipefail

# Verify testnet is running correctly
# Usage: ./verify-testnet.sh

APPS=("lattice-seed-1" "lattice-seed-2" "lattice-seed-3")

echo "=== Lattice Testnet Health Check ==="
echo ""

TIPS=()
HEIGHTS=()
ALL_OK=true

for APP in "${APPS[@]}"; do
    echo "--- $APP ---"
    RESPONSE=$(curl -s "https://$APP.fly.dev/api/chain/info" 2>/dev/null || echo "UNREACHABLE")

    if [ "$RESPONSE" = "UNREACHABLE" ]; then
        echo "  STATUS: UNREACHABLE"
        ALL_OK=false
        continue
    fi

    # Parse JSON with python3
    HEIGHT=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['height'])" 2>/dev/null || echo "?")
    TIP=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['tip'][:24])" 2>/dev/null || echo "?")
    MINING=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['mining'])" 2>/dev/null || echo "?")
    SYNCING=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['syncing'])" 2>/dev/null || echo "?")

    echo "  Height:  $HEIGHT"
    echo "  Tip:     $TIP..."
    echo "  Mining:  $MINING"
    echo "  Syncing: $SYNCING"

    TIPS+=("$TIP")
    HEIGHTS+=("$HEIGHT")

    # Check peers
    PEERS=$(curl -s "https://$APP.fly.dev/api/peers" 2>/dev/null || echo "{}")
    PEER_COUNT=$(echo "$PEERS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
    echo "  Peers:   $PEER_COUNT"
    echo ""
done

echo "=== Consensus Check ==="

if [ ${#TIPS[@]} -ge 2 ]; then
    if [ "${TIPS[0]}" = "${TIPS[1]}" ] && [ "${TIPS[1]}" = "${TIPS[2]:-${TIPS[1]}}" ]; then
        echo "  All nodes on same tip: PASS"
    else
        echo "  Tips diverge (normal if blocks are being mined)"
        echo "  Check that heights are close to each other"
    fi
fi

if [ ${#HEIGHTS[@]} -ge 2 ]; then
    H1=${HEIGHTS[0]:-0}
    H2=${HEIGHTS[1]:-0}
    H3=${HEIGHTS[2]:-0}
    MAX_H=$(python3 -c "print(max($H1,$H2,$H3))" 2>/dev/null || echo "0")
    MIN_H=$(python3 -c "print(min($H1,$H2,$H3))" 2>/dev/null || echo "0")
    DRIFT=$(python3 -c "print($MAX_H - $MIN_H)" 2>/dev/null || echo "0")
    echo "  Height range: $MIN_H - $MAX_H (drift: $DRIFT blocks)"
    if [ "$DRIFT" -gt 10 ]; then
        echo "  WARNING: Height drift > 10 blocks — nodes may not be syncing"
        ALL_OK=false
    else
        echo "  Height drift: OK"
    fi
fi

echo ""
if $ALL_OK; then
    echo "=== Testnet healthy ==="
else
    echo "=== Issues detected — check logs with: fly logs -a <app-name> ==="
fi
