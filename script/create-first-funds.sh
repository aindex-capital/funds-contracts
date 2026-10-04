#!/usr/bin/env bash
#
# Create AINDEX's own first Funds: one script/create-fund.sh run per entry of script/first-funds.json (FIRST_FUNDS to
# use another file). Entries whose manager is still the zero address, and Funds whose record already exists, are
# skipped, so it is safe to rerun after filling in more managers.
#
#   OWNER_ACCOUNT=aindex-owner script/create-first-funds.sh      the account owns every Fund and pays every stake
#   DRY_RUN=1 OWNER_ACCOUNT=aindex-owner script/create-first-funds.sh
#
# OWNER_ACCOUNT is a Foundry keystore name (recommended): its password is asked once here to read the address, then
# once per Fund when forge signs (not under DRY_RUN=1). OWNER_PRIVATE_KEY=0x... works instead; exactly one of the two.
# Both may also sit in .env (ENV_FILE to use another file).
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
preflight_signer OWNER
[ -z "${FUND_OWNER:-}" ] || [ "$(preflight_lower "$FUND_OWNER")" = "$(preflight_lower "$SIGNER_ADDRESS")" ] ||
  preflight_fail "$SIGNER_HOW is $SIGNER_ADDRESS, expected FUND_OWNER $FUND_OWNER"
echo "==> Fund owner $SIGNER_ADDRESS ($SIGNER_HOW)"
[ -z "${OWNER_ACCOUNT:-}" ] || export OWNER_ACCOUNT_ADDRESS="$SIGNER_ADDRESS"
LIST="${FIRST_FUNDS:-script/first-funds.json}"
N=$(python3 -c "import json;print(len(json.load(open('$LIST'))['funds']))")
for i in $(seq 0 $((N - 1))); do
  eval "$(python3 - "$LIST" "$i" <<'PY'
import json, shlex, sys
f = json.load(open(sys.argv[1]))["funds"][int(sys.argv[2])]
env = dict(FUND_NAME=f["name"], FUND_SYMBOL=f["symbol"], FUND_MANAGER=f["manager"], FUND_DIAL=f["dial"],
           FUND_STAKE_USDG=str(f["stakeUsdg"]), FUND_MANAGEMENT_BPS=str(f["managementBps"]),
           FUND_PERFORMANCE_BPS=str(f["performanceBps"]), FUND_STRATEGY=f["strategy"])
print("\n".join(f"export {k}={shlex.quote(v)}" for k, v in env.items()))
PY
)"
  if [ "$(echo "$FUND_MANAGER" | tr 'A-F' 'a-f')" = "0x0000000000000000000000000000000000000000" ]; then
    echo "==> $FUND_SYMBOL: no manager yet in $LIST, skipped"; continue
  fi
  if [ "${DRY_RUN:-0}" != "1" ] && [ -e "deployments/fund-$FUND_SYMBOL.json" ]; then
    echo "==> $FUND_SYMBOL: already created (deployments/fund-$FUND_SYMBOL.json), skipped"; continue
  fi
  echo "==> $FUND_SYMBOL: $FUND_NAME"
  script/create-fund.sh
done
