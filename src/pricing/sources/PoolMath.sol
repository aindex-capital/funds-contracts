// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IPriceSource} from "../../interfaces/IPriceSource.sol";

/**
 * @title  PoolMath
 * @notice Turns a Uniswap tick into USD per whole token, through the pool's other token and that token's
 *         price from another source. Shared by the v3 TWAP source and the v4 price recorder.
 */
library PoolMath {
    /// @dev Beyond this a pool price is a ratio of about 1e26 raw units either way: no real market. Refusing
    ///      it keeps every multiplication below in range, so pricing never reverts.
    int24 internal constant MAX_ABS_TICK = 600_000;

    /// @notice Raw units of the quote token that `baseAmount` raw units of the base token are worth at `tick`.
    ///         `baseIsToken0` says which side of the pool the base token is. Same as Uniswap's OracleLibrary.
    function quoteAtTick(int24 tick, uint128 baseAmount, bool baseIsToken0) internal pure returns (uint256) {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseIsToken0
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseIsToken0
            ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
            : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
    }

    /// @notice Whole quote tokens per whole base token at `tick`, 1e18 (the price a `IRatioSource` reports). Read
    ///         over a trillion whole base tokens so a cheap token against a few-decimal quote keeps its precision.
    ///         0 when the tick is beyond any real market or the decimals are absurd.
    function ratioAtTick(int24 tick, uint8 baseDecimals, bool baseIsToken0, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        if (tick > MAX_ABS_TICK || tick < -MAX_ABS_TICK || baseDecimals > 26 || quoteDecimals > 36) return 0;
        uint256 quoteRaw = quoteAtTick(tick, uint128(10 ** (uint256(baseDecimals) + 12)), baseIsToken0);
        return FullMath.mulDiv(quoteRaw, 1e6, 10 ** quoteDecimals);
    }

    /// @notice USD per whole base token (1e18) at `tick`, with the quote token priced by `quoteSource`.
    ///         Never reverts: a failing or unavailable quote price gives ok = false.
    function usdAtTick(
        int24 tick,
        uint8 baseDecimals,
        bool baseIsToken0,
        uint8 quoteDecimals,
        IPriceSource quoteSource,
        address quotePriceToken
    ) internal view returns (uint256 usd, uint64 quoteAt, bool ok) {
        if (tick > MAX_ABS_TICK || tick < -MAX_ABS_TICK || baseDecimals > 36) {
            return (0, 0, false);
        }
        uint256 q;
        try quoteSource.price(quotePriceToken) returns (uint256 p, uint64 at, bool pOk) {
            if (!pOk || p == 0) return (0, 0, false);
            q = p;
            quoteAt = at;
        } catch {
            return (0, 0, false);
        }
        uint256 quoteRaw = quoteAtTick(tick, uint128(10 ** baseDecimals), baseIsToken0);
        // A price this far out (only possible at extreme ticks) is no price; never revert on it.
        if (quoteRaw != 0 && q > type(uint256).max / quoteRaw) return (0, 0, false);
        usd = FullMath.mulDiv(quoteRaw, q, 10 ** quoteDecimals);
        ok = usd != 0;
    }
}
