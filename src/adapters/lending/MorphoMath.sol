// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMorpho, IMorphoIrm, MarketParams, MorphoMarket} from "../../interfaces/external/morpho/IMorpho.sol";

/**
 * @title  MorphoMath
 * @notice The arithmetic a Morpho Blue position needs, written for AINDEX: converting shares to assets in
 *         the direction that protects the Fund, and the interest a market has earned since it was last
 *         touched, so a view can report today's balances without sending a transaction.
 *
 * @dev    ## Shares
 *         Morpho counts every supply and borrow position in shares. A market behaves as if it always held
 *         one extra unit of assets and a million extra shares (the "virtual" amounts), which stops anyone
 *         from inflating the share price of an empty market. Every conversion here adds them in the same way
 *         Morpho does, otherwise our numbers would drift from Morpho's by a unit or two.
 *
 *         Rounding direction is a choice of who carries the dust. What the Fund is owed rounds down and
 *         what it owes rounds up, so the Fund never counts a unit it could not actually get back, and never
 *         forgets a unit it would have to repay.
 *
 *         ## Interest
 *         Morpho adds interest only when someone touches a market. Between touches the stored totals are
 *         stale. `expectedMarket` adds the interest that the next touch would add, using the market's own
 *         rate model in view mode. Morpho compounds with the first three terms of the exponential series,
 *         so we do the same, which keeps our view equal to what `accrueInterest` would write in the same
 *         block.
 */
library MorphoMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    /// @dev Morpho oracles quote one raw unit of collateral in raw loan units, times 1e36.
    uint256 internal constant ORACLE_SCALE = 1e36;

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return x * y / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    /// @notice Assets a number of shares is worth, rounded down (what the holder can count on).
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivDown(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Assets a number of shares is worth, rounded up (what a debtor must pay to clear them).
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Shares an amount of assets buys, rounded down.
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivDown(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Shares an amount of assets needs, rounded up.
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice e^(rate * elapsed) - 1, from the first three terms of its series, in WAD.
    function compoundedGrowth(uint256 ratePerSecond, uint256 elapsed) internal pure returns (uint256) {
        uint256 first = ratePerSecond * elapsed;
        uint256 second = mulDivDown(first, first, 2 * WAD);
        uint256 third = mulDivDown(second, first, 3 * WAD);
        return first + second + third;
    }

    /// @notice The market's totals as they would be after `accrueInterest` in this block.
    /// @dev    If the rate model's view reverts, the stored totals are returned unchanged, so one broken
    ///         market can never stop a whole Fund from being valued. That understates both what the Fund is
    ///         owed and what it owes in that market by the interest since its last touch.
    function expectedMarket(IMorpho morpho, MarketParams memory params, bytes32 id)
        internal
        view
        returns (MorphoMarket memory m)
    {
        (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee) =
            morpho.market(id);
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0 || m.totalBorrowAssets == 0 || params.irm == address(0)) return m;

        uint256 rate;
        try IMorphoIrm(params.irm).borrowRateView(params, m) returns (uint256 r) {
            rate = r;
        } catch {
            return m;
        }
        uint256 interest = mulDivDown(m.totalBorrowAssets, compoundedGrowth(rate, elapsed), WAD);
        m.totalBorrowAssets += uint128(interest);
        m.totalSupplyAssets += uint128(interest);
        if (m.fee != 0) {
            // The protocol's cut is paid as new supply shares, which slightly dilutes every supplier.
            uint256 feeAssets = mulDivDown(interest, m.fee, WAD);
            uint256 feeShares = toSharesDown(feeAssets, m.totalSupplyAssets - feeAssets, m.totalSupplyShares);
            m.totalSupplyShares += uint128(feeShares);
        }
        m.lastUpdate = uint128(block.timestamp);
    }
}
