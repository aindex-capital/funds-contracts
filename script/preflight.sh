# Checks every Funds script runs before it sends anything. Source it, name the signer, then call `preflight`:
#
#   . "$(dirname "$0")/preflight.sh"
#   preflight_signer DEPLOYER              # or OWNER; each script names its own required variables
#   preflight "$RPC"
#   forge script ... "${SIGNER_ARGS[@]}" $BROADCAST   # BROADCAST is "--broadcast", or empty under DRY_RUN=1
#
# Run on its own (`script/preflight.sh`) it does the same checks for the deployer and sends nothing.
#
# Signing. Each role signs one of two ways, exactly one of them set:
#   <ROLE>_ACCOUNT=<name>       a Foundry keystore in ~/.foundry/keystores (recommended: `cast wallet import <name>
#                               --interactive` once; no raw key ever sits in .env). Its address is read once with
#                               `cast wallet address --account <name>` (one password prompt) and passed to forge as
#                               `--account <name> --sender <address>`; forge asks for the password again to sign.
#                               Under DRY_RUN=1 forge gets only `--sender <address>`: a simulation signs nothing.
#   <ROLE>_PRIVATE_KEY=0x...    a raw key (the anvil rehearsal uses this); passed as `--private-key`.
# Setting both, or neither, is refused. ROLE is DEPLOYER (deploy, apply-pending) or OWNER (create-fund).
#
# `preflight` refuses, and exits the calling script, when:
#   1. tracked files have uncommitted changes (ALLOW_DIRTY=1 overrides; untracked files are ignored), so what
#      is broadcast is what is committed;
#   2. the RPC's chain id is not EXPECTED_CHAIN_ID (default 4663, Robinhood Chain; an anvil fork keeps 4663);
#   3. the signer is the deployer, EXPECTED_DEPLOYER is set and the signer is a different address (keystore or
#      key alike); or the signer is a Fund owner, FUND_OWNER is set and the signer is a different address.
#
# DRY_RUN=1 sets BROADCAST empty: `forge script` then simulates against the RPC and sends nothing. Nothing here
# reads or prints a key; only the address it derives is printed. Same rules as aindex-contracts-v2's preflight,
# without the bytecode pins (this repo has no reviewed pins yet).

preflight_fail() { echo "preflight: $*" >&2; exit 1; }

# A 20-byte hex address, or refuse. A mistyped address in a constructor argument is permanent.
preflight_address() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || preflight_fail "$name is not an address: '$value'"
  [ "$(echo "$value" | tr 'A-F' 'a-f')" != "0x0000000000000000000000000000000000000000" ] || preflight_fail "$name is the zero address"
}

preflight_lower() { echo "$1" | tr 'A-F' 'a-f'; }

