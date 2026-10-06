#!/usr/bin/env bash
#
# Make Robinhood Chain's Pendle markets usable by Funds' Pendle adapter: raises each market's oracle cardinality to
# what a 15-minute TWAP needs (permissionless; any funded key). Markets default to every active one; the oracle is
# ready about 15 minutes after.
#
#   script/pendle-oracles.sh               with DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY in .env
#   DRY_RUN=1 script/pendle-oracles.sh     simulate only
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
preflight_signer DEPLOYER
# Sends through the official RPC: Ordofi has served a stale nonce.
RPC="${FUNDS_RPC:-https://rpc.mainnet.chain.robinhood.com}"
export PENDLE_MARKETS="${PENDLE_MARKETS:-0x206a5cd00e9ffabb8ca564076b64799a78df19b9,0x892defbf510d9baa96dbd2a51b13e879a857a79b,0xd6e26e957b3207a5c618213d928647ec84150ca0,0x25f241538bc3de8f7130706827b3f6946db51f5d,0x752057e7a63d0a7f15b740d41ef484fdec459ead,0x25ee3232421a08f390ef25a34b1d2ccc8394bd05}"
preflight "$RPC"
# Plain cast, not forge script: a simulation reads ~900 storage slots per market one by one, and the official RPC
# prunes the block forge pinned before it finishes ("historical state is not available", 2026-10-06).
SEND_ARGS=()
for ((i = 0; i < ${#SIGNER_ARGS[@]}; i++)); do
  case "${SIGNER_ARGS[$i]}" in --sender) i=$((i + 1)) ;; *) SEND_ARGS+=("${SIGNER_ARGS[$i]}") ;; esac
done
ORACLE=0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2
for m in ${PENDLE_MARKETS//,/ }; do
  state=$(cast call --rpc-url "$RPC" "$ORACLE" 'getOracleState(address,uint32)(bool,uint16,bool)' "$m" 900 | tr '\n' ' ')
  read -r increase need _ <<<"$state"
  if [ "$increase" != true ]; then echo "ready already: $m"; continue; fi
  gas=$(cast estimate --rpc-url "$RPC" --from "$SIGNER_ADDRESS" "$m" 'increaseObservationsCardinalityNext(uint16)' "$need")
  if [ -z "$BROADCAST" ]; then echo "would raise $m to $need ($gas gas)"; continue; fi
  cast send --rpc-url "$RPC" "${SEND_ARGS[@]}" --gas-limit $((gas * 12 / 10)) "$m" 'increaseObservationsCardinalityNext(uint16)' "$need" --json \
    | jq -r '"raised '"$m"' to '"$need"': \(.transactionHash) status \(.status)"'
done
echo "the oracles are ready about 15 minutes after the last one"
