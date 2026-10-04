#!/usr/bin/env bash
#
# Create one Fund through the public teller: opened with the owner's stake (10 USDG by default), the chosen dial
# (open by default), fee rates, every adapter (or FUND_ADAPTERS) and a manager. The signing account becomes the
# Fund's owner and pays the stake, so it must hold that USDG and a little ETH for gas. Writes
# deployments/fund-<SYMBOL>.json.
#
#   OWNER_ACCOUNT=aindex-owner FUND_NAME="AINDEX Claude" FUND_SYMBOL=AX-CLAUDE FUND_MANAGER=0x... \
#     FUND_MANAGEMENT_BPS=100 FUND_PERFORMANCE_BPS=1000 script/create-fund.sh
#
# The owner signs with OWNER_ACCOUNT (a Foundry keystore name in ~/.foundry/keystores: recommended; one password
# prompt to read its address, one more when forge signs) or OWNER_PRIVATE_KEY (a raw key, as the anvil rehearsal
# does); exactly one. See script/preflight.sh.
#
# Optional (see script/CreateFund.s.sol): FUND_DIAL (open, balanced, conservative), FUND_STAKE_USDG (raw, 6 decimals),
# FUND_ADAPTERS, FUND_MANAGER_DAYS (default 90), FUND_FEE_RECIPIENT, FUND_OWNER, FUND_STRATEGY, FUND_OUT, FUNDS_RPC,
# FUNDS_DEPLOYMENT, DRY_RUN=1 to simulate. For AINDEX's own first Funds, script/create-first-funds.sh runs this once
# per entry of script/first-funds.json.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
mkdir -p deployments
: "${FUND_NAME:?set FUND_NAME}"
: "${FUND_SYMBOL:?set FUND_SYMBOL}"
: "${FUND_MANAGER:?set FUND_MANAGER (the agent session key or person who trades)}"
: "${FUND_MANAGEMENT_BPS:?set FUND_MANAGEMENT_BPS (a year, at most 200)}"
: "${FUND_PERFORMANCE_BPS:?set FUND_PERFORMANCE_BPS (of gains above the high-water mark, at most 2000)}"
preflight_address FUND_MANAGER
[ -z "${FUND_FEE_RECIPIENT:-}" ] || preflight_address FUND_FEE_RECIPIENT
[ -z "${FUND_OWNER:-}" ] || preflight_address FUND_OWNER
RPC="${FUNDS_RPC:-https://rpc.ordofi.network}"
export FUNDS_DEPLOYMENT="${FUNDS_DEPLOYMENT:-deployments/4663.json}"
[ -f "$FUNDS_DEPLOYMENT" ] || preflight_fail "$FUNDS_DEPLOYMENT not found: deploy first"
if [ "${DRY_RUN:-0}" = "1" ]; then
  export FUND_OUT="deployments/.dry-run-fund-$FUND_SYMBOL.json"; trap 'rm -f "$FUND_OUT"' EXIT
else
  OUT="${FUND_OUT:-deployments/fund-$FUND_SYMBOL.json}"
  [ -e "$OUT" ] && preflight_fail "$OUT exists: a Fund with this symbol was already created here"
fi
# The Fund owner, who holds the stake USDG: OWNER_ACCOUNT (keystore) or OWNER_PRIVATE_KEY. create-first-funds.sh
# reads a keystore's address once and passes it as OWNER_ACCOUNT_ADDRESS so each Fund does not ask again.
preflight_signer OWNER "${OWNER_ACCOUNT_ADDRESS:-}"
preflight "$RPC"
forge script script/CreateFund.s.sol:CreateFund --rpc-url "$RPC" "${SIGNER_ARGS[@]}" \
  $BROADCAST --slow
