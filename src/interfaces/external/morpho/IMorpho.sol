// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice The five values that define a Morpho Blue market. A market's id is the keccak256 of their ABI
 *         encoding, so the same five values always name the same market and a market can never change.
 */
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice A market's totals as Morpho stores them, as of `lastUpdate` (interest since then not yet added).
struct MorphoMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/**
 * @title  IMorpho
 * @notice The part of Morpho Blue the AINDEX adapter uses. Written from Morpho's public ABI; only the calls
 *         we make are listed. Market ids are plain bytes32 here.
 */
interface IMorpho {
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    function idToMarketParams(bytes32 id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);

    function accrueInterest(MarketParams memory marketParams) external;

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;
}

/// @notice A Morpho interest rate model. `borrowRateView` is the per-second borrow rate (1e18 = 100% a
///         second) the market would charge if interest were accrued now, without changing anything.
interface IMorphoIrm {
    function borrowRateView(MarketParams memory marketParams, MorphoMarket memory market) external view returns (uint256);
}

/// @notice A Morpho market oracle: the price of one raw unit of collateral in raw units of the loan token,
///         scaled by 1e36.
interface IMorphoOracle {
    function price() external view returns (uint256);
}
