// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IPockets} from "../interfaces/IPockets.sol";

/// @notice The teller's record of shares it held in custody for request owners (`Teller.custodyAt`).
interface ICustody {
    function custodyAt(address vault, uint256 id, address account) external view returns (uint256);
}

/**
 * @title  Pockets
 * @notice Holders' pockets: what a Fund held that NAV values at zero (a token with no market price, a claim nobody
 *         can value), set aside for the holders of the moment it was set aside, so that new shares never take a
 *         slice of it. One contract for every Fund, keyed by vault and snapshot id.
 *
 * @dev    The teller opens a pocket (`TellerOps.pocket`): it takes a snapshot of the Fund's shares
 *         (`FundVault.snapshot`), moves the holding here and records `(vault, id, token, amount, supplyAt)`. Each
 *         account's part is `amount * balanceOfAt(account, id) / supplyAt`, paid in kind by `claim`, which anyone
 *         may call for any account (the tokens go to the account) and which never expires. A pocket can grow later:
 *         an adapter whose unvalued position can only be paid out over time (supply in a Morpho market nobody has
 *         reviewed, lent out today) drains into it (`topUp`), and every account's part grows with it; `claimed`
 *         remembers what each account already took.
 *
 *         Shares in the teller's custody at the snapshot (an opening stake, escrowed cash exits, shares a batch
 *         minted that are not claimed yet) belong to request owners, not to the teller: the teller records each
 *         custody once, when it ends (`Teller.custodyAt`: owner, shares, the snapshots it spanned), and a claim asks
 *         it for the account's part at that one snapshot. So no claim, cancel or stake release in the teller ever
 *         walks the snapshots taken meanwhile, however many there are. What the teller never records (its dead
 *         shares) stays here. Shares the Fund's fee contract holds as the manager's locked
 *         first-loss stake are an ordinary account: their part can be claimed to that contract, which cannot pass
 *         it on, so it stays there.
 *
 *         Accounting: `held[token]` is what this contract owes across every pocket; a pocket is credited only with
 *         what arrived for it, measured: `topUp` credits what its transfer brought, and the teller's `credit` what
 *         arrived since its `mark` in the same transaction. A balance that grows on its own (a positive rebase, a
 *         stock token's dividend multiplier) is nobody's credit: it stays here unassigned rather than going to
 *         whichever pocket is credited next, so nobody can capture other Funds' growth with a pocket of their own.
 *         Only the one teller wired at deployment (`wireTeller`) opens and credits, and only for a vault that
 *         names it as its teller: a vault is whatever address a caller passes, so a vault's own word is never enough
 *         (a contract posing as a vault could otherwise open a pocket and claim every Fund's tokens from `held`). What
 *         one pocket pays out never exceeds what arrived for it (`paidOut`).
 */
