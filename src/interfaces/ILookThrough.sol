// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Amount} from "./IAdapter.sol";

/**
 * @notice What a wrapper token is made of. A Fund values a wrapper (an AINDEX index share, say) at its own
 *         price, but judges its class caps on what the wrapper holds, so thin tokens wrapped in an index still
 *         count as thin. The PriceRouter names one per token (`lookThrough`); most tokens have none.
 */
interface ILookThrough {
    /// @notice The tokens `amount` raw units of `token` stand for, as token amounts. May revert; a Fund then
    ///         counts the whole holding as thin.
    function underlying(address token, uint256 amount) external view returns (Amount[] memory);
}

/// @notice Implemented by the PriceRouter: the look-through for a token, or none (address 0).
interface ILookThroughRegistry {
    function lookThrough(address token) external view returns (ILookThrough);
}
