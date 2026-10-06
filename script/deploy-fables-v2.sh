#!/usr/bin/env bash
#
# Deploy FablesLiquidityAdapterV2 (v1 plus native ETH pools, held by the vault as WETH) and register it with the Funds'
# AdapterRegistry. Run by the deployer (the `aindex-deployer` keystore, which is also the registry's reviewer, so the
# adapter is marked verified in the same run). Writes deployments/4663-fables-v2.json with the config bytes (every
# active Fables hook, ETH hooks included) a Fund owner passes to addAdapter. v1 stays registered: live Funds use it.
#
#   script/deploy-fables-v2.sh             with DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY in .env
#   DRY_RUN=1 script/deploy-fables-v2.sh   simulate only
#
# The implementation is about 36 KB: over Ethereum's 24,576-byte limit, under Robinhood Chain's 49,152 (v1 on mainnet
# is 33,984), hence --disable-code-size-limit for the simulation, as script/deploy-funds.sh does.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
preflight_signer DEPLOYER
# Sends through the official RPC: Ordofi has served a stale nonce (it broke deploy-clm-adapter on 2026-10-06).
RPC="${FUNDS_RPC:-https://rpc.mainnet.chain.robinhood.com}"
export FUNDS_DEPLOYMENT="${FUNDS_DEPLOYMENT:-deployments/4663.json}"
[ -f "$FUNDS_DEPLOYMENT" ] || preflight_fail "$FUNDS_DEPLOYMENT not found"
preflight "$RPC"
# The check (walk every Fables pool, probe a clone with the config) reads thousands of storage slots: on the official
# RPC that tripped Cloudflare's bot challenge (HTTP 403, 2026-10-06). So forge simulates against READ_RPC, which
# serves heavy reads, and the three transactions go out through the official RPC with forge create and cast.
READ_RPC="${READ_RPC:-https://rpc.ordofi.network}"
OUT="${FABLES_V2_OUT:-deployments/4663-fables-v2.json}"
forge script script/DeployFablesV2.s.sol:DeployFablesV2 --rpc-url "$READ_RPC" \
  --sender "$SIGNER_ADDRESS" --disable-code-size-limit
[ -n "$BROADCAST" ] || exit 0
SEND_ARGS=()
for ((i = 0; i < ${#SIGNER_ARGS[@]}; i++)); do
  case "${SIGNER_ARGS[$i]}" in --sender) i=$((i + 1)) ;; *) SEND_ARGS+=("${SIGNER_ARGS[$i]}") ;; esac
done
REGISTRY="$(jq -r .adapterRegistry "$FUNDS_DEPLOYMENT")"
REF="${FUNDS_SOURCE_REF:-main}"
IMPL="$(forge create src/adapters/liquidity/FablesLiquidityAdapterV2.sol:FablesLiquidityAdapterV2 --rpc-url "$RPC" \
  "${SEND_ARGS[@]}" --broadcast --json --constructor-args \
  0x159A113E012593D9B3cC63ad45E30F0467e13Ef3 0x8366a39CC670B4001A1121B8F6A443A643e40951 \
  0xC9EcC11728a4955B31f77c077B97FEC521D78760 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 | jq -r .deployedTo)"
[[ "$IMPL" =~ ^0x[0-9a-fA-F]{40}$ ]] || preflight_fail "forge create gave no address"
echo "FablesLiquidityAdapterV2 implementation $IMPL"
cast send --rpc-url "$RPC" "${SEND_ARGS[@]}" "$REGISTRY" 'register(address,string)' "$IMPL" \
  "https://github.com/aindex-capital/funds-contracts/blob/$REF/src/adapters/liquidity/FablesLiquidityAdapterV2.sol" --json | jq -r '"registered: \(.transactionHash) status \(.status)"'
VERIFIED=false
if [ "$(cast call --rpc-url "$RPC" "$REGISTRY" 'reviewer()(address)')" = "$SIGNER_ADDRESS" ]; then
  cast send --rpc-url "$RPC" "${SEND_ARGS[@]}" "$REGISTRY" 'setVerified(address,bool)' "$IMPL" true --json | jq -r '"verified: \(.transactionHash) status \(.status)"'
  VERIFIED=true
else
  echo "registered, NOT verified: the registry's reviewer should send setVerified($IMPL, true)"
fi
# The simulation wrote the config (it does not depend on the address); record the real address.
jq --arg a "$IMPL" --argjson v "$VERIFIED" '.implementation = $a | .verified = $v' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "wrote $OUT"
