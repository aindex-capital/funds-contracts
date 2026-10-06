#!/usr/bin/env bash
#
# Deploy the managed liquidity adapter (Beefy CLM and Arrowfarm vaults) and register it with the Funds' AdapterRegistry.
# Run by the deployer (the `aindex-deployer` keystore, which is also the registry's reviewer, so the adapter is marked
# verified in the same run). Writes deployments/4663-clm.json with the config bytes a Fund owner passes to addAdapter.
#
#   script/deploy-clm-adapter.sh             with DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY in .env
#   DRY_RUN=1 script/deploy-clm-adapter.sh   simulate only
#
# The implementation is about 27 KB: over Ethereum's 24,576-byte limit, under Robinhood Chain's 49,152 (the Fables
# adapter on mainnet is 33,984), hence --disable-code-size-limit for the simulation, as script/deploy-funds.sh does.
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
forge script script/DeployClmAdapter.s.sol:DeployClmAdapter --rpc-url "$RPC" \
  "${SIGNER_ARGS[@]}" $BROADCAST --slow --disable-code-size-limit
