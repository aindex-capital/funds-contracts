#!/usr/bin/env bash
#
# Rehearse the whole Funds launch on an anvil fork of Robinhood Chain: deploy (with the public teller and the
# holders' pockets), apply prices, create a Fund, let its manager trade through every adapter kind, then run the
# public side, cash in at NAV: deposits, matching, cash exits from the Fund's USDG (and one with the cash short),
# exits in kind in one transaction and in parts, a weekend settlement at worse-of prices within the inflow cap, a
# holders' pocket for a token downgraded to no market, and fees. Nothing touches mainnet: every transaction goes to
# a local anvil. Rerun it any time:
#
#   script/rehearse-funds.sh                  (needs anvil, forge, cast, node 18+, python3, curl)
#
# Steps:
#   1. anvil forks Robinhood Chain (FUNDS_RPC, default https://rpc.ordofi.network) on port 8547;
#   2. script/deploy-funds.sh deploys everything (anvil accounts: 0 deployer and reviewer, 1 price owner and teller
#      admin, 2 guardian, 8 the teller's only keeper and the price recorder); account 1 accepts the router, the
#      sources, the recorder and the teller;
#   3. the clock moves a day and a minute (on to Monday if that lands on a weekend); Chainlink feeds on the fork get
#      their last answers with a fresh timestamp (script/rehearsal/FreshFeed.sol: a fork cannot see Chainlink publish
#      during the warped day);
#   4. script/apply-pending.sh applies the price configuration;
#   5. script/create-fund.sh creates "AINDEX Rehearsal" (owner account 3, 500 USDG stake, open dial, 1% management,
#      10% performance, six adapters: every kind but the index adapter, which needs an IndexZap plan; account 4 as
#      manager);
#   6. the manager trades (script/RehearseFund.s.sol): NVDA through KyberSwap, WETH through the Universal Router,
#      steakUSDG, Morpho supply plus collateral and a borrow, Uniswap v3 and v4 and Fables liquidity;
#   7. batch 1: account 5 deposits 200 USDG, which enters the Fund as cash at the ask NAV;
#   8. the manager invests the new cash (the teller's cash view before and after);
#   9. batch 2: accounts 6 and 7 deposit 150 and 100 USDG while account 5 leaves with half its shares to cash:
#      matched at fair NAV, the rest minted at ask;
#  10. batch 3: account 6 leaves in full, paid from the Fund's USDG at the bid NAV;
#  11. the manager invests nearly all the cash; batch 4: account 7 leaves in full, the Fund's USDG pays what it can and
#      the rest of its shares comes back, which it then takes out in kind;
#  12. account 5 leaves 30% in kind in one transaction, then half of what it has left in parts (startInKind, then
#      claimInKind for each adapter in a transaction of its own);
#  13. a Saturday: deposits of 20 and 60 USDG settle at the router's worse-of prices; what is above the closure's
#      inflow cap waits for a later round, which takes it once the cap or the open allows;
#  14. the manager buys a little TSLA, the router's owner downgrades TSLA to no market, a deposit waits (nobody is
#      minted while it is held), anyone pockets it for the holders of the moment, the deposit goes in and the
#      holders claim their part;
#  15. thirty days pass, a last batch accrues the fees; fees and gas per step are printed.
#
# Each settlement checks that entrants paid at most the ask NAV per share (fair where matched), leavers got at least
# the bid NAV per share for what the Fund paid in cash (fair where matched), and holders who stayed kept their fair
# NAV per share to within 0.05% (fee shares counted apart); exits in kind and the pocket check the holders who stay.
# Records go to deployments/rehearsal-*.json (ignored by git).
set -euo pipefail
cd "$(dirname "$0")/.."
FORK_RPC="${FUNDS_RPC:-https://rpc.ordofi.network}"
PORT="${REHEARSAL_PORT:-8547}"
RPC="http://127.0.0.1:$PORT"

# anvil's well-known test keys: worthless outside a local node.
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
K4=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
K5=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
K6=0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
K7=0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
K8=0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97
addr() { cast wallet address --private-key "$1"; }
A0=$(addr $K0); A1=$(addr $K1); A2=$(addr $K2); A3=$(addr $K3); A4=$(addr $K4)
A5=$(addr $K5); A6=$(addr $K6); A7=$(addr $K7); A8=$(addr $K8)
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
NVDA=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
TSLA=0x322F0929c4625eD5bAd873c95208D54E1c003b2d
USDG_HOLDER="${USDG_HOLDER:-0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010}" # Morpho: holds plenty of USDG

DEP=deployments/rehearsal-4663.json
FUND=deployments/rehearsal-fund.json
GASLOG=deployments/rehearsal-gas.txt
rm -f "$DEP" "$FUND" "$GASLOG" deployments/rehearsal-step.log
mkdir -p deployments
json() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): d=d[k]
print(d)" "$1" "$2"; }

