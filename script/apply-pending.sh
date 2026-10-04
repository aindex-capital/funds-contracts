#!/usr/bin/env bash
#
# Apply the price configuration DeployFunds proposed, once its 1-day delay has passed. Anyone may run it: applying
# a pending change needs no role. Stops without sending if anything is not yet due; ends by listing any token that
# still has no usable price.
#
#   script/apply-pending.sh            with DEPLOYER_ACCOUNT (a Foundry keystore name, recommended) or
#                                      DEPLOYER_PRIVATE_KEY in .env, exactly one: any funded account will do;
#                                      FUNDS_RPC and FUNDS_DEPLOYMENT (default deployments/4663.json) as for the
#                                      deploy. EXPECTED_DEPLOYER, if set, is checked here too.
#   DRY_RUN=1 script/apply-pending.sh  simulate only (with a keystore: one password prompt, nothing signed).
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
preflight_signer DEPLOYER # DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY: any funded account
RPC="${FUNDS_RPC:-https://rpc.ordofi.network}"
export FUNDS_DEPLOYMENT="${FUNDS_DEPLOYMENT:-deployments/4663.json}"
[ -f "$FUNDS_DEPLOYMENT" ] || preflight_fail "$FUNDS_DEPLOYMENT not found: deploy first"
preflight "$RPC"
forge script script/ApplyPending.s.sol:ApplyPending --rpc-url "$RPC" \
  "${SIGNER_ARGS[@]}" $BROADCAST --slow
