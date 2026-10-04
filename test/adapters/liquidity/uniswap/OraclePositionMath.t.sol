// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {OraclePositionMath} from "../../../../src/adapters/liquidity/OraclePositionMath.sol";

contract OraclePositionMathTest is Test {
    /// @dev The pool price (token1 raw per token0 raw) a sqrt price stands for, scaled by 1e18.
    function _priceWad(uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtP) * uint256(sqrtP), 1e18, 1 << 192);
    }

    function test_WethUsdg() public pure {
        // WETH (18 decimals) at $2,686.2 as token0, USDG (6 decimals) at $1: 2686.2e6 USDG raw per 1e18 WETH raw.
        uint160 s = OraclePositionMath.sqrtPriceFromPrices(2686.2e18, 18, 1e18, 6);
        assertApproxEqRel(_priceWad(s), 2686.2e6, 1e12);
        // Robinhood Chain's USDG/WETH 0.05% pool sat at this sqrt price when WETH traded near $2,686.
        assertApproxEqRel(uint256(s), 4106281126023541015556738, 0.0001e18);
    }

    function test_UsdgWethTheOtherWay() public pure {
        uint160 s = OraclePositionMath.sqrtPriceFromPrices(1e18, 6, 2680e18, 18);
        // 1e6 USDG raw buys 1e18/2680 WETH raw: price = 1e12 / 2680 per raw unit.
        assertApproxEqRel(_priceWad(s), uint256(1e12) * 1e18 / 2680, 1e12);
    }

    function test_ExtremeRatiosStayInRange() public pure {
        uint160 hi = OraclePositionMath.sqrtPriceFromPrices(1e30, 6, 1, 36);
        assertLt(hi, TickMath.MAX_SQRT_PRICE);
        assertGe(hi, TickMath.MIN_SQRT_PRICE);
        uint160 lo = OraclePositionMath.sqrtPriceFromPrices(1, 36, 1e30, 0);
        assertGe(lo, TickMath.MIN_SQRT_PRICE);
        assertEq(OraclePositionMath.sqrtPriceFromPrices(0, 18, 1e18, 18), TickMath.MIN_SQRT_PRICE);
        assertEq(OraclePositionMath.sqrtPriceFromPrices(1e18, 18, 0, 18), TickMath.MAX_SQRT_PRICE - 1);
    }

    /// The converted price matches the ratio across the large-ratio branches too.
    function testFuzz_PriceMatchesRatio(uint256 p0, uint256 p1, uint8 d0, uint8 d1) public pure {
        p0 = bound(p0, 1e12, 1e30);
        p1 = bound(p1, 1e12, 1e30);
        d0 = uint8(bound(d0, 0, 24));
        d1 = uint8(bound(d1, 0, 24));
        uint160 s = OraclePositionMath.sqrtPriceFromPrices(p0, d0, p1, d1);
        if (s <= TickMath.MIN_SQRT_PRICE || s >= TickMath.MAX_SQRT_PRICE - 1) return;
        // Compare in sqrt space: s^2 / 2^192 == p0 * 10^d1 / (p1 * 10^d0).
        uint256 lhs = FullMath.mulDiv(uint256(s), uint256(s), 1 << 96); // price * 2^96
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        if (num / den > (1 << 150) || FullMath.mulDiv(num, 1 << 96, den) < 1e9) return; // outside 2^96 precision
        assertApproxEqRel(lhs, FullMath.mulDiv(num, 1 << 96, den), 1e9);
    }

    /// Amounts for a liquidity never exceed the amounts that bought it (removal rounds down).
    function testFuzz_AmountsRoundTrip(uint256 a0, uint256 a1, int24 tick) public pure {
        a0 = bound(a0, 1e6, 1e30);
        a1 = bound(a1, 1e6, 1e30);
        tick = int24(bound(tick, -200_000, 200_000));
        uint160 p = TickMath.getSqrtPriceAtTick(tick);
        uint160 sa = TickMath.getSqrtPriceAtTick(tick - 600);
        uint160 sb = TickMath.getSqrtPriceAtTick(tick + 600);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(p, sa, sb, a0, a1);
        (uint256 x0, uint256 x1) = OraclePositionMath.amountsForLiquidity(p, sa, sb, l);
        assertLe(x0, a0);
        assertLe(x1, a1);
    }

    function test_FeesWrapLikeThePool() public pure {
        // Growth counters wrap; the difference is still right.
        uint256 last = type(uint256).max - (1 << 127) + 1;
        uint256 now_ = 1 << 127;
        assertEq(OraclePositionMath.feesEarned(now_, last, 2), 2);
    }
}
