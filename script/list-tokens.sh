#!/usr/bin/env bash
#
# List tokens added to funds-config.json after the first deploy (`twap` additions and `recorded`) with their sources and the PriceRouter. Run by the
# price owner (the `aindex-deployer` keystore). Each token waits the router's 1-day delay; then run
# script/apply-pending.sh, which applies them with everything else pending.
#
#   script/list-vault-shares.sh             with DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY in .env
#   DRY_RUN=1 script/list-vault-shares.sh   simulate only
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
forge script script/ListTokens.s.sol:ListTokens --rpc-url "$RPC" \
  "${SIGNER_ARGS[@]}" $BROADCAST --slow
