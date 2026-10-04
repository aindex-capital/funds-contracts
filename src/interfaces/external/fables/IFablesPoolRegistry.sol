// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title  IFablesPoolRegistry
 * @notice Fables' append-only list of its pools (0x159A113E012593D9B3cC63ad45E30F0467e13Ef3 on Robinhood Chain).
 *         Writes are restricted to Fables' admin, so a pool listed here is one Fables configured on its own hook.
 *         A retired pool keeps its entry with `active = false`.
 */
interface IFablesPoolRegistry {
    struct PoolInfo {
        PoolKey key;
        PoolId id;
        bool active;
    }

    function poolCount() external view returns (uint256);
    function poolAt(uint256 index) external view returns (PoolInfo memory);
    function isRegistered(PoolId id) external view returns (bool);

    /// @dev Reverts `NotRegistered` for an id that was never registered.
    function poolById(PoolId id) external view returns (PoolInfo memory);
}
