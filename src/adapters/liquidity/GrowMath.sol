// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";

/// @dev The Fund's controller exposes its price router publicly; IFundController does not declare it.
interface IRouterHolder {
    function router() external view returns (IPriceRouter);
}

/**
 * @title  GrowMath
 * @notice How much liquidity a deposit adds to a concentrated liquidity range, and what that costs, shared by
 *         every liquidity adapter's `grow` (Uniswap v3, v4, Fables).
 *
 * @dev    ## What grows
 *         `grow(f)` adds to the Fund's existing mix, so each range gets `fractionWad` more liquidity in the
 *         same ticks (since 2026-10-02 deposits enter as cash and the teller only calls `grow(0)`). Liquidity is the one number that does not depend on any price: the range's token amounts
 *         at any price scale with it. The teller checks afterwards that each position, as `positions` reports it
 *         at the router's fair prices, grew by at least the fraction.
 *
 *         ## Rounding
 *         `positions` rounds every amount down, so liquidity grown by exactly the fraction can read one raw
 *         unit short. We add the fraction rounded up plus a margin of the liquidity three raw units of each
 *         token are worth at the fair price, which covers that rounding. The margin is capped at a millionth of
 *         the range, so a side holding almost nothing (a few raw units at the fair price) never makes the
 *         deposit pay for a large extra slice; such a dust side may then read a unit short, which the teller
 *         tolerates. The price only sizes this margin of a few raw units; it never decides how much the
 *         position grows.
 *
 *         ## Cost
 *         Adding liquidity pays at the pool's current price, rounded up, exactly as the pool charges it
 *         (`SqrtPriceMath` with rounding up, the pool's own functions). The teller buys those amounts.
 *
 *         ## Exits, the mirror
 *         An exit of `f` takes the fraction of a range's liquidity rounded down, less the liquidity one raw unit
 *         of each token is worth at the fair price (`taken`). What stays then reads, rounded down, at least
 *         `(1 - f)` of what the range read before, in each token, so a leaver's slice rounds against the leaver
 *         in every range instead of the units adding up across ranges. The same cap applies: a side holding fewer
 *         than about a million raw units of its token (under about a dollar of USDG) is not covered, since one unit
 *         of it is worth more than a millionth of the whole range, which the leaver would give up; such a side may
 *         read a unit short, which the teller's slack of two units per row (one row per range) covers.
 */
library GrowMath {
    uint256 internal constant WAD = 1e18;
    /// @dev Raw units of each token the margin covers.
    uint256 internal constant MARGIN_UNITS = 3;
    /// @dev The margin never exceeds this share of the range's liquidity (1e6 = a millionth).
    uint256 internal constant MARGIN_CAP = 1e6;

    /**
     * @notice Liquidity to add to a range of `liquidity` so it grows by at least `fractionWad`.
     * @param  fair0 the range's token0 at fair prices (from `OraclePositionMath.fairAmounts`)
     * @param  fair1 likewise for token1
     */
    function added(uint128 liquidity, uint256 fractionWad, uint256 fair0, uint256 fair1)
        internal
        pure
        returns (uint128)
    {
        if (liquidity == 0 || fractionWad == 0) return 0;
        uint256 base = Math.mulDiv(liquidity, fractionWad, WAD, Math.Rounding.Ceil);
        uint256 margin = _margin(liquidity, fair0);
        uint256 m1 = _margin(liquidity, fair1);
        if (m1 > margin) margin = m1;
        uint256 cap = liquidity / MARGIN_CAP + 1;
        if (margin > cap) margin = cap;
        uint256 total = base + margin;
        if (total > type(uint128).max) total = type(uint128).max;
        return uint128(total);
    }

    /**
     * @notice Liquidity an exit of `fractionWad` takes from a range of `liquidity`: all of it at `WAD`, otherwise
     *         the fraction rounded down less a margin of the liquidity one raw unit of each token is worth at the
     *         fair price (none for a side the cap leaves out, see the header).
     * @param  fair0 the range's token0 at fair prices (from `OraclePositionMath.fairAmounts`)
     * @param  fair1 likewise for token1
     */
    function taken(uint128 liquidity, uint256 fractionWad, uint256 fair0, uint256 fair1)
        internal
        pure
        returns (uint128)
    {
        if (fractionWad >= WAD) return liquidity;
        uint256 take = uint256(liquidity) * fractionWad / WAD;
        uint256 cap = liquidity / MARGIN_CAP + 1;
        uint256 margin;
        if (fair0 != 0) {
            uint256 m0 = Math.mulDiv(liquidity, 1, fair0, Math.Rounding.Ceil);
            if (m0 <= cap) margin = m0;
        }
        if (fair1 != 0) {
            uint256 m1 = Math.mulDiv(liquidity, 1, fair1, Math.Rounding.Ceil);
            if (m1 <= cap && m1 > margin) margin = m1;
        }
        return take > margin ? uint128(take - margin) : 0;
    }

    /// @notice Tokens the pool charges, rounded up, to add `liquidity` between two ticks at `sqrtP`.
    function cost(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP < sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
        }
    }

    /// @dev Liquidity worth `MARGIN_UNITS` raw units of a token the range holds `fair` of; none when it holds none.
    function _margin(uint128 liquidity, uint256 fair) private pure returns (uint256) {
        if (fair == 0) return 0;
        return Math.mulDiv(liquidity, MARGIN_UNITS, fair, Math.Rounding.Ceil);
    }
}
