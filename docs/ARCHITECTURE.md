# AINDEX Funds: architecture

Funds are on-chain vaults on Robinhood Chain run by an AI agent or a person. The manager trades freely
inside a risk dial its owner chose; it can never withdraw, and what it can lose through bad trades is bounded by
the daily loss budget it chose. Everything a Fund can do is an **adapter**, so
new protocols and instruments are added later without touching existing Funds.

**The manager chooses the risk; AINDEX reviews are badges, not gates** (decided 2026-10-01). AINDEX reviews
adapters and instruments and says so on Fund pages, but whether a Fund keeps to reviewed things is a field of
its own dial (`allowUnreviewed`). The default dial a page offers (`DialPresets.open()`) has no caps and a 25%
daily loss budget. What protects depositors is not a cautious default but the fixed guarantees below: the
manager can never withdraw and can lose at most its daily loss budget through bad trades, entrants pay the ask NAV
and leavers get the bid NAV from manipulation-resistant prices read after a cut-off (docs/DEPOSITS-AND-EXITS.md),
anything NAV values at zero is set aside for the holders of the moment before a new share is minted, and any move
to more risk waits a notice so holders can leave.

Product plan: `../managed-funds-plan.md` (in the parent workspace). This file is the contract design.

## Contracts

```
src/
  core/
    FundFactory.sol      creates a Fund: vault + controller, wired to the shared registry and router
                         (ControllerDeployer, in the same file, holds the controller's code: size limit)
    FundVault.sol        shares (ERC-20) and custody; no protocol logic, no generic call
    FundController.sol   the manager's only door: runs adapter actions inside the dial
    FundBook.sol         linked library: reads a Fund's book (holdings, positions, debts) and prices it
    Teller.sol           the public teller, one for every Fund: opening (in one transaction with adapters and
                         manager: createFundWith), queued requests, batches (cash in
                         at ask NAV, cash out at bid NAV, matched at fair), exits in kind at once or in parts,
                         holders' pockets, dust (docs/DEPOSITS-AND-EXITS.md)
    TellerOps.sol        linked library: exits in kind (start, per-adapter claims, escrow), fee minting, pockets,
                         dust
    TellerMath.sol       linked library: one reading of a Fund, the exit plan and its measurement, the hold check,
                         prices per share
    TellerQueue.sol      linked library: the loops over a batch's requests (limits, rounds, moving skipped requests)
    Pockets.sol          holders' pockets: what NAV values at zero, set aside per snapshot, claimed in kind forever
    Fees.sol             FeeConfig (the split, AINDEX) and FundFees (rates, high-water mark, earned stake)
    SeedTeller.sol       seed-money teller (owner only, one price); no longer deployed (every Fund opens
                         through the Teller); kept for tests that need a Fund without the public teller
    DialPresets.sol      the canonical presets (open, balanced, conservative) for pages and scripts
  registry/
    AdapterRegistry.sol  anyone registers adapters; AINDEX marks verified ones; per-Fund clones
  pricing/
    PriceRouter.sol      class, sources, haircut per token; fair / bid / ask; prices chained through a quote token;
                         market sessions with the worse-of rule while closed; look-through
    sources/             price sources are adapters too (Chainlink, pool TWAP, price recorder, session pools)
  adapters/
    BaseAdapter.sol      what every adapter shares
    swap/ index/ yield/ lending/ liquidity/   one folder per kind
    index/IndexLookThrough.sol   what an AINDEX index share holds, for class caps
  interfaces/            IAdapter, IPriceRouter, IPriceSource (and IRatioSource), IFundVault, IFundController,
                         IAdapterRegistry, ILookThrough, ISessionSource, IClosedMarketSource, IPockets (and
                         IPocketable), ITeller
    external/            minimal interfaces of outside protocols (Morpho, Uniswap, Fables, Folio, ERC-4626)
```

`FundBook`, `TellerOps`, `TellerMath` and `TellerQueue` are external libraries, so deployment links them (forge
script does this on its own). Deploy order for the teller (`script/DeployFunds.s.sol`): `Pockets`, `FeeConfig`,
`FundFees(config)`, `Teller(factory, fees, pockets, admin)`, then `fees.wireTeller(teller)` and
`pockets.wireTeller(teller)` (Pockets serves only that teller, and only for a vault that names it), the weekend inflow cap
from `script/funds-config.json`'s `teller` and one `setKeeper` per keeper. The teller has no swap routers.

