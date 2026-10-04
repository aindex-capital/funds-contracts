// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Wrapped ether: the liquidity adapters keep a Fund's ether as WETH and unwrap it only for the
///         length of a call into a native-ether pool.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
