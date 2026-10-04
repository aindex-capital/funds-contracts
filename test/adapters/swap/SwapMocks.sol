// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../utils/Mocks.sol";

/// @notice A router that does what its calldata says: pulls `amountIn` from the caller, mints `amountOut` to
///         whoever the calldata names. Tests use it to build honest and dishonest routes.
contract MockAggregator {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address recipient) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(recipient, amountOut);
    }

    /// Pays native ETH instead of the token, as a route quoted with the 0xEeee sentinel would.
    function swapToNative(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = msg.sender.call{value: 1 ether}("");
        require(ok, "native payout refused");
    }

    receive() external payable {}
}

/// @notice The allowance half of Permit2: on-chain approvals with an expiry, spent by `transferFrom`.
contract MockPermit2 {
    struct Allowed {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => Allowed))) public allowed;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        Allowed storage a = allowed[msg.sender][token][spender];
        a.amount = amount;
        a.expiration = expiration == 0 ? uint48(block.timestamp) : expiration;
    }

    function allowance(address owner, address token, address spender) external view returns (uint160, uint48, uint48) {
        Allowed memory a = allowed[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowed storage a = allowed[from][token][msg.sender];
        require(block.timestamp <= a.expiration, "expired");
        require(a.amount >= amount, "insufficient allowance");
        a.amount -= amount;
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice A Universal Router stand-in: pays through Permit2 like the real one does.
contract MockUniversalRouter {
    MockPermit2 public immutable permit2;

    constructor(MockPermit2 p) {
        permit2 = p;
    }

    function execute(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address recipient)
        external
    {
        permit2.transferFrom(msg.sender, address(this), uint160(amountIn), tokenIn);
        MockERC20(tokenOut).mint(recipient, amountOut);
    }
}