The second teller (2026-10-04, `script/DeployTellerV2.s.sol`, record `deployments/4663-teller-v2.json`) serves new
Funds; Funds opened on the first keep it (a vault names its teller once). It mints the owner's opening deposit to
the owner's wallet and creates a Fund ready to trade in one transaction. New with it: a `FundFactory` (its
`ControllerDeployer` holds the controller's code, which gained the one-time `setup`), `Pockets` and `FundFees`
(each wired to one teller, once) and the `Teller`. Reused: the registry and every adapter implementation, the price
router and sources, the Morpho market registry, `FeeConfig` and the four linked libraries (unchanged source; the
wrapper links the deployed ones after checking their code on chain). Seven transactions: four deployments,
`fees.wireTeller`, `pockets.wireTeller` and `setKeeper` (plus `transferAdmin` when the admin is not the deployer);
about 21.8M gas. Settings are copied from the first teller on chain.

## How an action runs

```
manager ──act(adapter, action)──▶ FundController
   0. with allowUnreviewed off, the adapter's implementation must be verified in the registry
   1. book at bid prices (vault balances + every adapter's positions − debts); must be complete
   2. vault.track(adapter.outputs(action))         outputs will be counted
   3. vault.approveFor(input, adapter, exact)       duplicates summed, for this call only
   4. adapter.execute(action)                       pulls inputs, talks to the protocol, sends outputs to the vault
   5. approvals reset to 0, whether or not the adapter pulled them
   6. book at bid prices again; the drop counts against the loss budget
   7. caps per price class and per holding (fair prices), health if the Fund owes anything
```

Prices are read inside the same transaction, so market moves never count against the manager: only what
its own action did. That is only as honest as the price sources: a source an actor can move within a block
would let it hide a loss. So sources are oracle feeds, time-weighted or recorded prices, never spot, and
liquidity positions are valued at oracle prices, never at a pool's current price.

**Complete** means: every nonzero holding and every debt priced, and every listed adapter's `positions`
readable. A zero balance of an unpriceable token does not matter. A debt in a token with no market (class
None, worth zero) is unpriceable, not free, so downgrading a borrowed token can never raise a Fund's NAV.
`navReport(side)` lists the tokens and adapters that made a book incomplete.

An action never runs while the book is incomplete. Recovery: the source comes back, or AINDEX downgrades
the token to None at once (a zero value is a known value), or the owner disables and removes the adapter.

### The book never reverts

An adapter's `positions` gets at most 2M gas as a static call, and its reply is decoded under try/catch. A
reverting, gas-burning or malformed reply marks the book incomplete and lists the adapter; it never blocks
the owner from removing it. A router read that reverts or a value above $1e30 reads as unpriced.

### Loss budget

`dailyLossBps` of the NAV at the start of the UTC day, or of today's NAV plus today's losses if lower (so
redemptions shrink the budget and deposits never grow it). Yesterday's losses fade out linearly over today,
so the budget cannot be spent twice across midnight. If a day opens on an empty Fund, the next action
measures the start again instead of leaving a zero budget for the day. Gains never refill the budget.

### Caps

Caps are judged at fair prices, after the action. A cap that is already breached (prices moved, the dial
was tightened, someone donated) never blocks an action that does not add to the breach, so the manager can
always reduce risk:

- per class (Thin, Pool): passes if within the cap or no larger than before;
- per token (all but the base asset, which is never capped): the same, counting the token wherever it is
  held (vault and every adapter);
- no market: with `maxNoMarketBps == 0`, the amount of any None token may not grow (a donated crumb does
  not block). A nonzero cap on None tokens cannot be measured in value (they are worth zero); it is
  bounded by the loss budget, since buying them shows as a loss. Whatever the dial says, and however the
  token got there (bought, donated, or downgraded to None by the router), the teller mints no new share while
  the Fund holds a None token (or a claim valued at zero) above dust, until anyone sets it aside for the holders
  of that moment (`Teller.pocket`, docs/DEPOSITS-AND-EXITS.md, "Holders' pockets");
- health: with debts, assets at bid over debts at ask must stay above `max(minHealthBps, 1.0)` or not get
  worse; with `allowBorrow` off, debts may not grow (repaying is always allowed).

**Look-through.** A wrapper token (an AINDEX index share) may have an `ILookThrough` in the router. The
Fund values it at its own price, but splits that value across the classes of what it holds for the class
caps, so thin tokens inside an index still count as thin. If the look-through fails, the whole holding
counts as thin.

## The dial (owner's choice)

