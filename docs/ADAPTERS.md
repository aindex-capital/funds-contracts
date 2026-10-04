# Writing an adapter

An adapter lets every AINDEX Fund use one protocol or instrument. Anyone can write one: a protocol team,
an outside developer, AINDEX. Register it in the `AdapterRegistry`; AINDEX marks it verified after review.

## 1. Extend BaseAdapter

```solidity
contract MyProtocolAdapter is BaseAdapter {
    function name() external pure returns (string memory) { return "MyProtocol v1"; }
    function describe() external pure returns (string memory) { return '{"actions":[...]}'; }
    function inputs(bytes calldata action) external view returns (Amount[] memory) { ... }
    function outputs(bytes calldata action) external view returns (address[] memory) { ... }
    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) { ... }
    function positions(IPriceRouter router) external view returns (Amount[] memory assets, Amount[] memory debts) { ... }
    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory) { ... }
    function unwindInputs(uint256 fractionWad) external view returns (Amount[] memory) { ... }
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory) { ... }
}
```

`BaseAdapter` gives you `vault`, `controller`, `onlyController`, `_pull` (from the vault, exactly the
approved input), `_pushAll` (send everything you hold of a token to the vault), `_approve` and small helpers.

## 2. Encode actions

`execute` takes one `bytes` argument: `abi.encode(uint8 actionId, <params>)`. List every action in
`describe()` as JSON so agents can call it without reading Solidity:

```json
{
  "adapter": "MyProtocol v1",
  "actions": [
    {"id": 0, "name": "supply", "params": [
      {"name": "market", "type": "bytes32", "about": "market id"},
      {"name": "amount", "type": "uint256", "about": "raw units of the loan token"}],
     "encoding": "abi.encode(uint8 0, bytes32 market, uint256 amount)"}
  ]
}
```

## 3. Keep the rules

1. Only the controller calls `execute`, `unwind`, `split`.
2. Pull only what `inputs` declared; the vault approved exactly that.
3. Send every output to the vault in the same call; declare it in `outputs`.
4. Hold no loose tokens between calls. Whatever you hold is a position you report in `positions`.
5. `positions` reports what unwinding would return; price-dependent amounts (liquidity) use the router's
   fair prices, never a pool's current price.
6. `unwind` and `split` work without the manager and without your own team. One position that cannot be
   exited must not block the others: run each position on its own (a self-call under try/catch, as the
   Uniswap v3, v4 and Fables adapters do) and leave a failing one whole. Morpho keeps its strict rule for a
   borrowing market's `split`: a leaver's collateral never leaves without its slice of the debt.
   A row you report in `positions` keeps your adapter in every exit even at an amount of zero; report an
   empty list only when you hold nothing at all.
   If you hold a claim that `positions` counts as zero but that a leaver still takes a slice of (Morpho supply
   in a market AINDEX has not approved), report it in `positions` as a row of amount zero and also implement
   `IUnvalued.unvalued()` and report it there, in token amounts. The teller asks `unvalued` only of adapters
   that report a zero row (it saves reading every adapter twice), and mints no new shares while any such claim
   is above dust, since new shares would share it without paying for it. Anyone can then set it aside for the
   holders of that moment (`Teller.pocket`): an adapter that cannot simply be unwound whole (supply lent out
   today) should implement `IPocketable` (`src/interfaces/IPockets.sol`): `pocket(token, pockets, id)` stops
   counting those positions as the Fund's (they leave `positions`, `unvalued`, `split` and `unwind`, and the
   manager may not withdraw them), pays what it can into the pocket now (`Pockets.topUp`) and the rest later
   through `drain()`, which anyone may call. The Morpho adapter is the example. Without the hook, the teller
   unwinds the whole adapter into the vault for a pocket, measured on that adapter.
   A `split` must pay the leaver its whole slice of every position, or keep what it cannot pay now as the
   leaver's, outside the Fund's `positions` (the Morpho adapter keeps a leaver's unpaid supply as `leaverShares`
   and pays it out with `payLeaver`, anyone, as borrowers repay). Someone other than the leaver can complete a
   slice only when it paid in full (`TellerMath.NotPaid`) until the exit is 7 days old, so a moment of illiquidity
   (a flash borrow) never hands a leaver's slice to the other holders; after that, anyone completes it as far as it
   pays, so revert with a reason when a split cannot work at all, rather than paying part of it silently.
   Count only what the Fund put in: a position anyone else can add on your clone's behalf (Morpho's `onBehalf`
   supply) must not change what you report, or anyone could hold the Fund's deposits back or take its snapshots.
