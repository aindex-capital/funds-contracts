# Deposits and exits (the public teller)

Decided 2026-10-02 ("cash in at NAV"), built the same day. This replaces the earlier design in which a
deposit bought a slice of every holding inside its settlement (keeper routes, adapter grows, a measured purchase,
a premium cap): that settlement cost about 28M gas at small caps and could not get under 19M. This is the design
as implemented in `src/core/Teller.sol` (with its linked libraries `TellerOps`, `TellerMath`, `TellerQueue`),
`src/core/Pockets.sol`, `src/core/Fees.sol` (`FeeConfig`, `FundFees`) and the PriceRouter's closed-market pricing
(`src/pricing/PriceRouter.sol`, `src/pricing/sources/SessionPoolSource.sol`).

## The short version

- **Cash in at NAV.** A deposit's USDG enters the Fund as cash and the depositor gets shares at the Fund's
  **ask** NAV per share (assets at ask, debts at bid). The manager, or its AI agent, invests the cash in its own
  actions, inside its dial, as it would any cash. The same model as Enzyme and dHEDGE. The teller never swaps,
  never grows an adapter and never takes a route from anyone.
- **Cash out at NAV.** A cash exit is paid from the Fund's USDG at the **bid** NAV per share (assets at bid,
  debts at ask). When the Fund holds less USDG than that, the cash goes as far as it reaches and the rest of the
  leaver's shares comes back to it, to leave in kind; the app swaps those tokens for the user outside the
  contracts.
- **Batches stay**, so nobody trades on a stale price: requests come before the Fund's cut-off (daily at 21:00
  UTC by default) and settle after it, at prices read then. Inside a batch, entrants and cash leavers are matched
  first at the **fair** NAV per share: neutral for the Fund, and at least as good for each side as its own net
  price.
- **Weekends and holidays settle too.** While a US stock's market is closed, the router prices it on the
  "worse-of" rule: entrants at the highest of the token's deep pools and Friday's price, plus a spread; leavers at
  the lowest, less the spread. Per closure, deposits taken are capped at 5% of NAV (beyond it they wait for the next
  cut-off) and cash paid to leavers at 5% (beyond it their shares come back, to leave in kind). There is no
  closed-market hold and no matching freeze any more.
- **Holders' pockets.** Something NAV values at zero (a token with no market price, a claim nobody can value)
  is set aside for the holders of that moment before any new share is minted (`pocket`, anyone), and they claim it
  in kind, forever. Deposits never pause for it: they wait until the pocket runs, which a keeper does first.
- **Exits in kind** work at any time, without a keeper. A Fund too large to leave in one transaction is left in
  parts: the shares burn and the vault tokens are paid at once, and each adapter's slice is set aside (the Fund's
  book stops counting it) and paid out in its own transaction.
- Settling is open to the keepers the teller admin lists. A keeper chooses nothing but which requests' limits
  fail; every price comes from the router at settlement.
- **Receivers.** A deposit or a cash exit may be paid by one address for another (a partner app, a zap, an
  embedded wallet): the receiver owns the request and gets everything it pays. A deposit may name a referrer,
  which is only an event.

## One teller for every Fund

One `Teller` serves every Fund, keyed by vault. Pages and the MCP call a Fund investable only when its vault's
teller is the AINDEX teller; one address makes that a single check and gives keepers one contract to call. Funds
are kept apart by bookkeeping: everything the teller owes is counted in `owed(token)`, and the teller checks after
every settlement that it still holds what it owes in USDG and in the Fund's shares. Only vaults made by the AINDEX
`FundFactory` whose teller is this contract can be opened.

## Opening a Fund

Two tellers serve AINDEX Funds on Robinhood Chain. The first (`deployments/4663.json`) keeps the Funds opened on it,
whose owners' opening stakes stay in its custody under its own rules (`releaseStake` when the owner is the last
holder or 7 days after `windDown`; `assignStakePockets`). New Funds open on the second (`deployments/4663-teller-v2.json`,
owner decision 2026-10-04), described here: the owner's opening deposit is ordinary shares in its wallet.

`createFund(name, symbol, dial, stakeUsdg, managementBps, performanceBps)` creates the Fund through the factory
(the caller is its owner) and opens it in one transaction; `open(vault, ...)` opens a Fund made separately.
`createFundWith(name, symbol, dial, stakeUsdg, managementBps, performanceBps, setup)` does the same and readies the
Fund for its manager in that one transaction (one wallet prompt after the USDG approval): `setup` lists the adapters
to enable (implementations and configs), the manager and its term's end, and the fee recipient (zero: the owner).
The controller applies them through `FundController.setup` with exactly the checks and events of `addAdapter` and
`setManager` while only the owner holds (a fresh clone from the registry, which refuses an unknown or retired
implementation; at most 12 adapters; a term of at most 366 days). Only the Fund's teller may call `setup`, once,
before the Fund's first share exists, and the teller calls it only for the Fund `createFundWith` has just created
for its caller, so no one can run a setup on anyone else's Fund or reach it later. The plain flow still works:
`createFund`, then the owner's own `addAdapter`, `setManager` and `FundFees.setRecipient`.

- The owner deposits at least `minOpeningStake` USDG (10 USDG at deployment; it pays for the opening and keeps dust
  Funds out), at one share per USDG (scaled to 18 decimals). That is the only time a share count is set by a fixed
  price, and it is the owner's own money in an empty Fund.
- On a Fund's first opening the teller also mints `DEAD_SHARES` (1e12, about a millionth of a USDG) to itself:
  never owed, never redeemed, a floor under the supply. Without it an owner (or anyone) who is the last holder
  could shrink the supply to a few wei and then donate to the vault, so that rounding a new depositor's mint down
  took a large part of its deposit. With it, a mint rounds away less than one raw share, whatever anyone donates,
  and a donation stays with the holders of the moment, mostly the dead shares once the owner has left
  (`test/unit/TellerOwnerShares.t.sol`: the owner keeps one wei and donates a million USDG, the next depositor gets
  its 1,000 USDG back less rounding; the owner leaves in full and a stranger donates; a front-run donation on a new
  Fund).