| Field | Meaning |
|---|---|
| `maxNoMarketBps` | tokens with no market (worth zero); 0 forbids adding any |
| `maxThinBps` | shallow-pool tokens |
| `maxPoolBps` | pool-priced tokens |
| `maxPerTokenBps` | any one holding (the base asset, cash, is never capped) |
| `dailyLossBps` | what the manager's own actions may cost per day, at bid prices |
| `allowBorrow`, `minHealthBps` | whether the Fund may owe, and its floor (assets / debts, at least 1.0) |
| `allowUnreviewed` | off: only adapters AINDEX verified, only Morpho markets AINDEX approved. On: anything (supply in an unapproved Morpho market counts as nothing) |

Plus which adapters the Fund has enabled. **Raising risk waits 7 days, lowering it is instant**, field by
field: the safer parts of a change apply at once, the rest is pending; a change that only lowers risk
leaves nothing pending; the latest proposal replaces any earlier one; the owner can cancel it. Turning
`allowUnreviewed` on is a risk increase like any other; turning it off is instant.

### Presets (canonical; the website's `apps/web/lib/funds.ts` shows the same numbers)

The factory accepts any dial within bounds. `src/core/DialPresets.sol` holds the three presets pages, the MCP
and scripts offer; change the contract, this table and the website together.

| Preset | noMarket | thin | pool | perToken | dailyLoss | borrow | minHealth | unreviewed |
|---|---|---|---|---|---|---|---|---|
| `open()` (default) | 10,000 | 10,000 | 10,000 | 10,000 | 2,500 | yes | 10,000 | yes |
| `balanced()` | 0 | 1,000 | 5,000 | 4,000 | 1,000 | yes | 15,000 | no |
| `conservative()` | 0 | 0 | 2,000 | 2,500 | 300 | no | 0 (unused) | no |

`open()` stops at a 25% daily loss budget: a manager, or a stolen session key, with 100% could empty the Fund in
one transaction through a bad swap or a liquidity add at a moved price. A custom dial may still go up to
10,000, as the manager's explicit choice, shown on the Fund's page.

All in basis points of NAV (10,000 = 100%); `minHealthBps` 10,000 is a health of 1.0. In `conservative()`
`minHealthBps` is 0 because borrowing is off, and the controller checks the floor only for dials that borrow.

### Reviews are badges

AINDEX reviews two kinds of thing, and each is only a label until a Fund's own dial says otherwise:

- **Adapters**: the registry's `verified`. With `allowUnreviewed` off, `act` refuses an adapter whose
  implementation is not verified, checked at every action, so withdrawing a review stops new actions at once.
  Unwinding is never checked, so a Fund can always leave.
- **Morpho markets**: the `MorphoMarketRegistry` (adding waits a day, removing is instant). A review approves
  a whole market by its id, the hash of all five parameters (loan token, collateral token, oracle, rate model,
  LLTV), never an oracle on its own: anyone can build a market that lends USDG against a token they mint at
  will and prices it with a sound oracle meant for another token. With `allowUnreviewed` off, supply,
  collateral and borrow need an approved market; with it on, any market.

Supply in a market AINDEX has not approved counts as nothing in NAV (`positions` reports it at zero). Whoever
built such a market may be able to borrow every unlent dollar against worthless collateral, and the free
liquidity is no floor: when the Fund is the only lender, its own supply is the free liquidity, and another
lender can leave just before a drain. At zero, lending into such a market costs NAV inside the manager's own
action and is charged to the daily loss budget, so a drain can never take more than the budget the manager
chose. Leavers still get their slice of it, and deposits do not buy more of it. Supply in an approved market
counts in full. Only supply the adapter put in itself counts (`ownShares`): supply anyone adds on its behalf is
ignored, so nobody can hold a Fund's deposits back or take its snapshots by lending in its name. A leaver's supply
the market cannot pay at its exit stays the leaver's (`leaverShares`, paid out by anyone with `payLeaver`).

So "reviews are badges" holds for the dial: nothing AINDEX reviews blocks a Fund whose owner turned
`allowUnreviewed` on. What a review changes for such a Fund is how its Morpho supply is valued.

Other per-Fund settings that used to be AINDEX's choice are now the owner's too: the Fables adapter's pool
versus oracle guard (`maxSpotDeviationBps`, 0 = off, the default for new Funds) is a convenience, since
liquidity is valued at oracle prices and a deposit into a moved pool shows as a loss in the same action.

