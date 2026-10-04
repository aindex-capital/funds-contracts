// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockERC20} from "../../utils/Mocks.sol";

/// @notice An ERC-4626 vault with switches: refuse share transfers (a gated vault), refuse redemptions (an
///         illiquid one), charge an exit fee, and earn yield by having its asset minted to it.
contract MockVault4626 is ERC4626 {
    bool public blockTransfers;
    bool public blockRedeem;
    uint256 public exitFeeBps;

    constructor(IERC20 asset_) ERC20("Mock vault", "mVLT") ERC4626(asset_) {}

    function setBlockTransfers(bool b) external {
        blockTransfers = b;
    }

    function setBlockRedeem(bool b) external {
        blockRedeem = b;
    }

    function setExitFeeBps(uint256 b) external {
        exitFeeBps = b;
    }

    function earn(uint256 assets) external {
        MockERC20(asset()).mint(address(this), assets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return super.previewRedeem(shares) * (10_000 - exitFeeBps) / 10_000;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(!blockRedeem, "illiquid");
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blockTransfers || from == address(0) || to == address(0), "gated");
        super._update(from, to, value);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12; // 18-decimal shares over a 6-decimal asset, like steakUSDG over USDG
    }
}
