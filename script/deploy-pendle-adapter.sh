#!/usr/bin/env bash
#
# Deploy the Pendle adapter implementation and register it with the AdapterRegistry (verified in the same run when the
# signer is the registry's reviewer, which the `aindex-deployer` keystore is). Writes deployments/4663-pendle.json.
#
#   script/deploy-pendle-adapter.sh             with DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY in .env
#   DRY_RUN=1 script/deploy-pendle-adapter.sh   simulate only
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
forge script script/DeployPendleAdapter.s.sol:DeployPendleAdapter --rpc-url "$RPC" \
  "${SIGNER_ARGS[@]}" $BROADCAST --slow
