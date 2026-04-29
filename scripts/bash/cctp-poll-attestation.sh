#!/usr/bin/env bash
# Poll Circle's Iris API for a CCTP V2 attestation and print message + attestation when ready.
#
# Usage:
#   source .env
#   bash scripts/bash/cctp-poll-attestation.sh <SOURCE_TX_HASH>
#
# Required env vars: IRIS_API, SOURCE_DOMAIN
# Optional: POLL_INTERVAL (default 15 seconds)

set -euo pipefail

TX_HASH="${1:-${SOURCE_TX_HASH:-}}"
if [ -z "$TX_HASH" ]; then
  echo "Usage: bash scripts/bash/cctp-poll-attestation.sh <SOURCE_TX_HASH>"
  echo "  or set SOURCE_TX_HASH env var"
  exit 1
fi

IRIS_API="${IRIS_API:?Set IRIS_API in .env (https://iris-api-sandbox.circle.com or https://iris-api.circle.com)}"
SOURCE_DOMAIN="${SOURCE_DOMAIN:?Set SOURCE_DOMAIN in .env (e.g. 0 for Ethereum, 6 for Base)}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

API_URL="$IRIS_API/v2/messages/$SOURCE_DOMAIN?transactionHash=$TX_HASH"
echo "Polling: $API_URL"
echo "Interval: ${POLL_INTERVAL}s"
echo ""

while true; do
  RESPONSE=$(curl -s "$API_URL")
  STATUS=$(echo "$RESPONSE" | jq -r '.messages[0].status // "not_found"')
  echo "$(date +%H:%M:%S) - $STATUS"

  if [ "$STATUS" = "complete" ]; then
    echo ""
    MESSAGE=$(echo "$RESPONSE" | jq -r '.messages[0].message')
    ATTESTATION=$(echo "$RESPONSE" | jq -r '.messages[0].attestation')

    echo "=== Attestation Ready ==="
    echo "MESSAGE=$MESSAGE"
    echo ""
    echo "ATTESTATION=$ATTESTATION"
    echo ""

    # Print decoded info
    echo "=== Decoded ==="
    echo "$RESPONSE" | jq '{
      status: .messages[0].status,
      sourceDomain: .messages[0].decodedMessage.sourceDomain,
      destinationDomain: .messages[0].decodedMessage.destinationDomain,
      mintRecipient: .messages[0].decodedMessage.decodedMessageBody.mintRecipient,
      amount: .messages[0].decodedMessage.decodedMessageBody.amount,
      fee: .messages[0].decodedMessage.decodedMessageBody.feeExecuted
    }'

    echo ""
    echo "=== Next Step ==="
    echo "Run on the destination chain:"
    echo "  cast send \$MESSAGE_TRANSMITTER_V2 'receiveMessage(bytes,bytes)' \\"
    echo "    $MESSAGE \\"
    echo "    $ATTESTATION \\"
    echo '    --mnemonic "$MNEMONIC" --rpc-url $DEST_RPC_URL'
    break
  fi

  sleep "$POLL_INTERVAL"
done
