// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";

/**
 * @title  OraclePositionMath
 * @notice Values a concentrated liquidity position (Uniswap v3, v4 and their forks) at the price router's
 *         fair prices instead of the pool's current price.
 *
 * @dev    ## Why not the pool's price
 *         A position's token amounts depend on the price it is read at. Anyone can move a pool's price
 *         for the length of one transaction, so a Fund that valued its positions at the pool's price
 *         could be made to look richer or poorer at will, and its exposure caps judged against a price
 *         someone chose. The router's fair prices cannot be moved that way, so we ask: what would this
 *         position hold if the pool sat at the fair price?
 *
 *         That answer is also the conservative one. Valued at a fixed outside price, a position is
 *         worth least when the pool sits at that same price: anyone who pushes the pool elsewhere trades
 *         against the position at worse than fair, and the position keeps the difference. So the amounts
 *         reported here are a floor on what removing the liquidity returns, measured at fair prices,
 *         wherever the pool happens to be.
 *
 *         ## Prices we cannot use
 *         - A token with no market (worth zero) is treated as if the pool had run all the way to it:
 *           every unit of liquidity reported in that token, which is what arbitrage against a worthless
 *           token would leave. The Fund's caps then see the holding as no-market.
 *         - A token whose price is unavailable is reported at the most it could be, and the other token
 *           at zero. The router marks the unavailable token as such, so the Fund's book is incomplete and
 *           actions wait, instead of the position being quietly counted at a made-up price.
 *
 *         Every amount rounds down.
 */
library OraclePositionMath {
    /// @notice Tokens with more decimals than this are not supported: the price conversion below keeps
    ///         `10 ** decimals` and a 1e18 price comfortably inside 256 bits.
    uint8 internal constant MAX_DECIMALS = 36;

    error UnsupportedDecimals(address token);

    /// @notice What a position of `liquidity` between two ticks holds at the router's fair prices.
    /// @param  token0 the pool's lower-sorted token, as the router knows it (wrapped ETH for native ETH)
    /// @param  token1 the pool's higher-sorted token, likewise
    function fairAmounts(
        IPriceRouter router,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        IPriceRouter.Quote memory q0 = router.quote(token0);
        IPriceRouter.Quote memory q1 = router.quote(token1);
        if (!q0.available || !q1.available) {
            // Make the missing price visible: the unavailable token at its most, the other at zero.
            if (!q0.available) amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
            else amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
            return (amount0, amount1);
        }
        // A worthless token takes the whole position (see the header). When both are worthless, either will do.
        if (q0.fair == 0) return (SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false), 0);
        if (q1.fair == 0) return (0, SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false));
        uint160 sqrtP = sqrtPriceFromPrices(q0.fair, decimalsOf(token0), q1.fair, decimalsOf(token1));
        return amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
    }

    /**
     * @notice The pool price, as Uniswap's sqrt(token1 per token0) in Q64.96, at which two tokens trade at
     *         the given USD prices.
     * @dev    One raw unit of token0 is worth `price0 / 10**dec0` dollars and one raw unit of token1
     *         `price1 / 10**dec1`, so the pool price in raw units is `price0 * 10**dec1 / (price1 * 10**dec0)`.
     *         We scale that ratio by 2**192 before taking the square root so the result is already in Q96.
     *         When the ratio is too large for that, we scale by less and shift the root back up, losing only
     *         precision we could not have represented anyway. Results are clamped to the range a pool can
     *         reach, which is also where every position is entirely in one token.
     */
    function sqrtPriceFromPrices(uint256 price0, uint8 dec0, uint256 price1, uint8 dec1)
        internal
        pure
        returns (uint160)
    {
        uint256 num = price0 * 10 ** dec1;
        uint256 den = price1 * 10 ** dec0;
        if (num == 0) return TickMath.MIN_SQRT_PRICE;
        if (den == 0) return TickMath.MAX_SQRT_PRICE - 1;
        uint256 q = num / den;
        uint256 root;
        if (q < (1 << 64)) {
            root = Math.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        } else if (q < (1 << 128)) {
            root = Math.sqrt(FullMath.mulDiv(num, 1 << 128, den)) << 32;
        } else if (q < (1 << 192)) {
            root = Math.sqrt(FullMath.mulDiv(num, 1 << 64, den)) << 64;
        } else {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
        if (root < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (root >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(root);
    }

    /// @notice Token amounts a position of `liquidity` between `sqrtA` and `sqrtB` holds at `sqrtP`,
    ///         rounded down (what removing it would pay out).
    function amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    /// @notice Fees a position has earned since it last settled, from Uniswap's fee growth counters.
    /// @dev    The counters are meant to wrap around, so the subtraction is unchecked, as in the pools.
    function feesEarned(uint256 growthInsideNow, uint256 growthInsideLast, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            return FullMath.mulDiv(growthInsideNow - growthInsideLast, liquidity, 1 << 128);
        }
    }

    /// @notice A token's decimals, read from the token. Reverts above `MAX_DECIMALS`.
    function decimalsOf(address token) internal view returns (uint8 d) {
        d = IERC20Metadata(token).decimals();
        if (d > MAX_DECIMALS) revert UnsupportedDecimals(token);
    }
}
