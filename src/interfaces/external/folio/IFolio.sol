// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The part of a Reserve Index DTF (Folio) a Fund uses. AINDEX indexes are Folios: an ERC-20 share
///         fully backed by a basket the Folio holds. Minting takes the whole basket in proportion, redeeming
///         returns it.
/// @dev    `rounding` is OpenZeppelin's Math.Rounding: 0 = Floor, 1 = Ceil. Mint pulls the Ceil amounts,
///         redeem pays the Floor amounts.
interface IFolio {
    /// @notice The basket and the amounts the Folio holds of each.
    function totalAssets() external view returns (address[] memory, uint256[] memory);

    function toAssets(uint256 shares, uint8 rounding) external view returns (address[] memory, uint256[] memory);

    /// @notice Pulls `toAssets(shares, Ceil)` from the caller and mints `shares` less the mint fee to `receiver`.
    function mint(uint256 shares, address receiver, uint256 minSharesOut)
        external
        returns (address[] memory, uint256[] memory);

    /// @notice Burns the caller's `shares` and pays `toAssets(shares, Floor)` to `receiver`. `assets` must list
    ///         the basket exactly, in order.
    function redeem(uint256 shares, address receiver, address[] calldata assets, uint256[] calldata minAmountsOut)
        external
        returns (uint256[] memory);

    /// @notice True while a trusted fill is mid-swap, when `toAssets` may read wrong.
    function stateChangeActive() external view returns (bool syncStateChangeActive, bool asyncStateChangeActive);

    function isDeprecated() external view returns (bool);
}
