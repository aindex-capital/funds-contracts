// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice What a market is doing while its US session is closed: the PriceRouter asks it for a token whose session
 *         is closed, converts each answer to USD through its own price of the quote token (on the side it prices,
 *         in the same call), holds each within the token's band around the feed's last price, and prices entrants
 *         and leavers on the worst of them and the last price (`PriceRouter`, "Markets that close").
 */
interface IClosedMarketSource {
    /// @notice One market's price of the token in its quote token: whole quote per whole token, 1e18.
    struct Ratio {
        address quote;
        uint256 ratioWad;
    }

    /// @notice Every configured market that qualifies now (deep enough at its current price, history for the
    ///         whole window), with its time-weighted price. Empty when none does: the router then uses the last
    ///         price with its wider fallback spread. Must be unmovable within a block and never revert.
    function closedRatios(address token) external view returns (Ratio[] memory);
}
