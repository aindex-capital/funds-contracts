#!/usr/bin/env bash
#
# Deploy the second public teller for new AINDEX Funds next to the live deployment (deployments/4663.json): a new
# Teller (the owner's opening deposit as ordinary shares in its wallet; a Fund created ready to trade in one
# transaction with createFundWith), the contracts wired to one teller (FundFees, Pockets) and a new FundFactory with
# its ControllerDeployer (the controller's one-time creation setup). Everything else is reused: the adapter
# registry and every adapter, the price router and sources, the Morpho market registry, FeeConfig and the linked
# libraries FundBook, TellerMath, TellerOps and TellerQueue (linked by address; their code on chain is checked
# against this tree first). Existing Funds keep the first teller. Writes deployments/4663-teller-v2.json and refuses
# to run if it exists.
#
#   script/deploy-teller-v2.sh        from any directory, with a .env file at the repository root defining the
#                                     deployer (DEPLOYER_ACCOUNT, a Foundry keystore name: recommended; or
#                                     DEPLOYER_PRIVATE_KEY; exactly one). Optional: FUNDS_KEEPERS (comma-separated;
#                                     default the first deployment's keepers), FUNDS_TELLER_ADMIN (default the first
#                                     teller's admin), FUNDS_GUARDIAN (default the first factory's guardian),
#                                     FUNDS_RPC (default https://rpc.ordofi.network), DEPLOYER_ACCOUNT_ADDRESS (the
#                                     keystore's address, to skip the password prompt that reads it).
#
#   DRY_RUN=1 script/deploy-teller-v2.sh
#                                     simulate everything against the RPC and send nothing. The record goes to a
#                                     temporary file that is deleted afterwards. With a keystore the simulation runs
#                                     as its address and signs nothing.
#
# Before anything is sent, script/preflight.sh checks the tree is clean, the RPC is chain 4663 and, if
# EXPECTED_DEPLOYER is set, that the deployer is that address. The Teller's runtime code is above 24 KB (its initcode
# is under 49,152 bytes), fine on Robinhood Chain, hence --disable-code-size-limit for the simulation.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
. script/preflight.sh
V1="${FUNDS_V1_RECORD:-deployments/4663.json}"
[ -f "$V1" ] || preflight_fail "$V1 not found: the first deployment's record"
export FUNDS_V1_RECORD="$V1"

# Empty values in .env mean "use the default", not "set to empty".
for v in FUNDS_KEEPERS FUNDS_TELLER_ADMIN FUNDS_GUARDIAN; do [ -n "${!v:-}" ] || unset "$v"; done
[ -z "${FUNDS_TELLER_ADMIN:-}" ] || preflight_address FUNDS_TELLER_ADMIN
[ -z "${FUNDS_GUARDIAN:-}" ] || preflight_address FUNDS_GUARDIAN
for k in ${FUNDS_KEEPERS//,/ }; do
  [[ "$k" =~ ^0x[0-9a-fA-F]{40}$ ]] || preflight_fail "not an address in FUNDS_KEEPERS: $k"
done
preflight_signer DEPLOYER "${DEPLOYER_ACCOUNT_ADDRESS:-}"

RPC="${FUNDS_RPC:-https://rpc.ordofi.network}"
if [ "${DRY_RUN:-0}" = "1" ]; then
  OUT="deployments/.dry-run-4663-teller-v2.json"
  trap 'rm -f "$OUT"' EXIT
else
  OUT="${FUNDS_DEPLOYMENT_OUT:-deployments/4663-teller-v2.json}"
  [ -e "$OUT" ] && preflight_fail "$OUT exists: the second teller is already deployed there"
fi

preflight "$RPC"

# The libraries the new contracts link, from the first deployment, each checked against this tree's code.
forge build --silent
LIBS=()
for name in FundBook TellerMath TellerOps TellerQueue; do
  key="$(echo "${name:0:1}" | tr 'A-Z' 'a-z')${name:1}"
  addr="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$V1" "$key")"
  LIBS+=(--libraries "src/core/$name.sol:$name:$addr")
done
python3 - "$V1" "$RPC" <<'PY'
import json, subprocess, sys
rec, rpc = json.load(open(sys.argv[1])), sys.argv[2]
libs = {n: rec[n[0].lower() + n[1:]] for n in ("FundBook", "TellerMath", "TellerOps", "TellerQueue")}
for name, addr in libs.items():
    art = json.load(open(f"out/{name}.sol/{name}.json"))["deployedBytecode"]
    code = art["object"][2:].lower()
    for refs in art.get("linkReferences", {}).values():
        for lib, spots in refs.items():
            for s in spots:
                a, n = s["start"] * 2, s["length"] * 2
                code = code[:a] + libs[lib][2:].lower() + code[a + n:]
    code = code[:2] + addr[2:].lower() + code[42:]  # a library's code holds its own address after PUSH20
    chain = subprocess.check_output(["cast", "code", addr, "--rpc-url", rpc]).decode().strip()[2:].lower()
    if chain != code:
        sys.exit(f"preflight: {name} at {addr} is not this tree's {name}: link a fresh one instead")
    print(f"preflight: {name} at {addr} matches this tree")
PY

export FUNDS_SOURCE_REF="$(git rev-parse HEAD)"
export FUNDS_DEPLOYMENT_OUT="$OUT"
forge script script/DeployTellerV2.s.sol:DeployTellerV2 --rpc-url "$RPC" "${SIGNER_ARGS[@]}" "${LIBS[@]}" \
  $BROADCAST --slow --disable-code-size-limit

# Transactions and gas: what was sent (receipts), or what the simulation estimated.
CHAIN="$(cast chain-id --rpc-url "$RPC")"
RUN="broadcast/DeployTellerV2.s.sol/$CHAIN/run-latest.json"
[ "${DRY_RUN:-0}" = "1" ] && RUN="broadcast/DeployTellerV2.s.sol/$CHAIN/dry-run/run-latest.json"
python3 - "$OUT" "$RUN" <<'PY'
import json, sys
out, run = sys.argv[1], sys.argv[2]
rec = json.load(open(out)); r = json.load(open(run))
txs = r.get("transactions", [])
if r.get("receipts"):
    rec["deployGas"] = sum(int(x["gasUsed"], 16) for x in r["receipts"])
    print(f"==> {len(r['receipts'])} transactions, {rec['deployGas']} gas used")
else:
    est = sum(int(t["transaction"].get("gas", "0x0"), 16) for t in txs)
    print(f"==> {len(txs)} transactions, gas limits estimated {est} (the simulation's, with forge's margin)")
for t in txs:
    print("   ", t.get("transactionType"), t.get("contractName") or "", t.get("function") or "", t.get("contractAddress") or "")
json.dump(rec, open(out, "w"), indent=2, sort_keys=True); open(out, "a").write("\n")
PY

echo "==> record: $OUT"
cat "$OUT"
[ "${DRY_RUN:-0}" = "1" ] && echo "==> dry run done: nothing was sent."
echo "==> next: create Funds with FUNDS_DEPLOYMENT=$OUT script/create-fund.sh (one transaction after the approval)"
