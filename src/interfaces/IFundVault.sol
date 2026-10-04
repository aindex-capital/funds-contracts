// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Holds a Fund's tokens and issues its shares. Knows nothing about any protocol; every movement of
///         tokens out of it goes through its controller (to an adapter, for one call) or its teller (to a
///         depositor leaving).
interface IFundVault {
    function controller() external view returns (address);
    function teller() external view returns (address);

    /// @notice Tokens the vault counts in NAV. A token arrives in this list when an adapter declares it as an
    ///         output or a depositor brings it; anything else sent here is not counted.
    function trackedTokens() external view returns (address[] memory);
    function isTracked(address token) external view returns (bool);

    /// @notice Controller only: approve exactly `amount` of `token` to `spender` (an adapter of this Fund).
    function approveFor(address token, address spender, uint256 amount) external;

    /// @notice Controller only: start counting `token`.
    function track(address token) external;

    /// @notice Controller or teller: stop counting `token`. Both only ask for tokens the vault holds none (or
    ///         dust) of, so the tracked list cannot fill up for good.
    function untrack(address token) external;

    /// @notice True once anyone other than the Fund's owner has held a share. From then on every change that
    ///         adds risk waits the controller's notice, even if the shares come back to the owner.
    function hadOutsideHolder() external view returns (bool);

    /// @notice Teller only: shares.
    function mint(address to, uint256 shares) external;
    function burn(address from, uint256 shares) external;

    /// @notice Teller only: pay a leaving holder.
    function pay(address token, address to, uint256 amount) external;

    /// @notice Teller only: count queued depositors as outside holders before any share reaches them.
    function latchOutsideHolder() external;

    /// @notice Teller only: undo a latch set only for queued deposits once none is left (all cancelled or
    ///         paid back) and no share ever reached anyone but the owner. A no-op otherwise.
    function unlatchOutsideHolder() external;

    /// @notice When the outside-holder latch was last set (0 while it is not set). Fees run from here.
    function outsideHolderSince() external view returns (uint64);

    /// @notice Teller only: start a snapshot of every balance for a holders' pocket; returns its id.
    function snapshot() external returns (uint256 id);

    /// @notice The latest snapshot id (0 while none was taken).
    function currentSnapshotId() external view returns (uint64);

    /// @notice What `account` held when snapshot `id` was taken.
    function balanceOfAt(address account, uint256 id) external view returns (uint256);
}
