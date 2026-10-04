# AINDEX Funds contracts

AINDEX Funds: on-chain vaults on Robinhood Chain run by an AI agent or a person, inside a risk dial the
Fund's owner chooses. Everything a Fund can do is an adapter, so new protocols plug in without touching
existing Funds, and anyone can write one. AINDEX reviews are badges, not gates: each Fund's dial decides
whether it keeps to reviewed adapters and Morpho markets (reviewed by whole market, all five parameters).

- Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Deposits, exits, pricing and fees: [docs/DEPOSITS-AND-EXITS.md](docs/DEPOSITS-AND-EXITS.md)
- Writing an adapter: [docs/ADAPTERS.md](docs/ADAPTERS.md)

**Not audited by a third party. Use at your own risk.** The contracts have had internal reviews only.

## Deployed on Robinhood Chain (chain id 4663)

Every address is in [deployments/4663.json](deployments/4663.json). The main ones:

| Contract | Address |
|---|---|
| `Teller` (deposits, exits, fees) | `0xdd0a4146cD46AffbE29D625763623cBAb4e7Dd46` |
| `FundFactory` | `0x60AeB07cd2EB199Ea468C21ea7743d08E0467D82` |
| `FundBook` | `0xc833D4f68a5CC0ddb152737D9504762733dbb2ec` |
| `PriceRouter` | `0x7ca511aeA087381C8a1981A4F9850aE154e624BB` |
| `AdapterRegistry` | `0xaaCFe3653A17CcF2599c6a4B0DBbd78c59464ed9` |
| `MorphoMarketRegistry` | `0xd4E16F31b89d8f5FFEd93ECaDE563B102dbb33c8` |
| `Pockets` | `0xae030ec6d5DE05E5745fA7AB9c4E1FDB01DFfcC8` |
| `FundFees` | `0xB26b7601B60dfFE8c216cf9E3F9365eC2cd06aDB` |
| `FeeConfig` | `0x9B5eCD313c07dFB5B56DB7Cab8a852408F16eDe4` |
| Base asset (USDG) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

Adapter implementations (Funds use clones of these): swap `0x8bd36B4231F5e8A9dDDe7cEf7661912D66A656A0`,
ERC-4626 `0x3D2133eaA904269FCA5B72B3fD36C77ac69bEB7D`, Morpho `0x03E40959Fb646946AE4e8888e159E8863020F3f6`,
Uniswap v3 `0x57B135ae6Dd823140b8884bb35B5F16439DaF6EC`, Uniswap v4 `0xA9D824a30FA63d39b7e9896A63ef9B899Ea6073D`,
Fables `0xB568A71263B9A8a58A564A124034131846aa17F6`, AINDEX index `0x1cE0a160ED76835737d120D67E90ac66902cE2d0`.


## Build and test

