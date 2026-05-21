#!/bin/bash
set -euo pipefail

# Verify testnet is running correctly
# Usage: ./verify-testnet.sh [--faucet-key <hex>]

APPS=("lattice-testnet-1" "lattice-testnet-2" "lattice-testnet-3")
GENESIS_HASH="baguqeeraxodjzhzgip6j5w6ucjfhnj23l3qjc6mlv5rirywrulpufvjurodq"
PREMINE_ADDRESS="992fe6ae226df678b1f2dba90cd9704cba91abb9"
FAUCET_KEY="${LATTICE_FAUCET_KEY:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --faucet-key) FAUCET_KEY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; ALL_OK=false; }
warn() { echo "  [WARN] $1"; }

echo "=== Lattice Testnet Smoke Tests ==="
echo ""

TIPS=()
HEIGHTS=()
SYNCING_FLAGS=()
ALL_OK=true

# ── 1. Node liveness, genesis hash, height, mining ──────────────────────────
echo "--- Node Status ---"
for APP in "${APPS[@]}"; do
    RESPONSE=$(curl -s --max-time 10 "https://$APP.fly.dev/api/chain/info" 2>/dev/null || echo "UNREACHABLE")

    if [ "$RESPONSE" = "UNREACHABLE" ]; then
        fail "$APP: unreachable"
        continue
    fi

    HEIGHT=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['height'])" 2>/dev/null || echo "0")
    TIP=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['tip'][:24])" 2>/dev/null || echo "?")
    MINING=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['mining'])" 2>/dev/null || echo "False")
    GENESIS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('genesisHash',''))" 2>/dev/null || echo "")

    SYNCING=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chains'][0]['syncing'])" 2>/dev/null || echo "False")

    TIPS+=("$TIP")
    HEIGHTS+=("$HEIGHT")
    SYNCING_FLAGS+=("$SYNCING")

    # Genesis hash
    if [ "$GENESIS" = "$GENESIS_HASH" ]; then
        pass "$APP: genesis hash correct"
    else
        fail "$APP: genesis hash mismatch (got ${GENESIS:0:24}...)"
    fi

    # Mining
    if [ "$MINING" = "True" ] || [ "$MINING" = "true" ]; then
        pass "$APP: mining (height=$HEIGHT)"
    else
        fail "$APP: not mining (height=$HEIGHT)"
    fi

    # Height > 0
    if [ "$HEIGHT" -gt 0 ] 2>/dev/null; then
        pass "$APP: height > 0"
    else
        fail "$APP: height is 0 (genesis not mined past)"
    fi
done
echo ""

