// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Amount} from "./IAdapter.sol";
import {IPriceRouter} from "./IPriceRouter.sol";

/**
 * @notice The Fund's risk dial: chosen by its owner, shown to depositors. More risk waits `RISK_NOTICE`;
 *         less risk applies at once. Caps are in basis points of NAV (10_000 = 100%). Ready-made dials for
 *         pages and scripts are in `DialPresets`; any dial within bounds is accepted.
 */
struct Dial {
    uint16 maxNoMarketBps; // tokens that cannot be priced (worth zero in NAV)
    uint16 maxThinBps; // shallow-pool tokens
    uint16 maxPoolBps; // pool-priced tokens
    uint16 maxPerTokenBps; // any single token or position, feed-priced included
    uint16 dailyLossBps; // what the manager's own actions may cost per day, at bid prices
    bool allowBorrow;
    uint32 minHealthBps; // assets / debts, when borrowing (15_000 = 1.5)
    // AINDEX reviews (a verified adapter, an approved Morpho oracle) are badges. Off: the Fund acts only
    // through what AINDEX has reviewed. On: anything goes, and the Fund page says so.
    bool allowUnreviewed;
}

interface IFundController {
    event Acted(address indexed adapter, bytes action, uint256 navBefore, uint256 navAfter);
    event DialProposed(Dial dial, uint64 effectiveAt);
    event DialApplied(Dial dial);
    event AdapterProposed(address indexed implementation, address instance, uint64 effectiveAt);
    event AdapterEnabled(address indexed implementation, address instance);
    event AdapterDisabled(address instance);
    event ManagerSet(address indexed manager, uint64 expiresAt);
    event Paused(bool paused);

    function vault() external view returns (address);
    function owner() external view returns (address);
    function manager() external view returns (address);

    function dial() external view returns (Dial memory);
    function adapters() external view returns (address[] memory);

    /// @notice Manager: run `action` on one of the Fund's adapters, inside the dial.
    function act(address adapter, bytes calldata action) external returns (bytes memory result);

    /// @notice Net asset value in USD (1e18) on the chosen side, and whether every holding could be priced.
    function nav(uint8 side) external view returns (uint256 usd, bool complete);

    /// @notice `nav`, plus what made it incomplete: tokens with a nonzero holding or debt that could not be
    ///         priced, and adapters whose `positions` call failed. Both lists are empty when `complete`.
    function navReport(uint8 side)
        external
        view
        returns (uint256 usd, bool complete, address[] memory unpriced, address[] memory failedAdapters);

    /// @notice The Fund's cash and unit of account.
    function baseAsset() external view returns (address);

    function guardian() external view returns (address);

    /// @notice True while either the guardian or the owner has paused the manager.
    function paused() external view returns (bool);

    /// @notice True while the controller is inside one of its own calls (an action, an unwind, a setting).
    ///         The vault refuses to mint, burn or pay meanwhile, so no deposit or exit can land between the
    ///         two NAV readings of an action and hide what it cost.
    function isActing() external view returns (bool);

    function router() external view returns (IPriceRouter);

    /// @notice Enabled for new actions.
    function isAdapter(address adapter) external view returns (bool);

    /// @notice In the Fund's book: enabled or disabled, not yet removed.
    function isListed(address adapter) external view returns (bool);

    /// @notice Teller only, once, before the Fund's first share: the creating owner's initial adapters (as
    ///         `addAdapter`, enabled at once) and manager (as `setManager`; none when zero).
    function setup(address[] calldata implementations, bytes[] calldata configs, address manager_, uint64 expiresAt)
        external
        returns (address[] memory instances);

    /// @notice Teller only: collect what an enabled adapter has earned (liquidity fees) into the vault, `grow(0)`,
    ///         before an exit in kind reads the Fund.
    function collectFor(address adapter) external;

    /// @notice Teller only: set aside `fractionWad` of the Fund's part of `adapter` for a leaver (an exit in kind);
    ///         returns the slice in the adapter's units. The book stops counting it at once.
    function reserveFor(address adapter, uint256 fractionWad) external returns (uint256 units);

    /// @notice Teller only: pay out a slice set aside: split the adapter by `units` over its total to `to`.
    function splitUnitsFor(address adapter, uint256 units, address to)
        external
        returns (Amount[] memory sent, uint256 fractionWad);

    /// @notice Teller only: a slice set aside that will not be paid out goes back to the Fund.
    function releaseUnits(address adapter, uint256 units) external;

    /// @notice The Fund's part of `adapter`'s positions, `fund` of `total` (1 of 1 when no leaver's slice waits).
    function unitsOf(address adapter) external view returns (uint256 fund, uint256 total);

    /// @notice How many adapters have a leaver's slice waiting to be paid out.
    function pendingExits() external view returns (uint256);

    /// @notice Teller only: unwind a slice of an adapter's positions into the vault (a holders' pocket takes a
    ///         no-market token out of an adapter that holds it).
    function unwindFor(address adapter, uint256 fractionWad) external returns (Amount[] memory received);

    /// @notice Teller only: an adapter that implements `IPocketable` moves its unvalued positions in `token` into
    ///         pocket `id` of `pockets`.
    function pocketFor(address adapter, address token, address pockets, uint256 id) external returns (uint256 paid);

    /// @notice Teller only: mark `adapter` as having owed (`everOwed`) if it reports a debt now. Called after the
    ///         teller split or unwound it and saw a debt in its measurement.
    function noteDebt(address adapter) external;
}
