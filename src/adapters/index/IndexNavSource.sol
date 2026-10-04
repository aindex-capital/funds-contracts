// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceSource} from "../../interfaces/IPriceSource.sol";
import {IPriceRouter, Side} from "../../interfaces/IPriceRouter.sol";
import {IFolio} from "../../interfaces/external/folio/IFolio.sol";

/**
 * @title  IndexNavSource
 * @notice Prices one AINDEX index share by looking through it: the basket one whole share redeems for
 *         (`toAssets(1 share, Floor)`), each token valued at the PriceRouter's fair price, summed.
 *
 * @dev    ## Why look through
 *         An index share is always redeemable for its basket, at no fee, by anyone. So its value is its
 *         backing, and that backing is made of tokens the router already prices. Pricing the share from a
 *         pool would let anyone who moves that pool move every Fund holding the index; backing cannot be
 *         moved without moving the basket tokens' own prices, which the router already guards.
 *
 *         ## What it counts
 *         - Pending fee shares are in the Folio's `totalSupply`, so the dilution they bring is counted.
 *         - The mint fee is not: a holder redeems at backing, so a share is worth its backing.
 *         - A basket token with no market (class None) adds zero, the same as holding it directly.
 *         - Any basket token whose price is unavailable makes the share unavailable (`ok = false`), so a
 *           Fund's NAV is reported incomplete rather than quietly low.
 *         - While a trusted fill is mid-swap (`stateChangeActive`) the basket reads wrong, so the share is
 *           unavailable then too.
 *
 *         ## Configuring the router for an index token
 *         The router applies the index token's own class and haircut on top of this fair value. AINDEX sets
 *         the class to the worst class among the basket's material weights and the haircut to at least the
 *         basket's value-weighted haircut, so a Fund cannot dodge a class cap or a haircut by wrapping thin
 *         tokens in an index.
 *
 *         Stateless and permissionless: anyone may deploy one per router. Never reverts for a Folio.
 */
contract IndexNavSource is IPriceSource {
    IPriceRouter public immutable router;

    constructor(IPriceRouter router_) {
        router = router_;
    }

    function name() external pure returns (string memory) {
        return "AINDEX index look-through";
    }

    function price(address index) external view returns (uint256 usd, uint64 updatedAt, bool ok) {
        updatedAt = uint64(block.timestamp);
        uint256 one;
        try IERC20Metadata(index).decimals() returns (uint8 d) {
            one = 10 ** uint256(d);
        } catch {
            return (0, updatedAt, false);
        }
        try IFolio(index).stateChangeActive() returns (bool syncActive, bool asyncActive) {
            if (syncActive || asyncActive) return (0, updatedAt, false);
        } catch {}
        address[] memory assets;
        uint256[] memory amounts;
        try IFolio(index).toAssets(one, 0) returns (address[] memory a, uint256[] memory m) {
            (assets, amounts) = (a, m);
        } catch {
            return (0, updatedAt, false);
        }
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == index) return (0, updatedAt, false); // a share cannot back itself
            if (amounts[i] == 0) continue;
            (uint256 v,, bool okToken) = router.value(assets[i], amounts[i], Side.Fair);
            if (!okToken) return (0, updatedAt, false);
            usd += v;
        }
        ok = usd != 0;
    }
}