echo "==> 1. anvil fork of $FORK_RPC on $RPC"
anvil --fork-url "$FORK_RPC" --port "$PORT" --disable-code-size-limit --silent --retries 10 --timeout 60000 &
ANVIL=$!
# REHEARSAL_KEEP=1 leaves anvil running at the end (or after a failure) for `cast run` and friends.
[ "${REHEARSAL_KEEP:-0}" = "1" ] || trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
echo "fork at block $(cast block-number --rpc-url "$RPC"), chain $(cast chain-id --rpc-url "$RPC")"

echo "==> 2. deploy"
ENV_FILE=/dev/null ALLOW_DIRTY=1 FUNDS_RPC="$RPC" DEPLOYER_PRIVATE_KEY=$K0 FUNDS_REVIEWER=$A0 FUNDS_PRICE_OWNER=$A1 \
  FUNDS_GUARDIAN=$A2 FUNDS_TELLER_ADMIN=$A1 FUNDS_KEEPERS=$A8 FUNDS_DEPLOYMENT_OUT="$DEP" script/deploy-funds.sh
for c in priceRouter chainlinkSource uniswapV3TwapSource sessionPoolSource priceRecorder; do
  cast send --rpc-url "$RPC" --private-key $K1 "$(json $DEP $c)" 'acceptOwnership()' >/dev/null
done
cast send --rpc-url "$RPC" --private-key $K1 "$(json $DEP teller)" 'acceptAdmin()' >/dev/null
echo "account 1 ($A1) accepted the router, the sources, the recorder and the teller (keeper: account 8, $A8)"
TELLER=$(json $DEP teller)

echo "==> 3. a day passes (on to Monday if that is a weekend); feeds refreshed on the fork"
cast rpc --rpc-url "$RPC" evm_increaseTime 86460 >/dev/null
cast rpc --rpc-url "$RPC" evm_mine >/dev/null
DOW=$(( ($(cast block latest --rpc-url "$RPC" -f timestamp) / 86400 - 2) % 7 )) # 0 Saturday, 1 Sunday
if [ "$DOW" -lt 2 ]; then
  cast rpc --rpc-url "$RPC" evm_increaseTime $(( (2 - DOW) * 86400 )) >/dev/null
  cast rpc --rpc-url "$RPC" evm_mine >/dev/null