7. No delegatecall, no upgradeability, no admin that can move a Fund's positions.
8. Per-Fund settings (allowed routers, markets, pools) come in through `_configure` at enable time and are
   fixed for that Fund's clone.
9. `grow(0)` collects what the adapter has earned (liquidity fees; Fables also sweeps its pot's USDG) into the
   vault and changes no position: the teller calls it (`FundController.collectFor`) on every enabled adapter
   before an exit in kind reads the Fund, so a leaver takes its slice of the fees and the measurement sees
   positions without them. Since 2026-10-02 deposits enter the Fund as cash (docs/DEPOSITS-AND-EXITS.md), so
   the teller never calls `grow(f)` with `f` above zero. The AINDEX adapters keep their `grow(f)` (it still
   grows every position by at least `f` and every debt to within two raw units above it), but a new adapter may
   revert for `f` above zero.
10. Report one row per position and keep each row's rounding to the row. The teller's slack is two raw units per
   row an adapter reported for a token before the move (at least one row, at most `MAX_SLACK_ROWS`, 13: the
   largest per-adapter cap), so a liquidity adapter reports one row per position and token rather than summing
   them, and every row rounds on its own (owed down, owing up). Still: `split(f)` and `unwind(f)` leave every
   row at least `(1 - f)` of what `positions` reported for it, which means the leaver's slice of each row rounds
   against the leaver by a raw unit's worth (Morpho: the supply fraction less the shares one unit is worth, the
   debt fraction plus the shares one unit is worth; ERC-4626: the shares fraction less the shares one unit is
   worth; liquidity: `GrowMath.taken`, the fraction less the liquidity one unit of each token is worth at the fair
   price). The per-row slack covers the one side a liquidity range cannot: a token it holds fewer than about a
   million raw units of (under about a dollar of USDG, about 0.01 of an 8-decimal token), where one unit is worth
   more than a millionth of the whole range, so it may read a unit short. Before 2026-10-02 the slack was two
   units per token per adapter, and three or more such ranges in one adapter made exits revert
   (`test/unit/RoundingAcrossRows.t.sol`, `V4TinyRangesTest`). An adapter that reports more rows than
   `MAX_SLACK_ROWS` gets no more slack, so holders lose at most 26 raw units of a token per adapter per exit.
11. A leaver may leave in parts (`Teller.startInKind`, then `claimInKind` per adapter): from the moment its slice
   is set aside until it is paid out, the controller lets nothing but `split` touch your adapter (no action, no
   unwind, no pocket, no removal), and the Fund's book counts only the Fund's part of your positions. Your
   positions may still change by themselves meanwhile (interest, fees, prices) as long as every part of them
   shares the change pro rata: keep no per-holder state inside the adapter.
12. Keep `positions` and `split` cheap: a settlement reads every adapter once and an exit in kind reads and splits
   each. Measured per position on Robinhood Chain (docs/DEPOSITS-AND-EXITS.md, "Gas"): a reading costs about 30k
   (a Morpho market) to 90k (a Fables range), a split 150k to 230k. Each AINDEX adapter's position cap
   (`MAX_POSITIONS`, `MAX_MARKETS`, `MAX_RANGES`, `MAX_VAULTS`) is sized so the heaviest settlement stays at or
   under 12M gas with twelve such adapters.

## 4. Pass the shared test suite

Inherit the adapter suite in `test/adapters/AdapterSuite.sol` and implement its hooks (how to fund, which
actions to try). It checks the rules above with fuzzed actions: no value leaves the Fund, `positions`
matches what `unwind` returns, `split` slices sum to the whole, no loose tokens after any call.

## 5. Register and ask for review

`registry.register(implementation, "ipfs://… docs, source, audit")`, then open a review request with
AINDEX. Verification is a badge, not a gate: an unverified adapter works in any Fund whose dial has
`allowUnreviewed` on (the default `DialPresets.open()` does), and Fund pages label it. Funds that keep to
reviewed things (`allowUnreviewed` off) can enable it but cannot act through it until AINDEX verifies it.

Settings that limit risk inside your adapter (allowlists, price guards) should be the Fund owner's choice at
enable time, with "off" available, unless they protect the Fund's valuation itself. The Fables adapter's
pool versus oracle guard is the example: 0 turns it off, because oracle valuation already shows the cost.