- The opening shares are minted to the owner's wallet: ordinary shares. The owner may keep them, top up
  (`requestDeposit`), or sell part or all of them at any time through the same cash and in-kind exits as anyone,
  whether or not anyone else holds. Nothing is held back for it: holders are protected by the dial, the notices on
  every change that adds risk, the loss budget and their own exit in kind, not by the owner's money staying in.
- The owner's own shares never set the vault's outside-holder latch (`FundVault._update` latches only on a share
  reaching someone other than the owner or the teller), wherever they move between the owner's wallet and the
  teller's escrow, so an owner-only Fund keeps its instant dial, adapter and fee changes and is charged no fee. The
  teller sets the latch as soon as a deposit is queued for a receiver other than the owner (whoever pays it), and
  undoes it if every such deposit is cancelled before any share reaches an outsider. A share the owner sends to
  anyone else latches for good.
- `windDown` closes the Fund for good, at once: no deposit request is taken from then on, the owner's included, and
  every deposit still waiting is paid back at its next settlement. Exits go on as before. It needs no notice (it
  only stops money coming in) and no longer frees anything: there is no stake to wait for.
- A Fund every holder has left can be opened again by its owner while what is left in it is worth less than
  `dustUsd`.

## Requests and batches

- A request joins the Fund's open batch. Cut-offs fall every `interval` seconds, `offset` after midnight UTC:
  daily at 21:00 by default; the owner may choose any interval from 1 hour to 7 days (`setSchedule`).
- A batch takes at most 100 requests (`MAX_REQUESTS`); while it is full a request goes to the next batch with room
  (up to `MAX_SPILL`, 8, batches ahead).
- **Deposits** need at least `minDeposit` (10 USDG at deployment) and a `minShares` above zero: the least shares
  for the whole amount, so it is a price limit. No new deposit requests while the Fund's manager is paused
  (`DepositsPaused`) or after a wind-down. Nothing else refuses a deposit request: a no-market holding no longer
  pauses deposits. A request no longer reads the Fund (about 0.4M gas; it read every adapter before).
- **Cash exits** need at least `minDeposit * 1e12` shares (10 shares with 6-decimal USDG) and a `minUsdg` above
  zero: the least USDG for all the shares, judged as a price on the part the Fund pays in cash. A smaller holding
  leaves in kind, which needs no queue.
- One payer may have at most `maxLive` requests (3 at deployment, at most 8) waiting in one Fund for each
  receiver (`TooManyRequests`); someone acting for itself is the pair of itself and itself. Keyed by the pair, so a
  payer only ever uses its own places: nobody can fill another's places to block it. With `minDeposit`, filling
  every batch a Fund has open takes hundreds of funded requests.
- An owner can take a request back until its batch's cut-off (`cancel`). Once a request has waited `STALE_AFTER`
  (7 days) since it was made, anyone may return it to its owner, frozen or not, so escrow is never stuck if
  keepers stop.

### Paying for someone else: receivers and referrers

`requestDeposit(vault, usdg, minShares, receiver, referrer)` and `requestRedeem(vault, shares, minUsdg, receiver)`
let one address pay for another, for partner apps, zaps ("pay with any token") and embedded wallets. The
three-argument forms are the same call with the caller as receiver and no referrer.

- **The receiver owns the request.** Its `owner` is the receiver. Only the receiver may cancel it while its batch
  is open, and a cancel pays the receiver: the USDG of a deposit, the shares of a cash exit. The payer keeps no
  claim on it and cannot cancel it. A payer that wants to take its money back must not use a receiver.
- **Everything goes to the receiver:** the shares a deposit buys (or its USDG on a wind-down), a cash exit's USDG
  and any shares handed back for an exit in kind, a request paid back after its limit failed twice, the 7-day stale
  return, and the part of every pocket taken while the request's shares sat in the teller's custody.
- **A cash exit always takes the caller's own shares** (`transferFrom` the caller, never anyone else), so nobody
  can redeem another's shares, whatever allowance that someone gave the teller.
- **Places:** `maxLive` counts per payer and receiver pair (above), so a zap serving many users has `maxLive`
  places for each of them, and a stranger depositing for you fills only its own places for you, never yours.
- The minimum deposit, `minShares`, the cash exit minimum, the paused and wind-down refusals and every settlement
  rule are the same for a request with a receiver. The receiver may not be zero, the vault or the teller
  (`BadReceiver`). The outside-holder latch follows the receiver.
- **Referrer:** an optional `bytes32` (an address, left-padded, or a partner code). When it is not zero the teller
  emits `Referred(vault, id, referrer)` after `DepositRequested`; it is stored nowhere and changes nothing on chain,
  so it cannot touch accounting. Partner payouts are made off chain from the event.
- **Exits in kind** already send to a recipient (`to`) and burn the caller's own shares; nothing changed there. The
  caller stays that exit's owner (it may release a slice), and both the caller and `to` may claim its slices at
  once.

## Settlement

`settle(vault, batch, skip)`, by a listed keeper once the cut-off has passed. One transaction, no swaps:

1. **One reading.** The router prices every counted token once for the settlement (`warm`, kept in transient
   storage until `release`); every adapter's `positions` is read once (`TellerMath.snapshotAll`, scaled to the
   Fund's part where a leaver's slice waits to be paid out); `FundBook.navs` prices that one reading on every side
   (bid, fair, ask) in one call per token (`PriceRouter.values`), and the hold check reads the same rows.
2. **Fees** accrue at the bid NAV before anything changes the share count (management, performance above the
   high-water mark, first loss), exactly as before. Fees wait while a holding valued at zero is above dust (fee
   shares would take a slice of it too); they accrue in full at the next settlement after the pocket.
3. **Which deposits go in** (below: when deposits wait). A Fund winding down pays them back.
4. **Match.** With a complete fair NAV and a USDG price, entrants and cash leavers are matched at the fair NAV per
   share: the smaller side in full. The leavers' escrowed shares go to the entrants and the entrants' USDG to the
   leavers, inside the teller. Nothing moves in or out of the Fund. Fair lies between bid and ask, so a matched
   entrant pays no more than the ask it would pay unmatched, and a matched leaver gets no less than the bid.
