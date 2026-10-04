// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice One way of pricing tokens (Chainlink, a pool's time-weighted price, a price recorder). Sources
///         are adapters too: a new oracle on the chain is a new source, registered with the PriceRouter.
interface IPriceSource {
    /// @notice USD per whole token, 1e18. `ok` is false when this source cannot price the token right now
    ///         (stale, paused, sequencer down, not configured). Never reverts for a known token.
    function price(address token) external view returns (uint256 usd, uint64 updatedAt, bool ok);

    function name() external view returns (string memory);
}

/**
 * @notice A source that prices a token in another token rather than in USD: a pool's price against its other side.
 *         The PriceRouter converts it through its own price of that other token (the quote), on the same side and
 *         in the same call (a settlement reads it from the router's transient cache), so a pool may be paired with
 *         anything the router can price: USDG, WETH, cbBTC, another stock token, an index share. Chains are at most
 *         `PriceRouter.MAX_HOPS` long and may not loop; a chained price's class is the worse of the token's own
 *         class and its quote's.
 */
interface IRatioSource {
    /// @notice Whole `quote` tokens per whole `token`, 1e18. `ok` false when this source cannot price it now. Never
    ///         reverts for a known token.
    function ratio(address token) external view returns (address quote, uint256 ratioWad, uint64 updatedAt, bool ok);
}

/**
 * @notice Optional for a ratio source whose price is an average (a pool's TWAP, a recorded median): a recent price
 *         that still cannot move within a block. The PriceRouter prices the bid from the lower of it and `ratio` and
 *         the ask from the higher, so nobody enters cheap or leaves rich while the average trails the market.
 */
interface IRecentRatio {
    /// @notice Whole quote tokens per whole `token`, 1e18, in the same quote as `ratio`. `ok` false when the source
    ///         cannot give it now (the router then calls the token unavailable). Never reverts for a known token.
    function recentRatio(address token) external view returns (uint256 ratioWad, bool ok);

    /// @notice `ratio` and `recentRatio` in one call (what the router reads): one pool read for both. `ok` false when
    ///         either is unavailable.
    function ratioAndRecent(address token)
        external
        view
        returns (address quote, uint256 ratioWad, uint256 recentWad, uint64 updatedAt, bool ok);
}
