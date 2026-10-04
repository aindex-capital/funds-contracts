// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController} from "../interfaces/IFundController.sol";

/**
 * @title  SeedTeller
 * @notice The simplest teller, kept for tests (no longer deployed: every Fund opens through the public Teller,
 *         whose opening stake replaced seed money). The Fund's owner deposits the base
 *         asset once at a fixed price per share and holds every share. No public deposits, no exits other than
 *         the owner taking everything back in kind later. The public deposit and redemption teller replaces it
 *         for investable Funds.
 * @dev    Griefing: only the Fund's owner can seed, once, and the vault must name this contract as its teller,
 *         so nobody can seed someone else's Fund first, at a bad price or with a different token. A donation
 *         to the vault before seeding only gifts the owner. Seeding to an address other than the owner makes
 *         that address an outside holder (the vault's latch), so the Fund's risk changes then wait notice.
 *         The token must be the Fund's base asset and `tokenDecimals` must match it, so shares are never
 *         priced against a token the Fund does not count as cash or at a wrong scale.
 */
contract SeedTeller {
    using SafeERC20 for IERC20;

    error NotSeeder();
    error AlreadySeeded();
    error BadSeed();

    mapping(address => bool) public seeded; // by vault

    event Seeded(address indexed vault, address indexed to, address token, uint256 amount, uint256 shares);

    /// @notice Move `amount` of `token` from the caller into `vault` and mint 1 share per base unit, scaled to
    ///         18 decimals. Only once per vault, and only by the Fund's owner, so nobody can seed someone else's
    ///         new Fund first and take its opening shares.
    function seed(IFundVault vault, address token, uint256 amount, uint8 tokenDecimals, address to) external returns (uint256 shares) {
        if (vault.teller() != address(this) || IFundController(vault.controller()).owner() != msg.sender) revert NotSeeder();
        if (seeded[address(vault)]) revert AlreadySeeded();
        if (
            amount == 0 || to == address(0) || tokenDecimals > 18
                || token != IFundController(vault.controller()).baseAsset()
                || IERC20Metadata(token).decimals() != tokenDecimals
        ) revert BadSeed();
        seeded[address(vault)] = true;
        IERC20(token).safeTransferFrom(msg.sender, address(vault), amount);
        vault.track(token);
        shares = amount * (10 ** (18 - tokenDecimals));
        vault.mint(to, shares);
        emit Seeded(address(vault), to, token, amount, shares);
    }
}
