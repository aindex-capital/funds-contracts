#!/usr/bin/env bash
#
# Deploy AINDEX Funds to Robinhood Chain: every contract and adapter, the public teller with its fee contracts and
# the holders' pockets, and the production price configuration from script/funds-config.json proposed (Chainlink
# feeds, pool TWAPs, the weekend pools, sessions and the weekend inflow cap; applied a day later by
# script/apply-pending.sh). Writes every address
# to deployments/4663.json and refuses to run if that file already exists.
#
#   script/deploy-funds.sh            from any directory, with a .env file at the repository root defining
#                                     the deployer (DEPLOYER_ACCOUNT, a Foundry keystore name: recommended; or
#                                     DEPLOYER_PRIVATE_KEY; exactly one), FUNDS_REVIEWER (AINDEX operator wallet:
#                                     registry reviewer and Morpho market registry owner), FUNDS_PRICE_OWNER (owner of the price router,
#                                     sources, session pool source and recorder), FUNDS_GUARDIAN (guardian of new Funds) and FUNDS_KEEPERS
#                                     (comma-separated: who may settle teller batches; also the price recorders unless
#                                     FUNDS_RECORDERS is set). FUNDS_RPC overrides the RPC (default
#                                     https://rpc.ordofi.network: the public RPC turns Foundry away).
#
#   DEPLOYER_ACCOUNT=aindex-deployer EXPECTED_DEPLOYER=0x... script/deploy-funds.sh
#                                     with a keystore: one password prompt to read its address, one more when
#                                     forge signs. See script/preflight.sh.
#
#   DRY_RUN=1 script/deploy-funds.sh  simulate everything against the RPC and send nothing. The record goes to a
#                                     temporary file that is deleted afterwards. With a keystore the simulation
#                                     runs as its address (one password prompt) and signs nothing.
#
# Before anything is sent, script/preflight.sh checks the tree is clean, the RPC is chain 4663 and, if
# EXPECTED_DEPLOYER is set, that the deployer (keystore or key) is that address. Contracts above 24 KB (the Teller,
# the Fables, Uniswap and Morpho adapters, the controller, the factory's initcode) are fine on Robinhood Chain, which accepts far larger code
# (checked 2026-10-01 with eth_estimateGas: a 60,000-byte contract deploys, a 100,000-byte one does not), hence
# --disable-code-size-limit for the simulation.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
mkdir -p deployments

# Every value here is permanent or holds a role: no defaults.
: "${FUNDS_REVIEWER:?set FUNDS_REVIEWER (AINDEX operator wallet: verifies adapters, owns the Morpho market registry)}"
: "${FUNDS_KEEPERS:?set FUNDS_KEEPERS (comma-separated keeper wallets that may settle teller batches)}"
: "${FUNDS_PRICE_OWNER:?set FUNDS_PRICE_OWNER (owns the price router and sources; must accept ownership after)}"
: "${FUNDS_GUARDIAN:?set FUNDS_GUARDIAN (guardian of every new Fund)}"
preflight_address FUNDS_REVIEWER
preflight_address FUNDS_PRICE_OWNER
preflight_address FUNDS_GUARDIAN
RECS="${FUNDS_RECORDERS:-}"
for k in ${FUNDS_KEEPERS//,/ } ${RECS//,/ }; do
  [[ "$k" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "not an address in FUNDS_KEEPERS or FUNDS_RECORDERS: $k"; exit 1; }
  [ "$(echo "$k" | tr 'A-F' 'a-f')" != "0x0000000000000000000000000000000000000000" ] ||
    { echo "the zero address in FUNDS_KEEPERS or FUNDS_RECORDERS"; exit 1; }
done
export FUNDS_TELLER_ADMIN="${FUNDS_TELLER_ADMIN:-$FUNDS_REVIEWER}"
export FUNDS_AIX_RECIPIENT="${FUNDS_AIX_RECIPIENT:-0x8d3e8ccCD0062f3b780a166bdd1DFCB3dfbAEFc5}"
export FUNDS_TREASURY="${FUNDS_TREASURY:-0x230C4Df28A0065216F2BEf86122125c0F8e4A5af}"
preflight_address FUNDS_TELLER_ADMIN
preflight_address FUNDS_AIX_RECIPIENT
preflight_address FUNDS_TREASURY
# The deploying account: DEPLOYER_ACCOUNT (a keystore; asks for its password once here) or DEPLOYER_PRIVATE_KEY.
preflight_signer DEPLOYER

RPC="${FUNDS_RPC:-https://rpc.ordofi.network}"

if [ "${DRY_RUN:-0}" = "1" ]; then
  OUT="deployments/.dry-run-4663.json"
  trap 'rm -f "$OUT"' EXIT
else
  OUT="${FUNDS_DEPLOYMENT_OUT:-deployments/4663.json}"
  [ -e "$OUT" ] && { echo "$OUT exists: Funds are already deployed there. Remove it only if you mean to deploy again."; exit 1; }
fi

preflight "$RPC"

export FUNDS_SOURCE_REF="$(git rev-parse HEAD)"
export FUNDS_DEPLOYMENT_OUT="$OUT"
forge script script/DeployFunds.s.sol:DeployFunds --rpc-url "$RPC" "${SIGNER_ARGS[@]}" \
  $BROADCAST --slow --disable-code-size-limit

# FundBook, TellerOps, TellerMath and TellerQueue are linked libraries forge deployed first; add them to the record.
CHAIN="$(cast chain-id --rpc-url "$RPC")"
RUN="broadcast/DeployFunds.s.sol/$CHAIN/run-latest.json"
[ "${DRY_RUN:-0}" = "1" ] && RUN="broadcast/DeployFunds.s.sol/$CHAIN/dry-run/run-latest.json"
python3 - "$OUT" "$RUN" <<'PY'
import json, sys
out, run = sys.argv[1], sys.argv[2]
rec = json.load(open(out)); r = json.load(open(run))
for l in r.get("libraries", []):
    _, name, addr = l.split(":")
    if name in ("FundBook", "TellerOps", "TellerMath", "TellerQueue"):
        rec[name[0].lower() + name[1:]] = addr
if "receipts" in r and r["receipts"]:
    rec["deployGas"] = sum(int(x["gasUsed"], 16) for x in r["receipts"])
json.dump(rec, open(out, "w"), indent=2, sort_keys=True); open(out, "a").write("\n")
PY

echo "==> record: $OUT"
cat "$OUT"
[ "${DRY_RUN:-0}" = "1" ] && echo "==> dry run done: nothing was sent."
echo "==> next: after $(python3 -c "import json,datetime;print(datetime.datetime.fromtimestamp(json.load(open('$OUT'))['applyAfter'],datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC'))"), run script/apply-pending.sh"
