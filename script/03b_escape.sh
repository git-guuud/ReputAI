#!/usr/bin/env bash
# T6 demo, beat 3 — the escape attempts.
#
# The agent tries the three moves that would break containment: transfer its name, repoint its
# resolver, and rewrite its payout address. All three revert on-chain.
#
# This is a shell script rather than a beat in `03_Demo.s.sol` because `forge script` simulates
# before it broadcasts and refuses to send a call that reverts — which is every call here. `cast
# send --gas-limit` skips estimation, so the failures land on Sepolia as clickable transactions
# with their revert reasons decoded by Etherscan. Each attempt is shown twice: first as an
# `eth_call` (so the revert reason is printed here), then as the real transaction.
#
# Usage: script/03b_escape.sh          # simulate and send
#        script/03b_escape.sh --dry    # simulate only, spend nothing
set -euo pipefail

cd "$(dirname "$0")/.."
set -a && . ./.env && set +a

DEPLOYMENT_FILE=${DEPLOYMENT_FILE:-./deployments/sepolia.json}
DEMO_FILE=${DEMO_FILE:-./deployments/demo-sepolia.json}
DRY=${1:-}

REGISTRY=$(jq -r .operatorRegistry "$DEPLOYMENT_FILE")
RESOLVER=$(jq -r .resolver "$DEPLOYMENT_FILE")
TOKEN_ID=$(jq -r .tokenId "$DEMO_FILE")
NODE=$(jq -r .agentNode "$DEMO_FILE")
AGENT=$(jq -r .agent "$DEMO_FILE")
ATTACKER=0x000000000000000000000000000000000000bAdD

echo "beat 3 - escape attempts, all from the agent's own key"
echo "  agent    : $AGENT"
echo "  registry : $REGISTRY"
echo "  resolver : $RESOLVER"
echo "  tokenId  : $TOKEN_ID"
echo

# The two revert reasons this beat is expecting, decoded locally rather than through a selector
# database, so the demo names the mechanism instead of printing hex:
#   TransferDisallowed          -- the name is soulbound to the agent, because transfer is gated on
#                                  ROLE_CAN_TRANSFER_ADMIN held by the *sender*, which it lacks.
#   EACUnauthorizedAccountRoles -- the agent holds no such role at that resource. `resource` says
#                                  where it was checked: the name-wide resource for setResolver and
#                                  for setAddr, never one of its two authorized text keys.
decode_revert() {
  local data=$1 sel=${1:0:10} sig=""
  case "$sel" in
    0xe58f6d5a) sig="TransferDisallowed(uint256,address)" ;;
    0x4b27a133) sig="EACUnauthorizedAccountRoles(uint256,uint256,address)" ;;
  esac
  if [ -n "$sig" ]; then
    echo "    reverted: ${sig%%(*}"
    cast decode-error "$data" --sig "$sig" | sed 's/^/      /'
  else
    echo "    reverted: $data"
  fi
}

attempt() {
  local what=$1 target=$2 sig=$3
  shift 3
  echo "--- $what"
  # eth_call first: names the revert reason without spending anything.
  local out
  if out=$(cast call "$target" "$sig" "$@" --from "$AGENT" --rpc-url "$SEPOLIA_RPC_URL" 2>&1); then
    echo "    !!! DID NOT REVERT -- containment is broken, stop the demo"
    exit 1
  fi
  decode_revert "$(echo "$out" | grep -oE '0x[0-9a-fA-F]{8,}' | tail -1)"
  if [ "$DRY" = "--dry" ]; then echo; return; fi
  # Then for real, with an explicit gas limit so estimation is skipped and the failure is mined.
  cast send "$target" "$sig" "$@" \
    --private-key "$DEMO_AGENT_PK" \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --gas-limit 120000 \
    --json 2>/dev/null | jq -r '"    tx: \(.transactionHash)  status: \(.status) (0x0 = reverted, as intended)"'
  echo
}

attempt "transfer the name to an attacker" \
  "$REGISTRY" "safeTransferFrom(address,address,uint256,uint256,bytes)" \
  "$AGENT" "$ATTACKER" "$TOKEN_ID" 1 0x

attempt "repoint the resolver" \
  "$REGISTRY" "setResolver(uint256,address)" \
  "$TOKEN_ID" "$ATTACKER"

attempt "rewrite the payout address" \
  "$RESOLVER" "setAddr(bytes32,address)" \
  "$NODE" "$ATTACKER"

echo "state after all three attempts (unchanged):"
echo "  owner    : $(cast call "$REGISTRY" 'ownerOf(uint256)(address)' "$TOKEN_ID" --rpc-url "$SEPOLIA_RPC_URL")"
echo "  resolver : $(cast call "$REGISTRY" 'getResolver(uint256)(address)' "$TOKEN_ID" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || cast call "$REGISTRY" 'getResolver(string)(address)' "$(jq -r .label "$DEMO_FILE")" --rpc-url "$SEPOLIA_RPC_URL")"
echo "  addr()   : $(cast call "$RESOLVER" 'addr(bytes32)(address)' "$NODE" --rpc-url "$SEPOLIA_RPC_URL")"
