// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {IPermit2} from "../../interfaces/external/permit2/IPermit2.sol";

/**
 * @title  AggregatorSwapAdapter
 * @notice Swaps any token for any token through a router the Fund's owner allowed: KyberSwap, 0x, ParaSwap,
 *         LiFi or Uniswap's Universal Router (which also covers a direct Uniswap v3 or v4 path). The manager
 *         brings calldata built off chain by the router's API; the adapter never trusts it. What protects the
 *         Fund is what the adapter measures, not what the calldata says.
 *
 * @dev    ## Why calldata is never trusted
 *         Aggregator calldata names a recipient, an amount and a path that the adapter cannot decode in
 *         general (every router encodes differently, and they change). So the adapter checks the effect:
 *         1. The router can only spend `amountIn`: the adapter holds nothing else (rule 4) and approves
 *            exactly `amountIn`, to the router or through Permit2, for this call only, then resets to zero.
 *         2. Output counts only if it arrived here: `tokenOut` is measured by this adapter's balance before
 *            and after the call. A route that pays anyone else (the manager, the router, a third party)
 *            delivers nothing here and fails `minOut`, so the whole action reverts.
 *         3. `minOut` must be non-zero, so a lazily built action cannot accept nothing.
 *         4. All of `tokenOut` and any unspent `tokenIn` go back to the vault in the same call.
 *         On top of this the controller prices the Fund before and after, so a swap at a bad price (inside
 *         `minOut` but far from fair) still counts against the Fund's daily loss budget.
 *
 *         ## Native ETH
 *         A Fund holds ERC-20 tokens only; WETH is its ETH. The adapter never sends value and has no
 *         `receive`, so a route that pays out native ETH reverts instead of leaving ETH loose here. Agents
 *         quote WETH (0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 on Robinhood Chain), never the 0xEeee
 *         sentinel or address(0). A router may still unwrap and rewrap inside its own route; that is its
 *         business, and only the balance that lands here counts.
 *
 *         ## Approvals
 *         - Direct (KyberSwap MetaAggregationRouterV2, 0x AllowanceHolder, ParaSwap Augustus 6.2, LiFi
 *           diamond): the router is the spender. For 0x the target is AllowanceHolder itself, which spends
 *           for the Settler it forwards to, so the approval never reaches a Settler that can change.
 *         - Permit2 (Universal Router): the token is approved to Permit2 and Permit2 lets the router spend
 *           `amountIn` until the end of this block; both are cleared after the call.
 *
 *         ## Targets
 *         Fixed per Fund clone at enable time (`_configure`) and checked once there: each has code, appears
 *         once, and is not Permit2 or the Fund's vault or controller. Tokens are refused as targets at
 *         execution, so even a mistaken allowlist cannot turn this into a plain `transfer`.
 *
 *         Holds nothing between calls, so it has no positions; `unwind`, `split` and `grow` return nothing.
 */
