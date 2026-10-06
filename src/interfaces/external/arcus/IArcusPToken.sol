// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Arcus pTokens (beacon proxies, implementation 0x1815A37B6027Ae8066720d873A508F25fC151AC5 on Robinhood Chain): an
 *         ERC-7540 vault share over an Arcus perps account, with ERC-7887 cancellation. Only what the redeem adapter
 *         calls. Behaviour measured on a fork on 2026-10-06:
 *         - `requestRedeem(shares, controller, owner)` takes the shares from `owner` into the pToken and returns the
 *           request id; the request expires `requestTtl` (7 days) after it is filed.
 *         - Arcus' keeper fulfils it (two calls, through its bridge) in about a minute: the shares become claimable and
 *           `redeem(shares, receiver, controller)` pays their USDG to `receiver`. Only the controller (or its operator)
 *           may claim.
 *         - The keeper may reject instead (`rejectRedeemRequest`): the shares become claimable-cancelled and
 *           `claimCancelRedeemRequest(id, receiver, controller)` returns them.
 *         - The controller may cancel only after expiry (`cancelRedeemRequest` reverts before it); the shares then
 *           become claimable-cancelled at once.
 */
interface IArcusPToken {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableCancelRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function maxRedeem(address controller) external view returns (uint256 shares);
    function maxWithdraw(address controller) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function cancelRedeemRequest(uint256 requestId, address controller) external;
    function claimCancelRedeemRequest(uint256 requestId, address receiver, address controller) external returns (uint256 shares);
    /// @dev (controller, status, expiry, shares, claimable shares)
    function redemption(uint256 requestId) external view returns (address, uint8, uint64, uint256, uint256);
}

interface IArcusPTokenFactory {
    function isPToken(address token) external view returns (bool);
}
