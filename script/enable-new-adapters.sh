#!/usr/bin/env bash
#
# Switch the four adapters added on 2026-10-06 on for AINDEX's three AI Funds, as their owner (0x9168..492C):
# Pendle, managed liquidity (Beefy and Arrowfarm), Arcus pToken redeem, Fables v2 (native-ETH pools). Each is
# FundController.addAdapter(implementation, config), read from the deployment records; it applies at once while
# nobody but the owner holds shares. Every call is simulated first; one already enabled is skipped.
#
#   script/enable-new-adapters.sh             owner key from OWNER_PRIVATE_KEY, else from OWNER_ENV_FILE's DEPLOYER_PRIVATE_KEY line
#   DRY_RUN=1 script/enable-new-adapters.sh   simulate only
set -euo pipefail
cd "$(dirname "$0")/.."
RPC="${FUNDS_RPC:-https://rpc.mainnet.chain.robinhood.com}"
OWNER=0x916817f2c44c44f0255249140300E78AfD6c492C
if [ -z "${OWNER_PRIVATE_KEY:-}" ] && [ -n "${OWNER_ENV_FILE:-}" ] && [ -f "$OWNER_ENV_FILE" ]; then
  OWNER_PRIVATE_KEY="$(grep -E '^DEPLOYER_PRIVATE_KEY=' "$OWNER_ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"')"
fi
[ -n "${OWNER_PRIVATE_KEY:-}" ] || { echo "no owner key: set OWNER_PRIVATE_KEY" >&2; exit 1; }
[ "$(cast wallet address --private-key "$OWNER_PRIVATE_KEY" | tr 'A-F' 'a-f')" = "$(echo "$OWNER" | tr 'A-F' 'a-f')" ] || { echo "that key is not the Funds' owner $OWNER" >&2; exit 1; }

need() { [ -f "$1" ] || { echo "missing $1: run its deploy script first" >&2; exit 1; }; }
need deployments/4663-pendle.json; need deployments/4663-clm.json; need deployments/4663-arcus-redeem.json; need deployments/4663-fables-v2.json
ADAPTERS=(
  "Pendle|$(jq -r .pendleAdapter deployments/4663-pendle.json)|0x"
  "Managed liquidity|$(jq -r .implementation deployments/4663-clm.json)|$(jq -r .defaultConfig deployments/4663-clm.json)"
  "Arcus pToken redeem|$(jq -r .implementation deployments/4663-arcus-redeem.json)|$(jq -r '.defaultConfig // "0x"' deployments/4663-arcus-redeem.json)"
  "Fables v2|$(jq -r .implementation deployments/4663-fables-v2.json)|$(jq -r .defaultConfig deployments/4663-fables-v2.json)"
)
CONTROLLERS=(
  "Aindex Claude Fund|0xa44f97a515912fd298b5c3a2c91a56a61d2126f1"
  "Aindex GPT Fund|0x7967815bfaa140aebbf81a014033cb65c384ab34"
  "Aindex Qwen Fund|0xed3f6a0c2a2d67644c7df542e80cf82c0b63306a"
)
REGISTRY=0xaaCFe3653A17CcF2599c6a4B0DBbd78c59464ed9
for a in "${ADAPTERS[@]}"; do
  IFS='|' read -r name impl _ <<<"$a"
  verified=$(cast call --rpc-url "$RPC" "$REGISTRY" 'entry(address)((address,bool,bool,string))' "$impl" | tr -d '()' | cut -d, -f2 | tr -d ' ')
  [ "$verified" = "true" ] || { echo "$name $impl is not registered and verified yet" >&2; exit 1; }
done
for c in "${CONTROLLERS[@]}"; do
  IFS='|' read -r fund ctl <<<"$c"
  enabled=$(cast call --rpc-url "$RPC" "$ctl" 'adapters()(address[])' | tr 'A-F' 'a-f')
  for a in "${ADAPTERS[@]}"; do
    IFS='|' read -r name impl config <<<"$a"
    # An instance is a clone; the registry knows which implementation each instance is.
    has=no
    for inst in $(echo "$enabled" | tr -d '[] ' | tr ',' ' '); do
      [ "$(cast call --rpc-url "$RPC" "$REGISTRY" 'implementationOf(address)(address)' "$inst" | tr 'A-F' 'a-f')" = "$(echo "$impl" | tr 'A-F' 'a-f')" ] && has=yes
    done
    if [ "$has" = yes ]; then echo "$fund: $name already enabled"; continue; fi
    cast call --rpc-url "$RPC" --from "$OWNER" "$ctl" 'addAdapter(address,bytes)(address)' "$impl" "$config" >/dev/null || { echo "$fund: $name would fail; nothing sent for it" >&2; continue; }
    if [ -n "${DRY_RUN:-}" ]; then echo "$fund: $name simulates OK (dry run)"; continue; fi
    cast send --rpc-url "$RPC" --private-key "$OWNER_PRIVATE_KEY" "$ctl" 'addAdapter(address,bytes)' "$impl" "$config" --json | jq -r '"\(.transactionHash) status \(.status)"' | sed "s/^/$fund: $name /"
  done
done
