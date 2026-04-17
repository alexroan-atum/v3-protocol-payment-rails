#!/usr/bin/env bash
# ============================================================================
# cowswap-submit.sh — Extract orderId from forge broadcast and submit to CowSwap API
# ============================================================================
#
# After running CowSwapSmoke.s.sol with --broadcast, this script:
#   1. Parses the broadcast JSON to find the OrderCreated event
#   2. Extracts orderId, validTo, and all order fields from the event
#   3. Prints (or executes) the curl command to submit to CowSwap API
#   4. Prints monitoring commands (Explorer, cancel, balance checks)
#
# Usage:
#   bash scripts/solidity/test/cowswap/cowswap-submit.sh                          # print curl
#   AUTO_SUBMIT=true bash scripts/solidity/test/cowswap/cowswap-submit.sh         # run curl
#   COWSWAP_API=https://api.cow.fi/base bash scripts/solidity/test/cowswap/cowswap-submit.sh
#
# Environment variables:
#   COWSWAP_API     — API base URL (default: auto-detect from chain ID)
#   BROADCAST_FILE  — Path to broadcast JSON (default: auto-detect latest)
#   AUTO_SUBMIT     — Set to "true" to execute curl automatically
#
# ============================================================================
set -euo pipefail

# --- Check dependencies ---
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install: brew install jq (mac) or apt install jq (linux)"
    exit 1
fi

# --- Locate broadcast JSON ---
if [[ -n "${BROADCAST_FILE:-}" ]]; then
    BROADCAST="$BROADCAST_FILE"
else
    # Find most recent run-latest.json under CowSwapSmoke broadcasts (exclude dry-run)
    BROADCAST=$(find broadcast/CowSwapSmoke.s.sol -name "run-latest.json" -not -path "*/dry-run/*" -type f 2>/dev/null | head -1)
    if [[ -z "$BROADCAST" ]]; then
        echo "Error: No broadcast found. Run CowSwapSmoke.s.sol with --broadcast first."
        exit 1
    fi
fi
echo "Using broadcast: $BROADCAST"

# --- OrderCreated event signature (constant) ---
EVENT_SIG="0x41a7e2b9a6f9fee038de5c9f72781454a4b1b4dff86a7118070f1fdf111bc8e1"

# --- Find the OrderCreated log in any receipt ---
ORDER_LOG=$(jq -r --arg sig "$EVENT_SIG" '
    [.receipts[].logs[] | select(.topics[0] == $sig)] | last
' "$BROADCAST")

if [[ "$ORDER_LOG" == "null" || -z "$ORDER_LOG" ]]; then
    echo "Error: No OrderCreated event found in broadcast receipts."
    echo "Make sure executeAction() succeeded (check forge script output)."
    exit 1
fi

# --- Extract fields from the event ---
ORDER_ID=$(echo "$ORDER_LOG" | jq -r '.topics[1]')
NODE_RAW=$(echo "$ORDER_LOG" | jq -r '.topics[2]')
MODULE=$(echo "$ORDER_LOG" | jq -r '.address')
DATA=$(echo "$ORDER_LOG" | jq -r '.data')

# Strip 0x prefix from data, then extract 32-byte words
DATA_HEX="${DATA#0x}"
# OrderCreated data layout: sellToken(0), buyToken(1), sellAmount(2), minBuyAmount(3), validTo(4), appData(5)
SELL_TOKEN="0x${DATA_HEX:24:40}"
BUY_TOKEN="0x${DATA_HEX:$((64+24)):40}"
SELL_AMOUNT_HEX="${DATA_HEX:$((128)):64}"
MIN_BUY_HEX="${DATA_HEX:$((192)):64}"
VALID_TO_HEX="${DATA_HEX:$((256)):64}"
APP_DATA="0x${DATA_HEX:$((320)):64}"

# Convert hex to decimal
SELL_AMOUNT=$(printf '%d' "0x$SELL_AMOUNT_HEX")
MIN_BUY_AMOUNT=$(printf '%d' "0x$MIN_BUY_HEX")
VALID_TO=$(printf '%d' "0x$VALID_TO_HEX")

# Node address from indexed topic (strip 0x000...000 padding)
NODE="0x${NODE_RAW: -40}"

# Checksummed module address (use as-is from log, cast can fix casing)
MODULE_ADDR="$MODULE"

# Build Order UID: orderId (32 bytes) + module (20 bytes) + validTo (4 bytes)
ORDER_ID_BARE="${ORDER_ID#0x}"
MODULE_BARE="${MODULE_ADDR#0x}"
VALID_TO_4BYTE=$(printf '%08x' "$VALID_TO")
MODULE_LOWER=$(echo "$MODULE_BARE" | tr '[:upper:]' '[:lower:]')
ORDER_UID="0x${ORDER_ID_BARE}${MODULE_LOWER}${VALID_TO_4BYTE}"

# --- Auto-detect CowSwap API from chain ID ---
if [[ -z "${COWSWAP_API:-}" ]]; then
    CHAIN_ID=$(jq -r '.chain // empty' "$BROADCAST")
    case "$CHAIN_ID" in
        8453)  COWSWAP_API="https://api.cow.fi/base" ;;
        1)     COWSWAP_API="https://api.cow.fi/mainnet" ;;
        42161) COWSWAP_API="https://api.cow.fi/arbitrum_one" ;;
        100)   COWSWAP_API="https://api.cow.fi/xdai" ;;
        *)     COWSWAP_API="https://api.cow.fi/mainnet"
               echo "Warning: Unknown chain $CHAIN_ID, defaulting to mainnet API" ;;
    esac