contract AggregatorSwapAdapter is BaseAdapter {
    using Strings for address;

    error BadConfig();
    error UnknownAction(uint8 id);
    error AmountTooLarge();
    error TargetNotAllowed(address target);
    error BadTokens();
    error ZeroAmount();
    error ZeroMinOut();
    error TooLittle(uint256 received, uint256 minOut);
    error Overspent(uint256 spent, uint256 amountIn);

    event Swapped(
        address indexed target, address indexed tokenIn, uint256 spent, address indexed tokenOut, uint256 received
    );

    /// @notice How a target is allowed to spend the input.
    enum Approval {
        Direct, // ERC-20 approval to the target itself
        Permit2 // ERC-20 approval to Permit2, then a Permit2 allowance to the target
    }

    struct Target {
        address target;
        Approval approval;
    }

    uint8 public constant SWAP = 0;
    uint256 public constant MAX_TARGETS = 8;
    address private constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Uniswap's Permit2 on this chain. An immutable of the implementation, shared by every clone.
    IPermit2 public immutable permit2;

    Target[] private _targets;
    /// @dev target => approval kind + 1 (0 means not allowed)
    mapping(address => uint8) private _kind;

    constructor(IPermit2 permit2_) {
        permit2 = permit2_;
    }

    /// @param config abi.encode(Target[] targets): the routers this Fund may swap through, fixed for life.
    function _configure(bytes calldata config) internal override {
        Target[] memory t = abi.decode(config, (Target[]));
        if (t.length == 0 || t.length > MAX_TARGETS) revert BadConfig();
        for (uint256 i; i < t.length; ++i) {
            address a = t[i].target;
            if (a.code.length == 0 || a == address(permit2) || a == vault || a == controller || _kind[a] != 0) {
                revert BadConfig();
            }
            if (t[i].approval == Approval.Permit2 && address(permit2).code.length == 0) revert BadConfig();
            _kind[a] = uint8(t[i].approval) + 1;
            _targets.push(t[i]);
        }
    }

    // ---------------------------------------------------------------- reads

    function name() external pure returns (string memory) {
        return "Aggregator swap v1";
    }

    function targets() external view returns (Target[] memory) {
        return _targets;
    }

    function isAllowed(address target) external view returns (bool) {
        return _kind[target] != 0;
    }

    function describe() external view returns (string memory) {
        string memory list;
        for (uint256 i; i < _targets.length; ++i) {
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                '{"target":"',
                _targets[i].target.toHexString(),
                '","approval":"',
                _targets[i].approval == Approval.Permit2 ? "permit2" : "direct",
                '"}'
            );
        }
        return string.concat(
            '{"adapter":"Aggregator swap v1","kind":"swap","positions":false,',
            '"about":"Swap any ERC-20 for any ERC-20 through an allowed router. Build calldata with the router API using this adapter as both sender and recipient; the adapter measures what arrives and reverts below minOut. Native ETH is not supported: quote WETH.",',
            '"targets":[',
            list,
            '],"actions":[{"id":0,"name":"swap","params":[',
            '{"name":"tokenIn","type":"address","about":"token the vault pays (ERC-20, never native)"},',
            '{"name":"amountIn","type":"uint256","about":"raw units of tokenIn pulled from the vault and approved to the router"},',
            '{"name":"tokenOut","type":"address","about":"token the vault receives (ERC-20, never native)"},',
            '{"name":"minOut","type":"uint256","about":"least tokenOut, raw units, that must arrive at this adapter; non-zero"},',
            '{"name":"target","type":"address","about":"one of targets; KyberSwap router, 0x AllowanceHolder, ParaSwap Augustus, LiFi diamond or Universal Router"},',
            '{"name":"data","type":"bytes","about":"calldata from the router API, built with sender = recipient = this adapter"}],',
            '"encoding":"abi.encode(uint8 0, address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, address target, bytes data)",',
            '"returns":"abi.encode(uint256 received, uint256 spent)"}]}'
        );
    }

    function inputs(bytes calldata action) external pure returns (Amount[] memory) {
        Swap memory w = _swap(action);
        return _one(w.tokenIn, w.amountIn);
    }

    function outputs(bytes calldata action) external pure returns (address[] memory) {
        Swap memory w = _swap(action);
        return _tokens2(w.tokenOut, w.tokenIn);
    }

    // ---------------------------------------------------------------- the action

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        Swap memory w = _swap(action);
        uint8 kind = _kind[w.target];
        if (kind == 0) revert TargetNotAllowed(w.target);
        if (
            w.tokenIn == w.tokenOut || w.tokenIn == address(0) || w.tokenOut == address(0)
                || w.tokenIn == NATIVE_SENTINEL || w.tokenOut == NATIVE_SENTINEL || w.target == w.tokenIn
                || w.target == w.tokenOut
        ) revert BadTokens();
        if (w.amountIn == 0) revert ZeroAmount();
        if (w.minOut == 0) revert ZeroMinOut();

        _pull(w.tokenIn, w.amountIn);
        uint256 inBefore = IERC20(w.tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(w.tokenOut).balanceOf(address(this));

        bool viaPermit2 = kind == uint8(Approval.Permit2) + 1;
        _allow(w, viaPermit2, w.amountIn);
        (bool ok, bytes memory ret) = w.target.call(w.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        _allow(w, viaPermit2, 0);

        uint256 spent = inBefore - _min(inBefore, IERC20(w.tokenIn).balanceOf(address(this)));
        if (spent > w.amountIn) revert Overspent(spent, w.amountIn);
        uint256 received = IERC20(w.tokenOut).balanceOf(address(this));
        received = received > outBefore ? received - outBefore : 0;
        if (received < w.minOut) revert TooLittle(received, w.minOut);

        _pushAll(w.tokenOut);
        _pushAll(w.tokenIn);
        emit Swapped(w.target, w.tokenIn, spent, w.tokenOut, received);
        return abi.encode(received, spent);
    }

    /// @dev Set (amount > 0) or clear (amount = 0) the router's right to spend tokenIn for this one call.
    function _allow(Swap memory w, bool viaPermit2, uint256 amount) private {
        if (viaPermit2) {
            if (amount != 0) {
                _approve(w.tokenIn, address(permit2), amount);
                // Expires with this block, so the allowance cannot outlive the call even if a reset were missed.
                permit2.approve(w.tokenIn, w.target, _u160(amount), uint48(block.timestamp));
            } else {
                permit2.approve(w.tokenIn, w.target, 0, 0);
                _approve(w.tokenIn, address(permit2), 0);
            }
        } else {
            _approve(w.tokenIn, w.target, amount);
        }
    }

    // ---------------------------------------------------------------- positions: none

    function positions(IPriceRouter) external pure returns (Amount[] memory assets, Amount[] memory debts) {
        return (new Amount[](0), new Amount[](0));
    }

    function unwind(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    function split(uint256, address) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    /// @notice A swap venue holds no positions, so a deposit has nothing to grow here: the teller buys the
    ///         vault's token holdings directly.
    function grow(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function growInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    // ---------------------------------------------------------------- helpers

    struct Swap {
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minOut;
        address target;
        bytes data;
    }

    function _swap(bytes calldata action) private pure returns (Swap memory w) {
        uint8 id;
        (id, w.tokenIn, w.amountIn, w.tokenOut, w.minOut, w.target, w.data) =
            abi.decode(action, (uint8, address, uint256, address, uint256, address, bytes));
        if (id != SWAP) revert UnknownAction(id);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _u160(uint256 x) private pure returns (uint160) {
        if (x > type(uint160).max) revert AmountTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(x); // checked above
    }
}