fi
FRESH=$(forge inspect FreshFeed deployedBytecode)
for feed in $(python3 -c "import json;print(' '.join(sorted({e['feed'] for e in json.load(open('script/funds-config.json'))['chainlink']})))"); do
  answer=$(cast call --rpc-url "$RPC" "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | cut -d' ' -f1)
  dec=$(cast call --rpc-url "$RPC" "$feed" 'decimals()(uint8)')
  cast rpc --rpc-url "$RPC" anvil_setCode "$feed" "$FRESH" >/dev/null
  cast rpc --rpc-url "$RPC" anvil_setStorageAt "$feed" 0x0 "$(cast to-uint256 "$answer")" >/dev/null
  cast rpc --rpc-url "$RPC" anvil_setStorageAt "$feed" 0x1 "$(cast to-uint256 "$dec")" >/dev/null
done

echo "==> 4. apply pending"
ENV_FILE=/dev/null ALLOW_DIRTY=1 FUNDS_RPC="$RPC" DEPLOYER_PRIVATE_KEY=$K2 FUNDS_DEPLOYMENT="$DEP" script/apply-pending.sh

echo "==> 5. create the Fund"
cast rpc --rpc-url "$RPC" anvil_setBalance "$USDG_HOLDER" 0x56BC75E2D63100000 >/dev/null
cast rpc --rpc-url "$RPC" anvil_impersonateAccount "$USDG_HOLDER" >/dev/null
for who in "$A3:500000000" "$A5:400000000" "$A6:400000000" "$A7:400000000"; do
  cast send --rpc-url "$RPC" --unlocked --from "$USDG_HOLDER" "$USDG" 'transfer(address,uint256)' "${who%%:*}" "${who##*:}" >/dev/null
done
cast rpc --rpc-url "$RPC" anvil_stopImpersonatingAccount "$USDG_HOLDER" >/dev/null
# Six adapters, the most a Fund lists (FundController.MAX_ADAPTERS): every kind the rehearsal trades through. The
# index adapter is left out: its step needs an IndexZap plan from AINDEX's trade API (ZAP_DATA), which this does
# not fetch, so it would sit unused.
ENV_FILE=/dev/null ALLOW_DIRTY=1 FUNDS_RPC="$RPC" OWNER_PRIVATE_KEY=$K3 FUNDS_DEPLOYMENT="$DEP" FUND_OUT="$FUND" \
  FUND_ADAPTERS="${FUND_ADAPTERS:-swap,erc4626,morpho,uniswapV3,uniswapV4,fables}" \
  FUND_NAME="AINDEX Rehearsal" FUND_SYMBOL=AX-REH FUND_MANAGER=$A4 FUND_STAKE_USDG=500000000 \
  FUND_MANAGEMENT_BPS=100 FUND_PERFORMANCE_BPS=1000 FUND_STRATEGY="Rehearsal: one of everything." \
  script/create-fund.sh
SWAP=$(json $FUND adapters.swap)
export FUND_RECORD="$FUND"

now() { cast block latest --rpc-url "$RPC" -f timestamp; }
deadline() { echo $(( $(now) + 3600 )); }

echo "==> 6. the manager trades"
if eval "$(node script/rehearsal/kyber-route.mjs "$SWAP" $NVDA 100000000 KYBER_NVDA "$(deadline)")"; then
  echo "KyberSwap route fetched for $SWAP"
else
  echo "KyberSwap unavailable: the NVDA buy falls back to the Universal Router"
fi
forge script script/RehearseFund.s.sol:RehearseFund --rpc-url "$RPC" --private-key $K4 --broadcast --slow

# The teller's steps: one forge call each, with the actor's key.
LOG=deployments/rehearsal-step.log
teller() {
  if ! forge script script/RehearseTeller.s.sol:RehearseTeller --rpc-url "$RPC" --broadcast --slow --sig "$@" >"$LOG" 2>&1; then
    tail -60 "$LOG"; echo "step failed: $1"; exit 1
  fi
  sed -n '/== Logs ==/,/^$/p' "$LOG" | sed '1d'
}
view() { forge script script/RehearseTeller.s.sol:RehearseTeller --rpc-url "$RPC" --sig "$@" | sed -n '/== Logs ==/,/^$/p' | sed '1d'; }
fund() { forge script script/RehearseFund.s.sol:RehearseFund --rpc-url "$RPC" --private-key $K4 --broadcast --slow --sig "$@" | sed -n '/== Logs ==/,/^$/p' | sed '1d'; }
warp_to() {
  cast rpc --rpc-url "$RPC" evm_setNextBlockTimestamp "$1" >/dev/null
  cast rpc --rpc-url "$RPC" evm_mine >/dev/null
}
# On to the cut-off of the batch the latest request joined.
to_cutoff() {
  local c; c=$(forge script script/RehearseTeller.s.sol:RehearseTeller --rpc-url "$RPC" --sig "cutoff()" | grep -o 'CUTOFF [0-9]* [0-9]*')
  local t; t=$(echo "$c" | cut -d' ' -f3)
  [ "$(now)" -lt "$t" ] && warp_to $(( t + 60 ))
  echo "batch $(echo "$c" | cut -d' ' -f2) closed at $t"
}
gas() {
  python3 - "$1" "$GASLOG" "${2:-RehearseTeller}" <<'PY'
import json, glob, os, sys
files = sorted(glob.glob(f"broadcast/{sys.argv[3]}.s.sol/4663/*-latest.json"), key=os.path.getmtime)
r = json.load(open(files[-1]))
with open(sys.argv[2], "a") as log:
    for t, x in zip(r["transactions"], r["receipts"]):
        line = f"{sys.argv[1]:<34} {int(x['gasUsed'], 16):>11,}  {t.get('function') or t.get('transactionType')}"
        print("   gas", line); log.write(line + "\n")
PY
}
settle_once() { teller "settle(uint256)" $K8; gas "$1"; }
# Settle, then every later round while deposits wait (the closure's inflow cap, at most five rounds).
settle() {
  local round=1 w
  while :; do
    settle_once "$1, round $round"
    view "inflowCheck()"
    w=$(forge script script/RehearseTeller.s.sol:RehearseTeller --rpc-url "$RPC" --sig "waits()" 2>/dev/null | grep -o 'WAITS [0-9]* [0-9]*' || true)
    [ -z "$w" ] && break
    round=$(( round + 1 ))
    [ "$round" -gt 5 ] && { echo "deposits still waiting after 5 rounds"; exit 1; }
    echo "   deposits of batch $(echo "$w" | cut -d' ' -f2) wait for the cut-off at $(echo "$w" | cut -d' ' -f3)"
    warp_to $(( $(echo "$w" | cut -d' ' -f3) + 60 ))
  done
}

# Move the clock until the next 21:00 UTC cut-off falls on a US trading day (Monday to Friday, not one of the
# router's holidays), so ordinary batches settle at the feeds' prices.
ROUTER=$(json $DEP priceRouter)
weekday_cutoff() {
  local t c d
  while :; do
    t=$(now); c=$(( t / 86400 * 86400 + 75600 )); [ "$c" -le "$t" ] && c=$(( c + 86400 ))
    d=$(( (c / 86400 - 2) % 7 )) # 0 Saturday, 1 Sunday
    [ "$d" -ge 2 ] && [ "$(cast call --rpc-url "$RPC" "$ROUTER" 'holidayFrom(uint256)(uint64)' $(( c / 86400 )))" = "0" ] && break
    cast rpc --rpc-url "$RPC" evm_increaseTime 86400 >/dev/null
    cast rpc --rpc-url "$RPC" evm_mine >/dev/null
  done
}
# The next Saturday at 12:00 UTC (the US market is closed until Monday 01:00 UTC).
saturday() {
  local t d; t=$(now); d=$(( t / 86400 + 1 ))
  while [ $(( (d - 2) % 7 )) -ne 0 ]; do d=$(( d + 1 )); done
  warp_to $(( d * 86400 + 43200 ))
}

echo "==> 7. batch 1: a deposit enters as cash at the ask NAV"
weekday_cutoff
teller "deposit(uint256,uint256)" $K5 200000000
to_cutoff
settle "batch 1 (cash in)"

echo "==> 8. the manager invests the new cash"
view "cash()"
fund "invest(uint256)" 50000000
gas "manager invests the new cash" RehearseFund
view "cash()"

echo "==> 9. batch 2: two deposits and a cash exit, matched at fair"
weekday_cutoff
teller "deposit(uint256,uint256)" $K6 150000000
teller "deposit(uint256,uint256)" $K7 100000000
teller "redeem(uint256,uint256)" $K5 5000
to_cutoff
settle "batch 2 (match + cash in)"

echo "==> 10. batch 3: a cash exit paid from the Fund's USDG at bid"
weekday_cutoff
teller "redeem(uint256,uint256)" $K6 10000
to_cutoff
settle "batch 3 (cash exit)"

echo "==> 11. the cash is invested; batch 4: a cash exit with the USDG short, the rest in kind"
fund "invest(uint256)" 5000000
gas "manager invests nearly all cash" RehearseFund
view "cash()"
weekday_cutoff
teller "redeem(uint256,uint256)" $K7 10000
to_cutoff
settle "batch 4 (cash short)"
teller "backInKind(uint256)" $K7
gas "shares back, in kind"

echo "==> 12. exits in kind: one transaction, then in parts"
teller "inKind(uint256,uint256)" $K5 3000
gas "exit in kind"
teller "inKindParts(uint256,uint256)" $K5 5000
gas "exit in kind in parts"

echo "==> 13. a Saturday: worse-of prices, the closure's inflow cap"
saturday
view "quote(address)" $NVDA
teller "deposit(uint256,uint256)" $K6 20000000
teller "deposit(uint256,uint256)" $K7 60000000
to_cutoff
view "quote(address)" $NVDA
settle "weekend batch"

echo "==> 14. a token downgraded to no market goes to a holders' pocket"
weekday_cutoff
fund "tsla()"
teller "downgrade(uint256,address)" $K1 $TSLA
teller "deposit(uint256,uint256)" $K6 20000000
to_cutoff
settle_once "batch with a no-market holding"
teller "pocket(uint256,address,address[])" $K8 $TSLA "[$A5,$A6,$A7]"
gas "pocket"
w=$(forge script script/RehearseTeller.s.sol:RehearseTeller --rpc-url "$RPC" --sig "waits()" 2>/dev/null | grep -o 'WAITS [0-9]* [0-9]*' || true)
[ -n "$w" ] || { echo "the deposit did not wait for the pocket"; exit 1; }
warp_to $(( $(echo "$w" | cut -d' ' -f3) + 60 ))
settle "the same batch, after the pocket"

echo "==> 15. thirty days later: fees accrue at a settlement"
cast rpc --rpc-url "$RPC" evm_increaseTime $(( 30 * 86400 )) >/dev/null
cast rpc --rpc-url "$RPC" evm_mine >/dev/null
weekday_cutoff
teller "deposit(uint256,uint256)" $K5 10000000
to_cutoff
settle "batch after 30 days (fees)"
view "fees()"
python3 - <<'PY'
import json
for name in ["DeployFunds", "ApplyPending", "CreateFund", "RehearseFund"]:
    r = json.load(open(f"broadcast/{name}.s.sol/4663/run-latest.json"))
    rs = r["receipts"]; tx = r["transactions"]
    print(f"{name}: {len(rs)} transactions, {sum(int(x['gasUsed'], 16) for x in rs):,} gas")
    if name in ("CreateFund",):
        for t, x in zip(tx, rs):
            print(f"   {int(x['gasUsed'],16):>10,}  {t.get('function') or t.get('transactionType')}")
PY
echo "teller steps:"; cat "$GASLOG"
echo "==> rehearsal done. Records: $DEP, $FUND"
