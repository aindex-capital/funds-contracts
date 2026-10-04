// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAdapter, Amount} from "../interfaces/IAdapter.sol";
import {IPocketable, IPockets} from "../interfaces/IPockets.sol";
import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController, Dial} from "../interfaces/IFundController.sol";
import {IPriceRouter, PriceClass, Side} from "../interfaces/IPriceRouter.sol";
import {FundBook} from "./FundBook.sol";

/**
 * @title  FundController
 * @notice The only door to a Fund's money. Its manager (an AI session key or a person) acts through the
 *         Fund's adapters; the controller checks every action against the Fund's dial.
 *
 * @dev    ## Roles
 *         - owner: chooses the dial, the adapters, the manager and (with notice) the guardian. Two-step
 *           transfer, so a typo cannot lose the Fund.
 *         - manager: acts. Has an expiry (at most `MAX_MANAGER_TERM` ahead), so an agent's session key lapses
 *           on its own.
 *         - guardian (AINDEX): pauses the manager, revokes a manager, disables an adapter. Cannot move money
 *           or loosen anything. Only the guardian lifts its own pause. The guardian can hand its role on at
 *           once; the owner can replace it only after `RISK_NOTICE`, so a lost or rogue guardian key is
 *           recoverable but a rogue owner cannot silently remove the guard.
 *
 *         ## What every action passes
 *         1. NAV at bid prices before and after, both complete (every nonzero holding and debt priced, every
 *            adapter's `positions` readable). What the action cost counts against the loss budget:
 *            `dailyLossBps` of the NAV at the start of the UTC day (or of today's NAV plus today's losses, if
 *            lower), with yesterday's losses fading out over today so the budget cannot be spent twice across
 *            midnight. Prices are read inside the same transaction, so market moves never count against the
 *            manager; only what its own action did. This is only as honest as the price sources: a source an
 *            actor can move within a block would let it hide a loss, which is why sources are time-weighted
 *            or oracle feeds, never spot, and nothing they read can change between the two readings: a weekend
 *            pool qualifies on its window's liquidity and history, never on what a trade in the block can move,
 *            and the price recorder never counts the slot a `record` in the same transaction could finalise.
 *         2. After the action: caps per price class and per holding at fair prices, and, when the Fund owes
 *            anything, its health (assets at bid / debts at ask). A cap that is already breached (prices
 *            moved, the dial was tightened, someone donated) never blocks an action that does not add to the
 *            breach, so the manager can always reduce risk.
 *         3. Inputs are approved exactly for the one call (duplicates summed) and reset after, whether or not
 *            the adapter pulled them. Outputs land in the vault, which counts what the adapter declared.
 *         4. With `allowUnreviewed` off, the adapter's implementation is one AINDEX has verified in the
 *            registry. Checked at every action, not at enable time, so a review withdrawn later stops new
 *            actions at once; unwinding never checks it, so a Fund can always leave.
 *
 *         ## Reviews are badges, the dial makes them gates
 *         AINDEX reviews adapters (the registry's `verified`) and instruments inside them (the Morpho oracle
 *         registry). Those reviews never block a Fund by themselves: the owner's `allowUnreviewed` decides
 *         whether this Fund keeps to reviewed things. Turning it on is a risk increase like any other and
 *         waits the notice; turning it off is instant.
 *
 *         ## Raising risk waits, lowering it is instant
 *         A dial change, a new adapter or a new guardian applies after `RISK_NOTICE`, so holders who joined
 *         under the old terms can leave first. Parts of a dial change that lower risk apply at once. While
 *         nobody but the owner has ever held a share, there is nobody to protect, so changes apply at once.
 *
 *         ## Bounds that keep the book affordable
 *         The book (`FundBook`, a linked library) reads every tracked token and every adapter's positions,
 *         twice per action. The vault tracks at most `FundVault.MAX_TRACKED` tokens, a Fund lists at most
 *         `MAX_ADAPTERS` adapters (enabled or disabled), and each `positions` call gets at most
 *         `POSITIONS_GAS`. A teller settlement reads every adapter once and moves only USDG; an exit in kind
 *         reads every adapter before and after it splits each one (the teller passes what it saw to
 *         `noteDebt`). Sized on a fork at those maxima (test/fork/SettlementGas.fork.t.sol,
 *         docs/DEPOSITS-AND-EXITS.md, "Gas").
 *         A failing or gas-hungry adapter makes the book incomplete instead of reverting it, so the owner can
 *         disable and remove it.
 *
 *         ## What an adapter can reach
 *         Only its own Fund: it is called by this controller alone, the vault approves it exact amounts for
 *         one call, `positions` is a static call, and every other state-changing function here and in the
 *         vault is gated to the owner, manager, guardian, controller or teller. What an adapter reports in
 *         `positions` is trusted: an unverified adapter that misreports can hide a loss, which is why enabling
 *         one waits the notice and Fund pages label it.
 */
