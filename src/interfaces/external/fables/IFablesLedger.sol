// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Fables' per-range totals, as returned by `rangeState`. Same layout on every hook generation.
struct FablesRangeState {
    uint128 totalShares; // equals the hook's v4 position liquidity for the range
    uint128 totalStaked;
    uint256 accFee0X128; // fee per unstaked share, Q128
    uint256 accFee1X128;
    uint256 accStaked0X128;
    uint256 accStaked1X128;
    uint128 stakedResidual0;
    uint128 stakedResidual1;
    uint64 collectionSeq;
    uint64 resetSeq;
}

/// @notice One holder's slice of a range, as returned by `userPosition`. Same layout on every hook generation.
struct FablesUserPosition {
    uint128 staked;
    uint128 owed0; // fees already credited to the holder, net of the claim fee
    uint128 owed1;
    uint256 checkpoint0X128;
    uint256 checkpoint1X128;
    uint256 stakedCheckpoint0X128;
    uint256 stakedCheckpoint1X128;
    uint256 forgone0;
    uint256 forgone1;
}

/**
 * @title  IFablesLedger
 * @notice The slice of a Fables hook that a Fund uses. Every Fables hook on Robinhood Chain is a Uniswap v4
 *         fee hook and its own LP ledger: it owns one v4 position per (pool, tickLower, tickUpper) and mints
 *         ERC-6909 shares 1:1 with liquidity units to depositors.
 * @dev    Only functions present with the same selector on both live generations are declared here: the
 *         one-hook-per-pool gen 1 (NVDA, SPY, TSLA, AAPL, GLD, META, SPY/NVDA, SPY/GLD) and the singleton gen 2
 *         (FablesRamp 0x08E5, FablesRWA 0x5Eb8, and the ETH variants). `withdrawAndClaim`, `pausedFor` and the
 *         per-pool claim-fee getters exist on gen 2 only and are left out on purpose.
 *
 *         Facts verified in the verified source (FablesLedger.sol, both generations):
 *         - `withdraw` carries no pause modifier: admin state cannot block principal.
 *         - `deposit`, `claimFees`, ERC-6909 transfers and staking are pausable, at most 7 days per call.
 *         - `withdraw` credits accrued fees to `owed0/owed1` (after the claim-fee skim) but does not pay them;
 *           `claimFees` pays them.
 *         - Tokens for a deposit are pulled from `msg.sender` with `transferFrom`, so the caller approves the hook.
 *         - `to` may be any address except the hook itself and the PoolManager.
 */
interface IFablesLedger {
    function poolManager() external view returns (address);

    /// @notice Adds `liquidity` units to the range and mints that many shares to the caller. Payable only on
    ///         the native-ETH hooks; must carry no value on ERC20 pools.
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable;

    /// @notice Burns `liquidity` shares and sends the principal to `to`. Never pausable.
    function withdraw(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external;

    /// @notice Syncs the range and pays the caller's owed fees to `to`. Pausable. Reverts `ClaimFeeAboveMax`
    ///         when the rate this sync would charge exceeds `maxFeeBps`, `NothingToClaim` when the caller has no
    ///         shares and nothing owed.
    function claimFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, address to, uint16 maxFeeBps)
        external;

    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function rangeId(PoolId poolId, int24 tickLower, int24 tickUpper) external pure returns (uint256);
    function rangeState(uint256 id) external view returns (FablesRangeState memory);
    function userPosition(uint256 id, address owner) external view returns (FablesUserPosition memory);

    /// @notice The claim-fee rate the range's next sync will charge on fees it collects.
    function effectiveClaimFee(uint256 id) external view returns (uint16);

    /// @notice True while the whole hook is paused (deposits, claims, transfers).
    function paused() external view returns (bool);

    /// @notice Non-zero once Fables wires its ve(3,3) voter. Zero on every hook until gauges launch.
    function ballotGate() external view returns (address);

    function maxFee(PoolId poolId) external view returns (uint24);
}