Requires [Foundry](https://getfoundry.sh). Dependencies are git submodules:

```sh
git submodule update --init --recursive
forge build
forge test                      # unit and invariant tests (fork tests skip without ROBINHOOD_RPC)
ROBINHOOD_RPC=https://rpc.ordofi.network forge test --match-path 'test/fork/*'
```

The public RPC (`rpc.mainnet.chain.robinhood.com`) returns Cloudflare 403 to Foundry; use
`https://rpc.ordofi.network` or a private endpoint.

## Deployment

The live addresses are in `deployments/4663.json`. The deploy and apply steps are the scripts in `script/`
(`deploy-funds.sh`, `apply-pending.sh`, `create-fund.sh`), described below; each writes what it deployed to
`deployments/`.

### Deploying to Robinhood Chain

Three steps, a day apart. Every script checks the tree is clean and the RPC is chain 4663, and takes
`DRY_RUN=1` to simulate without sending anything. Put the settings in `.env` at the repository root (ignored by
git), or pass them on the command line.

**Signing: use Foundry keystores.** Every script signs with either a keystore account or a raw key, exactly one:

| Role | Keystore (recommended) | Raw key |
|---|---|---|
| deployer (deploy, apply prices) | `DEPLOYER_ACCOUNT=<keystore name>` | `DEPLOYER_PRIVATE_KEY=0x...` |
| Fund owner (create Funds) | `OWNER_ACCOUNT=<keystore name>` | `OWNER_PRIVATE_KEY=0x...` |

A keystore lives in `~/.foundry/keystores` (create one with `cast wallet import <name> --interactive`), so no raw
key ever sits in `.env`. The script reads its address once with `cast wallet address --account <name>` (one password
prompt), checks it, and runs `forge script --account <name> --sender <address>`; forge asks for the password again
when it signs. Under `DRY_RUN=1` forge only gets `--sender`, so a simulation signs nothing and asks once. Setting
both the account and the key for a role, or neither, is refused. Raw keys stay supported for the anvil rehearsal.
`script/preflight.sh` on its own runs the checks (clean tree, chain 4663, `EXPECTED_DEPLOYER`) and sends nothing.

**0. Rehearse first (local, nothing sent):**

```sh
script/rehearse-funds.sh
```

It runs steps 1 to 3 on an anvil fork of the chain, lets the manager trade through every adapter kind, then runs
the public teller, cash in at NAV: deposits entering as cash at the ask NAV, a batch matching entrants and a cash
leaver at fair, cash exits paid from the Fund's USDG at bid (one with the cash short, the rest of its shares then
taken out in kind), exits in kind in one transaction and in parts, a Saturday settlement at the weekend pools'
worse-of prices within the inflow cap, a holders' pocket for a token downgraded to no market, the manager investing
new cash, and fees. Each settlement checks that entrants paid at most ask, leavers got at least bid for their cash
part, and holders who stayed lost nothing beyond rounding. It prints NAV after each trade and gas per step. About ten
minutes.

