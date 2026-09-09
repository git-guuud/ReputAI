#!/usr/bin/env bash
# T6 demo, beat 4 (second half) — the payment that gets refused.
#
# `Beat4_Revoke` shows the verifier's verdict flip to `Unresolvable` in a view call. This sends
# the payment anyway, so the refusal exists as a transaction a viewer can click: same
# counterparty, same message, same operating key, same signature as the payment that worked one
# beat earlier. Only the ENS state changed.
#
# Like beat 3 this is `cast` rather than `forge script`, because the transaction must revert and
# `forge script` refuses to broadcast a call that reverts in simulation.
#
# Usage: script/03c_refused.sh          # show the refusal, then send it
#        script/03c_refused.sh --dry    # show the refusal only, spend nothing
set -euo pipefail

cd "$(dirname "$0")/.."
set -a && . ./.env && set +a

DEPLOYMENT_FILE=${DEPLOYMENT_FILE:-./deployments/sepolia.json}
DEMO_FILE=${DEMO_FILE:-./deployments/demo-sepolia.json}
DRY=${1:-}

VERIFIER=$(jq -r .verifier "$DEPLOYMENT_FILE")
NAME=$(jq -r .agentNameEncoded "$DEMO_FILE")
AGENT_NAME=$(jq -r .agentName "$DEMO_FILE")
COUNTERPARTY=$(jq -r .counterparty "$DEMO_FILE")
PAY_WEI=${DEMO_PAY_WEI:-1000000000000000}

MESSAGE=${DEMO_MESSAGE:?set DEMO_MESSAGE in .env}
MSG_HEX=$(cast from-utf8 "$MESSAGE")
# The agent's current operating key signs, exactly as it did for the payment that succeeded. The
# key is not the problem; the name is gone.
SIG=$(cast wallet sign --private-key "$DEMO_KEY_ROTATED_PK" "$MESSAGE")

echo "beat 4 - the counterparty tries to pay a revoked agent"
echo "  agent name   : $AGENT_NAME"
echo "  verifier     : $VERIFIER"
echo "  counterparty : $COUNTERPARTY"
echo "  signed by    : $(cast wallet address --private-key "$DEMO_KEY_ROTATED_PK") (unchanged)"
echo

out=$(cast call "$VERIFIER" "payAgent(bytes,bytes,bytes)(address)" "$NAME" "$MSG_HEX" "$SIG" \
  --from "$COUNTERPARTY" --value "$PAY_WEI" --rpc-url "$SEPOLIA_RPC_URL" 2>&1) && {
  echo "  !!! THE PAYMENT WENT THROUGH — the agent is not revoked, stop the demo"
  exit 1
}

# Refusal is a value, not just a revert: the enum ordinal says which check failed.
# 1 = Unresolvable, which is what the kill switch looks like from outside ENS.
data=$(echo "$out" | grep -oE '0x[0-9a-fA-F]{8,}' | tail -1)
echo "  refused:"
cast decode-error "$data" --sig "Refused(uint8,bytes)" | sed 's/^/    /'
echo "    (reason 1 = Unresolvable: the name has no resolver of its own any more)"
echo

if [ "$DRY" = "--dry" ]; then exit 0; fi

cast send "$VERIFIER" "payAgent(bytes,bytes,bytes)" "$NAME" "$MSG_HEX" "$SIG" \
  --value "$PAY_WEI" \
  --private-key "$DEMO_COUNTERPARTY_PK" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --gas-limit 200000 \
  --json 2>/dev/null | jq -r '"  tx: \(.transactionHash)  status: \(.status) (0x0 = refused, as intended)"'

echo "  treasury balance unchanged: $(cast balance "$(jq -r .treasury "$DEMO_FILE")" --rpc-url "$SEPOLIA_RPC_URL" -e) ETH"
