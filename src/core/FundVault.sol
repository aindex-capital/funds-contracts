// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController} from "../interfaces/IFundController.sol";

/**
 * @title  FundVault
 * @notice Holds a Fund's tokens and issues its shares. It has no protocol logic and no generic call: tokens
 *         leave only as an exact, one-call approval to one of the Fund's own adapters (through the
 *         controller) or as a payment to a holder who is leaving (through the teller).
 * @dev    Shares cannot be minted or burned and holders cannot be paid while the controller is inside one of
 *         its own calls, so a deposit or exit can never land between an action's two NAV readings.
 *         At most `MAX_TRACKED` tokens are counted, which bounds the gas of every NAV reading and of an exit in
 *         kind (one transfer per token).
 *
 *         ## Snapshots (holders' pockets)
 *         When the Fund holds something NAV values at zero (a token with no market, a claim the router or an
 *         adapter cannot value), the teller moves it out to a pocket (`Pockets`) that belongs to the holders of
 *         that moment, so new shares never take a slice of it. `snapshot` (teller only) starts a new snapshot id;
 *         `balanceOfAt` answers what an account held when it was taken. Checkpoints are lazy, as in OpenZeppelin's
 *         former ERC20Snapshot: an account's balance is written once per snapshot, at its first move after it, as one
 *         entry of its own ordered list (`_checkpoints[account]`: the snapshot id and the balance, in one slot), so
 *         `balanceOfAt` finds it by binary search, whatever the number of snapshots anyone took. A move costs one
 *         extra read while no snapshot was ever taken (about 2.1k gas), about 44k for an account's first move after
 *         a snapshot (a new list entry), and about 4k after that.
 */
