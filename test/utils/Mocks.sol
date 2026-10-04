// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice A price source tests set by hand.
contract MockPriceSource is IPriceSource {
    mapping(address => uint256) public prices;
    mapping(address => bool) public down;
    /// @dev When set, the reading's time (a feed whose last round is older than now); otherwise now.
    mapping(address => uint64) public readAt;

    function setReadAt(address token, uint64 at) external {
        readAt[token] = at;
    }

    function set(address token, uint256 usdWad) external {
        prices[token] = usdWad;
    }

    function setDown(address token, bool d) external {
        down[token] = d;
    }

    function price(address token) external view returns (uint256 usd, uint64 updatedAt, bool ok) {
        usd = prices[token];
        updatedAt = readAt[token] != 0 ? readAt[token] : uint64(block.timestamp);
        ok = !down[token] && usd != 0;
    }

    function name() external pure returns (string memory) {
        return "mock";
    }
}
