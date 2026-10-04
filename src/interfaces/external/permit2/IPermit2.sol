// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The part of Uniswap's Permit2 (0x000000000022D473030F116dDEE9F6B43aC78BA3) an adapter needs to
///         let the Universal Router spend a token: an on-chain allowance, set for one call and cleared after.
interface IPermit2 {
    /// @notice Lets `spender` move up to `amount` of `token` from the caller through Permit2 until `expiration`.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
