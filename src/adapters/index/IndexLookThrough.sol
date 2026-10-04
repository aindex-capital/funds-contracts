// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Amount} from "../../interfaces/IAdapter.sol";
import {ILookThrough} from "../../interfaces/ILookThrough.sol";
import {IFolio} from "../../interfaces/external/folio/IFolio.sol";

/**
 * @title  IndexLookThrough
 * @notice Says what an amount of an AINDEX index share holds: the basket it redeems for, `toAssets(amount,
 *         Floor)`. Named by the PriceRouter for each index token, so a Fund's class caps see the basket's thin
 *         or pool-priced tokens instead of the share's own class.
 * @dev    Reverts while a trusted fill is mid-swap (the basket reads wrong then) or when the Folio cannot say;
 *         a Fund then counts the whole holding as thin, the cautious answer. Stateless; one serves every index.
 */
contract IndexLookThrough is ILookThrough {
    error Unreadable();

    function underlying(address token, uint256 amount) external view returns (Amount[] memory parts) {
        try IFolio(token).stateChangeActive() returns (bool syncActive, bool asyncActive) {
            if (syncActive || asyncActive) revert Unreadable();
        } catch {}
        (address[] memory assets, uint256[] memory amounts) = IFolio(token).toAssets(amount, 0);
        if (assets.length != amounts.length) revert Unreadable();
        parts = new Amount[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            parts[i] = Amount(assets[i], amounts[i]);
        }
    }
}