contract FundController is IFundController, ReentrancyGuardTransient {
    error NotOwner();
    error NotManager();
    error NotGuardian();
    error IsPaused();
    error UnknownAdapter();
    error NotReady();
    error LossBudget(uint256 loss, uint256 allowed);
    error OverCap(address token, uint256 valueUsd, uint256 capUsd);
    error ClassCap(uint8 class_, uint256 valueUsd, uint256 capUsd);
    error BorrowNotAllowed();
    error Unhealthy(uint256 healthBps, uint256 minBps);
    error PriceUnavailable();
    error BadDial();
    error TooManyAdapters();
    error StillEnabled();
    error AdapterOwes();
    error RetiredAdapter();
    error BadFraction();
    error BadTerm();
    error CannotUntrack();
    error BadPositions();
    error Unreviewed(address adapter);
    error NotTeller();
    error TellerBusy();
    /// @notice A leaver's slice of `adapter` is still to be paid out (an exit in kind in parts): its positions may
    ///         only change by `split` until every pending slice is claimed (`Teller.claimInKind`, anyone).
    error ExitPending(address adapter);

    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianProposed(address indexed guardian, uint64 effectiveAt);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event PauseSet(address indexed by, bool guardianPaused, bool ownerPaused);
    event PendingDialCancelled();
    event PendingAdapterCancelled(address indexed implementation, address instance);
    event PendingGuardianCancelled();
    event AdapterRemoved(address indexed instance, bool writtenOff);
    event Unwound(address indexed adapter, uint256 fractionWad, uint256 navBefore, uint256 navAfter);
    event Untracked(address indexed token);
    event TellerCalled(address indexed adapter, uint8 indexed kind, uint256 fractionWad, address to);
    event ExitUnits(address indexed adapter, uint256 owed, uint256 total);

    uint64 public constant RISK_NOTICE = 7 days;
    /// @notice Most adapters a Fund lists at once, enabled or disabled. Bounds the gas of every NAV reading and of
    ///         an exit in kind, which splits every adapter (see `FundVault.MAX_TRACKED`).
    uint256 public constant MAX_ADAPTERS = 12;
    /// @notice Gas each adapter's `positions` may use in one reading; more counts as a failed reading.
    uint256 public constant POSITIONS_GAS = FundBook.POSITIONS_GAS;
    /// @notice Longest a manager may be named for. A session key must lapse; a person renews yearly.
    uint64 public constant MAX_MANAGER_TERM = 366 days;
    /// @notice A priced holding worth less than this ($1) may be untracked; it frees a slot, costs nothing real.
    uint256 public constant DUST_USD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    IFundVault private immutable _vault;
    IAdapterRegistry public immutable registry;
    IPriceRouter public immutable router;
    /// @notice The Fund's cash and unit of account (USDG on Robinhood Chain).
    address public immutable baseAsset;

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public pendingGuardian;
    uint64 public pendingGuardianAt;

    address public manager;
    uint64 public managerExpiresAt;
    /// @notice Set and lifted by the guardian only.
    bool public guardianPaused;
    /// @notice Set and lifted by the owner.
    bool public ownerPaused;

    Dial private _dial;
    Dial public pendingDial;
    uint64 public pendingDialAt;

    address[] private _adapters; // enabled and disabled; disabled ones still hold positions
    /// @notice Enabled for new actions.
    mapping(address => bool) public isAdapter;
    /// @notice In the Fund's book (enabled or disabled, not yet removed).
    mapping(address => bool) public isListed;
    mapping(address => uint64) public disabledAt;
    /// @notice True once an adapter reported a debt after any call into it: the manager's actions, an unwind,
    ///         and the teller's grow, split and unwind (the teller measures those and calls `noteDebt`). Such an
    ///         adapter is only removed when it can show it owes nothing.
    mapping(address => bool) public everOwed;

    struct PendingAdapter {
        address instance;
        uint64 effectiveAt;
    }

    mapping(address => PendingAdapter) public pendingAdapter; // by implementation

    /// @notice Per adapter, leavers' slices not yet paid out (an exit in kind in parts). The adapter's positions
    ///         count as `total` units, of which `owed` belong to leavers, not to the Fund: the book counts only
    ///         `(total - owed) / total` of them. `total` is 0 while nothing is owed (then the Fund owns all).
    struct Units {
        uint128 total;
        uint128 owed;
    }

    mapping(address => Units) private _units;
    /// @notice Adapters with a leaver's slice still to be paid out; while 0, the book scales nothing.
    uint256 public pendingExits;

    // Loss budget, per UTC day.
    uint64 public windowDay;
    uint256 public windowStartNav;
    uint256 public windowLoss;
    /// @notice Yesterday's losses; they fade out linearly over today.
    uint256 public prevWindowLoss;

    constructor(
        IFundVault vault_,
        IAdapterRegistry registry_,
        IPriceRouter router_,
        address guardian_,
        address owner_,
        address baseAsset_,
        Dial memory dial_
    ) {
        _vault = vault_;
        baseAsset = baseAsset_;
        registry = registry_;
        router = router_;
        guardian = guardian_;
        owner = owner_;
        _checkDial(dial_);
        _dial = dial_;
        emit DialApplied(dial_);
    }

    // ---------------------------------------------------------------- views

    function vault() external view returns (address) {
        return address(_vault);
    }

    function dial() external view returns (Dial memory) {
        return _dial;
    }

    function adapters() external view returns (address[] memory) {
        return _adapters;
    }

    function paused() public view returns (bool) {
        return guardianPaused || ownerPaused;
    }

    function isActing() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @notice The Fund's part of `adapter`'s positions as `fund` of `total` (1 of 1 when nothing is owed to
    ///         leavers). See `Units`.
    function unitsOf(address adapter) public view returns (uint256 fund, uint256 total) {
        Units memory u = _units[adapter];
        if (u.owed == 0) return (1, 1);
        return (u.total - u.owed, u.total);
    }

    function nav(uint8 side) external view returns (uint256 usd, bool complete) {
        FundBook.Book memory b = _read(Side(side));
        return (_net(b), b.complete);
    }

    function navReport(uint8 side)
        external
        view
        returns (uint256 usd, bool complete, address[] memory unpriced, address[] memory failedAdapters)
    {
        FundBook.Book memory b = _read(Side(side));
        unpriced = b.unpriced;
        failedAdapters = b.failed;
        uint256 n = b.nUnpriced;
        uint256 m = b.nFailed;
        assembly {
            mstore(unpriced, n)
            mstore(failedAdapters, m)
        }
        return (_net(b), b.complete, unpriced, failedAdapters);
    }

    // ---------------------------------------------------------------- the manager

    function act(address adapter, bytes calldata action) external nonReentrant returns (bytes memory result) {
        _onlyManager();
        _tellerIdle();
        if (paused()) revert IsPaused();
        if (!isAdapter[adapter]) revert UnknownAdapter();
        _noExit(adapter);
        if (!_dial.allowUnreviewed && !registry.entry(registry.implementationOf(adapter)).verified) {
            revert Unreviewed(adapter);
        }

        (FundBook.Book memory pre, uint256 navBefore) = _open();

        // Count every token the action may return, then approve exactly its inputs for this one call.
        address[] memory outs = IAdapter(adapter).outputs(action);
        for (uint256 i; i < outs.length; ++i) _vault.track(outs[i]);
        Amount[] memory ins = _approve(adapter, IAdapter(adapter).inputs(action));

        result = IAdapter(adapter).execute(action);

        // Reset even when the adapter pulled less (or nothing): nothing stays approved between calls.
        _reset(adapter, ins);

        (FundBook.Book memory post, uint256 navAfter) = _close(navBefore);
        _checkExposure(pre, post);
        if (post.debtRows != 0 && !everOwed[adapter]) _noteDebt(adapter);
        emit Acted(adapter, action, navBefore, navAfter);
    }

    /**
     * @notice Turn `fractionWad` of an adapter's positions back into tokens in the vault. Works on disabled
     *         adapters too, which is how a Fund leaves an adapter it no longer trusts. The manager may call it
     *         while not paused; the owner may call it unless the guardian has paused the Fund.
     * @dev    Charged to the loss budget like any action. Caps are not checked: an unwind turns a position
     *         into the tokens it was already counted as, so it cannot add exposure, and it must work exactly
     *         when caps are already breached.
     */
    function unwindAdapter(address instance, uint256 fractionWad)
        external
        nonReentrant
        returns (Amount[] memory received)
    {
        bool byManager = msg.sender == manager && block.timestamp <= managerExpiresAt;
        if (!byManager && msg.sender != owner) revert NotManager();
        _tellerIdle();
        if (guardianPaused || (msg.sender != owner && ownerPaused)) revert IsPaused();
        if (!isListed[instance]) revert UnknownAdapter();
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        _noExit(instance);

        (, uint256 navBefore) = _open();

        // Count what the position is made of, so what comes back is counted.
        (, Amount[] memory held,) = FundBook.positionsOf(instance, router);
        _trackAll(held);
        Amount[] memory ins = _approve(instance, IAdapter(instance).unwindInputs(fractionWad));
        received = IAdapter(instance).unwind(fractionWad);
        _reset(instance, ins);
        _trackAll(received);
        if (!everOwed[instance]) _noteDebt(instance);

        (, uint256 navAfter) = _close(navBefore);
        emit Unwound(instance, fractionWad, navBefore, navAfter);
    }

    /**
     * @notice Stop counting a token the vault holds none of, or less than `DUST_USD` of at a fair price.
     *         Keeps the tracked list from filling up with tokens the Fund passed through. A token that cannot
     *         be priced is only untracked at a zero balance, so a holder never loses an in-kind claim on it.
     */
    function untrack(address token) external nonReentrant {
        bool byManager = msg.sender == manager && block.timestamp <= managerExpiresAt;
        if (!byManager && msg.sender != owner) revert NotManager();
        _tellerIdle();
        if (token == baseAsset || !_vault.isTracked(token)) revert CannotUntrack();
        uint256 bal = IERC20(token).balanceOf(address(_vault));
        if (bal != 0) {
            (uint256 usd, PriceClass c, bool ok) = FundBook.valueOf(router, token, bal, Side.Fair);
            if (!ok || c == PriceClass.None || usd >= DUST_USD) revert CannotUntrack();
        }
        _vault.untrack(token);
        emit Untracked(token);
    }

    // ---------------------------------------------------------------- the teller

    /**
     * @notice Teller only: `grow(0)` on an enabled adapter, which collects what it has earned (liquidity fees) into
     *         the vault and changes no position, before an exit in kind reads the Fund (so a leaver takes its
     *         slice of the fees, not all of them). Deposits enter as cash, so the teller never grows an adapter.
     */
    function collectFor(address adapter) external nonReentrant {
        _onlyTeller();
        if (!isAdapter[adapter]) revert UnknownAdapter();
        Amount[] memory ins = _approve(adapter, IAdapter(adapter).growInputs(0));
        IAdapter(adapter).grow(0);
        _reset(adapter, ins);
        emit TellerCalled(adapter, 0, 0, address(0));
    }

    /**
     * @notice Teller only: set aside `fractionWad` of the Fund's part of `adapter` for a leaver (an exit in kind).
     *         From now on the book no longer counts it, and the adapter's positions may change only by `split`
     *         until every slice set aside is paid out (`splitUnitsFor`) or handed back (`releaseUnits`).
     * @return units the slice, in the adapter's units (see `Units`); 0 when too small to count.
     */
    function reserveFor(address adapter, uint256 fractionWad) external nonReentrant returns (uint256 units) {
        _onlyTeller();
        if (!isListed[adapter]) revert UnknownAdapter();
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        Units memory u = _units[adapter];
        if (u.owed == 0) u.total = uint128(WAD);
        units = Math.mulDiv(u.total - u.owed, fractionWad, WAD);
        if (units == 0) return 0;
        if (u.owed == 0) ++pendingExits;
        u.owed += uint128(units);
        _units[adapter] = u;
        emit ExitUnits(adapter, u.owed, u.total);
    }

    /**
     * @notice Teller only: pay out a slice set aside by `reserveFor`: `split` the adapter by `units` over its total
     *         (rounded down, so the leaver never takes more than its slice) to `to`, repaying the slice's debt from
     *         the vault through `unwindInputs` (the teller has put the leaver's escrow there). Works on disabled
     *         adapters too: leaving must always work.
     * @return sent        what the adapter says it sent
     * @return fractionWad the fraction of the adapter's positions split off
     */
    function splitUnitsFor(address adapter, uint256 units, address to)
        external
        nonReentrant
        returns (Amount[] memory sent, uint256 fractionWad)
    {
        _onlyTeller();
        if (!isListed[adapter]) revert UnknownAdapter();
        Units memory u = _units[adapter];
        if (units == 0 || units > u.owed) revert BadFraction();
        fractionWad = units * WAD / u.total;
        if (fractionWad != 0) {
            Amount[] memory ins = _approve(adapter, IAdapter(adapter).unwindInputs(fractionWad));
            sent = IAdapter(adapter).split(fractionWad, to);
            _reset(adapter, ins);
        }
        _drop(adapter, u, units, units);
        emit TellerCalled(adapter, 1, fractionWad, to);
    }

    /// @notice Teller only: a slice set aside that will not be paid out (its leaver gave it up, or it could not be
    ///         split for a week) goes back to the Fund.
    function releaseUnits(address adapter, uint256 units) external nonReentrant {
        _onlyTeller();
        Units memory u = _units[adapter];
        if (units > u.owed) revert BadFraction();
        _drop(adapter, u, units, 0);
    }

    /**
     * @notice Teller only: turn `fractionWad` of `adapter`'s positions into tokens in the vault, when a holders'
     *         pocket takes a no-market token out of an adapter that holds it. Debt is repaid from the vault first.
     *         Not charged to the loss budget: the teller measures the Fund's NAV around it instead.
     */
    function unwindFor(address adapter, uint256 fractionWad) external nonReentrant returns (Amount[] memory received) {
        _onlyTeller();
        if (!isListed[adapter]) revert UnknownAdapter();
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        _noExit(adapter);
        Amount[] memory ins = _approve(adapter, IAdapter(adapter).unwindInputs(fractionWad));
        received = IAdapter(adapter).unwind(fractionWad);
        _reset(adapter, ins);
        emit TellerCalled(adapter, 2, fractionWad, address(0));
    }

    /**
     * @notice Teller only: an adapter that implements `IPocketable` moves its unvalued positions in `token` (what
     *         NAV counts as zero) into pocket `id`. Works on disabled adapters too. Nothing is approved: the adapter
     *         pays the pocket from its own positions.
     */
    function pocketFor(address adapter, address token, address pockets, uint256 id)
        external
        nonReentrant
        returns (uint256 paid)
    {
        _onlyTeller();
        if (!isListed[adapter]) revert UnknownAdapter();
        _noExit(adapter);
        paid = IPocketable(adapter).pocket(token, IPockets(pockets), id);
        emit TellerCalled(adapter, 3, 0, pockets);
    }

    /**
     * @notice Teller only: after it split or unwound `adapter` and measured it, for each adapter that
     *         reported a debt (or could not be measured). Leaves the `everOwed` mark when the adapter reports a
     *         debt now, read here, so the mark never rests on the teller's word. Once marked, nothing is read.
     */
    function noteDebt(address adapter) external nonReentrant {
        _onlyTeller();
        if (isListed[adapter] && !everOwed[adapter]) _noteDebt(adapter);
    }

    // ---------------------------------------------------------------- the owner

    function setManager(address manager_, uint64 expiresAt) external nonReentrant {
        _onlyOwner();
        if (expiresAt > block.timestamp + MAX_MANAGER_TERM) revert BadTerm();
        manager = manager_;
        managerExpiresAt = expiresAt;
        emit ManagerSet(manager_, expiresAt);
    }

    /**
     * @notice Change the dial. The parts that lower risk apply now; the rest after RISK_NOTICE. The latest
     *         proposal replaces any earlier pending one. A change that only lowers risk leaves nothing pending.
     */
    function setDial(Dial calldata next) external nonReentrant {
        _onlyOwner();
        _checkDial(next);
        Dial memory safer = _safer(_dial, next);
        if (_noOutsideHolders() || _same(safer, next)) {
            _applyDial(next);
            _clearPendingDial();
            return;
        }
        _applyDial(safer);
        pendingDial = next;
        pendingDialAt = uint64(block.timestamp) + RISK_NOTICE;
        emit DialProposed(next, pendingDialAt);
    }

    function applyPendingDial() external nonReentrant {
        if (pendingDialAt == 0 || block.timestamp < pendingDialAt) revert NotReady();
        Dial memory next = pendingDial;
        delete pendingDial;
        pendingDialAt = 0;
        _applyDial(next);
    }

    function cancelPendingDial() external nonReentrant {
        _onlyOwner();
        _clearPendingDial();
    }

    /// @notice Enable an adapter: a fresh clone for this Fund. Adds risk, so it waits RISK_NOTICE unless nobody
    ///         but the owner has ever held a share.
    function addAdapter(address implementation, bytes calldata config)
        external
        nonReentrant
        returns (address instance)
    {
        _onlyOwner();
        instance = registry.instantiate(implementation, address(_vault), config);
        if (_noOutsideHolders()) {
            _enable(implementation, instance);
        } else {
            uint64 at = uint64(block.timestamp) + RISK_NOTICE;
            pendingAdapter[implementation] = PendingAdapter(instance, at);
            emit AdapterProposed(implementation, instance, at);
        }
    }

    /// @notice Anyone, once the notice has passed. Refuses an implementation the registry retired meanwhile,
    ///         so a review that finds a problem during the notice stops it.
    function enablePendingAdapter(address implementation) external nonReentrant {
        PendingAdapter memory p = pendingAdapter[implementation];
        if (p.instance == address(0) || block.timestamp < p.effectiveAt) revert NotReady();
        if (registry.entry(implementation).retired) revert RetiredAdapter();
        delete pendingAdapter[implementation];
        _enable(implementation, p.instance);
    }

    function cancelPendingAdapter(address implementation) external nonReentrant {
        _onlyOwner();
        PendingAdapter memory p = pendingAdapter[implementation];
        if (p.instance == address(0)) revert NotReady();
        delete pendingAdapter[implementation];
        emit PendingAdapterCancelled(implementation, p.instance);
    }

    /// @notice Stop using an adapter for new actions. Its positions stay counted and can be unwound.
    ///         Lowers risk, so it applies at once (owner or guardian).
    function disableAdapter(address instance) external nonReentrant {
        if (msg.sender != owner && msg.sender != guardian) revert NotOwner();
        if (!isAdapter[instance]) revert UnknownAdapter();
        isAdapter[instance] = false;
        disabledAt[instance] = uint64(block.timestamp);
        emit AdapterDisabled(instance);
    }

    /**
     * @notice Take a disabled adapter out of the book, freeing its slot.
     * @dev    At once when it reports nothing held and nothing owed. Otherwise this writes its positions off
     *         (NAV drops by what it held), which is allowed only `RISK_NOTICE` after it was disabled (or at
     *         once while nobody but the owner has held a share): that is the way out for an adapter whose
     *         positions are stuck or whose `positions` call fails for good. An adapter that reports a debt is
     *         never removed: hiding a debt would raise NAV. Nor is one that ever reported a debt and cannot be
     *         read now: only a readable report of no debt proves the debt is gone.
     */
    function removeAdapter(address instance) external nonReentrant {
        _onlyOwner();
        if (!isListed[instance]) revert UnknownAdapter();
        if (isAdapter[instance]) revert StillEnabled();
        _noExit(instance);
        (bool ok, Amount[] memory held, Amount[] memory owed) = FundBook.positionsOf(instance, router);
        if (!ok && everOwed[instance]) revert AdapterOwes();
        bool empty = ok;
        if (ok) {
            for (uint256 i; i < owed.length; ++i) {
                if (owed[i].amount != 0) revert AdapterOwes();
            }
            for (uint256 i; i < held.length; ++i) {
                if (held[i].amount != 0) empty = false;
            }
        }
        if (!empty && !_noOutsideHolders() && block.timestamp < disabledAt[instance] + RISK_NOTICE) {
            revert NotReady();
        }
        isListed[instance] = false;
        delete disabledAt[instance];
        uint256 n = _adapters.length;
        for (uint256 i; i < n; ++i) {
            if (_adapters[i] == instance) {
                _adapters[i] = _adapters[n - 1];
                _adapters.pop();
                break;
            }
        }
        emit AdapterRemoved(instance, !empty);
    }

    /// @notice Pause or unpause the manager. The guardian's pause and the owner's pause are separate: each
    ///         lifts only its own, so an owner cannot undo an emergency pause by AINDEX.
    function setPaused(bool p) external nonReentrant {
        if (msg.sender == guardian) guardianPaused = p;
        else if (msg.sender == owner) ownerPaused = p;
        else revert NotGuardian();
        emit Paused(paused());
        emit PauseSet(msg.sender, guardianPaused, ownerPaused);
    }

    function revokeManager() external nonReentrant {
        if (msg.sender != guardian && msg.sender != owner) revert NotGuardian();
        manager = address(0);
        managerExpiresAt = 0;
        emit ManagerSet(address(0), 0);
    }

    /// @notice Start a two-step ownership transfer; `next` must accept.
    function transferOwnership(address next) external nonReentrant {
        _onlyOwner();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /**
     * @notice Replace the guardian. The guardian may hand its role on at once (key rotation). The owner may
     *         replace it after RISK_NOTICE (at once while nobody but the owner has held a share), which is
     *         the recovery path for a lost or rogue guardian key; holders see it coming.
     */
    function transferGuardian(address next) external nonReentrant {
        if (msg.sender == guardian) {
            _setGuardian(next);
        } else if (msg.sender == owner) {
            if (_noOutsideHolders()) {
                _setGuardian(next);
            } else {
                pendingGuardian = next;
                pendingGuardianAt = uint64(block.timestamp) + RISK_NOTICE;
                emit GuardianProposed(next, pendingGuardianAt);
            }
        } else {
            revert NotGuardian();
        }
    }

    function applyPendingGuardian() external nonReentrant {
        if (pendingGuardianAt == 0 || block.timestamp < pendingGuardianAt) revert NotReady();
        _setGuardian(pendingGuardian);
    }

    function cancelPendingGuardian() external nonReentrant {
        _onlyOwner();
        if (pendingGuardianAt == 0) revert NotReady();
        pendingGuardian = address(0);
        pendingGuardianAt = 0;
        emit PendingGuardianCancelled();
    }

    /// @notice Decode an adapter's `positions` return data. External so the book can call it under try/catch:
    ///         an adapter returning malformed data then marks the book incomplete instead of reverting it.
    function decodePositions(bytes calldata data) external pure returns (Amount[] memory, Amount[] memory) {
        return abi.decode(data, (Amount[], Amount[]));
    }

    // ---------------------------------------------------------------- internals

    /// @dev Remember an adapter that owes after a call into it, for `removeAdapter`. An adapter that cannot be
    ///      read now leaves no mark; while it stays unreadable it shows no debt either, and once readable again
    ///      `removeAdapter` sees any debt it reports.
    function _noteDebt(address adapter) private {
        (bool ok,, Amount[] memory owed) = FundBook.positionsOf(adapter, router);
        for (uint256 i; ok && i < owed.length; ++i) {
            if (owed[i].amount != 0) {
                everOwed[adapter] = true;
                return;
            }
        }
    }

    /// @dev Nothing but a `split` may change an adapter while a leaver's slice of it waits to be paid out.
    function _noExit(address adapter) private view {
        if (_units[adapter].owed != 0) revert ExitPending(adapter);
    }

    /// @dev `units` leave the adapter's total (`gone`, paid out) or only the leavers' part (handed back).
    function _drop(address adapter, Units memory u, uint256 owedLess, uint256 gone) private {
        u.owed -= uint128(owedLess);
        u.total -= uint128(gone);
        if (u.owed == 0) {
            u.total = 0;
            --pendingExits;
        }
        _units[adapter] = u;
        emit ExitUnits(adapter, u.owed, u.total);
    }

    /// @dev The manager and the owner may not act while the Fund's teller is inside one of its calls (a deposit
    ///      or an exit between its plan and its measurement, reached through a token's transfer hook).
    function _tellerIdle() private view {
        (bool ok, bytes memory ret) = _vault.teller().staticcall(abi.encodeWithSignature("busy()"));
        if (ok && ret.length >= 32 && abi.decode(ret, (uint256)) != 0) revert TellerBusy();
    }

    /// @dev The first half of every action: a complete bid book, and the loss window rolled.
    function _open() private returns (FundBook.Book memory pre, uint256 navBefore) {
        pre = _read(Side.Bid);
        if (!pre.complete) revert PriceUnavailable();
        navBefore = _net(pre);
        _rollWindow(navBefore);
    }

    /// @dev The second half: a complete bid book again, and what the action cost charged to the budget.
    function _close(uint256 navBefore) private returns (FundBook.Book memory post, uint256 navAfter) {
        post = _read(Side.Bid);
        if (!post.complete) revert PriceUnavailable();
        navAfter = _net(post);
        _chargeLoss(navBefore, navAfter);
    }

    function _approve(address spender, Amount[] memory raw) private returns (Amount[] memory ins) {
        ins = _merge(raw);
        for (uint256 i; i < ins.length; ++i) _vault.approveFor(ins[i].token, spender, ins[i].amount);
    }

    function _reset(address spender, Amount[] memory ins) private {
        for (uint256 i; i < ins.length; ++i) _vault.approveFor(ins[i].token, spender, 0);
    }

    function _trackAll(Amount[] memory a) private {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].amount != 0) _vault.track(a[i].token);
        }
    }

    function _read(Side side) private view returns (FundBook.Book memory) {
        return FundBook.read(_vault, _adapters, router, side, _scales());
    }

    /// @dev Per listed adapter, the Fund's part of its positions (`unitsOf`); empty while nothing is owed.
    function _scales() private view returns (uint256[2][] memory sc) {
        if (pendingExits == 0) return sc;
        uint256 n = _adapters.length;
        sc = new uint256[2][](n);
        for (uint256 i; i < n; ++i) {
            (sc[i][0], sc[i][1]) = unitsOf(_adapters[i]);
        }
    }

    function _net(FundBook.Book memory b) private pure returns (uint256) {
        return b.assets > b.debts ? b.assets - b.debts : 0;
    }

    /// @dev A token's amount and fair value in a book (zero when absent).
    function _row(FundBook.Book memory b, address token) private pure returns (uint256 amount, uint256 fairUsd) {
        for (uint256 i; i < b.rows; ++i) {
            if (b.tokens[i] == token) return (b.amounts[i], b.fair[i]);
        }
    }

    /// @dev Every cap holds after the action, or the action did not add to a cap that was already breached.
    function _checkExposure(FundBook.Book memory pre, FundBook.Book memory post) private view {
        Dial memory d = _dial;
        uint256 nav_ = post.fairAssets > post.fairDebts ? post.fairAssets - post.fairDebts : 0;

        for (uint256 i; i < post.rows; ++i) {
            address t = post.tokens[i];
            (uint256 preAmount, uint256 preFair) = _row(pre, t);
            // No-market tokens are worth zero, so a cap in value cannot see them; with a 0 cap, any holding
            // breaks it unless the action did not add to it (so a donated or leftover crumb never blocks).
            if (post.classes[i] == PriceClass.None) {
                if (d.maxNoMarketBps == 0 && post.amounts[i] > preAmount) {
                    revert ClassCap(uint8(PriceClass.None), 1, 0);
                }
                continue;
            }
            // Cash in the Fund's base asset is never capped: a Fund may always sit in cash.
            if (d.maxPerTokenBps < BPS && t != baseAsset) {
                uint256 cap = nav_ * d.maxPerTokenBps / BPS;
                if (post.fair[i] > cap && post.fair[i] > preFair) revert OverCap(t, post.fair[i], cap);
            }
        }
        _classCap(PriceClass.Thin, post, pre, nav_, d.maxThinBps);
        _classCap(PriceClass.Pool, post, pre, nav_, d.maxPoolBps);

        if (post.debts > 0) {
            if (!d.allowBorrow && post.debts > pre.debts) revert BorrowNotAllowed();
            uint256 minHealth = d.minHealthBps > BPS ? d.minHealthBps : BPS;
            uint256 health = post.assets * BPS / post.debts;
            if (health < minHealth) {
                uint256 before = pre.debts == 0 ? type(uint256).max : pre.assets * BPS / pre.debts;
                if (health < before) revert Unhealthy(health, minHealth);
            }
        }
    }

    function _classCap(PriceClass c, FundBook.Book memory post, FundBook.Book memory pre, uint256 nav_, uint16 capBps) private pure {
        if (capBps >= BPS) return;
        uint256 v = post.byClass[uint8(c)];
        uint256 cap = nav_ * capBps / BPS;
        if (v > cap && v > pre.byClass[uint8(c)]) revert ClassCap(uint8(c), v, cap);
    }

    function _rollWindow(uint256 navNow) private {
        uint64 day = uint64(block.timestamp / 1 days);
        if (day != windowDay) {
            prevWindowLoss = day == windowDay + 1 ? windowLoss : 0;
            windowDay = day;
            windowStartNav = navNow;
            windowLoss = 0;
        } else if (windowStartNav == 0) {
            // The day started with nothing to lose (an empty Fund): measure from the first real NAV instead
            // of leaving a zero budget for the rest of the day.
            windowStartNav = navNow;
        }
    }

    /// @dev Used: today's losses plus yesterday's fading out over today. Allowed: the daily share of the
    ///      smaller of the day's opening NAV and today's NAV plus today's losses, so money leaving the Fund
    ///      (redemptions) shrinks the budget and money arriving never grows it.
    function _budget(uint256 navNow) private view returns (uint256 used, uint256 allowed) {
        uint256 ref = windowStartNav;
        if (navNow + windowLoss < ref) ref = navNow + windowLoss;
        allowed = ref * _dial.dailyLossBps / BPS;
        used = windowLoss + prevWindowLoss * (1 days - block.timestamp % 1 days) / 1 days;
    }

    function _chargeLoss(uint256 navBefore, uint256 navAfter) private {
        if (navAfter >= navBefore) return;
        uint256 loss = navBefore - navAfter;
        (uint256 used, uint256 allowed) = _budget(navBefore);
        if (used + loss > allowed) revert LossBudget(used + loss, allowed);
        windowLoss += loss;
    }

    /// @dev Sum duplicate inputs so an adapter that lists a token twice is approved the total, not the last.
    function _merge(Amount[] memory ins) private pure returns (Amount[] memory out) {
        out = new Amount[](ins.length);
        uint256 n;
        for (uint256 i; i < ins.length; ++i) {
            bool found;
            for (uint256 k; k < n; ++k) {
                if (out[k].token == ins[i].token) {
                    out[k].amount += ins[i].amount;
                    found = true;
                    break;
                }
            }
            if (!found) out[n++] = ins[i];
        }
        assembly {
            mstore(out, n)
        }
    }

    function _enable(address implementation, address instance) private {
        if (_adapters.length >= MAX_ADAPTERS) revert TooManyAdapters();
        _adapters.push(instance);
        isAdapter[instance] = true;
        isListed[instance] = true;
        emit AdapterEnabled(implementation, instance);
    }

    function _applyDial(Dial memory d) private {
        _dial = d;
        emit DialApplied(d);
    }

    function _clearPendingDial() private {
        if (pendingDialAt == 0) return;
        delete pendingDial;
        pendingDialAt = 0;
        emit PendingDialCancelled();
    }

    function _setGuardian(address next) private {
        emit GuardianSet(guardian, next);
        guardian = next;
        pendingGuardian = address(0);
        pendingGuardianAt = 0;
    }

    function _onlyOwner() private view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _onlyTeller() private view {
        if (msg.sender != _vault.teller()) revert NotTeller();
    }

    function _onlyManager() private view {
        if (msg.sender != manager || block.timestamp > managerExpiresAt) revert NotManager();
    }

    /// @dev Nobody to protect: no one but the owner has ever held a share, and the owner holds them all (in
    ///      the wallet, or in the teller's custody: the opening stake). The vault's latch means shares handed
    ///      back to the owner do not reopen the shortcut. The public teller latches as soon as someone other
    ///      than the owner queues a deposit, so queued depositors count as holders before they hold shares.
    function _noOutsideHolders() private view returns (bool) {
        if (_vault.hadOutsideHolder()) return false;
        IERC20 v = IERC20(address(_vault));
        return v.totalSupply() == v.balanceOf(owner) + v.balanceOf(_vault.teller());
    }

    function _checkDial(Dial memory d) private pure {
        if (
            d.maxNoMarketBps > BPS || d.maxThinBps > BPS || d.maxPoolBps > BPS || d.maxPerTokenBps > BPS
                || d.dailyLossBps > BPS
        ) {
            revert BadDial();
        }
        if (d.allowBorrow && d.minHealthBps < BPS) revert BadDial(); // health below 1.0 is already insolvent
        // `allowUnreviewed` is a plain choice either way: nothing to bound.
    }

    /// @dev Field by field, the less risky of the two.
    function _safer(Dial memory a, Dial memory b) private pure returns (Dial memory s) {
        s.maxNoMarketBps = a.maxNoMarketBps < b.maxNoMarketBps ? a.maxNoMarketBps : b.maxNoMarketBps;
        s.maxThinBps = a.maxThinBps < b.maxThinBps ? a.maxThinBps : b.maxThinBps;
        s.maxPoolBps = a.maxPoolBps < b.maxPoolBps ? a.maxPoolBps : b.maxPoolBps;
        s.maxPerTokenBps = a.maxPerTokenBps < b.maxPerTokenBps ? a.maxPerTokenBps : b.maxPerTokenBps;
        s.dailyLossBps = a.dailyLossBps < b.dailyLossBps ? a.dailyLossBps : b.dailyLossBps;
        s.allowBorrow = a.allowBorrow && b.allowBorrow;
        // Kept even when borrowing is switched off: debts already open are still held to the floor, so a lower
        // floor is a risk increase whatever `allowBorrow` says.
        s.minHealthBps = a.minHealthBps > b.minHealthBps ? a.minHealthBps : b.minHealthBps;
        // Keeping to reviewed instruments is the safer side: switching it on waits, switching it off does not.
        s.allowUnreviewed = a.allowUnreviewed && b.allowUnreviewed;
    }

    function _same(Dial memory a, Dial memory b) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }
}
