// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPriceSource} from "../../interfaces/IPriceSource.sol";
import {IPriceRouter, Side} from "../../interfaces/IPriceRouter.sol";

/**
 * @title  VaultShareSource
 * @notice Prices a vault share a Fund holds as a plain token: what one whole share converts to in the vault's asset
 *         (`convertToAssets`), valued at the PriceRouter's fair price of that asset.
 *
 * @dev    ## What it is for
 *         Shares of ERC-4626 vaults and of ERC-7540 asynchronous vaults, held directly in a Fund's vault rather than
 *         through the ERC-4626 adapter: the first users are Arcus pTokens (leveraged long and short perps exposure,
 *         bought from their Uniswap v4 pools), whose deposits are allowlisted, so a Fund can only buy them on the
 *         market, never mint them through an adapter.
 *
 *         ## Whose number this is
 *         The vault's own accounting, the way Funds value every third-party position (Morpho's supply, an ERC-4626
 *         vault's `previewRedeem`). For a vault whose share price a manager posts (Arcus' keeper posts each pToken's
 *         NAV from its perps account), that is the manager's number: AINDEX adds the token only after reviewing who
 *         posts it, gives it the Thin class and a haircut that covers the cost of selling it, and can downgrade it at
 *         once. Nobody else can move it within a block, which is what a price source must guarantee: a Fund compares
 *         its NAV before and after an action in the same transaction.
 *
 *         ## What makes it unavailable
 *         - The token is not a vault (`asset` or `convertToAssets` reverts), or converts to nothing.
 *         - The asset is unavailable at the router, or the token is its own asset.
 *         A Fund's NAV then reads incomplete rather than quietly low.
 *
 *         Stateless and permissionless, like `IndexNavSource`: anyone may deploy one per router. Never reverts.
 */
contract VaultShareSource is IPriceSource {
    IPriceRouter public immutable router;

    constructor(IPriceRouter router_) {
        router = router_;
    }

    function name() external pure returns (string memory) {
        return "Vault share (convertToAssets)";
    }

    function price(address share) external view returns (uint256 usd, uint64 updatedAt, bool ok) {
        updatedAt = uint64(block.timestamp);
        // A call to an address without code returns nothing, and decoding nothing reverts outside `try`.
        if (share.code.length == 0) return (0, updatedAt, false);
        uint256 one;
        try IERC20Metadata(share).decimals() returns (uint8 d) {
            if (d > 36) return (0, updatedAt, false);
            one = 10 ** uint256(d);
        } catch {
            return (0, updatedAt, false);
        }
        address asset;
        try IERC4626(share).asset() returns (address a) {
            asset = a;
        } catch {
            return (0, updatedAt, false);
        }
        if (asset == address(0) || asset == share || asset.code.length == 0) return (0, updatedAt, false);
        uint256 assets;
        try IERC4626(share).convertToAssets(one) returns (uint256 x) {
            assets = x;
        } catch {
            return (0, updatedAt, false);
        }
        if (assets == 0) return (0, updatedAt, false);
        (uint256 v,, bool okAsset) = router.value(asset, assets, Side.Fair);
        if (!okAsset) return (0, updatedAt, false);
        return (v, updatedAt, v != 0);
    }
}