fi

# --- Print summary ---
echo ""
echo "============================================================="
echo "  Order extracted from broadcast"
echo "============================================================="
echo "Order ID:       $ORDER_ID"
echo "Node:           $NODE"
echo "Module:         $MODULE_ADDR"
echo "Sell Token:     $SELL_TOKEN"
echo "Buy Token:      $BUY_TOKEN"
echo "Sell Amount:    $SELL_AMOUNT"
echo "Min Buy Amount: $MIN_BUY_AMOUNT"
echo "Valid To:       $VALID_TO ($(date -r "$VALID_TO" 2>/dev/null || date -d "@$VALID_TO" 2>/dev/null || echo "N/A"))"
echo "App Data:       $APP_DATA"
echo "API:            $COWSWAP_API"
echo "============================================================="

# --- Build curl command ---
CURL_CMD="curl -X POST '${COWSWAP_API}/api/v1/orders' \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"sellToken\": \"${SELL_TOKEN}\",
    \"buyToken\": \"${BUY_TOKEN}\",
    \"receiver\": \"${NODE}\",
    \"sellAmount\": \"${SELL_AMOUNT}\",
    \"buyAmount\": \"${MIN_BUY_AMOUNT}\",
    \"validTo\": ${VALID_TO},
    \"appData\": \"${APP_DATA}\",
    \"feeAmount\": \"0\",
    \"kind\": \"sell\",
    \"partiallyFillable\": false,
    \"sellTokenBalance\": \"erc20\",
    \"buyTokenBalance\": \"erc20\",
    \"signingScheme\": \"eip1271\",
    \"signature\": \"${ORDER_ID}\",
    \"from\": \"${MODULE_ADDR}\"
  }'"

if [[ "${AUTO_SUBMIT:-false}" == "true" ]]; then
    echo ""
    echo "Submitting order to CowSwap API..."
    echo ""
    eval "$CURL_CMD"
    echo ""
else
    echo ""
    echo "============================================================="
    echo "  Run this curl to submit the order:"
    echo "============================================================="
    echo ""
    echo "$CURL_CMD"
    echo ""
fi

# --- Print monitoring commands ---
echo "============================================================="
echo "  Monitor"
echo "============================================================="
echo ""
echo "CowSwap Explorer:"
echo "  https://explorer.cow.fi/orders/${ORDER_UID}"
echo ""
echo "# Check if filled:"
echo "#   cast call 0x9008D19f58AAbD9eD0D60971565AA8510560ab41 'filledAmount(bytes)(uint256)' ${ORDER_UID}"
echo ""
echo "# Check buyToken at Node:"
echo "#   cast call ${BUY_TOKEN} 'balanceOf(address)(uint256)' ${NODE}"
echo ""
echo "# Cancel (owner only):"
echo "#   cast send ${MODULE_ADDR} 'cancelOrder(bytes32)' ${ORDER_ID}"
echo ""
