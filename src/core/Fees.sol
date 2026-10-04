// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController} from "../interfaces/IFundController.sol";
import {Side} from "../interfaces/IPriceRouter.sol";

/**
 * @title  FeeConfig
 * @notice Who gets what of every Fund fee: the manager, $AIX holders and the AINDEX treasury. One shared contract;
 *         AINDEX (the admin) may change the split and the two AINDEX recipients at any time, and a change applies
 *         from the next accrual of each Fund. It cannot change a Fund's fee rates, only how they are shared.
 * @dev    The split is read at every accrual, never cached, so "from the next accrual" needs no bookkeeping. The
 *         plan suggests announcing a change a few days ahead off chain; managers size their effort on it.
 */
contract FeeConfig {
    error NotAdmin();
    error BadSplit();
    error ZeroAddress();

    event SplitSet(uint16 managerBps, uint16 aixBps, uint16 treasuryBps);
    event RecipientsSet(address indexed aixRecipient, address indexed treasury);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    uint16 private constant BPS = 10_000;

    address public admin;
    address public pendingAdmin;

    uint16 public managerBps = 7000;
    uint16 public aixBps = 1500;
    uint16 public treasuryBps = 1500;
    /// @notice Receives the $AIX holders' part (the daily payout contract).
    address public aixRecipient;
    address public treasury;

    constructor(address admin_, address aixRecipient_, address treasury_) {
        if (admin_ == address(0) || aixRecipient_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        admin = admin_;
        aixRecipient = aixRecipient_;
        treasury = treasury_;
        emit SplitSet(7000, 1500, 1500);
        emit RecipientsSet(aixRecipient_, treasury_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice Change the split; the three parts must add up to the whole fee.
    function setSplit(uint16 manager_, uint16 aix_, uint16 treasury_) external onlyAdmin {
        if (uint256(manager_) + aix_ + treasury_ != BPS) revert BadSplit();
        managerBps = manager_;
        aixBps = aix_;
        treasuryBps = treasury_;
        emit SplitSet(manager_, aix_, treasury_);
    }

    function setRecipients(address aixRecipient_, address treasury_) external onlyAdmin {
        if (aixRecipient_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        aixRecipient = aixRecipient_;
        treasury = treasury_;
        emit RecipientsSet(aixRecipient_, treasury_);
    }

    function split() external view returns (uint16, uint16, uint16, address, address) {
        return (managerBps, aixBps, treasuryBps, aixRecipient, treasury);
    }

    function transferAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminTransferStarted(admin, next);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}

/**
 * @title  FundFees
 * @notice Every Fund's fee terms, high-water mark and the manager's earned first-loss stake. Fees are taken as new
 *         shares (dilution), never as tokens out of the vault, so charging a fee never sells anything.
 *
 * @dev    ## Rates
 *         The Fund's owner sets a management fee (a year, at most `MAX_MANAGEMENT_BPS`, 2%) and a performance fee
 *         (at most `MAX_PERFORMANCE_BPS`, 20%, of the rise in NAV per share above the high-water mark). The maxima
 *         are constants, so no admin and no owner can exceed them. A higher rate waits `INCREASE_NOTICE` (30
 *         days) so holders can leave first; a lower rate applies at once. While nobody but the owner has ever
 *         held a share (the vault's latch) and the owner holds them all (in its wallet or the teller's custody),
 *         there is nobody to protect, so any change applies at once.
 *
 *         ## Accrual
 *         Only the teller accrues, at every settlement (and the management part at every in-kind exit, which
 *         needs no price). Until the Fund has an outside holder nothing is charged: the owner would only pay
 *         itself and AINDEX, and the clock and the mark simply follow the Fund. The management clock starts
 *         when the outside-holder latch is set (`IFundVault.outsideHolderSince`), not at the last accrual, so
 *         a long owner-only stretch is never charged at the first accrual after an outsider arrives.
 *         1. First loss: if NAV per share (bid, before this accrual's dilution) is below the mark, the locked
 *            stake is burned until NAV per share is back at the mark or the stake is gone. Holders lose nothing
 *            until the manager's earned stake has absorbed the fall.
 *         2. Management: `rate * elapsed / year` of the Fund, by minting `s * x / (1 - x)` shares, so the new
 *            shares are worth exactly x of the Fund afterwards.
 *         3. Performance: on NAV per share after management, above the mark, at the rate; minted the same way.
 *            The mark becomes NAV per share after both fees. A mark never falls.
 *         When the book is incomplete (a price unavailable) steps 1 and 3 wait for the next settlement.
 *
 *         ## Split and stake
 *         Fee shares are split by `FeeConfig` (manager / $AIX holders / treasury, 70 / 15 / 15 by default), read
 *         at each accrual. Half of the manager's performance shares stay here, locked for `LOCK` (7 days), as
 *         first-loss: burned pro rata (every lock loses the same fraction) when step 1 burns, released to the
 *         manager's recipient once unlocked. An accrual burns before it releases, and `release` (anyone, between
 *         accruals) refuses while NAV per share is below the mark or cannot be read: a lock that has served its time
 *         still absorbs a loss that is already there, so a manager cannot pull its stake out ahead of the burn.
 */
contract FundFees {
    using SafeERC20 for IERC20;

    error NotTeller();
    error NotOwner();
    error AlreadyWired();
    error OverMaximum();
    error ZeroAddress();
    error NotReady();

    event TermsProposed(address indexed vault, uint16 management, uint16 performance, uint64 effectiveAt);
    event TermsSet(address indexed vault, uint16 management, uint16 performance);
    event RecipientSet(address indexed vault, address indexed recipient);
    event Accrued(
        address indexed vault,
        uint256 managementShares,
        uint256 performanceShares,
        uint256 navPerShare,
        uint256 highWaterMark
    );
    event Locked(address indexed vault, address indexed to, uint256 shares, uint64 unlockAt);
    event Released(address indexed vault, address indexed to, uint256 shares);
    event FirstLossBurned(address indexed vault, uint256 shares, uint256 navPerShare, uint256 highWaterMark);

    uint16 public constant MAX_MANAGEMENT_BPS = 200;
    uint16 public constant MAX_PERFORMANCE_BPS = 2000;
    uint64 public constant INCREASE_NOTICE = 30 days;
    uint64 public constant LOCK = 7 days;
    /// @notice Most expired locks released inside one accrual; `release` takes any number.
    uint256 public constant RELEASE_PER_ACCRUAL = 8;
    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    struct Terms {
        uint16 management;
        uint16 performance;
        uint16 nextManagement;
        uint16 nextPerformance;
        uint64 nextAt; // 0 = nothing pending
        uint64 lastAccrual;
        address recipient; // the manager's part (the owner's choice; a session key should never be paid)
    }

    struct Lock {
        address to;
        uint64 unlockAt;
        uint256 units;
    }

    /// @dev Locks share one pot: each holds `units`, worth `units * shares / units` of the pot, so a first-loss
    ///      burn takes the same fraction of every lock without touching each one.
    struct Pot {
        uint256 shares;
        uint256 units;
        uint256 head; // first lock not yet released
        Lock[] list;
    }

    /// @notice What the teller mints and burns for one accrual.
    struct Accrual {
        address manager;
        uint256 managerShares;
        address aix;
        uint256 aixShares;
        address treasury;
        uint256 treasuryShares;
        uint256 lockedShares; // minted to this contract
        uint256 burnLocked; // burned from this contract
    }

    FeeConfig public immutable config;
    address public teller;
    address private immutable _deployer;

    mapping(address => Terms) private _terms;
    /// @notice USD per share (1e18) at bid that performance is measured from.
    mapping(address => uint256) public highWaterMark;
    mapping(address => Pot) private _pots;

    constructor(FeeConfig config_) {
        config = config_;
        _deployer = msg.sender;
    }

    /// @notice Set once by the deployer: the teller that accrues and mints.
    function wireTeller(address teller_) external {
        if (msg.sender != _deployer || teller != address(0)) revert AlreadyWired();
        if (teller_ == address(0)) revert ZeroAddress();
        teller = teller_;
    }

    modifier onlyTeller() {
        if (msg.sender != teller) revert NotTeller();
        _;
    }

    // ---------------------------------------------------------------- views

    function terms(address vault) external view returns (Terms memory) {
        return _terms[vault];
    }

    /// @notice Shares locked as the manager's first-loss stake, and how many locks are still held.
    function locked(address vault) external view returns (uint256 shares, uint256 openLocks) {
        Pot storage p = _pots[vault];
        return (p.shares, p.list.length - p.head);
    }

    function lockAt(address vault, uint256 i) external view returns (address to, uint64 unlockAt, uint256 shares) {
        Pot storage p = _pots[vault];
        Lock memory l = p.list[i];
        uint256 s = i < p.head || p.units == 0 ? 0 : l.units * p.shares / p.units;
        return (l.to, l.unlockAt, s);
    }

    // ---------------------------------------------------------------- the owner

    /**
     * @notice Set the Fund's rates. Lower parts apply now; higher parts wait `INCREASE_NOTICE`, replacing any
     *         earlier pending change. At once while nobody but the owner has held a share.
     */
    function setTerms(address vault, uint16 management, uint16 performance) external {
        _onlyOwner(vault);
        if (management > MAX_MANAGEMENT_BPS || performance > MAX_PERFORMANCE_BPS) revert OverMaximum();
        Terms storage t = _terms[vault];
        if (!_outsideHolders(vault)) {
            _setNow(vault, t, management, performance);
            return;
        }
        uint16 m = management < t.management ? management : t.management;
        uint16 p = performance < t.performance ? performance : t.performance;
        _setNow(vault, t, m, p);
        if (m != management || p != performance) {
            t.nextManagement = management;
            t.nextPerformance = performance;
            t.nextAt = uint64(block.timestamp) + INCREASE_NOTICE;
            emit TermsProposed(vault, management, performance, t.nextAt);
        }
    }

    /// @notice Anyone, once the notice has passed (accruals also apply it).
    function applyPendingTerms(address vault) external {
        Terms storage t = _terms[vault];
        if (t.nextAt == 0 || block.timestamp < t.nextAt) revert NotReady();
        _applyDue(vault, t);
    }

    function setRecipient(address vault, address recipient) external {
        _onlyOwner(vault);
        if (recipient == address(0)) revert ZeroAddress();
        _terms[vault].recipient = recipient;
        emit RecipientSet(vault, recipient);
    }

    /// @notice Release every lock that has served its time to its recipient (anyone may call), while NAV per share at
    ///         bid is at or above the mark (`NotReady` otherwise: the next accrual burns first).
    function release(address vault, uint256 max) external {
        uint256 hwm = highWaterMark[vault];
        if (hwm != 0 && _pots[vault].shares != 0) {
            (uint256 nav, bool ok) = IFundController(IFundVault(vault).controller()).nav(uint8(Side.Bid));
            uint256 s = IERC20(vault).totalSupply();
            if (!ok || s == 0 || nav * WAD / s < hwm) revert NotReady();
        }
        _release(vault, max);
    }

    // ---------------------------------------------------------------- the teller

    /// @notice A Fund opens: the clock starts, with the owner's first rates and its manager's recipient.
    function start(address vault, uint16 management, uint16 performance, address recipient) external onlyTeller {
        if (management > MAX_MANAGEMENT_BPS || performance > MAX_PERFORMANCE_BPS) revert OverMaximum();
        if (recipient == address(0)) revert ZeroAddress();
        Terms storage t = _terms[vault];
        t.management = management;
        t.performance = performance;
        t.nextAt = 0;
        t.lastAccrual = uint64(block.timestamp);
        t.recipient = recipient;
        highWaterMark[vault] = 0;
        emit TermsSet(vault, management, performance);
        emit RecipientSet(vault, recipient);
    }

    /**
     * @notice Fees since the last accrual, as shares for the teller to mint (and locked shares to burn).
     * @param  supply the vault's total supply now
     * @param  nav    NAV in USD (1e18) at bid; only used when `navOk`
     */
    function accrue(address vault, uint256 supply, uint256 nav, bool navOk)
        external
        onlyTeller
        returns (Accrual memory a)
    {
        Terms storage t = _terms[vault];
        uint256 dt = _elapsed(vault, t.lastAccrual);
        t.lastAccrual = uint64(block.timestamp);

        if (!_outsideHolders(vault)) {
            _release(vault, RELEASE_PER_ACCRUAL);
            if (navOk && supply != 0) highWaterMark[vault] = nav * WAD / supply;
            _applyDue(vault, t);
            return a;
        }

        uint256 hwm = highWaterMark[vault];
        uint256 s = supply;
        if (navOk && s != 0 && hwm != 0 && nav * WAD / s < hwm) {
            a.burnLocked = _firstLoss(vault, s, nav, hwm);
            s -= a.burnLocked;
        }
        // Burn first, then release: a lock that has served its time still absorbs a loss already there. With NAV
        // unknown nothing is released (a loss could be hiding).
        if (navOk) _release(vault, RELEASE_PER_ACCRUAL);

        uint256 mShares;
        if (t.management != 0 && dt != 0 && s != 0) {
            uint256 x = uint256(t.management) * dt * WAD / (BPS * YEAR);
            if (x > WAD / 2) x = WAD / 2;
            mShares = s * x / (WAD - x);
        }
        uint256 s1 = s + mShares;

        uint256 pShares;
        if (navOk && s1 != 0) {
            uint256 p1 = nav * WAD / s1;
            if (hwm == 0) {
                hwm = p1;
            } else if (p1 > hwm) {
                if (t.performance != 0) {
                    uint256 ff = uint256(t.performance) * (p1 - hwm) * WAD / (BPS * p1);
                    pShares = s1 * ff / (WAD - ff);
                }
                hwm = nav * WAD / (s1 + pShares);
            }
            highWaterMark[vault] = hwm;
        }

        _split(vault, t, a, mShares, pShares);
        emit Accrued(vault, mShares, pShares, s1 == 0 ? 0 : nav * WAD / s1, hwm);
        _applyDue(vault, t);
    }

    // ---------------------------------------------------------------- internals

    /// @dev The management clock runs from the later of the last accrual and the moment the Fund's outside-holder
    ///      latch was set: time the owner spent alone is never charged.
    function _elapsed(address vault, uint64 last) private view returns (uint256) {
        uint256 from = last;
        uint256 since = IFundVault(vault).outsideHolderSince();
        if (since > from) from = since;
        return block.timestamp - from;
    }

    /// @dev Burn locked shares until NAV per share is back at the mark, or the pot is empty.
    function _firstLoss(address vault, uint256 s, uint256 nav, uint256 hwm) private returns (uint256 burn) {
        Pot storage p = _pots[vault];
        if (p.shares == 0) return 0;
        uint256 atMark = Math.mulDiv(nav, WAD, hwm); // shares the Fund would have at the mark
        burn = s > atMark ? s - atMark : 0;
        if (burn > p.shares) burn = p.shares;
        if (burn == 0) return 0;
        p.shares -= burn;
        if (p.shares == 0) {
            // Every lock is worth nothing now; drop them so a new lock does not share an empty pot.
            p.units = 0;
            p.head = p.list.length;
        }
        emit FirstLossBurned(vault, burn, nav * WAD / s, hwm);
    }

    function _split(address vault, Terms storage t, Accrual memory a, uint256 mShares, uint256 pShares) private {
        uint256 total = mShares + pShares;
        if (total == 0) return;
        (uint16 mb, uint16 ab,, address aix, address tr) = config.split();
        a.manager = t.recipient;
        a.aix = aix;
        a.treasury = tr;
        a.managerShares = total * mb / BPS;
        a.aixShares = total * ab / BPS;
        a.treasuryShares = total - a.managerShares - a.aixShares;
        uint256 lock = pShares * mb / BPS / 2;
        if (lock > a.managerShares) lock = a.managerShares;
        if (lock != 0) {
            a.managerShares -= lock;
            a.lockedShares = lock;
            Pot storage p = _pots[vault];
            uint256 units = p.units == 0 ? lock : lock * p.units / p.shares;
            if (units == 0) units = 1;
            p.shares += lock;
            p.units += units;
            uint64 at = uint64(block.timestamp) + LOCK;
            p.list.push(Lock(t.recipient, at, units));
            emit Locked(vault, t.recipient, lock, at);
        }
    }

    function _release(address vault, uint256 max) private {
        Pot storage p = _pots[vault];
        uint256 n = p.list.length;
        for (uint256 k; k < max && p.head < n; ++k) {
            Lock memory l = p.list[p.head];
            if (l.unlockAt > block.timestamp) break;
            uint256 s = l.units == p.units ? p.shares : l.units * p.shares / p.units;
            p.shares -= s;
            p.units -= l.units;
            delete p.list[p.head];
            ++p.head;
            if (s != 0) IERC20(vault).safeTransfer(l.to, s);
            emit Released(vault, l.to, s);
        }
    }

    function _applyDue(address vault, Terms storage t) private {
        if (t.nextAt == 0 || block.timestamp < t.nextAt) return;
        uint16 m = t.nextManagement;
        uint16 p = t.nextPerformance;
        t.nextAt = 0;
        t.nextManagement = 0;
        t.nextPerformance = 0;
        t.management = m;
        t.performance = p;
        emit TermsSet(vault, m, p);
    }

    function _setNow(address vault, Terms storage t, uint16 m, uint16 p) private {
        t.management = m;
        t.performance = p;
        t.nextAt = 0;
        t.nextManagement = 0;
        t.nextPerformance = 0;
        emit TermsSet(vault, m, p);
    }

    /// @dev Someone other than the owner holds or has held a share: the vault's latch, or shares outside the
    ///      owner's wallet and the teller's custody (the dead shares, batches before claims). The balance check
    ///      covers an ownership handover, where the former owner's shares never moved and so never latched.
    ///      The same rule as the controller's `_noOutsideHolders`.
    function _outsideHolders(address vault) private view returns (bool) {
        if (IFundVault(vault).hadOutsideHolder()) return true;
        IERC20 v = IERC20(vault);
        address owner = IFundController(IFundVault(vault).controller()).owner();
        return v.totalSupply() != v.balanceOf(owner) + v.balanceOf(IFundVault(vault).teller());
    }

    function _onlyOwner(address vault) private view {
        if (IFundController(IFundVault(vault).controller()).owner() != msg.sender) revert NotOwner();
    }
}