# Resolve who signs for ROLE (DEPLOYER or OWNER) from <ROLE>_ACCOUNT or <ROLE>_PRIVATE_KEY. Sets SIGNER_ROLE,
# SIGNER_ADDRESS, SIGNER_HOW and SIGNER_ARGS (the forge wallet flags). With an account, a caller that already
# knows the address may pass it as the second argument to skip the password prompt; forge then refuses to sign
# if it is not the account's address, and nothing is sent.
preflight_signer() {
  local role="$1" known="${2:-}"
  local acct_var="${role}_ACCOUNT" key_var="${role}_PRIVATE_KEY"
  local acct="${!acct_var:-}" key="${!key_var:-}"
  SIGNER_ROLE="$role"
  if [ -n "$acct" ] && [ -n "$key" ]; then
    preflight_fail "both $acct_var and $key_var are set. Set one: $acct_var (a Foundry keystore, recommended) or $key_var."
  elif [ -n "$acct" ]; then
    if [ -n "$known" ]; then
      SIGNER_ADDRESS="$known"
    else
      echo "preflight: unlocking keystore '$acct' to read its address" >&2
      SIGNER_ADDRESS="$(cast wallet address --account "$acct")" ||
        preflight_fail "could not read keystore account '$acct' (is it in ~/.foundry/keystores? right password?)"
    fi
    [[ "$SIGNER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || preflight_fail "keystore '$acct' gave no address"
    SIGNER_HOW="keystore $acct"
    if [ "${DRY_RUN:-0}" = "1" ]; then
      SIGNER_ARGS=(--sender "$SIGNER_ADDRESS")
    else
      SIGNER_ARGS=(--account "$acct" --sender "$SIGNER_ADDRESS")
    fi
  elif [ -n "$key" ]; then
    SIGNER_ADDRESS="$(cast wallet address --private-key "$key" 2>/dev/null)" || preflight_fail "$key_var is not a valid key"
    SIGNER_HOW="$key_var"
    SIGNER_ARGS=(--private-key "$key")
  else
    preflight_fail "set $acct_var (a Foundry keystore name, recommended) or $key_var"
  fi
}

preflight() {
  local rpc="$1"
  [ -n "$rpc" ] || preflight_fail "no RPC given"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || preflight_fail "not inside the git repository"

  # 1. Clean tree.
  local dirty; dirty="$(git -C "$root" status --porcelain --untracked-files=no)"
  if [ -n "$dirty" ]; then
    if [ "${ALLOW_DIRTY:-0}" = "1" ]; then
      echo "preflight: WARNING tracked files have uncommitted changes (ALLOW_DIRTY=1):"; echo "$dirty" | sed 's/^/  /'
    else
      echo "$dirty" | sed 's/^/  /' >&2
      preflight_fail "tracked files have uncommitted changes. Commit or stash them, or set ALLOW_DIRTY=1 to override."
    fi
  fi

  # 2. Right chain.
  local want="${EXPECTED_CHAIN_ID:-4663}" got
  got="$(cast chain-id --rpc-url "$rpc" 2>/dev/null)" || preflight_fail "could not read the chain id from $rpc"
  [ "$got" = "$want" ] || preflight_fail "RPC $rpc is chain $got, expected $want"
  echo "preflight: chain $got at $rpc"

  # 3. Right signer, when the caller says which address it must be.
  if [ -n "${SIGNER_ADDRESS:-}" ]; then
    echo "preflight: sending from $SIGNER_ADDRESS ($SIGNER_HOW)"
    if [ "$SIGNER_ROLE" = "DEPLOYER" ] && [ -n "${EXPECTED_DEPLOYER:-}" ] &&
      [ "$(preflight_lower "$SIGNER_ADDRESS")" != "$(preflight_lower "$EXPECTED_DEPLOYER")" ]; then
      preflight_fail "$SIGNER_HOW is $SIGNER_ADDRESS, expected EXPECTED_DEPLOYER $EXPECTED_DEPLOYER"
    fi
    if [ "$SIGNER_ROLE" = "OWNER" ] && [ -n "${FUND_OWNER:-}" ] &&
      [ "$(preflight_lower "$SIGNER_ADDRESS")" != "$(preflight_lower "$FUND_OWNER")" ]; then
      preflight_fail "$SIGNER_HOW is $SIGNER_ADDRESS, expected FUND_OWNER $FUND_OWNER"
    fi
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    BROADCAST=""
    echo "preflight: DRY_RUN=1, simulating only. Nothing will be sent."
  else
    BROADCAST="--broadcast"
    echo "preflight: all checks passed. Broadcasting."
  fi
}

# Run on its own: the same checks for the deployer (DEPLOYER_ACCOUNT or DEPLOYER_PRIVATE_KEY, if either is set),
# against FUNDS_RPC, sending nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  cd "$(dirname "$0")/.."
  ENV_FILE="${ENV_FILE:-.env}"
  if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
  if [ -n "${DEPLOYER_ACCOUNT:-}${DEPLOYER_PRIVATE_KEY:-}" ]; then preflight_signer DEPLOYER; fi
  DRY_RUN=1
  preflight "${FUNDS_RPC:-https://rpc.ordofi.network}"
  echo "preflight: checks only; nothing was sent."
fi
