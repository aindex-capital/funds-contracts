// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Holders' pockets (`Pockets`): what a Fund held that NAV values at zero, set aside for the holders of the
 *         moment, claimable in kind pro rata to their shares at the snapshot, forever.
 */
interface IPockets {
    event PocketOpened(address indexed vault, uint256 indexed id, address indexed token, uint256 supplyAt);
    event Credited(address indexed vault, uint256 indexed id, address indexed token, uint256 amount);
    event Claimed(address indexed vault, uint256 indexed id, address indexed account, address token, uint256 amount);

    /// @notice The Fund's teller: open pocket `id` (a snapshot id of `vault`) for `token`, with the Fund's share
    ///         supply at the snapshot.
    function open(address vault, uint256 id, address token, uint256 supplyAt) external;

    /// @notice The teller, before it moves a pocket's token here: remember what is here beyond what is owed, for
    ///         `credit` in the same transaction.
    function mark(address token) external;

    /// @notice The Fund's teller: credit pocket `id` with what arrived for its token since its `mark` in this
    ///         transaction (nothing else: growth nobody sent is not this pocket's).
    function credit(address vault, uint256 id) external returns (uint256 amount);

    /// @notice Anyone: add `amount` of the pocket's token, pulled from the caller (an adapter draining a position
    ///         over time), and credit what arrived. Returns what the pocket was credited.
    function topUp(address vault, uint256 id, uint256 amount) external returns (uint256 got);

    /// @notice Anyone: pay `account` its part of pocket `id` not yet claimed. Never expires.
    function claim(address vault, uint256 id, address account) external returns (uint256 paid);

    function pocket(address vault, uint256 id) external view returns (address token, uint256 amount, uint256 supplyAt);
    function pocketInfo(address vault, uint256 id)
        external
        view
        returns (address token, uint256 amount, uint256 supplyAt, uint64 openedAt);
    function pocketIds(address vault) external view returns (uint256[] memory);
    /// @notice What `claim(vault, id, account)` would pay now.
    function due(address vault, uint256 id, address account) external view returns (uint256);
    /// @notice The shares `account` counts with in pocket `id`: its balance at the snapshot plus what the teller held
    ///         for it in custody then (`Teller.custodyAt`).
    function sharesAt(address vault, uint256 id, address account) external view returns (uint256);
}

/**
 * @notice Optional for adapters whose positions can hold something NAV values at zero that cannot simply be unwound
 *         (supply in a Morpho market nobody reviewed, lent out today). `TellerOps.pocket` calls `pocket` through the
 *         Fund's controller: the adapter stops counting that position as the Fund's (it leaves `positions`,
 *         `unvalued`, `split` and `unwind`), sends what it can pay now to the pocket, and pays the rest into it later
 *         through `drain`, which anyone may call.
 */
interface IPocketable {
    /// @notice Controller only: move every position of `token` this adapter reports as unvalued into pocket `id`
    ///         of `pockets`. Returns what it paid in now.
    function pocket(address token, IPockets pockets, uint256 id) external returns (uint256 paid);

    /// @notice Anyone: pay into its pocket what a pocketed position can pay now. Returns what it paid.
    function drain() external returns (uint256 paid);
}