contract Pockets is IPockets, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error NotTeller();
    error NoPocket();
    error AlreadyOpen();
    error Short();
    error TellerAccount();
    error AlreadyWired();
    error NotMarked();

    struct Pocket {
        address token;
        uint64 openedAt;
        uint256 amount; // everything that arrived for it so far
        uint256 supplyAt; // the Fund's share supply at the snapshot
    }

    mapping(address => mapping(uint256 => Pocket)) private _pockets;
    mapping(address => uint256[]) private _ids;
    /// @notice What `account` already took from pocket (`vault`, `id`).
    mapping(address => mapping(uint256 => mapping(address => uint256))) public claimed;
    /// @notice What this contract owes in `token` across every pocket.
    mapping(address => uint256) public held;
    /// @notice What pocket (`vault`, `id`) has paid out in all; never more than its `amount`.
    mapping(address => mapping(uint256 => uint256)) public paidOut;

    /// @notice The public teller, the only one that opens and credits pockets (set once, `wireTeller`).
    address public teller;
    address private immutable _deployer;

    constructor() {
        _deployer = msg.sender;
    }

    /// @notice Set once by the deployer: the teller (it is built with this contract's address, so it comes after).
    function wireTeller(address teller_) external {
        if (msg.sender != _deployer || teller != address(0) || teller_ == address(0)) revert AlreadyWired();
        teller = teller_;
    }

    // ---------------------------------------------------------------- the teller

    modifier onlyTeller(address vault) {
        if (msg.sender != teller || IFundVault(vault).teller() != msg.sender) revert NotTeller();
        _;
    }

    /// @inheritdoc IPockets
    function open(address vault, uint256 id, address token, uint256 supplyAt) external onlyTeller(vault) {
        Pocket storage p = _pockets[vault][id];
        if (p.token != address(0) || token == address(0) || supplyAt == 0) revert AlreadyOpen();
        p.token = token;
        p.openedAt = uint64(block.timestamp);
        p.supplyAt = supplyAt;
        _ids[vault].push(id);
        emit PocketOpened(vault, id, token, supplyAt);
    }

    /// @inheritdoc IPockets
    function mark(address token) external {
        if (msg.sender != teller) revert NotTeller();
        uint256 s = _surplus(token);
        bytes32 slot = _markSlot(token);
        assembly ("memory-safe") {
            tstore(slot, add(s, 1))
        }
    }

    /// @inheritdoc IPockets
    function credit(address vault, uint256 id) external onlyTeller(vault) returns (uint256 amount) {
        Pocket storage p = _pockets[vault][id];
        if (p.token == address(0)) revert NoPocket();
        bytes32 slot = _markSlot(p.token);
        uint256 m;
        assembly ("memory-safe") {
            m := tload(slot)
            tstore(slot, 0)
        }
        if (m == 0) revert NotMarked();
        uint256 s = _surplus(p.token);
        amount = s > m - 1 ? s - (m - 1) : 0;
        _add(vault, id, p, amount);
    }

    // ---------------------------------------------------------------- anyone

    /// @inheritdoc IPockets
    function topUp(address vault, uint256 id, uint256 amount) external nonReentrant returns (uint256 got) {
        Pocket storage p = _pockets[vault][id];
        if (p.token == address(0)) revert NoPocket();
        if (amount == 0) return 0;
        uint256 before = IERC20(p.token).balanceOf(address(this));
        IERC20(p.token).safeTransferFrom(msg.sender, address(this), amount);
        got = IERC20(p.token).balanceOf(address(this)) - before;
        _add(vault, id, p, got);
    }

    /// @inheritdoc IPockets
    function claim(address vault, uint256 id, address account) external nonReentrant returns (uint256 paid) {
        if (account == IFundVault(vault).teller()) revert TellerAccount();
        Pocket storage p = _pockets[vault][id];
        if (p.token == address(0)) revert NoPocket();
        paid = _due(vault, id, p, account);
        if (paid == 0) return 0;
        uint256 out = paidOut[vault][id] + paid;
        if (out > p.amount) revert Short();
        paidOut[vault][id] = out;
        claimed[vault][id][account] += paid;
        held[p.token] -= paid;
        IERC20(p.token).safeTransfer(account, paid);
        emit Claimed(vault, id, account, p.token, paid);
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IPockets
    function pocket(address vault, uint256 id) external view returns (address token, uint256 amount, uint256 supplyAt) {
        Pocket storage p = _pockets[vault][id];
        return (p.token, p.amount, p.supplyAt);
    }

    /// @inheritdoc IPockets
    function pocketInfo(address vault, uint256 id)
        external
        view
        returns (address token, uint256 amount, uint256 supplyAt, uint64 openedAt)
    {
        Pocket storage p = _pockets[vault][id];
        return (p.token, p.amount, p.supplyAt, p.openedAt);
    }

    /// @inheritdoc IPockets
    function pocketIds(address vault) external view returns (uint256[] memory) {
        return _ids[vault];
    }

    /// @inheritdoc IPockets
    function due(address vault, uint256 id, address account) external view returns (uint256) {
        Pocket storage p = _pockets[vault][id];
        if (p.token == address(0) || account == IFundVault(vault).teller()) return 0;
        return _due(vault, id, p, account);
    }

    /// @inheritdoc IPockets
    function sharesAt(address vault, uint256 id, address account) public view returns (uint256) {
        return IFundVault(vault).balanceOfAt(account, id) + ICustody(teller).custodyAt(vault, id, account);
    }

    // ---------------------------------------------------------------- internals

    function _due(address vault, uint256 id, Pocket storage p, address account) private view returns (uint256) {
        uint256 total = p.amount * sharesAt(vault, id, account) / p.supplyAt;
        uint256 taken = claimed[vault][id][account];
        return total > taken ? total - taken : 0;
    }

    /// @dev What this contract holds of `token` beyond what it owes (0 if short).
    function _surplus(address token) private view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 owed = held[token];
        return bal > owed ? bal - owed : 0;
    }

    function _markSlot(address token) private pure returns (bytes32) {
        return keccak256(abi.encode("aindex.pockets.mark", token));
    }

    /// @dev Credit the pocket with `amount` that arrived for it (measured by the caller).
    function _add(address vault, uint256 id, Pocket storage p, uint256 amount) private {
        if (amount == 0) return;
        if (IERC20(p.token).balanceOf(address(this)) < held[p.token] + amount) revert Short();
        held[p.token] += amount;
        p.amount += amount;
        emit Credited(vault, id, p.token, amount);
    }
}
