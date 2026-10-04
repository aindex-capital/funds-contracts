// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceRouter} from "./IPriceRouter.sol";

/// @notice A token amount: what an adapter needs, holds or owes.
struct Amount {
    address token;
    uint256 amount;
}

/**
 * @title  IAdapter
 * @notice Everything a Fund can do goes through an adapter: one small contract per protocol or instrument
 *         (a swap venue, a lending market, a liquidity venue, an index, a yield vault). The vault knows
 *         nothing about any protocol, so a new instrument is a new adapter and every Fund can use it.
 *
 * @dev    ## Instances
 *         An adapter is registered once as an implementation. A Fund that enables it gets its own clone,
 *         bound to that Fund for life (`initialize`). Positions the adapter opens (lending shares, liquidity
 *         positions, borrow debt) belong to that clone, so one Fund's adapter can never touch another's.
 *
 *         ## Rules every adapter keeps (checked by the shared test suite in test/adapters)
 *         1. Only the Fund's controller may call `execute`, `unwind` and `split`.
 *         2. Inputs: the adapter declares them with `inputs`; the vault approves exactly those amounts for the
 *            one call, and the adapter pulls them with `transferFrom(vault, ...)`.
 *         3. Outputs: every token that comes out of an action is sent to the Fund's vault in the same call,
 *            and declared in advance with `outputs` so the vault counts it. Nothing is sent anywhere else.
 *         4. Between calls the adapter holds no loose tokens; whatever it holds is a position and is reported
 *            by `positions` at what unwinding it would return.
 *         5. `unwind` and `split` always work for transferable positions, without the manager and without
 *            the adapter's owner.
 *         6. No delegatecall, no upgradeability, no owner that can move a Fund's positions.
 *         7. Each position's rounding stays with that position: report one row per position, and `split` and
 *            `unwind` leave each at least `(1 - f)` of what `positions` reported for it (the slice rounds against
 *            the leaver). The teller allows two raw units per row, at most `TellerMath.MAX_SLACK_ROWS` rows.
 *         8. A claim `positions` counts as zero (an unvalued position) is reported as a row of amount zero and
 *            through `IUnvalued`; an adapter that cannot unwind it whole may implement `IPocketable`.
 */
interface IAdapter {
    /// @notice Binds this clone to one Fund. Called once by the registry when the Fund enables the adapter.
    /// @param  vault      the Fund's vault, which holds its tokens and receives every output
    /// @param  controller the only caller allowed to act on behalf of the Fund
    /// @param  config     adapter-specific settings fixed for this Fund (may be empty)
    function initialize(address vault, address controller, bytes calldata config) external;

    function vault() external view returns (address);

    /// @notice Name and version, for pages and agents ("Morpho Blue v1").
    function name() external view returns (string memory);

    /**
     * @notice A machine-readable description of the adapter's actions, for agents and the MCP: JSON with
     *         each action's name, its parameters (name, Solidity type, meaning) and the ABI encoding of
     *         `execute`'s argument. The MCP reads this to offer the action to every agent automatically.
     */
    function describe() external view returns (string memory);

    /// @notice What `execute(action)` will pull from the vault. The controller approves exactly these.
    function inputs(bytes calldata action) external view returns (Amount[] memory);

    /// @notice Tokens `execute(action)` may send back to the vault, so the vault counts them.
    function outputs(bytes calldata action) external view returns (address[] memory);

    /// @notice Runs one action for the Fund. Only the controller.
    function execute(bytes calldata action) external returns (bytes memory result);

    /**
     * @notice What this Fund holds through the adapter, as token amounts, and what it owes.
     * @dev    Amounts are what unwinding would return. Positions whose amounts depend on price (liquidity)
     *         are computed at the router's fair prices, never at a pool's current price, so moving a pool
     *         cannot move a Fund's value.
     */
    function positions(IPriceRouter router) external view returns (Amount[] memory assets, Amount[] memory debts);

    /**
     * @notice Turns `fractionWad` (1e18 = all) of every position back into tokens, sent to the vault.
     *         Used for wind-downs and cash redemptions. Debt is repaid pro rata from the vault's tokens
     *         first (the adapter declares what it needs through `unwindInputs`).
     */
    function unwind(uint256 fractionWad) external returns (Amount[] memory received);

    function unwindInputs(uint256 fractionWad) external view returns (Amount[] memory);

    /**
     * @notice `grow(0)` collects what the adapter has earned into the vault (liquidity fees; Fables also sweeps its
     *         pot's USDG) and changes no position. The teller calls it (`FundController.collectFor`) on every
     *         enabled adapter before an exit in kind reads the Fund, so a leaver takes its slice of the fees and
     *         nothing lands in the vault in the middle of a measurement.
     *
     *         `grow(f)` for `f` above zero grows every position by `fractionWad` (1e18 = double it) from tokens the
     *         vault holds. Deposits enter the Fund as cash since 2026-10-02, so the teller no longer calls it; the
     *         AINDEX adapters keep it, and a new adapter may revert for `f` above zero.
     */
    function grow(uint256 fractionWad) external returns (Amount[] memory used);

    /// @notice What `grow(fractionWad)` will pull from the vault, so the teller can buy and approve it.
    function growInputs(uint256 fractionWad) external view returns (Amount[] memory);

    /**
     * @notice In-kind exit: hands `to` its `fractionWad` slice of every position, as the position itself
     *         where it can be split and as underlying tokens where it cannot. Never needs a price.
     */
    function split(uint256 fractionWad, address to) external returns (Amount[] memory sent);
}

/**
 * @notice Optional for adapters: claims the Fund holds through the adapter that `positions` counts as zero
 *         (supply in a Morpho market AINDEX has not approved, say), yet a leaver still takes a slice of. Each also
 *         appears in `positions` as a row of amount zero (the teller asks only adapters that report one). While
 *         any is above dust the teller mints no new shares (they would share such a claim without paying for it)
 *         until it is set aside for the holders of the moment (`Teller.pocket`, `IPocketable`). An adapter without
 *         this function holds none.
 */
interface IUnvalued {
    /// @notice The zero-valued claims, as token amounts (what they would be worth if they were counted).
    function unvalued() external view returns (Amount[] memory);
}