5. **Net entrants.** Their remaining USDG goes into the vault as cash and they are minted
   `usdg * usdgBid / unit * supply / navAsk` shares, rounded down. The holders they join never pay for their
   entry: the ask NAV counts every holding at its ask, so the spread stays with the Fund.
6. **Net leavers.** Their remaining shares are worth `shares * navBid / supply` at bid. The vault pays that much
   USDG if it holds it; otherwise it pays all it holds for the matching part of the shares, and the rest of the
   shares (`sharesBack`) go back to the leavers on `claim`, to leave in kind. Without a complete bid NAV or a USDG
   price nothing can be priced, so every share goes back.
7. **Limits.** Each entrant's `minShares` and each leaver's `minUsdg` must be met, or the keeper lists it in
   `skip`: it moves to the next batch once (a request moved before, or one that does not fit there, is paid back
   in full). A keeper may only list a request whose limit would have failed, so it cannot hold anyone back at will:
   with nobody left on a request's side it must be beyond the fair NAV, and with a price missing (deposits wait,
   leavers' shares come back) nothing is judged, so nothing can be listed.
   When the round's price beats the batch's tightest limit on a side (`depTight`, and for leavers `redTight` by a
   raw unit on the smallest exit, `redLow`), that side is not read at all.
8. **Pay out pro rata.** `claim(id)` pays a deposit its shares (or its USDG back on a wind-down) once its round is
   done, and a cash exit its USDG plus any shares handed back. Anyone may call it for the owner. The last claim of a
   round takes the rounding remainder.

Every price used comes from the router at settlement, after the cut-off: a request cannot see the price it will
get. A keeper still chooses the moment it settles (after the cut-off); the spread between fair and bid or ask
covers an oracle's own deviation band (0.5% for Robinhood's feeds), and settling is limited to listed keepers.

### When deposits wait: rounds

