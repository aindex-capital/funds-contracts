// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice How well a token can be priced. A measurement, not a permission: a Fund's owner decides how
///         much of each class the Fund may hold (its dial). Ordered from worst to best.
enum PriceClass {
    None, // no market: worth zero in NAV
    Thin, // shallow pool: recorded price with a size haircut
    Pool, // deep, long-running pool: time-weighted price
    Feed // an oracle feed (Chainlink)
}

/// @notice Which side of a price to use. Deposits price at the ask, redemptions and loss checks at the bid,
///         exposure caps at the fair price, so nobody can deposit cheap or leave rich against a moved price.
enum Side {
    Fair,
    Bid,
    Ask
}

/// @notice Prices tokens for Funds, in USD with 18 decimals per whole token.
interface IPriceRouter {
    struct Quote {
        uint256 fair; // USD per whole token, 1e18
        uint256 bid; // fair less the token's haircut
        uint256 ask; // fair plus the token's haircut
        PriceClass class_;
        bool available; // false when every source is stale, paused or missing
    }

    function quote(address token) external view returns (Quote memory);

    /// @notice USD value (1e18) of `amount` raw units of `token` on `side`. A `None` token is worth zero.
    ///         Returns ok = false when the token's price is unavailable.
    function value(address token, uint256 amount, Side side) external view returns (uint256 usd, PriceClass class_, bool ok);

    function classOf(address token) external view returns (PriceClass);

    /// @notice True while `token`'s market is closed (a weekend or a calendar holiday, for US-session tokens):
    ///         its price is the last one before the closure, not one the market is making.
    function marketClosed(address token) external view returns (bool);
}
