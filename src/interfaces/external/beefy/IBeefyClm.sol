// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Beefy's concentrated liquidity manager ("CLM", cowcentrated) vault, as deployed on Robinhood Chain by Beefy
 *         and by its fork Arrowfarm. ERC-20 shares over a strategy that keeps two Uniswap v3 ranges (main and alt).
 * @dev    Only what the adapter calls. Read from the live contracts on 2026-10-05: `previewDeposit` returns five values
 *         (shares, the amounts it would take, and the fees on them); `withdraw` pays `msg.sender`.
 */
interface IBeefyClmVault {
    function strategy() external view returns (address);
    function wants() external view returns (address token0, address token1);
    function balances() external view returns (uint256 amount0, uint256 amount1);
    function isCalm() external view returns (bool);
    function owner() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function previewDeposit(uint256 amount0, uint256 amount1)
        external
        view
        returns (uint256 shares, uint256 used0, uint256 used1, uint256 fee0, uint256 fee1);
    function previewWithdraw(uint256 shares) external view returns (uint256 amount0, uint256 amount1);
    function deposit(uint256 amount0, uint256 amount1, uint256 minShares) external;
    function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1) external;
}

/// @notice The CLM strategy behind a vault (a beacon proxy). Positions live in the pool under `keccak256(strategy, lo, hi)`.
interface IBeefyClmStrategy {
    function vault() external view returns (address);
    function pool() external view returns (address);
    function factory() external view returns (address);
    function owner() external view returns (address);
    function lpToken0() external view returns (address);
    function lpToken1() external view returns (address);
    /// @dev The strategy's idle tokens, less the fees it holds back for harvesting.
    function balancesOfThis() external view returns (uint256 token0Bal, uint256 token1Bal);
    /// @dev Harvested profit that is still dripping in; `balances()` leaves it out, so a withdrawal does not pay it.
    function lockedProfit() external view returns (uint256 locked0, uint256 locked1);
    function getKeys() external view returns (bytes32 keyMain, bytes32 keyAlt);
    function positionMain() external view returns (int24 tickLower, int24 tickUpper);
    function positionAlt() external view returns (int24 tickLower, int24 tickUpper);
}

/// @notice A Uniswap v3 pool's position by key, and its identity for the factory check.
interface IUniswapV3PoolKeyed {
    function positions(bytes32 key)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

/// @notice Arrowfarm's vaults charge their fees in basis points of `FEE_DENOMINATOR`; Beefy's have none.
interface IClmFees {
    function withdrawFee() external view returns (uint256);
    function FEE_DENOMINATOR() external view returns (uint256);
}