contract FundVault is ERC20, IFundVault {
    using SafeERC20 for IERC20;

    error NotController();
    error NotTeller();
    error AlreadyWired();
    error TooManyTokens();
    error ControllerBusy();

    /// @notice Most tokens the vault counts at once. A diversified stock Fund fits; a manager filling the
    ///         list with junk only blocks itself, and can untrack what it no longer holds.
    /// @dev    40: since deposits enter as cash (2026-10-02), a settlement reads the book and moves USDG, and the
    ///         heaviest paths are an exit in kind (one transfer per counted token, every adapter split) and the
    ///         reading itself. Sized on a fork with real tokens and venues (test/fork/SettlementGas.fork.t.sol,
    ///         docs/DEPOSITS-AND-EXITS.md, "Gas"), with `FundController.MAX_ADAPTERS` and the adapters' own caps.
    uint256 public constant MAX_TRACKED = 40;

    address public controller;
    address public teller;
    address private immutable _deployer;

    address[] private _tracked;
    mapping(address => bool) public isTracked;

    /// @notice See IFundVault: true once anyone other than the owner has held a share, or while someone other
    ///         than the owner has a deposit queued.
    bool public hadOutsideHolder;
    /// @notice See IFundVault: when the latch was last set.
    uint64 public outsideHolderSince;
    /// @dev True once a share actually reached someone other than the owner (the teller's custody aside). A
    ///      latch set this way is permanent; one set only for queued deposits can be undone.
    bool private _shareReachedOutsider;

    /// @notice The latest snapshot id (0: none taken yet). See "Snapshots".
    uint64 public currentSnapshotId;
    /// @dev Balance plus one at snapshot `id`, written at the account's first move after it.
    /// @dev An account's balance when snapshot `id` was taken, written at its first move after it.
    struct Checkpoint {
        uint48 id;
        uint208 balance;
    }

    /// @dev Per account, its checkpoints in snapshot order (for `balanceOfAt`'s binary search).
    mapping(address => Checkpoint[]) private _checkpoints;

    event Snapshot(uint256 indexed id);
    event Tracked(address indexed token);
    event Untracked(address indexed token);
    event Wired(address indexed controller, address indexed teller);
    event OutsideHolderLatched();
    event OutsideHolderUnlatched();

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _deployer = msg.sender;
    }

    /// @notice Set once by the factory that deployed this vault.
    function wire(address controller_, address teller_) external {
        if (msg.sender != _deployer || controller != address(0)) revert AlreadyWired();
        controller = controller_;
        teller = teller_;
        emit Wired(controller_, teller_);
    }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    modifier onlyTeller() {
        if (msg.sender != teller) revert NotTeller();
        if (IFundController(controller).isActing()) revert ControllerBusy();
        _;
    }

    function trackedTokens() external view returns (address[] memory) {
        return _tracked;
    }

    function approveFor(address token, address spender, uint256 amount) external onlyController {
        IERC20(token).forceApprove(spender, amount);
    }

    function track(address token) external {
        if (msg.sender != controller && msg.sender != teller) revert NotController();
        if (isTracked[token]) return;
        if (_tracked.length >= MAX_TRACKED) revert TooManyTokens();
        isTracked[token] = true;
        _tracked.push(token);
        emit Tracked(token);
    }

    /// @notice Controller, or the teller once it has sold or written off dust, stops counting `token`.
    function untrack(address token) external {
        if (msg.sender != controller && msg.sender != teller) revert NotController();
        if (!isTracked[token]) return;
        isTracked[token] = false;
        uint256 n = _tracked.length;
        for (uint256 i; i < n; ++i) {
            if (_tracked[i] == token) {
                _tracked[i] = _tracked[n - 1];
                _tracked.pop();
                break;
            }
        }
        emit Untracked(token);
    }

    /// @notice Teller only: start a snapshot for a holders' pocket; returns its id.
    function snapshot() external onlyTeller returns (uint256 id) {
        id = ++currentSnapshotId;
        emit Snapshot(id);
    }

    /// @notice What `account` held when snapshot `id` was taken (0 for an id not taken yet).
    /// @dev    The first checkpoint at or after `id` holds it: the account did not move between `id` and that
    ///         checkpoint's snapshot. With none, it has not moved since, so its balance now is the answer. Found by
    ///         binary search over the account's own checkpoints, so the cost grows with the log of how often it
    ///         moved, never with how many snapshots anyone took.
    function balanceOfAt(address account, uint256 id) external view returns (uint256) {
        if (id == 0 || id > currentSnapshotId) return 0;
        Checkpoint[] storage c = _checkpoints[account];
        uint256 lo;
        uint256 hi = c.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (c[mid].id < id) lo = mid + 1;
            else hi = mid;
        }
        if (lo == c.length) return balanceOf(account);
        return c[lo].balance;
    }

    function mint(address to, uint256 shares) external onlyTeller {
        _mint(to, shares);
    }

    function burn(address from, uint256 shares) external onlyTeller {
        _burn(from, shares);
    }

    function pay(address token, address to, uint256 amount) external onlyTeller {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Teller only: set the outside-holder latch before any share moves, because someone other than the
    ///         owner has queued a deposit. Queued depositors are holders in waiting, so from then on every change
    ///         that adds risk waits the controller's notice.
    function latchOutsideHolder() external onlyTeller {
        _latch();
    }

    /// @notice Teller only: every deposit that latched has been cancelled or paid back. Undoes the latch unless a
    ///         share ever reached someone other than the owner, so queuing and cancelling cannot latch a Fund
    ///         for good.
    function unlatchOutsideHolder() external onlyTeller {
        if (!hadOutsideHolder || _shareReachedOutsider) return;
        hadOutsideHolder = false;
        outsideHolderSince = 0;
        emit OutsideHolderUnlatched();
    }

    function _latch() private {
        if (hadOutsideHolder) return;
        hadOutsideHolder = true;
        outsideHolderSince = uint64(block.timestamp);
        emit OutsideHolderLatched();
    }

    /// @dev Latch the first time a share reaches anyone but the owner (a transfer, or a mint to someone else).
    ///      The owner's own shares (its opening deposit, minted to its wallet) never latch. Shares the teller holds
    ///      in custody (a batch's shares before depositors claim them; the first teller's opening stakes) do not
    ///      latch either: the teller latches through `latchOutsideHolder` when someone other than the
    ///      owner queues a deposit, which is earlier than any share reaches them.
    function _update(address from, address to, uint256 value) internal override {
        uint256 cur = currentSnapshotId;
        if (cur != 0) {
            if (from != address(0)) _checkpoint(from, cur);
            if (to != address(0) && to != from) _checkpoint(to, cur);
        }
        super._update(from, to, value);
        if (
            !_shareReachedOutsider && to != address(0) && value != 0 && to != teller
                && to != IFundController(controller).owner()
        ) {
            _shareReachedOutsider = true;
            _latch();
        }
    }

    /// @dev The account's balance at snapshot `cur`, before its first move after it.
    function _checkpoint(address account, uint256 cur) private {
        Checkpoint[] storage c = _checkpoints[account];
        uint256 n = c.length;
        if (n == 0 || c[n - 1].id != cur) c.push(Checkpoint(SafeCast.toUint48(cur), SafeCast.toUint208(balanceOf(account))));
    }
}
