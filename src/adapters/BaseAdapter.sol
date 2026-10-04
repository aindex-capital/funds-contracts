// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAdapter, Amount} from "../interfaces/IAdapter.sol";

/**
 * @title  BaseAdapter
 * @notice What every adapter shares: binding to one Fund, the controller-only gate, pulling declared inputs
 *         from the vault and sending outputs back to it. An adapter author writes the protocol part only.
 * @dev    Deployed once as an implementation; Funds get clones (`initialize` runs once per clone). The
 *         implementation itself is locked in its constructor so nobody can initialise it.
 */
abstract contract BaseAdapter is IAdapter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error AlreadyInitialized();
    error NotController();
    error ZeroAddress();

    address public vault;
    address public controller;

    constructor() {
        // Lock the implementation: clones have fresh storage, the implementation does not.
        vault = address(0xdead);
    }

    function initialize(address vault_, address controller_, bytes calldata config) external {
        if (vault != address(0)) revert AlreadyInitialized();
        if (vault_ == address(0) || controller_ == address(0)) revert ZeroAddress();
        vault = vault_;
        controller = controller_;
        _configure(config);
    }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    /// @dev Adapter-specific settings fixed at enable time. Default: none.
    function _configure(bytes calldata config) internal virtual {
        config;
    }

    /// @dev Pull a declared input from the vault (the controller approved exactly this for this call).
    function _pull(address token, uint256 amount) internal {
        if (amount != 0) IERC20(token).safeTransferFrom(vault, address(this), amount);
    }

    /// @dev Send everything this adapter holds of `token` to the vault. Adapters hold no loose tokens
    ///      between calls, so every action ends by pushing its outputs and leftovers.
    function _pushAll(address token) internal returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(vault, amount);
    }

    function _push(address token, address to, uint256 amount) internal {
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Approve exactly `amount` to a protocol for one call; reset with `_approve(token, spender, 0)`.
    function _approve(address token, address spender, uint256 amount) internal {
        IERC20(token).forceApprove(spender, amount);
    }

    function _one(address token, uint256 amount) internal pure returns (Amount[] memory a) {
        a = new Amount[](1);
        a[0] = Amount(token, amount);
    }

    function _none() internal pure returns (Amount[] memory a) {
        a = new Amount[](0);
    }

    /// @dev Adds `amount` of `token` to the first `rows` entries of `list`, merging with an entry of the same token,
    ///      and returns the new row count. Used to declare one input per token, so a caller that approves entry by
    ///      entry never overwrites one approval with another.
    function _tally(Amount[] memory list, uint256 rows, address token, uint256 amount) internal pure returns (uint256) {
        for (uint256 i; i < rows; ++i) {
            if (list[i].token == token) {
                list[i].amount += amount;
                return rows;
            }
        }
        list[rows] = Amount(token, amount);
        return rows + 1;
    }

    /// @dev Shortens `list` to its first `rows` entries.
    function _trim(Amount[] memory list, uint256 rows) internal pure returns (Amount[] memory) {
        assembly ("memory-safe") {
            mstore(list, rows)
        }
        return list;
    }

    /// @dev Pulls every declared amount from the vault, then returns `list` unchanged for chaining.
    function _pullAll(Amount[] memory list) internal returns (Amount[] memory) {
        for (uint256 i; i < list.length; ++i) _pull(list[i].token, list[i].amount);
        return list;
    }

    /// @dev What a `grow` used: what it pulled less what it sends back to the vault now (the protocol took
    ///      less than the rounded-up amount it was offered). Ends with no loose tokens of the pulled kinds.
    function _settleGrow(Amount[] memory pulled) internal returns (Amount[] memory used) {
        used = new Amount[](pulled.length);
        for (uint256 i; i < pulled.length; ++i) {
            uint256 back = _pushAll(pulled[i].token);
            used[i] = Amount(pulled[i].token, pulled[i].amount > back ? pulled[i].amount - back : 0);
        }
    }

    function _tokens1(address a) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    function _tokens2(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }
}