A deposit that cannot go in at a settlement is never sent back by it. It stays in its batch with its id, its
limit and its 7-day clock; the batch takes the Fund's next cut-off (`DepositsWait(vault, batch, toBatch, usdg,
reason, token)`), its owner can take it back until then, and a later round of the same batch takes it. Leavers are
paid at the batch's first round and never wait. Reasons:

- **2, a holding valued at zero** above dust (`writeOffMaxWad`, 0.0001 of a token): nobody is minted until the
  pocket runs (below). A keeper runs `pocket` first and then settles, so in practice deposits do not wait.
- **3, a price unavailable**: the Fund's NAV is incomplete (a feed down, an adapter that cannot be read) or USDG
  has no price.
- **4, over the closure's inflow cap** (weekends and holidays, below): the batch's deposits go in oldest first
  while they fit (one too large to fit waits and a later, smaller one may still go in), the rest wait; they go in
  whole when the market opens.
- **5, over the pool-price flow cap** (below): oldest first too, but the first one too large for the room left goes
  in in part when that room is at least the least deposit (`minDeposit`): the part becomes a request of its own
  (same owner, batch and 7-day clock, its limit scaled to the part and rounded up, `DepositSplit`), and the rest
  keeps its id and the rest of its limit and waits for the next day. Without enough room for a part, it waits whole
  and a later, smaller one may still go in. So a deposit larger than a whole day's cap still goes in over the next
  days, instead of waiting until it is handed back.

A round writes nothing per waiting deposit: a round that takes every waiting deposit marks nothing (a deposit
still unmarked when its batch is settled belongs to its last round), and a round under the cap marks only the
deposits it takes, plus at most one part. The earlier design moved waiting deposits into the next batch (about 30k
gas each, 3M for a full batch) or kept them in pro-rata partial rounds.

### Weekend and closed-market pricing (the worse-of rule)

A token the router marks `usSession` (Robinhood stock and ETF tokens) follows Robinhood's 24/5 market. The router
calls it closed from Saturday 00:00 to Monday 01:00 UTC and for each calendar holiday from that day's 00:00 to
01:00 UTC the next day: it may call the market closed for an hour while it trades, never open while it does not.

A reopened market is not yet a new price: until the feed's first round of the new session the router would quote
Friday's price as if open (on a winter Monday the calendar reopens at 01:00 UTC, the moment the market does). So a token counts as open only once its primary source has a reading from at or after the
reopening, 20:00 New York time (00:00 UTC while New York keeps summer time, 01:00 UTC otherwise, by the US rule since
2007). Until then it is still in the closure that just ended: worse-of prices, and the same closure's caps
(`PriceRouter.lastClosedSince`, which the teller keys its caps on). Measured 2026-09-28: SPY, AAPL and SGOV posted their
first round at 00:00:40 to 00:00:48 UTC, so the extra closed time is under a minute after the calendar reopens. A
feed with no new round `REOPEN_GRACE` (26 hours) after the reopening is unavailable. The same applies after a
holiday.

What we measured (14 weekends of feeds, 2 of pools, 2026-10-02):

- Robinhood's stock feeds stop from Friday 20:00 to Sunday 20:00 New York time. The gap from the frozen Friday
  price to Monday's open: 0.57% at the median, 5.4% at the 99th percentile, 7.75% at most.
- The tokens keep trading in Uniswap v3 pools. The deepest give 1% depth of about $40k to $770k; moving a pool 1%
  costs about twice its fee on its depth.
- Pools paired with WETH, converted at the live Chainlink ETH feed, tracked the USDG pools of the same stock within
  0.6% over both sampled weekends (median under 0.1%) and within 0.4% live on 2026-10-02: the ETH feed's own 0.5%
  deviation band. So a pool may be paired with any token the router prices.
- The worse-of rule with a 0.5% spread left the worst holder edge at 0.02% on the measured data.

The rule, per token, while its market is closed:

- `last` is the feed's last price (Friday's). `P_pool` is each configured pool's 30-minute time-weighted price
  (`SessionPoolSource`, up to three pools per token), converted to USD through the router's own price of the pool's
  other token, on the side it prices, in the same call, and held within `closedClampBps` of `last` (3% single
  stocks, 1.5% ETFs). A pool counts only while its in-range liquidity over the window (the harmonic mean, from the
  pool's `secondsPerLiquidityCumulative`) is at least its `minLiquidity` (a quarter of what it held on 2026-10-02),
  and its stored history covers the window even after one more observation is written in this block. Neither can
  change within a block (qualifying on the liquidity at the current tick would let a flash add or
  remove move a closed-market quote by about 1% to 4%, and choose which pools the router takes the worst of).
- Entrants (the ask): `max(last, every P_pool) * (1 + s)`. Leavers (the bid): `min(last, every P_pool) * (1 - s)`.
  Fair: halfway between. `s` (`closedSpreadBps`) is 0.5% for ETFs, 1% for megacaps, 3% for volatile names (COIN,
  CRCL, GME, MSTR, SPCX, TSLA).
- When no pool qualifies (none configured, too thin, pushed out of its range, too short a history), the fallback:
  `last` with the closed spread on top of the haircut (`closedHaircutBps`: 5% in all for single stocks, 1.5% for
  ETFs; 5% for pool-priced stock tokens and the AIXSTR index share).

Bending a pool can only make entrants pay more or leavers get less, never the other way round, so nobody gains by
bending one: a holder could grief entrants by at most the band, which each entrant's own limit bounds. What the
rule cannot see is a true move beyond the band (the 7.75% weekend): an entrant who expects such a gap up and holds
the pools down for 30 minutes pays the clamped ask instead of the true price. So:

- **Deposits per closure are capped** at `weekendInflowBps` (5% at deployment) of the Fund's fair NAV at the
  closure's first settlement, matched with a leaver or not (a matched entrant pays the closed market's fair price
  too); deposits beyond the cap wait for the next cut-off. **Cash paid to leavers per closure is capped** the same way
  at `weekendOutflowBps` (5%): a leaver who expects a gap down leaves at the lowest price the pools and Friday show,
  so cash exits beyond the cap come back as shares, to leave in kind (an exit in kind is never priced). The hold check
  reports a closed market even when the Fund also holds a no-market token, so the caps apply then too.
- The worst a closure can cost the holders is therefore about each cap times what the gap exceeds the band and the
  spread by: 5% times (7.75% less 3% less 1%), about 0.19% of NAV a side at the largest gap measured, before the
  attacker's cost of holding every qualifying pool off market for half an hour. Measured in testing: an entrant who bends the pool down before a gap up gains 2.8%
  on what the cap lets in; a leaver who bends it up before an 8% gap down costs the stayers 0.22% of their value.
- Settlement, matching and exits otherwise run as on a weekday. The old closed-market hold (`depositHold` said
  `MarketClosed`, every deposit waited, nobody was matched) is gone; `depositHold` still says `MarketClosed` while
  the worse-of rule and the cap apply.

Configuration lives in the router's session (`closedSpreadBps`, `closedClampBps`, `closedHaircutBps`,
`closedSource`) and in `SessionPoolSource` (the pools and their `minLiquidity`), both behind the one-day delay.
Widening a spread is instant (the emergency lever); a new or removed source, a new clamp, a narrower spread or a
new pool waits. `script/funds-config.json` lists the pools (`weekend`) and the cap (`teller.weekendInflowBps`).

**More weekends are being collected.** The spreads above rest on two weekends of pool data, and the read RPC keeps
only about 15 days of state, so from its next deploy (code written 2026-10-03) the AINDEX market indexer samples every pool in `weekend`
(`aindex/apps/indexer/src/weekendpools.ts`): every 30 minutes of each closure and once at the reopening, the
pool's 30-minute TWAP in USD (through the Chainlink feed of its other token), its in-range liquidity, the token's
last feed price, and after the reopening the feed's first round of the new session. After 4 to 6 more weekends,
run `node deploy/weekend-spreads.mjs` in the `aindex` container (or on a copy of the database, after
`npm run build`; see `aindex/apps/fund-agent/README.md`). It prints per token and weekend the Friday-to-Monday
feed gap, each pool at the reopening against Friday and against Monday, and how far Monday landed outside the
worse-of band; then the p50/p95/p99 across weekends and a suggested `closedSpreadBps` = max(0.5%, p95 feed gap)
and fallback = p99 feed gap, beside today's. The indexer keeps a copy of `weekend`; update it with the config
(a test there compares the two).

### Pool-priced tokens on any day (the worse of the average and the recent price)

A token priced from a pool (class Pool: a 30-minute v3 TWAP; class Thin: the same with a 10% haircut, or a recorded
24-hour median) trails its market. Minting and redeeming at the average alone let anyone who saw the market move
enter cheap or leave rich (the open dial allows a Fund wholly in Thin tokens). Two mechanisms:

- **Worse of the average and the recent price.** The TWAP source also gives the pool's last minute and the recorder
  its newest complete slot (`IRecentRatio`); the router takes the bid from the lower of the two and the ask from the
  higher, each with the haircut; fair stays the average. Neither recent price can move within a block (a v3 pool
  writes at most one observation per second, with the price from before that second's trades; the recorder never
  counts its current slot). Bending the recent price only worsens the price of whoever bends it. Honest cost,
  measured over the week to 2026-10-02 on every configured TWAP pool (168 hourly samples each): an entrant pays on
  average 0.05% more than at the average alone (PONS 0.24%, every stock token 0.05% or less); the gap between the
  average and the last minute was 0.3% or less at the median and 4% at most.
- **A flow cap per day.** While a Fund holds such tokens, the deposits it takes and the cash it pays per 24-hour
  window (UTC days, whatever the Fund's cut-offs, so hourly cut-offs share one cap a day and a new schedule does not
  start a new one) are each capped at `poolFlowBps` (5% at deployment) of fair NAV divided by the share of NAV in
  Pool and Thin tokens: 5% of NAV for a Fund wholly in them, 10% for one half in them, no real limit for a crumb.
  The cap is never under `poolFlowFloorUsd` ($250 at deployment, at most $1,000, teller admin), so a small new Fund
  still takes a normal deposit. Deposits beyond it wait (reason 5, `WAIT_POOL_FLOW`), oldest first, the first one too
  large going in in part (above); cash exits beyond it come back as shares to leave in kind. A pool held off market
  for a whole window (to bend the average and the recent price together) can then cost the holders at most the cap
  times how far it was bent beyond the haircut, per day (the cap is per 24-hour window, not per cut-off interval).

### Holders' pockets (no-market holdings)

A token the router cannot price (class None) is worth zero in NAV, yet an exit in kind hands its slice over; the
same holds for a claim an adapter values at zero (`IUnvalued`, Morpho supply in a market AINDEX has not approved).
A share minted while the Fund holds one would take a slice of it without paying. Instead of pausing deposits, the
holding is set aside for the holders of that moment:

- **Snapshots.** `FundVault.snapshot()` (teller only) starts a snapshot; `balanceOfAt(account, id)` answers what an
  account held then. Checkpoints are lazy, as in OpenZeppelin's former ERC20Snapshot: an account's balance is
  written once per snapshot, at its first move after it, as one entry of its own ordered list, and `balanceOfAt` finds
  it by binary search, so its cost never grows with how many snapshots anyone took. A share move costs one extra read
  while no snapshot was ever taken (about 2.1k gas), about 44k for an account's first move after a snapshot, and about
  4k after that.
- **Pockets** (one contract for every Fund) records `(vault, id, token, amount, supplyAt)`. `claim(vault, id,
  account)` pays the account `amount * sharesAt / supplyAt` in kind, less what it already took; anyone may call it
  (the tokens go to the account), and it never expires. A pocket can grow later (`topUp`): every account's part
  grows with it. A pocket is credited only with measured arrivals: `topUp` with what its transfer brought, the
  teller's `credit` with what arrived since its `mark` in the same transaction. Growth nobody sent (a rebase, a
  dividend multiplier) stays unassigned, so nobody captures other Funds' growth with a pocket of their own. Only the teller wired at deployment (`Pockets.wireTeller`) opens and credits, and only for a
  vault that names it as its teller; a pocket never pays out more than arrived for it (`paidOut`).
- **`pocket(vault, token, adapters, into)`**, anyone, when the token is class None (or an adapter's unvalued claim
  in it) above `writeOffMaxWad`: it snapshots the shares, opens the pocket, and for each named adapter that holds
  the token either calls its `IPocketable` hook (the Morpho adapter moves its unapproved-market supply into the
  pocket: what the market can pay now, the rest by `drain()`, anyone, as borrowers repay) or unwinds the adapter
  whole into the vault (a no-market token cannot be taken out of a position on its own), measured on that adapter:
  its positions plus what the vault got from it may be worth at most 0.1% less, at fair, than before. An unwind at
  a moved pool price returns more than a position's oracle value, never less, so a sandwiched pocket costs the Fund
  nothing. Then the vault's whole balance of a no-market token goes to the pocket and the token is no longer
  counted. `into` adds to a pocket opened for the same token within a day while no share has been minted since
  and no exit in kind has begun since (`lastInKindAt`: a leaver in kind already took its slice of what was still in
  the adapters, and its snapshot balance must not take a part of it again), so a token many adapters hold can be
  pocketed over several transactions. After such an exit the rest is pocketed afresh (`into` 0).
- **The owner's opening shares** sit in its wallet, so the snapshot counts them like anyone's: no custody record,
  nothing to assign, and shares it sells after a snapshot keep their part of that pocket.
- **Shares in the teller's custody at a snapshot** (an escrowed cash exit, shares a round minted that are not
  claimed yet, shares handed back) belong to request owners: when the shares leave custody (`claim` or `cancel`)
  the teller records the custody once
  (owner, shares, the snapshots it spanned), and a pocket claim asks it for the account's part at that one snapshot
  (`Teller.custodyAt`). One write however many snapshots were taken: walking every snapshot
  instead, 600 of them would make a claim cost 85M gas, freezing a leaver's cash. The dead shares' part
  stays in Pockets. The manager's locked
  first-loss shares in `FundFees` are an ordinary account: their part can be claimed only to `FundFees`, which
  cannot pass it on.
- **When it runs.** A settlement with entrants first needs every holding valued at zero above dust pocketed; until
  then its deposits wait (reason 2) and its fees wait. The keeper calls `pocket` in its own transaction, then
  settles. A no-market token inside a wrapper (an index share's basket) cannot be pocketed: new money waits until
  the manager sells the wrapper.

### Exits to cash

At settlement, after the match, from the Fund's own USDG at the bid NAV per share. The leavers bear no swap and no
slippage; the bid spread stays with the holders who remain. When the USDG is short, the cash is shared pro rata by
every leaver in the batch and the rest of each leaver's shares comes back on `claim`; the leaver then leaves in
kind (`redeemInKind`, or in parts), and the app swaps those tokens for it. Taking cash out of a Fund that borrowed
against its holdings raises its leverage (its debts stay); its health floor binds the manager's next actions, not
the leavers.

A **minimum cash buffer** (a dial field the manager must keep, say 5% of NAV in USDG) would make cash exits pay in
full more often and keep fewer leavers on the in-kind path, at the cost of cash drag and one more check in every
manager action. It is not added; see the report of 2026-10-02.

### Exits in kind

`redeemInKind(vault, shares, to)`, any time, no keeper: the leaver's shares are burned and it receives its slice
of every counted vault token and of every adapter (`split`), sent to `to`.

1. Every enabled adapter's fees are collected into the vault first (`grow(0)`), so the leaver's slice of the vault
   includes its share of them.
2. The leaver's slice of each adapter is set aside in the controller's units (`reserveFor`): the Fund's book
   stops counting it at once.
3. The shares are burned; the leaver gets its slice of every counted vault token, rounded down, less the escrow
   its slices' debt repayment needs (`unwindInputs`), which the teller holds. Where its own slice of a token does
   not cover the escrow, the leaver brings the difference (approve it; `inKindNeeds` shows how much).
4. Each adapter's slice is paid out (`claimInKind`, or at once in `redeemInKind`): the escrow goes into the vault,
   the controller splits the adapter by the slice's units (`splitUnitsFor`), repaying its debt from the vault,
   and the adapter is measured to keep at least `(1 - x)` of every position and owe no more than `(1 - x)` of every
   debt, within two raw units per row. Escrow left over goes to the leaver; a shortfall is brought by the caller.
5. `redeemInKindLeaving(vault, shares, to, leave)` leaves listed adapters or tokens behind (one that cannot be split
   or transferred now); what is left stays with the other holders.

**In parts.** At the caps one transaction cannot split every adapter (a full Fund measured about 40M gas against
Robinhood Chain's 32M limit), so `startInKind(vault, shares, to, leave)` does steps 1 to 3 (with
`EXIT_MARGIN_BPS`, 0.5%, of escrow on top for interest) and `claimInKind(exitId, adapters)` does step 4 for the
listed adapters, in as many transactions as needed. An adapter that holds and owes nothing (`TellerMath.holdsNothing`:
its `positions` read and every row is zero, and where a row of zero could stand for a claim valued at zero, `unvalued`
answers nothing or does not exist) gets no slice and needs no step; when no adapter holds anything the exit is
complete in `startInKind` itself (`pending` 0). An adapter that cannot be read, or whose `unvalued` fails, is set
aside as any other. `inKindSteps(vault, shares)` lists the adapters that would need a step. An exit in parts needs at
least a cash exit's minimum (`minDeposit * 1e12` shares): a dust exit leaves in one transaction. It is safe because of what the controller enforces while a
slice waits:

- the Fund's book counts only the Fund's part of that adapter (`unitsOf`, scaled in every NAV reading: the
  controller's, the teller's and the hold check's), so NAV per share is the same before and after a slice is set
  aside, and nothing priced meanwhile (a deposit, a cash exit, fees) sees the leaver's slice;
- nothing but `split` may change that adapter: the manager's `act` and `unwindAdapter`, the owner's
  `removeAdapter`, a pocket's unwind or hook all revert `ExitPending` until every slice set aside on it is paid
  out. Positions may still change by themselves (interest, fees, prices), and every unit shares that pro rata;
- the leaver or its recipient may claim at once; anyone else from `EXIT_OPEN_AFTER` (1 day) after the exit began,
  so nobody can pick a bad moment for the leaver (a lending market with nothing free to withdraw) and a manager
  waits at most a day before it can pay a slice out itself to act again. An exit under `SMALL_EXIT_WAD` (0.1%) of
  the Fund can be paid out by anyone at once, so a small exit never holds a manager up;
- a slice is paid in full or stays pending: until `STALE_AFTER` (7 days) after the exit began, someone other than the
  leaver may finalise a slice only when it paid at least its share of every position, less the slack and a
  ten-thousandth of the slice (`TellerMath.NotPaid`). After it, anyone may finalise it as far as the split pays (an
  LP adapter that skips a broken position pays the rest; the leaver keeps what was paid), so a slice that can only
  be split in part never freezes the adapter. The
  Morpho adapter pays a leaver's supply as far as the market's free liquidity allows and keeps the rest as the
  leaver's own supply shares (`leaverShares`, out of the Fund's positions), which anyone pays out with `payLeaver` as
  borrowers repay. So a flash borrow around a payout (which could otherwise hand the leaver's
  unpaid supply to the Fund) only delays it, in `claimInKind` and in `redeemInKind` alike. The Morpho adapter also
  counts only supply it put in itself (`ownShares`): supply anyone adds on its behalf is ignored, so it can neither
  hold deposits back nor mint snapshots;
- a slice the leaver gives up (`releaseInKind`, its owner) goes back to the Fund with its escrow (the escrow pays
  the slice's share of the adapter's debt, which goes back with it, so a leaver can never leave its debt to the
  holders, even from an underwater position); one that still cannot be split in full `STALE_AFTER` (7 days) after
  the exit began can be given back by anyone, so a broken adapter never stays frozen. That probe asks for a full
  split (`FULL`), gets `PROBE_GAS` (10M) or the call fails (`ShortGas`), and a probe that ran out of gas (a revert
  without data that used at least half of `PROBE_GAS`) counts as unknown and refuses the release, so nobody can make
  a working slice look broken by the gas they send. A revert without data that left more gas unused (a bare
  `require`, a pause without a reason) is a real failure and the release goes on (refusing it would
  freeze the adapter for good);
- escrow pulled from a leaver or a caller is measured, the shortfall a caller brings at payout too: a token that
  arrives short (a fee on transfer) reverts (`ShortArrival`) instead of drawing on what the teller holds for other
  Funds.

## Fees

`FundFees` keeps every Fund's rates, high-water mark and the manager's earned stake; `FeeConfig` keeps the split.
Unchanged by this redesign except where they accrue:

- **Rates**: management up to 2% a year, performance up to 20% of the rise in NAV per share (bid) above the
  high-water mark. A higher rate waits 30 days; a lower one applies at once; while nobody but the owner has ever
  held a share, any change applies at once.
- **Accrual** at every settlement, as new shares, before pricing (management, then performance on NAV per share
  after management, above the mark; first loss burns the manager's locked shares first). Exits in kind no longer
  accrue management: a leaver skips at most one batch interval of it (a day at 2% a year is 0.005%), and the exit
  stays cheaper. Fees wait while a holding valued at zero is above dust.
- **Split** of every fee: manager / $AIX holders recipient / treasury, 70 / 15 / 15 at deployment.
- **Earned stake**: half of the manager's performance shares stay locked in `FundFees` for 7 days as first loss. An
  accrual burns before it releases expired locks, and `release` (anyone, between accruals) refuses while NAV per
  share at bid is below the mark or cannot be read: a lock that has served its time still absorbs a loss already
  there.

## For the manager: new cash

`cash(vault)` is a cheap view: the Fund's USDG now, what is queued in (USDG) and out (shares) in its unsettled
batches, and its fair NAV and cash right after the last settlement (invested is roughly NAV less cash). After a
settlement with net entrants the manager sees new cash and invests it through its own actions, inside its dial;
after net leavers it may want to raise cash for the next batch.

## Dust

`writeOff(vault, token)`, anyone: stops counting a holding worth less than `dustUsd` ($1), or one that cannot be
priced and is no more than `writeOffMaxWad` (0.0001) whole tokens. USDG is never written off, nor a token any
adapter reports holding or owing. (`sweepDust` and the teller's swap routers are gone with the routes.)

## Where prices are used

The match (fair NAV per share), net entrants (ask), net leavers (bid), fees (bid), the inflow cap (fair), a
pocket's unwind measurement (fair) and dust (fair). Every one is read inside the transaction from the router's
manipulation-resistant sources: feeds, time-weighted pool prices, recorded prices. Never a pool's spot price.

## While the controller acts

The vault refuses to mint, burn or pay while the controller is inside one of its calls, and the controller refuses
`act`, `unwindAdapter` and `untrack` while the teller is inside one of its calls (`busy()`), so nothing can land
between an action's two NAV readings or between a teller's plan and its measurement.

## For keepers, pages and the MCP

Views: `currentBatch(vault)`, `liveRequests(vault, owner)` (its own requests) and `liveRequests(vault, payer,
receiver)`, `batch(vault, id)` (with `rounds`, `deposits` still
waiting and `cutoff`), `round(vault, batch, round)`, `batchRequests`, `request(id)` (with `round` and `madeAt`),
`due(id)`, `fund(vault)`, `closure(vault)` (the current closure's NAV and inflow so far), `depositHold(vault)`
(`Open`, `MarketClosed`, or `NoMarket` with the token to pocket), `cash(vault)`, `inKindNeeds(vault, shares)` and
`inKindNeedsInParts`, `exit(id)`, `exitUnits(id, adapter)`, `exitEscrow(id, adapter)`; `Pockets`: `pocketIds`,
`pocketInfo`, `due`, `sharesAt`, `claimed`; the controller: `unitsOf(adapter)`, `pendingExits()`.

Events: `Opened`, `DepositRequested` and `RedeemRequested` (their `owner` is the receiver), `Referred`, `Cancelled`, `Moved`, `Skipped`, `Matched`, `Minted`,
`Paid`, `DepositsWait`, `Settled`, `Claimed`, `RedeemedInKind`, `SlicePaid`, `SliceFunded`, `Left`, `ExitStarted`,
`ExitClaimed`, `Pocketed`, `WrittenOff`, `ScheduleSet`, `WindDown` (its second field is when the Fund closed),
`FeesAccrued`; `Pockets`:
`PocketOpened`, `Credited`, `Assigned`, `Claimed`; controller: `TellerCalled`, `ExitUnits`; vault: `Snapshot`.

A keeper, per Fund with a closed batch: read `depositHold(vault)`; if it says `NoMarket`, call `pocket(vault, token,
adapters, 0)` naming every adapter that reports the token (or an unvalued claim in it), in more transactions with
`into` if one is too large; then simulate `settle(vault, batch, [])`, list in `skip` any request whose limit the
result fails, and send it. A batch that is not settled but has `rounds` and a passed `cutoff` needs its next
round. Nothing else: no routes, no fractions, no premium.

## Gas

Robinhood Chain takes at most 32M gas per transaction (ArbGasInfo, checked 2026-10-02). What a transaction's gas
limit must cover is its gas **before refunds** (a slot cleared in the call is refunded only at its end), which
`test/fork/SettlementGas.fork.t.sol` measures on a fork of Robinhood Chain with the production price
configuration, deployed and applied by the real scripts, real tokens and real venues, every call its own
transaction (`--isolate`):

```
ROBINHOOD_RPC=https://rpc.ordofi.network forge test --match-contract SettlementGasFork --isolate --gas-limit 900000000000 -vv
```

Targets: every settlement path at or under **12M**, the exit in kind (the guaranteed way out) at or under **20M**
per transaction.

### Measured at the caps (2026-10-02, gas before refunds, fork block 77,897,467)

The Fund holds every counted token the vault allows (40: USDG, AINDEX's AIXSTR index share valued by look-through
over its ten basket tokens, and Chainlink- and pool-priced stock, ETF and crypto tokens), every batch is full (100
requests), and every adapter slot (12) is filled to its kind's cap. "Default" is the swap adapter, ERC-4626 in both
USDG vaults, 3 Morpho clones, 3 Uniswap v3, 2 Uniswap v4 and 2 Fables; the other columns fill all twelve slots with
one kind, its heaviest mix. Morpho clones lend in every market, post collateral and borrow USDG in every stock
market (eight reviewed markets and five more approved for the test). The Saturday paths read every stock token's
weekend pools (19 tokens, 27 pools).

| Path | Default | 12 x v3 (10 positions) | 12 x v4 (10) | 12 x Fables (6 ranges) | 12 x Morpho (13 markets) |
|---|---|---|---|---|---|
| settle: 100 deposits, cash in at ask | 9.97M | 10.75M | 10.78M | 9.92M | 10.55M |
| settle: match plus net entry (50 + 50) | 10.10M | 10.88M | 10.91M | 10.05M | 10.68M |
| settle: cash exit, 100 leavers paid from cash | 9.97M | 10.75M | 10.78M | 9.92M | 10.55M |
| settle: cash exit, USDG short (shares back) | 10.78M | 11.56M | 11.59M | 10.73M | 11.37M |
| settle: 99 leavers and one entrant | 10.11M | 10.88M | 10.92M | 10.05M | 10.69M |
| settle: Saturday, worse-of prices, 50 + 50 | **11.09M** | **11.86M** | **11.94M** | **11.07M** | **11.71M** |
| settle: Saturday, inflow cap reached, 100 wait | 10.79M | 11.57M | 11.64M | 10.77M | 11.41M |
| settle: a no-market holding, 100 wait for the pocket | 9.50M | 10.28M | 10.31M | 9.45M | 10.07M |
| requestDeposit | 0.44M | 0.44M | 0.44M | 0.44M | 0.44M |
| exit in kind in parts: `startInKind` (reads every adapter to skip the empty ones) | 14.49M | 18.53M | 15.85M | 15.43M | 12.93M |
| exit in kind in parts: heaviest `claimInKind` | 4.91M | 4.92M | 3.34M | 3.61M | 4.33M |
| exit in kind in one transaction (`redeemInKind`) | 38.3M | 48.5M | 40.7M | 35.8M | 43.8M |
| pocket, vault balance only | 0.43M | 0.43M | 0.43M | 0.43M | 0.43M |
| pocket, heaviest adapter unwound (one per transaction) | 5.28M | 5.40M | | 3.25M | 5.28M |

Measured again on 2026-10-02 with the closed-market pool checks, the pool-price flow cap and the Morpho leaver
shares in place: every settlement is 0.13M to
0.22M heavier than before. Per token, a pool-priced token's recent price (one more point in the same pool read,
about 6k), the weekend pools' window liquidity and history checks (about 9k a token on a Saturday) and the closure
clock (worked out once per transaction in `warm`); per Fund, the pool-price flow cap (two slots). The Morpho adapter's
own supply shares share a slot with the market's parameters, so a market costs no extra read. The Saturday path with
twelve Fables adapters was then the heaviest settlement, 11.98M at 7 ranges, just under the 12M target, so the Fables
range cap went to 6 before launch (2026-10-02): twelve Fables adapters now settle a Saturday in 11.07M, and the
heaviest settlement is twelve Uniswap v4 adapters, 11.94M. The other columns did not change; the default mix holds two
Fables adapters and came down with them.

Twelve ERC-4626 clones (each in both of Robinhood Chain's two USDG vaults): a Saturday settlement 5.44M, `startInKind`
4.51M, a claim 0.48M. A vault costs a reading about 80k and a split about 0.2M, so twelve clones of eight vaults
would read about 7.7M more and stay under 12M.

Every settlement path is at or under 12M (the heaviest, a Saturday with the weekend pools, 11.94M) and every part of
an exit in kind at or under 18.6M (`startInKind` with twelve full Uniswap v3 adapters, 18.53M; it reads every
adapter's positions once more than before 2026-10-02, to give no slice of an empty one). In one transaction an exit in kind at the caps needs 36M to 49M, above Robinhood
Chain's 32M: that is why it runs in parts. A Fund up to about a third of the caps leaves in one transaction.

Measured again on 2026-10-04 for the second teller (the owner's opening shares in its wallet, `createFundWith`): the
settlement and exit paths are unchanged to within a few thousand gas (default mix: 9.97M, 10.09M, 9.96M, 10.77M,
10.10M, 11.09M, 10.79M, 9.50M, `startInKind` 14.49M; twelve Uniswap v4 adapters on a Saturday 11.94M; `startInKind`
with twelve Uniswap v3 adapters 18.53M). Creating a Fund in one transaction with `createFundWith`, seven adapters
(one of every kind) and a manager, used 9.84M on an anvil fork of Robinhood Chain; twelve adapters stay well under
32M (a clone and its configuration cost about 1.2M each).

### What each item costs

| Item | A settlement's reading | An exit in kind (collect, two readings, split) |
|---|---|---|
| a counted token (vault balance, price, NAV row) | about 60k, plus about 40k for its weekend pools on a Saturday | about 30k (one transfer) |
| a Uniswap v3 position | about 50k | about 0.45M |
| a Uniswap v4 position | about 53k | about 0.33M |
| a Fables range | 70k to 100k | about 0.56M |
| a Morpho market (supply, collateral, a borrow) | about 31k (position, market, rate model, review) | about 0.33M |
| an ERC-4626 vault (MetaMorpho) | about 80k | about 0.2M |
| a request in the batch (limits read) | about 7k, none when the round beats every limit | |

The fixed part of a settlement is about 4.5M (pricing every token once 1.6M to 2.7M with the weekend pools, NAV on
every side, the hold check, fees); the fixed part of `startInKind` is about 3M plus each adapter's fee collection and one reading of its positions.

### Why the caps are where they are

The heaviest settlement path is the Saturday one (it reads every stock token's weekend pools as well as every
adapter). With twelve adapters of one kind at the old caps it measured 11.64M (v3, 10 positions), 11.71M (v4, 10),
12.65M (Fables, 8 ranges) and 12.87M (Morpho, 16 markets). So Morpho went to 13 markets and Fables to 7 ranges, and
after the final changes of 2026-10-02 (11.98M with twelve Fables adapters) Fables went to 6 ranges for headroom;
everything else is back at the old caps (40 tokens, 12 adapters, 10 v3 and v4 positions, 8 ERC-4626 vaults). The
exit in kind is no longer the binding limit since it runs in parts; each part is bounded by one adapter.

### How the gas came down from the purchase model

The purchase model needed, at much smaller caps (28 tokens, 6 adapters), 28.2M before refunds for its worst
settlement: fee collection on every adapter, two readings of every adapter, one swap route per token and a grow or
unwind of every position. A settlement now reads every adapter once and moves only USDG. On top of that, 2026-10-02:

- one router call per NAV row on every side (`PriceRouter.values`), which also reports whether the token's market
  is closed and whether it has a look-through, so the hold check reads the priced rows instead of asking the router
  again (about 0.5M at the caps);
- batch totals kept as the requests come instead of read at settlement, and each side's tightest limit kept so a
  round that beats it reads no request (about 0.9M for a full batch);
- deposits that must wait stay in their batch for a later round instead of moving (moving cost about 30k each).


## Rounding across rows

The in-kind measurement allows two raw units (`TellerMath.TOLERANCE`) per row an adapter reported for a token
before the split, at least one row and at most `MAX_SLACK_ROWS` (13, the largest per-adapter cap). Each adapter
keeps every row's rounding to itself (docs/ADAPTERS.md, rule 10): each row's slice rounds against the leaver by a
raw unit's worth, so what stays reads at least `(1 - f)` of that row. The per-row slack covers a liquidity range
holding fewer than about a million raw units of one token, which may read a unit short. Holders lose at most 26 raw
units of a token per adapter per exit. `test/unit/RoundingAcrossRows.t.sol` keeps the cases the fork once caught
(USDG lent or borrowed in many Morpho markets, many v4 positions, several ERC-4626 vaults, tiny v4 ranges).