The shortcut: while **nobody but the owner has ever held a share** (the vault latches the first share that
reaches anyone else) and the owner holds them all, changes apply at once. Shares handed back to the owner
do not reopen it. The owner's own shares never latch, in its wallet (its opening deposit on the second teller,
top-ups, fee shares when it is the recipient) or in the teller's escrow. Shares in the teller's custody (a batch's
shares before they are claimed; the first teller's opening stakes) do not latch and count as the owner's for this
check; the teller latches the vault itself as soon as someone other than the owner queues a deposit, so queued
depositors count before they hold shares.

`setup` (teller only, once, before the first share) is how `Teller.createFundWith` applies the creating owner's
adapters and manager in the creation's own transaction: the same registry clone, `_enable` and `ManagerSet` as
`addAdapter` and `setManager` while only the owner holds, then closed for good (`setupDone`).

## Limits

| Limit | Value | Why |
|---|---|---|
| Tracked tokens per vault | 40 | bounds every NAV reading and an exit in kind (one transfer per token) |
| Adapters per Fund (enabled or disabled) | 12 | same: a settlement reads every adapter, an exit in kind splits each |
| Positions per adapter | Uniswap v3: 10; Uniswap v4: 10; Fables: 6 ranges; Morpho: 13 markets; ERC-4626: 8 vaults | each position is read once per settlement and read twice and split once per exit in kind |
| Gas per `positions` call | 2M | a broken adapter cannot eat the action's gas |
| Manager term | 366 days ahead at most | a session key must lapse; a person renews |
| Dust that may be untracked | under $1 at fair | frees a slot, costs nothing real |
| Requests per teller batch | 100 | bounds settlement gas; later requests wait for the next batch (up to 8 ahead) |
| Requests one address may have waiting per Fund | 3 (teller admin, 1 to 8) | filling a Fund's queue takes hundreds of funded addresses |

Robinhood Chain takes at most 32M gas per transaction (ArbGasInfo `getMaxTxGasLimit`, checked 2026-10-02). Since
deposits enter as cash (2026-10-02) a settlement reads the Fund once and moves only USDG, so the caps went back up
to the old ones but for Morpho (16 to 13 markets) and Fables (8 to 6 ranges): with twelve adapters of one kind at
its cap, every settlement path measures at or under 12M gas before refunds on a fork, and an exit in kind, done in
parts at the caps (`startInKind`, then one `claimInKind` per adapter that holds anything), at or under about 18.6M
per transaction (measured again on 2026-10-02 after the final changes and the Fables cap at 6 ranges: settlements at
most 11.94M, twelve Uniswap v4 adapters on a Saturday; `startInKind` at most 18.53M, twelve Uniswap v3 adapters).
Figures and method: docs/DEPOSITS-AND-EXITS.md, "Gas".

`untrack(token)` (owner or manager) frees a slot for a token the vault holds none of, or less than $1 of
at a fair price. A token that cannot be priced is only untracked at a zero balance, so holders never lose
an in-kind claim on it. The base asset is never untracked.

## Adapters: enable, disable, unwind, remove

- `addAdapter`: a fresh clone for this Fund; waits 7 days when there are outside holders. Anyone enables
  it after the notice, unless the registry retired the implementation meanwhile. The owner can cancel.
- `disableAdapter` (owner or guardian): no new actions; positions stay counted.
- `unwindAdapter(instance, fraction)` (manager, or owner): turns positions back into tokens in the vault,
  for enabled or disabled adapters (not while a leaver's slice of it waits to be paid out: pay it out first,
  anyone may a day after the exit began). Charged to the loss budget; caps not checked (an unwind cannot add
  exposure, and it must work exactly when caps are breached).
- `removeAdapter` (owner): takes a disabled adapter out of the book (not while a leaver's slice of it waits to be
  paid out). At once when it reports nothing;
  otherwise its positions are written off, which waits 7 days after it was disabled (at once while nobody
  but the owner has held a share). An adapter that reports a debt is never removed, and neither is one that
  once reported a debt (`everOwed`) and cannot be read now: only a readable report of no debt proves the debt is
  gone. `everOwed` is set whenever an adapter shows a debt after any call into it: the manager's `act`,
  `unwindAdapter`, and the teller's `splitUnitsFor` and `unwindFor`. Nothing else can create a debt for a Fund's
  adapter (a clone holds nothing when enabled, and lending protocols let only the borrower borrow); interest only
  grows a debt that was already marked.

## The teller's doors in the controller

The teller reaches adapters only through teller-only controller calls, each with exact approvals for the one call
and none charged to the manager's loss budget (the teller measures instead):

- `collectFor(adapter)`: `grow(0)` on an enabled adapter, fees into the vault, before an exit in kind reads it;
- `reserveFor(adapter, f)`: sets aside a leaver's slice of an adapter in the adapter's units. From then on the
  book counts only the Fund's part (`unitsOf`, applied in every NAV reading), and `act`, `unwindAdapter`,
  `removeAdapter`, `unwindFor` and `pocketFor` on that adapter revert `ExitPending` until every slice set aside is
  paid out or handed back (`pendingExits` counts such adapters);
- `splitUnitsFor(adapter, units, to)`: pays a slice out (`split`, enabled or disabled: leaving must always work);
  `releaseUnits(adapter, units)` hands one back to the Fund;
- `unwindFor(adapter, f)` and `pocketFor(adapter, token, pockets, id)`: a holders' pocket taking a no-market token
  out of an adapter (whole unwind, measured by the teller, or the adapter's own `IPocketable` hook).

The teller reads every adapter it moved afterwards anyway (its measurement), so instead of the controller reading
each again, the teller calls `noteDebt(adapter)` for each that reports a debt (or could not be measured); the
controller then reads that adapter itself and leaves the `everOwed` mark if it owes, so the mark never rests on the
teller's word. The vault lets the teller track and untrack tokens, take snapshots for pockets and set the
outside-holder latch.

## What an adapter can reach

Only its own Fund. It is called by that Fund's controller alone; the vault approves it exact amounts for
one call and resets them after; `positions` is a static call; every other state-changing function in the
controller and vault is gated to the owner, manager, guardian, controller or teller; every controller
function holds one reentrancy lock, and the vault refuses to mint, burn or pay while the controller is
inside a call, so no deposit or exit can land between an action's two NAV readings. A registry clone is
bound to one vault for life.

What an adapter reports in `positions` is trusted. An unverified adapter that misreports can hide what it
takes (the invariant suite shows this with a "liar" adapter). That is why enabling an adapter waits the
notice, the registry can retire an implementation during it, Fund pages label unverified adapters, and an
owner who wants none of that keeps `allowUnreviewed` off.

## Pricing

- Unconfigured tokens are class None, worth zero. A first configuration, a better class, a smaller
  haircut, a new or removed source, a looser deviation or fewer decimals wait 1 day. Anything that can only
  lower asset values applies at once and cancels a pending raise for that token, so an emergency downgrade
  is never undone by an older announcement.
- Reads never revert: a reverting source or an absurd amount reads as unavailable.
- **Prices in another token.** A pool source (`UniswapV3TwapSource`, `PriceRecorder`) reports a token's price in
  the pool's other token (`IRatioSource`), and the router converts it through its own price of that token, side by
  side (bid through the quote's bid, ask through its ask), in the same call and from the settlement's transient
  cache. So a pool may be paired with anything the router prices: USDG, WETH, cbBTC, another stock, an index share.
  A chain is at most `MAX_HOPS` (3) long and may not loop; a chained price's class is the worse of the token's
  own and its quote's (a quote with no market makes it worth zero). The config marks chained sources
  (`Config.chained`).
- **Market sessions.** A token marked `usSession` follows Robinhood's 24/5 market (Sunday 20:00 to Friday
  20:00 New York time). New York's daylight saving moves that by an hour in UTC, so the router takes the
  safe side of both: closed from Saturday 00:00 to Monday 01:00 UTC, and for a calendar holiday from its
  00:00 UTC to 01:00 UTC the next day (`REOPEN_LAG`); it may call the market closed for an hour while it
  trades, never open while it does not. After a reopening a token counts as open only once its primary source has
  a reading from at or after it (20:00 New York time, by the US daylight saving rule); until then it is still in
  the closure that ended, with its prices and caps (`lastClosedSince`), and a source with no new reading
  `REOPEN_GRACE` (26 hours) after the reopening is unavailable. While closed, a token with a closed-market source (`SessionPoolSource`:
  its deepest pools, any pair, 30-minute TWAPs, each counting only while its in-range liquidity over the window and
  its stored history qualify, neither of which a trade in the same block can change) is priced on the worse-of rule: entrants at the highest of the
  converted pool prices (each held within `closedClampBps` of the last feed price) and the last price, times
  `1 + closedSpreadBps`; leavers at the lowest, times `1 - closedSpreadBps`; fair halfway. Without a qualifying
  pool, bid and ask widen around the last price by its `closedHaircutBps` on top of its haircut (5% in all for
  single stocks, 1.5% for ETFs at deployment). When a source calls its price stale, the router asks it
  (`ISessionSource`) for its last reading and accepts it if it was at most 26 hours old when the closure began.
  Holidays are added a day ahead and removed at once; session changes are instant only when they widen a spread
  with the same source and clamp; anything else waits a day.
- **Pool prices lag.** A pool source that also gives a recent price that cannot move within a block
  (`IRecentRatio`: a v3 pool's last minute, the recorder's newest complete slot) sets the bid from the lower of it
  and the average and the ask from the higher; fair stays the average. Funds also cap what one day moves in and out
  of a Fund holding Pool or Thin tokens (`Teller.poolFlowBps`, scaled to the share of NAV in them, at least
  `poolFlowFloorUsd`, $250).
- **Look-through** for wrappers: any change waits a day (it can loosen a cap either way).
- Funds' deposits and exits settle at weekends too, at those prices, with the deposits taken and the cash paid out
  per market closure each capped at 5% of NAV (`weekendInflowBps`, `weekendOutflowBps`; see
  docs/DEPOSITS-AND-EXITS.md).

## Roles

| Role | Can | Cannot |
|---|---|---|
| Owner | set dial, adapters, manager; unwind; pause the manager (own pause); replace the guardian after notice | act as manager unless it names itself; lift the guardian's pause |
| Manager | `act` and `unwindAdapter` within the dial until its expiry; untrack dust | change the dial, move money out |
| Guardian (AINDEX) | pause (only it lifts its pause), revoke a manager, disable an adapter, hand its role to a new key | move money, loosen anything |
| Registry reviewer (AINDEX) | mark adapters verified, retire and reinstate, correct an author | touch Funds |
| Price router owner (AINDEX) | configure pricing, sessions, holidays, look-through; raising a value waits 1 day | price instantly upward |
| Keeper (listed by the teller admin) | settle a closed batch (or a later round of one whose deposits wait); list requests whose limit fails; choose when to settle after the cut-off | choose a price (every price is the router's at settlement), send a deposit back, hold one request back while including another on the same terms, mint while a holding valued at zero is above dust |
| Anyone | return a request to its owner once it has waited 7 days since it was made, write off dust, set aside a holding valued at zero for the holders (`pocket`), claim a pocket for its holders, drain a pocketed position, pay out an exit slice a day after the exit began | touch a token an adapter holds or owes |
| Teller admin (AINDEX) | allow keepers (or open settlement to anyone); minimum opening stake and deposit, dust thresholds, the weekend inflow and outflow caps (0 to 10,000 bps each), the pool-price flow cap (0 to 10,000 bps) and its daily floor (at most $1,000), requests one payer may have waiting per Fund for each receiver (`maxLive`, 1 to 8) | touch escrow or Funds |
| Price recorder owner (AINDEX) | list recorders, who may record in the first 5 minutes of every 10-minute slot (anyone may after) | write a price |
| Fee config admin (AINDEX) | the fee split and the $AIX and treasury recipients, from the next accrual | change a Fund's rates or exceed the maxima |

The owner also sets the Fund's fee rates (`FundFees.setTerms`: a raise waits 30 days), its manager fee recipient,
its batch schedule, and may wind the Fund down: closed for good at once, deposits stop and waiting ones are paid
back; exits go on. On the second teller the owner's opening deposit is ordinary shares it may sell at any time; on
the first, its stake may leave 7 days after a wind-down, or when it is the last holder.

Role recovery: owner, reviewer and router owner transfer in two steps. The guardian of a Fund can hand on
its role at once; the owner can replace a lost or rogue guardian after the 7-day notice (holders see it
coming). The factory's guardian for new Funds also transfers in two steps; existing Funds keep their own.

The factory lets anyone create a Fund and name its teller. The teller can mint, burn and pay, so pages and
the MCP should list a Fund as investable only when its teller is an AINDEX teller, and take Funds from
`FundFactory.isFund`, not from registry events (anyone can produce those with a fake vault).

## Guarantees (not optional)

1. The manager can never withdraw: outputs go to the vault, approvals are exact and per call. What it can lose
   through bad trades is bounded by the daily loss budget it chose (`dailyLossBps`; 25% in `open()`).
2. Holders never pay for anyone's entry or exit: entrants are minted at the ask NAV per share and leavers paid at
   the bid, both from manipulation-resistant prices read after the batch's cut-off (and on the worse-of rule while
   a market is closed, with the net inflow per closure capped); entrants and leavers matched inside a batch trade
   with each other at fair NAV, which leaves the Fund untouched; new shares never take a slice of a holding valued
   at zero (it is pocketed for the holders of the moment first). An exit in kind pays its slice, measured.
   A request paid by one address for another belongs to its receiver, who alone cancels it and gets everything it
   pays; a cash exit only ever takes the caller's own shares, and a referrer is an event, never accounting.
3. Exit in kind always works: each adapter's `split`, any time, without the manager or a keeper, in one transaction
   or in parts (a leaver can leave behind an adapter or token that cannot be split right now).
4. More risk waits for notice.
5. Everything public (events, and manager notes through the MCP).

## Tests

- `test/unit`: registry, router (delays, lowers-only, deviation, None, sessions and a Monday holiday,
  look-through), vault, factory, seed teller, controller (every dial field, notice and safer merge, adapter
  notice, disable, unwind, remove, pause, revoke, expiry, loss window rollover, caps per class and per token
  with cash exempt, health with debts, unavailable prices, broken adapters, gas at the maxima,
  `allowUnreviewed` on waits and off is instant, unverified adapters refused while it is off, presets).
- `test/invariant`: a hostile manager drives honest venues and three hostile adapters (keeps tokens, sends
  them out, misreports) while prices move and days pass. Invariants: value never leaves through an honest
  adapter; vault approvals are zero between calls; a day's losses never exceed the budget; caps hold after
  every successful action.
- `test/adapters/AdapterSuite.sol`: what every adapter must pass, including `testSuite_SplitSumsToWhole`.
- `test/unit/TellerOwnerShares.t.sol`: the owner's opening shares in its wallet: sold in part or in full, in cash
  and in kind, while others hold or not; top-ups; no latch from the owner's own shares; the management clock from
  the latch; wind-down without notice; reopening (`AlreadyOpen`, `NotEmpty`); first-depositor and donation attacks
  on a new Fund.
- `test/unit/CreateFundWith.t.sol`: a Fund created ready in one transaction (adapters, manager, fee recipient, the
  same events), the same checks as the owner's calls (unknown or retired implementation, 13 adapters, a long term),
  and a setup nobody else can run (not the owner, the manager or a stranger; not twice; not after the first share;
  not on a Fund someone else made for the owner).
- `test/unit/Teller*.t.sol`: opening, requests and batches, cash in at ask NAV, cash out at bid NAV
  (in full, or short with shares handed back), matching at fair, limits (as prices, the fast paths, skips moved once
  then paid back), `maxLive`, receivers (the receiver owns the request, the payer cannot cancel it, places per
  payer and receiver pair, referrer events, pockets custody for the receiver; `TellerReceiver.t.sol`), the 10 USDG
  minimum, the 7-day return, owner cancel, wind-down, dead shares and
  donations, fees at settlement, exits in kind at once and in parts (units, NAV unchanged while a slice waits, the
  manager refused on that adapter, claim timing, escrow, release), reentrancy and the busy flag, the cash view.
- `test/unit/TellerWeekend.t.sol`: weekend settlement on the worse-of rule, the fallback, the inflow cap per
  closure (oldest first, the rest wait in rounds), rounds and their claims, a reopened market whose feed has no new
  round still counted in the weekend's closure.
- `test/unit/TellerPoolFlow.t.sol`: the pool-price flow cap per 24-hour window (deposits wait or go in in part,
  cash comes back as shares, scaled to the share of NAV in Pool and Thin tokens, the $250 floor, one cap a day
  whatever the cut-offs).
- `test/unit/Pockets.t.sol`: lazy snapshots (gas per move, binary search), pockets and claims, custody recorded once
  (claim gas flat in the number of snapshots), measured credits (growth nobody sent is not credited), pocketing a
  vault token, an adapter unwound and measured, continuation, Morpho supply in an unapproved market pocketed and
  drained, deposits and fees waiting until the pocket runs.
- `test/adapters/lending/MorphoOwnShares.t.sol`: supply on the clone's behalf ignored, a leaver's unpaid supply kept
  as its own and paid out later.
- `test/unit/ControllerExitUnits.t.sol`: units, the book scaled, the adapter frozen to all but `split`.
- `test/pricing/*`: chained prices (a WETH pool, two hops, a loop refused, the class downgrade), the worse of a pool's
  average and its recent price, the session pool source (window liquidity, history judged as after this block's
  write), the worse-of rule with one and with several pools in any pair, the reopening round (winter and summer
  Mondays, the daylight saving switches, a feed that never returns), the recorder's current slot left out.
- `test/unit/TellerGas.t.sol`: settlement and exit gas with mocks at the caps (live costs: docs/DEPOSITS-AND-EXITS.md).
- `test/unit/RoundingAcrossRows.t.sol`: exits in kind from adapters that report one token in many rows.
- `test/invariant/TellerInvariant.t.sol`: random deposits, cash exits, exits in kind (also in parts), settlements
  at any time (weekends included), prices moving and a manager trading. Invariants: holders who stay never lose NAV
  per share to the teller beyond rounding, the teller holds what it owes, fees stay within the maxima.
- `test/fork/SettlementGas.fork.t.sol`: every settlement path, the exit in kind (at once and in parts) and pockets
  at the caps on a fork of Robinhood Chain.

## Deploying

`script/deploy-funds.sh` (with `script/preflight.sh`: clean tree, chain 4663, DRY_RUN=1) runs
`script/DeployFunds.s.sol`, which deploys every contract and adapter implementation and the public teller
(`FeeConfig` at 70 / 15 / 15 with the $AIX holders' recipient `FUNDS_AIX_RECIPIENT`, default the AINDEX payout
wallet, and the treasury `FUNDS_TREASURY`, default the AINDEX Safe; `FundFees`; `Teller` with a 10 USDG opening
stake and the five swap routers allowed), and proposes the price configuration in `script/funds-config.json`.
The router and sources delay any raise by a day, a first configuration included, so `script/apply-pending.sh`
(`ApplyPending.s.sol`, anyone may run it) applies it 24 hours later. Then `script/create-fund.sh`
(`CreateFund.s.sol`) creates a Fund through the teller: owner (the key), name, symbol, dial preset (open by
default), fee rates, opening deposit, adapters and manager; the strategy lives off chain. With a record that says
`oneTxCreate` (the second teller's) it is one `createFundWith` after the approval, otherwise `createFund` then one
call per adapter and the manager. `script/deploy-teller-v2.sh` (DRY_RUN=1, preflight, keystore) deploys the second
teller next to the first.
`script/create-first-funds.sh` runs it for each of AINDEX's first Funds in `script/first-funds.json`.

`script/rehearse-funds.sh` runs all of it on an anvil fork, then the manager's trades through every adapter kind
(`RehearseFund.s.sol`: KyberSwap and Universal Router swaps, ERC-4626, Morpho supply, collateral and borrow,
Uniswap v3, v4 and Fables liquidity) and the public side (`RehearseTeller.s.sol`: cash-in batches, a match, cash
exits in full and short, exits in kind at once and in parts, a weekend settlement on the worse-of rule, a pocket,
fees after 30 days, the manager investing new cash), checking fairness at each settlement. Steps are in
the README.

Contract sizes (`forge build --sizes`, 2026-10-04): the Teller (46.4 KB, initcode 47.7 KB,
under the 49.2 KB initcode cap), the Fables adapter (34.0 KB), the Uniswap v4 adapter (28.6 KB), the Morpho adapter
(27.4 KB), the controller (26.2 KB), the Uniswap v3 adapter (24.6 KB) and the factory's initcode (38.7 KB) are above
Ethereum's 24 KB limit; TellerOps (20.0 KB), the PriceRouter (18.7 KB), TellerMath (16.7 KB), FundBook (11.5 KB),
TellerQueue (5.7 KB) and Pockets (5.1 KB) are under it. Robinhood Chain accepts far larger code (checked 2026-10-01 with
`eth_estimateGas`: a 60,000-byte contract deploys, a 100,000-byte one does not), so the 24 KB limit is not a hard
constraint there; the scripts simulate with `--disable-code-size-limit` and the rehearsal's anvil runs with it.

## Status

- Core: vault, controller, book, registry, price router (sessions, look-through), factory, seed teller,
  dial presets.
- Price sources (Chainlink, v3 TWAP, v4 recorder) and adapters (swap, index, ERC-4626, Morpho, Uniswap v3
  and v4, Fables), fork-tested on Robinhood Chain; deploy, apply and create-Fund scripts rehearsed on a fork.
- Public teller (`Teller` and its libraries), holders' pockets (`Pockets`) and fees (`FeeConfig`, `FundFees`):
  rebuilt for cash in at NAV on 2026-10-02, tested with mocks, in the deploy scripts, and rehearsed on a fork with
  every adapter. Live on Robinhood Chain (`deployments/4663.json`).
- Second teller (owner's opening deposit in its wallet, one-transaction creation): tested, dry-run against the
  chain and rehearsed on a fork on 2026-10-04; not yet deployed.
