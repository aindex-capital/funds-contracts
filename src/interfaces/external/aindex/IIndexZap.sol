// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice AINDEX's IndexZap (aindex-contracts-v2/src/IndexZap.sol): buys an index at its backing with one
///         token, or sells one for one token, in one call. The Universal Router plan is built off chain.
interface IIndexZap {
    function router() external view returns (address);
    function factory() external view returns (address);
    function weth() external view returns (address);
    function usdg() external view returns (address);

    /// @param payToken address(0) for ETH (sent as value), otherwise an ERC-20 approved to the zap.
    function buy(
        address index,
        uint256 shares,
        uint256 minSharesOut,
        address payToken,
        uint256 payAmount,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable returns (uint256 sharesOut);

    /// @param outToken address(0) for ETH, otherwise the ERC-20 the plan delivers to the zap.
    function sell(
        address index,
        uint256 shares,
        address outToken,
        uint256 minOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external returns (uint256 received);
}

/// @notice The AINDEX IndexFactory's registry of indexes it created.
interface IIndexFactory {
    function isIndex(address index) external view returns (bool);
}