**1. Deploy** (any day; about 90M gas over some 190 transactions, well under 0.01 ETH at today's gas price):

```sh
DRY_RUN=1 script/deploy-funds.sh     # simulate first
script/deploy-funds.sh
```

For example, with the deployer keystore:

```sh
DEPLOYER_ACCOUNT=aindex-deployer EXPECTED_DEPLOYER=0xd6634f05BC79c19cD7027636F3c7c29E853EB844 script/deploy-funds.sh
```

`.env` needs:

| Variable | What |
|---|---|
| `DEPLOYER_ACCOUNT` | the deploying account's Foundry keystore name (recommended; needs a little ETH) |
| `DEPLOYER_PRIVATE_KEY` | instead of `DEPLOYER_ACCOUNT`: the deploying account's raw key (never both) |
| `FUNDS_REVIEWER` | AINDEX operator wallet: verifies adapters, owns the Morpho market registry |
| `FUNDS_PRICE_OWNER` | owns the price router, sources and price recorder (proposes prices, downgrades in an emergency); must accept each |
| `FUNDS_KEEPERS` | comma-separated keeper wallets that may settle teller batches (the teller admin can list more later) |
| `FUNDS_RECORDERS` | optional, default `FUNDS_KEEPERS`: who may record v4 prices in the first half of every slot |
| `FUNDS_GUARDIAN` | guardian of every new Fund (pauses, revokes a manager, disables an adapter) |
| `FUNDS_TELLER_ADMIN` | optional, default `FUNDS_REVIEWER`: admin of the teller (routers, opening stake, dust) and of `FeeConfig` (the split, the recipients) |
| `FUNDS_AIX_RECIPIENT` | optional, default the AINDEX payout wallet `0x8d3e8ccCD0062f3b780a166bdd1DFCB3dfbAEFc5`: receives the $AIX holders' 15% of every fee |
| `FUNDS_TREASURY` | optional, default the AINDEX Safe `0x230C4Df28A0065216F2BEf86122125c0F8e4A5af`: receives the treasury's 15% |
| `FUNDS_RPC` | optional, default `https://rpc.ordofi.network` |
| `EXPECTED_DEPLOYER` | optional, recommended: refuse unless the deployer (keystore or key) is this address |

It deploys the registry, prices (with the weekend session pool source), factory, every adapter, the holders'
pockets and the public teller (`FeeConfig` at 70 / 15 / 15, `FundFees`, `Teller` with a 10 USDG opening stake, a 10
USDG minimum deposit, a 5% weekend inflow cap, at most 3 waiting requests per address per Fund, and the keepers
allowed; the teller has no swap routers, since deposits enter as cash), writes every address to
`deployments/4663.json` and prints what is left for other keys:

- if the deployer is not `FUNDS_REVIEWER`, the reviewer sends the printed `setVerified` calls (one per adapter);
- if the deployer is not `FUNDS_PRICE_OWNER`, the price owner sends the printed `acceptOwnership` calls (router,
  Chainlink source, TWAP source, session pool source, price recorder);
- if the deployer is not `FUNDS_TELLER_ADMIN`, the teller admin sends the printed `acceptAdmin` call.

Prices are only proposed in this step: the router waits a day before any price becomes usable. Deposits can be
queued from the moment a Fund opens, but a batch holding anything besides USDG settles only once prices apply.

**2. Apply prices, 24 hours later** (anyone can send this; the script stops if it is too early). It signs as the
deployer (`DEPLOYER_ACCOUNT` or `DEPLOYER_PRIVATE_KEY`), though any funded account will do:

```sh
DRY_RUN=1 script/apply-pending.sh
script/apply-pending.sh
```

It ends by listing any token that still has no usable price (a stale feed, a paused stock token).

**3. Create Funds.** The signing account (`OWNER_ACCOUNT`, or `OWNER_PRIVATE_KEY`) is the Fund's owner and pays the
opening stake (10 USDG at least) and a little ETH:

```sh
OWNER_ACCOUNT=aindex-owner FUND_NAME="AINDEX Claude" FUND_SYMBOL=AX-CLAUDE \
  FUND_MANAGER=0x<the agent's session key> FUND_MANAGEMENT_BPS=100 FUND_PERFORMANCE_BPS=1000 \
  FUND_STAKE_USDG=500000000 script/create-fund.sh
```

The Fund opens through the teller's `createFund` with the open dial (`FUND_DIAL=balanced` or `conservative` for
the presets), one adapter of every kind (`FUND_ADAPTERS` to choose; up to 12) and its manager for 90 days. The strategy lives off chain;
`FUND_STRATEGY` only copies it into the record, `deployments/fund-<SYMBOL>.json`. While the owner holds every
share, the owner can change anything at once.

For AINDEX's own first Funds, fill in the managers (and confirm names, stakes and fees) in
`script/first-funds.json`, then:

```sh
DRY_RUN=1 OWNER_ACCOUNT=aindex-owner script/create-first-funds.sh
OWNER_ACCOUNT=aindex-owner script/create-first-funds.sh
```

The keystore's password is asked once to read the owner's address, then once per Fund when forge signs.

Entries with no manager yet, and Funds already created, are skipped, so it can be rerun.

## Configuration

`script/funds-config.json` is the production configuration: Chainlink feeds (stock and ETF tokens with pause
and session checks, crypto and stablecoins), pool-priced tokens by Uniswap v3 TWAP, AINDEX indexes, the weekend pools and spreads for stock and ETF tokens (worse-of pricing while the US market is
closed), the teller's weekend inflow cap, the Morpho markets AINDEX reviewed (by market id), US market holidays
through 2027, and the adapter settings new Funds get. Each section has a note
saying how its values were chosen.

## Security

Not audited by a third party. Use at your own risk. The contracts were reviewed internally and are covered by
unit, invariant and fork tests, but that is no guarantee against loss of funds.

## License

MIT, see [LICENSE](LICENSE).