# ── 2. Consensus ─────────────────────────────────────────────────────────────
echo "--- Consensus ---"
if [ ${#HEIGHTS[@]} -ge 2 ]; then
    H1=${HEIGHTS[0]:-0}
    H2=${HEIGHTS[1]:-0}
    H3=${HEIGHTS[2]:-${HEIGHTS[1]:-0}}
    MAX_H=$(python3 -c "print(max($H1,$H2,$H3))")
    MIN_H=$(python3 -c "print(min($H1,$H2,$H3))")
    DRIFT=$(python3 -c "print($MAX_H - $MIN_H)")
    # Large drift is OK if nodes are actively syncing; only fail if drift is
    # large AND no node reports syncing=True
    ANY_SYNCING=$(echo "${SYNCING_FLAGS[*]:-}" | grep -c "True" 2>/dev/null || echo "0")
    if [ "$DRIFT" -le 10 ]; then
        pass "Height drift: $DRIFT blocks ($MIN_H-$MAX_H)"
    elif [ "$ANY_SYNCING" -gt 0 ]; then
        warn "Height drift: $DRIFT blocks — nodes are catching up (syncing)"
    else
        fail "Height drift: $DRIFT blocks — nodes may not be syncing"
    fi
fi
echo ""

# ── 3. Balance resolution ────────────────────────────────────────────────────
echo "--- Balance Resolution ---"
# Use first reachable node
NODE=""
for APP in "${APPS[@]}"; do
    if curl -s --max-time 5 "https://$APP.fly.dev/api/chain/info" >/dev/null 2>&1; then
        NODE="https://$APP.fly.dev"; break
    fi
done
if [ -z "$NODE" ]; then
  fail "No nodes reachable for RPC tests"
  echo ""
else
BAL_RESP=$(curl -s --max-time 10 "$NODE/api/balance/$PREMINE_ADDRESS" 2>/dev/null || echo "{}")
BAL_OK=$(echo "$BAL_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('balance',0) > 0 else 'fail')" 2>/dev/null || echo "fail")
BALANCE=$(echo "$BAL_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('balance',0))" 2>/dev/null || echo "0")
if [ "$BAL_OK" = "ok" ]; then
    pass "Premine balance resolvable: $BALANCE tokens"
else
    fail "Premine balance not resolvable: $(echo "$BAL_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error","unknown error"))' 2>/dev/null)"
fi
echo ""

# ── 4. Block RPC ─────────────────────────────────────────────────────────────
echo "--- Block RPC ---"
BLOCK0=$(curl -s --max-time 10 "$NODE/api/block/0" 2>/dev/null || echo "{}")
HAS_HEIGHT=$(echo "$BLOCK0" | python3 -c "import sys,json; d=json.load(sys.stdin); print('height' in d)" 2>/dev/null || echo "False")
HAS_POST=$(echo "$BLOCK0" | python3 -c "import sys,json; d=json.load(sys.stdin); print('postStateCID' in d)" 2>/dev/null || echo "False")
if [ "$HAS_HEIGHT" = "True" ] && [ "$HAS_POST" = "True" ]; then
    pass "Block 0 returns v2 field names (height, postStateCID)"
else
    fail "Block 0 missing v2 fields: $BLOCK0"
fi
echo ""

# ── 5. Faucet (optional) ─────────────────────────────────────────────────────
if [ -n "$FAUCET_KEY" ]; then
    echo "--- Faucet ---"
    # Generate a fresh address each run to avoid nonce/duplicate conflicts
    SCRIPT_DIR_TMP="$(cd "$(dirname "$0")" && pwd)"
    BINARY_TMP="$SCRIPT_DIR_TMP/../.build/debug/LatticeNode"
    if [ ! -f "$BINARY_TMP" ]; then BINARY_TMP="$SCRIPT_DIR_TMP/../.build/release/LatticeNode"; fi
    if [ ! -f "$BINARY_TMP" ]; then BINARY_TMP="lattice-node"; fi
    TEST_ADDR=$($BINARY_TMP keys generate 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE "Address:.*" | awk '{print $2}' || true)
    [ -z "$TEST_ADDR" ] && TEST_ADDR="f3c725845370882020038db0173cba192fe8d07e"
    FAUCET_PORT=18090
    # Kill any stale faucet on this port
    lsof -ti:$FAUCET_PORT 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1

    # Start faucet in background
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    BINARY="$SCRIPT_DIR/../.build/debug/LatticeNode"
    if [ ! -f "$BINARY" ]; then BINARY="$SCRIPT_DIR/../.build/release/LatticeNode"; fi
    if [ ! -f "$BINARY" ]; then BINARY="lattice-node"; fi

    $BINARY faucet \
        --faucet-key "$FAUCET_KEY" \
        --node-url "$NODE" \
        --port $FAUCET_PORT \
        --amount 1000000 --chain Nexus &
    FAUCET_PID=$!
    sleep 3

    DRIP=$(curl -s --max-time 10 -X POST "http://localhost:$FAUCET_PORT/faucet" \
        -H "Content-Type: application/json" \
        -d "{\"address\":\"$TEST_ADDR\"}" 2>/dev/null || echo "{}")
    kill $FAUCET_PID 2>/dev/null

    TX_CID=$(echo "$DRIP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txCID',''))" 2>/dev/null || echo "")
    if [ -n "$TX_CID" ]; then
        pass "Faucet dripped: txCID=${TX_CID:0:24}..."
    else
        ERR=$(echo "$DRIP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo "unreachable")
        fail "Faucet failed: $ERR"
    fi
    echo ""
fi  # end faucet key check
fi  # end NODE available check

# ── Summary ───────────────────────────────────────────────────────────────────
if $ALL_OK; then
    echo "=== All tests passed ==="
else
    echo "=== FAILURES detected ==="
    exit 1
fi
