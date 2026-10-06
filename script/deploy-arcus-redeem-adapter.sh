#!/usr/bin/env bash
#
# Deploy the Arcus pToken redeem adapter and register it with the Funds' AdapterRegistry. Run by the deployer (the
# `aindex-deployer` keystore, which is also the registry's reviewer, so the adapter is marked verified in the same run).
# Writes deployments/4663-arcus-redeem.json. A Fund's owner enables it with addAdapter(implementation, 0x).
#
#   script/deploy-arcus-redeem-adapter.sh             with DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY in .env
#   DRY_RUN=1 script/deploy-arcus-redeem-adapter.sh   simulate only
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
forge script script/DeployArcusRedeemAdapter.s.sol:DeployArcusRedeemAdapter --rpc-url "$RPC" \
  "${SIGNER_ARGS[@]}" $BROADCAST --slow
