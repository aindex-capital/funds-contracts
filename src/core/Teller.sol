// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Amount} from "../interfaces/IAdapter.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController, Dial} from "../interfaces/IFundController.sol";
import {IPriceRouter, Side} from "../interfaces/IPriceRouter.sol";
import {IPockets} from "../interfaces/IPockets.sol";
import {ITeller} from "../interfaces/ITeller.sol";
import {FundFees} from "./Fees.sol";
import {TellerMath, Snap} from "./TellerMath.sol";
import {FundBook} from "./FundBook.sol";
import {TellerOps} from "./TellerOps.sol";
import {TellerQueue} from "./TellerQueue.sol";

/// @notice The parts of the FundFactory the teller uses.
interface IFundFactoryLike {
    function isFund(address vault) external view returns (bool);
    function baseAsset() external view returns (address);
    function create(string calldata name, string calldata symbol, address owner, address teller, Dial calldata dial)
        external
        returns (address vault, address controller);
}

/// @notice The PriceRouter's closure calendar (`PriceRouter.lastClosedSince`).
interface IClosureCalendar {
    function lastClosedSince() external view returns (uint256);
}

/**
 * @title  Teller
 * @notice The public desk of every AINDEX Fund: deposits in USDG, exits to USDG at a settlement or in kind at any
 *         time, the owner's opening deposit, fees, holders' pockets and dust. One contract serves every Fund, keyed by
 *         vault.
 *
 * @dev    ## Cash in at NAV (owner decision 2026-10-02)
 *         A deposit's USDG enters the Fund as cash and the depositor gets shares at the Fund's NAV; the manager (or
 *         its AI agent) invests the cash in its own actions, inside its dial, as it would any cash. The teller
 *         never swaps, never grows an adapter and never chooses a route: a settlement reads the Fund once, prices
 *         shares, mints and burns, and moves USDG. The same model as Enzyme and dHEDGE.
 *
 *         ## Batches, so nobody trades on a stale price
 *         Requests queue until the Fund's next cut-off (daily at 21:00 UTC by default) and settle after it, at
 *         prices read then: a request cannot see the price it will get. A listed keeper settles:
 *         1. fees accrue, before anything changes the share count (management and performance, the high-water
 *            mark, first loss), at the bid NAV;
 *         2. entrants and cash leavers in the batch are matched at the Fund's fair NAV per share: the leavers'
 *            escrowed shares go to the entrants and the entrants' USDG to the leavers, inside the teller. Neutral
 *            for the Fund, and at least as good for each side as its own net price, since fair lies between bid
 *            and ask;
 *         3. the net entrants' USDG goes into the vault as cash and they are minted shares at the ask NAV per share
 *            (assets at ask, debts at bid): the holders they join never pay for their entry;
 *         4. the net leavers are paid from the vault's USDG at the bid NAV per share (assets at bid, debts at ask).
 *            When the vault holds less USDG than that, the cash goes as far as it reaches and the rest of their
 *            shares comes back to them, to leave in kind (`redeemInKind`; the app swaps those tokens for them).
 *         Every request meets its own limit on the result, or the keeper lists it and it moves to the next batch
 *         once (failing again, it is paid back). The keeper chooses nothing else.
 *
 *         ## When deposits wait (they are never sent back by a settlement)
 *         A deposit that cannot go in now stays in its batch with its id, its limit and its 7-day clock; the batch
 *         takes the Fund's next cut-off, a later round of it takes the deposit, and its owner can take it back until
 *         that cut-off (`DepositsWait`). Leavers are paid at the batch's first round and never wait. Deposits wait
 *         when:
 *         - the Fund holds a token with no market price, or a claim valued at zero, above dust: a share minted now
 *           would take a slice of it without paying. Anyone may set it aside for the holders of this moment
 *           (`pocket`), and a keeper does so first; until then nobody is minted (and no fee shares);
 *         - a price is unavailable (the Fund's NAV incomplete, or USDG's price);
 *         - over the closure's inflow cap: while a market the Fund holds is closed (a weekend, a holiday, and after
 *           the reopening until the token's feed has a new round), the deposits taken per closure, matched or not,
 *           are capped at `weekendInflowBps` of NAV (5% at deployment), oldest requests first. Weekend prices
 *           follow the router's worse-of rule (entrants at the higher of the pools and Friday's price, leavers at
 *           the lower, each with a spread), so deposits and exits settle at weekends too; the cap bounds what a
 *           weekend gap the pools could not show can cost the holders. Cash paid to leavers per closure is capped
 *           the same way (`weekendOutflowBps`): the rest of their shares comes back, to leave in kind;
 *         - over the pool-price flow cap: a Fund holding tokens priced from pools (classes Pool and Thin: a TWAP or
 *           a recorded median, which trail the market) takes deposits per 24-hour window (UTC days, whatever its
 *           cut-offs) up to `poolFlowBps` of NAV divided by the share of NAV in such tokens (5% of NAV for a Fund
 *           wholly in them, 10% for one half in them, no real limit for a crumb), never under `poolFlowFloorUsd`
 *           ($250), and pays cash to leavers the same way; a deposit larger than the room left goes in in part
 *           over the windows. Their prices are already the worse of the average and a recent price
 *           (`PriceRouter`); the cap bounds what a pool held off market for a whole window can cost the holders per
 *           day: at most the cap times how far the pool was bent beyond the token's haircut.
 *         A Fund winding down pays every deposit back: it takes no more money.
 *
 *         ## Holders' pockets
 *         NAV counts a token with no market (class None) and a claim an adapter cannot value as nothing, yet an
 *         exit in kind hands their slice over. `pocket` snapshots the shares (`FundVault.snapshot`) and moves such
 *         a holding to the `Pockets` contract, where the holders of that moment claim it in kind, forever. Shares in
 *         the teller's custody at a snapshot (an escrowed cash exit, shares a batch minted and not yet claimed) pass
 *         their part to the request's owner (`custodyAt`) when they leave custody. The owner's opening shares sit in
 *         its own wallet, so the vault's snapshot counts them like anyone's.
 *
 *         ## Keepers
 *         Settling is open to the keepers the admin lists (`setKeeper`), or to anyone once the admin opens it
 *         (`setOpenSettlement`). A keeper cannot send a deposit back or hold anyone back: it can only list
 *         requests whose limit fails. If keepers stop, nothing is stuck: a request that has waited `STALE_AFTER`
 *         can be returned to its owner by anyone, and exits in kind never need a keeper.
 *
 *         ## The queue
 *         A batch takes `MAX_REQUESTS`, then requests spill up to `MAX_SPILL` batches ahead. One payer may have
 *         `maxLive` requests waiting per Fund for each receiver (its own requests are the pair of itself and
 *         itself), deposits need `minDeposit` and cash exits as many shares, so filling every batch takes hundreds
 *         of funded requests, and a limit no settlement meets leaves the queue after one move.
 *
 *         ## Receivers (partner apps, zaps, embedded wallets)
 *         A request may be paid by one address for another (`requestDeposit` and `requestRedeem` with a
 *         `receiver`). The receiver owns it: only the receiver may cancel it while its batch is open, and the
 *         shares, the USDG, a refund, shares handed back for an exit in kind, a cancel's and a stale return's
 *         escrow and the custody's part of every pocket all go to the receiver. The payer keeps no claim on it. A
 *         cash exit always takes the caller's own shares. `maxLive` counts per payer and receiver pair, so nobody
 *         can fill another's places. Exits in kind already send to `to` and burn the caller's own shares; the
 *         caller stays that exit's owner. A deposit's optional `referrer` is emitted in `Referred` for off-chain
 *         attribution and changes nothing on chain.
 *
 *         ## Exits in kind
 *         Any time: the leaver receives its slice of every vault token and every adapter's `split`. Where the Fund
 *         owes (a borrowing adapter), the slice's debt is repaid from the vault through `unwindInputs` and charged
 *         to the leaver's own slice of that token; if the leaver's slice is not enough, the leaver brings the
 *         difference (`inKindNeeds`). Each adapter is measured to keep at least `(1 - f)` of every position.
 *         A Fund too large to leave in one transaction is left in parts (`startInKind`): the shares burn and the
 *         vault tokens are paid at once, and each adapter's slice is set aside in the controller's units (the
 *         Fund's book stops counting it, and the adapter may change only by `split` until it is paid) and paid out
 *         by `claimInKind`, which anyone may call; an adapter that holds and owes nothing gets no slice and needs no
 *         step. A slice that cannot be split for `STALE_AFTER` goes back to the
 *         Fund (`releaseInKind`), as when a leaver leaves an adapter behind.
 *
 *         ## While the controller acts
 *         The vault refuses to mint, burn or pay while the controller is inside one of its calls, so nothing here
 *         can land between an action's two NAV readings, and the controller refuses the manager while the teller
 *         is inside one of its calls (`busy`).
 *
 *         ## Opening deposit (owner decision 2026-10-04)
 *         A Fund opens with its owner's deposit of at least `minOpeningStake` USDG, at one share per USDG, minted to
 *         the owner's wallet: ordinary shares, which the owner may keep, top up (`requestDeposit`) or sell in part or
 *         in full at any time through the same cash and in-kind exits as anyone, outside holders or not. On its
 *         first opening the teller also mints `DEAD_SHARES` to itself, never owed and never redeemed, so the supply
 *         can never be pushed down to a few wei, where rounding a mint would be a large part of the Fund (the
 *         first-depositor and donation attacks). The minimum pays for the opening and keeps dust Funds out. The
 *         owner's own shares never set the vault's outside-holder latch (`FundVault._update`).
 */
contract Teller is ITeller, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error NotAdmin();
    error NotOwner();
    error NotFund();
    error NotOpen();
    error AlreadyOpen();
    error StakeTooSmall();
    error BadAmount();
    error BadSchedule();
    error BadRequest(uint256 id);
    error NotReady();
    error AlreadySettled();
    error BatchFull();
    error WindingDown();
    /// @notice No new deposit requests while the Fund's manager is paused.
    error DepositsPaused();
    error EscrowTouched(address token);
    error BadParams();
    error NotKeeper();
    error NotEmpty();
    error TooManyRequests();
    /// @notice A request's receiver may not be zero, the Fund's vault or the teller.
    error BadReceiver();
    /// @notice Too little gas for `releaseInKind`'s probe of whether a slice can be split.
    error ShortGas();

    event ParamsSet(
        uint256 minOpeningStake, uint256 minDeposit, uint256 dustUsd, uint256 writeOffMaxWad, uint16 weekendInflowBps
    );
    event KeeperSet(address indexed keeper, bool allowed);
    event WeekendOutflowSet(uint16 bps);
    event PoolFlowSet(uint16 bps);
    event PoolFlowFloorSet(uint256 usd);
    event MaxLiveSet(uint8 maxLive);
    event OpenSettlementSet(bool open);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    /// @notice Most requests one batch takes; later ones go to the next batch. Bounds settlement gas.
    uint256 public constant MAX_REQUESTS = 100;
    /// @notice How many batches ahead a request may go when the open batch is full.
    uint256 public constant MAX_SPILL = 8;
    /// @notice Highest `maxLive` the admin may set.
    uint256 public constant MAX_LIVE = 8;
    /// @notice Shares minted to the teller itself when a Fund first opens, and never redeemed: a floor under the
    ///         supply (about a millionth of a USDG at the opening price).
    uint256 public constant DEAD_SHARES = 1e12;
    /// @notice Highest `writeOffMaxWad` the admin may set: a hundredth of a token. It is also the dust line for a
    ///         holding valued at zero, above which new money waits for a pocket.
    uint256 public constant MAX_WRITE_OFF_WAD = 1e16;
    /// @notice A request that has waited this long since it was made may be returned to its owner by anyone, so
    ///         escrow is never stuck. Counted per request, so a deposit moved from batch to batch keeps its clock.
    uint64 public constant STALE_AFTER = 7 days;
    /// @notice `DepositsWait` reasons beyond `Hold`'s: a price was unavailable; over the closure's inflow cap; over
    ///         the pool-price flow cap of the 24-hour window (`poolFlowBps`).
    uint8 public constant WAIT_NO_PRICE = 3;
    uint8 public constant WAIT_INFLOW_CAP = 4;
    uint8 public constant WAIT_POOL_FLOW = 5;
    /// @notice Held on top of an exit slice's debt repayment, in basis points, for interest until it is paid out
    ///         (what is not needed goes back to the leaver). None when the slices are paid in the same transaction.
    uint256 public constant EXIT_MARGIN_BPS = 50;
    /// @notice An exit's own owner or recipient may claim its slices at once; anyone else from this long after it
    ///         began (so nobody can pick a bad moment for a leaver, such as a lending market with nothing free to
    ///         withdraw, and a manager waits at most this long for a slice to be paid out).
    uint64 public constant EXIT_OPEN_AFTER = 1 days;
    /// @notice Gas `releaseInKind` gives its probe of whether a slice can be split (`trySplit`).
    uint256 public constant PROBE_GAS = 10_000_000;
    /// @notice The most `poolFlowFloorUsd` may be: the floor stays small next to the cap it is under.
    uint256 public constant MAX_POOL_FLOW_FLOOR = 1_000e18;
    /// @notice An exit in parts of less than this share of the Fund (0.1%) can be paid out by anyone at once: its
    ///         slices are too small for the moment to matter, and a manager never waits on one.
    uint256 public constant SMALL_EXIT_WAD = 1e15;
    uint64 public constant DEFAULT_INTERVAL = 1 days;
    uint64 public constant DEFAULT_OFFSET = 21 hours; // 21:00 UTC
    uint64 public constant MIN_INTERVAL = 1 hours;
    uint64 public constant MAX_INTERVAL = 7 days;

    uint8 private constant HOLD_CLOSED = uint8(Hold.MarketClosed);
    uint8 private constant HOLD_NO_MARKET = uint8(Hold.NoMarket);

    IFundFactoryLike public immutable factory;
    FundFees public immutable fees;
    /// @notice Where holdings valued at zero go for the holders of the moment.
    IPockets public immutable pockets;
    /// @notice The deposit currency and every Fund's base asset (USDG on Robinhood Chain).
    address public immutable usdg;
    uint256 private immutable _shareScale; // shares per raw USDG unit at opening (1 share per USDG)
    uint256 private immutable _unit; // one whole USDG in raw units

    address public admin;
    address public pendingAdmin;
    /// @notice Least opening stake, in raw USDG (10 USDG at deployment). Checked only when a Fund opens.
    uint256 public minOpeningStake;
    /// @notice Least deposit request, in raw USDG (10 USDG at deployment; never zero). A cash exit request must be
    ///         for at least as many shares as this buys at the opening price (one share per USDG); a smaller
    ///         holding leaves in kind, which needs no queue.
    uint256 public minDeposit;
    /// @notice Most requests one address may have waiting in one Fund's unsettled batches (3 at deployment, at
    ///         most `MAX_LIVE`).
    uint8 public maxLive = 3;
    /// @notice Most deposit USDG a Fund takes per market closure (matched with leavers or not), in basis points of
    ///         its fair NAV at the closure's first settlement (500 at deployment). 0 takes none while a market it
    ///         holds is closed.
    uint16 public weekendInflowBps = 500;
    /// @notice Most cash a Fund pays its leavers per market closure, the same way (500 at deployment); cash exits
    ///         beyond it come back as shares, to leave in kind (which a closed market does not price).
    uint16 public weekendOutflowBps = 500;
    /// @notice Most deposit USDG a Fund holding pool-priced tokens (classes Pool and Thin) takes per 24-hour window
    ///         (UTC days), and most cash it pays its leavers, each in basis points of its fair NAV divided by the share
    ///         of NAV in such tokens, both at the window's first settlement (500 at deployment), and at least
    ///         `poolFlowFloorUsd`. 0 takes none and pays no cash while it holds any.
    uint16 public poolFlowBps = 500;
    /// @notice The least the pool-price flow cap is per window, USD 1e18 ($250 at deployment, at most
    ///         `MAX_POOL_FLOW_FLOOR`): a small Fund mostly in pool-priced tokens still takes a normal deposit.
    uint256 public poolFlowFloorUsd = 250e18;
    /// @notice Holdings worth less than this (USD, 1e18, fair) may be written off.
    uint256 public dustUsd = 1e18;
    /// @notice A holding valued at zero above this many whole tokens (1e18 = one) needs a pocket before new money
    ///         goes in; at or below it, anyone may write it off.
    uint256 public writeOffMaxWad = 1e14;
    /// @notice Who may settle batches while settlement is not open to everyone.
    mapping(address => bool) public isKeeper;
    /// @notice True once the admin lets anyone settle.
    bool public openSettlement;
    /// @notice Deposits queued by someone other than the Fund's owner that are not yet claimed or cancelled.
    mapping(address => uint256) public outsideQueued;

    struct FundState {
        bool opened;
        uint64 interval;
        uint64 offset;
        uint64 openBatch;
        uint64 windDownAt;
        uint256 lastNav; // fair NAV (USD, 1e18) after the last settlement
        uint256 lastCash; // the vault's USDG after the last settlement
        uint64 lastAt;
    }

    /// @dev The current market closure a Fund's flows are counted in.
    struct Closure {
        uint64 since; // the router's `closedSince` (0: none yet)
        uint256 nav; // fair NAV at the closure's first settlement
        uint256 inflow; // deposits taken so far, matched or not, USD 1e18
        uint256 outflow; // cash paid out of the Fund so far, USD 1e18
    }

    /// @dev A Fund's flows in the current 24-hour window (UTC days), for the pool-price flow cap.
    struct Flow {
        uint64 until; // the window's end (the next 00:00 UTC), whatever the Fund's cut-offs
        uint192 cap; // fair NAV x poolFlowBps / share of NAV priced from pools, at least the floor, USD 1e18
        uint128 inflow; // deposits taken so far, matched or not, USD 1e18
        uint128 outflow; // cash paid out of the Fund so far, USD 1e18
    }

    /// @dev Shares held in custody for an account over the snapshots after `from` up to `until` (`_assign`).
    struct Custody {
        uint128 shares;
        uint32 from;
        uint32 until;
    }

    /// @dev What is still to be paid out to a batch's leavers; the last claim takes the remainder.
    struct Remaining {
        uint256 red; // cash exits still to be paid, as requested
        uint256 out; // USDG held for them
        uint256 back; // shares handed back to them for an exit in kind
    }

    /// @dev What is still to be paid out of a round's deposits; the last claim takes the remainder.
    struct RoundLeft {
        uint256 dep;
        uint256 minted;
    }

    mapping(address => FundState) private _funds;
    mapping(address => Closure) private _closures;
    mapping(address => Flow) private _flows;
    mapping(address => mapping(address => Custody[])) private _custody;
    mapping(address => mapping(uint64 => Batch)) private _batches;
    mapping(address => mapping(uint64 => uint256[])) private _ids;
    mapping(address => mapping(uint64 => Remaining)) private _remaining;
    mapping(address => mapping(uint64 => mapping(uint16 => Round))) private _rounds;
    mapping(address => mapping(uint64 => mapping(uint16 => RoundLeft))) private _left;
    mapping(uint256 => Exit) private _exits;
    /// @notice Per exit in parts and adapter, the leaver's slice still to be paid out, in the adapter's units.
    mapping(uint256 => mapping(address => uint256)) public exitUnits;
    /// @notice Per Fund, when the last exit in kind began. A pocket opened at or before it is not added to (`pocket`
    ///         with `into`): a leaver in kind already took its slice of what was still in the adapters, and its
    ///         snapshot balance would take a part of it again from the pocket.
    mapping(address => uint64) public lastInKindAt;
    mapping(uint256 => mapping(address => Amount[])) private _escrow;
    uint256 public nextExitId = 1;
    mapping(uint256 => Request) private _requests;
    mapping(uint256 => uint256) private _pos; // a request's place in its batch's list, plus one
    mapping(uint256 => bool) private _outside; // a deposit counted in `outsideQueued`
    mapping(uint256 => bool) private _moved; // moved to a later batch once already: a second failed limit pays it back
    /// @dev Per Fund, payer and owner (the receiver), the requests that may still be waiting (checked when a slot is
    ///      needed). Someone acting for itself is the pair (it, it).
    mapping(address => mapping(address => mapping(address => uint256[MAX_LIVE]))) private _live;
    uint256 public nextId = 1;

    /// @notice Everything the teller owes, per token: queued USDG, unclaimed exits, escrowed and unclaimed shares.
    ///         Its balance never falls below this.
    mapping(address => uint256) public owed;

    constructor(IFundFactoryLike factory_, FundFees fees_, IPockets pockets_, address admin_) {
        factory = factory_;
        fees = fees_;
        pockets = pockets_;
        admin = admin_;
        usdg = factory_.baseAsset();
        uint8 d = IERC20Metadata(usdg).decimals();
        _shareScale = 10 ** (18 - d);
        _unit = 10 ** d;
        minOpeningStake = 10 * 10 ** d;
        minDeposit = 10 * 10 ** d;
    }

    // ================================================================ admin

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setParams(
        uint256 minOpeningStake_,
        uint256 minDeposit_,
        uint256 dustUsd_,
        uint256 writeOffMaxWad_,
        uint16 weekendInflowBps_
    ) external onlyAdmin {
        if (
            minOpeningStake_ == 0 || minDeposit_ == 0 || dustUsd_ > 100e18 || writeOffMaxWad_ > MAX_WRITE_OFF_WAD
                || weekendInflowBps_ > BPS
        ) {
            revert BadParams();
        }
        minOpeningStake = minOpeningStake_;
        minDeposit = minDeposit_;
        dustUsd = dustUsd_;
        writeOffMaxWad = writeOffMaxWad_;
        weekendInflowBps = weekendInflowBps_;
        emit ParamsSet(minOpeningStake_, minDeposit_, dustUsd_, writeOffMaxWad_, weekendInflowBps_);
    }

    /// @notice Most cash a Fund pays its leavers per market closure, in basis points of its NAV (0 to 10,000).
    function setWeekendOutflowBps(uint16 bps) external onlyAdmin {
        if (bps > BPS) revert BadParams();
        weekendOutflowBps = bps;
        emit WeekendOutflowSet(bps);
    }

    /// @notice The pool-price flow cap's floor per window (`poolFlowFloorUsd`, USD 1e18, at most `MAX_POOL_FLOW_FLOOR`).
    function setPoolFlowFloor(uint256 usd) external onlyAdmin {
        if (usd > MAX_POOL_FLOW_FLOOR) revert BadParams();
        poolFlowFloorUsd = usd;
        emit PoolFlowFloorSet(usd);
    }

    /// @notice The pool-price flow cap (`poolFlowBps`, 0 to 10,000).
    function setPoolFlowBps(uint16 bps) external onlyAdmin {
        if (bps > BPS) revert BadParams();
        poolFlowBps = bps;
        emit PoolFlowSet(bps);
    }

    /// @notice Most requests one address may have waiting per Fund (1 to `MAX_LIVE`).
    function setMaxLive(uint8 maxLive_) external onlyAdmin {
        if (maxLive_ == 0 || maxLive_ > MAX_LIVE) revert BadParams();
        maxLive = maxLive_;
        emit MaxLiveSet(maxLive_);
    }

    /// @notice Allow or stop a keeper settling batches.
    function setKeeper(address keeper, bool allowed) external onlyAdmin {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Let anyone settle (true), or only the listed keepers (false, the default).
    function setOpenSettlement(bool open_) external onlyAdmin {
        openSettlement = open_;
        emit OpenSettlementSet(open_);
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

    // ================================================================ opening and the owner

    /**
     * @notice Create a Fund served by this teller and open it with the caller's opening deposit (shares to the
     *         caller's wallet), in one transaction. The caller becomes its owner. Fee rates may be set later through `FundFees` (instant until the
     *         first outside holder).
     */
    function createFund(
        string calldata name,
        string calldata symbol,
        Dial calldata dial,
        uint256 stakeUsdg,
        uint16 managementBps,
        uint16 performanceBps
    ) external nonReentrant returns (address vault, address controller) {
        (vault, controller) = factory.create(name, symbol, msg.sender, address(this), dial);
        _open(vault, stakeUsdg, managementBps, performanceBps, msg.sender);
    }

    /**
     * @notice `createFund` with the Fund ready to trade, in the same one transaction (after the USDG approval): the
     *         caller's initial adapters and manager (`FundController.setup`: the same checks and events as
     *         `addAdapter` and `setManager` while only the owner holds) and fee recipient (zero: the caller). Only
     *         ever applied to the Fund this call creates for the caller, before its first share exists, so nobody
     *         else's setup can reach it and it cannot be used again.
     */
    function createFundWith(
        string calldata name,
        string calldata symbol,
        Dial calldata dial,
        uint256 stakeUsdg,
        uint16 managementBps,
        uint16 performanceBps,
        FundSetup calldata setup
    ) external nonReentrant returns (address vault, address controller) {
        (vault, controller) = factory.create(name, symbol, msg.sender, address(this), dial);
        IFundController(controller).setup(setup.adapters, setup.configs, setup.manager, setup.managerExpiresAt);
        address to = setup.feeRecipient == address(0) ? msg.sender : setup.feeRecipient;
        _open(vault, stakeUsdg, managementBps, performanceBps, to);
    }

    /**
     * @notice Open a Fund made by the factory with this teller: the owner deposits at least `minOpeningStake` USDG
     *         at one share per USDG, minted to its wallet. Also reopens a Fund every holder has left.
     */
    function open(address vault, uint256 stakeUsdg, uint16 managementBps, uint16 performanceBps)
        external
        nonReentrant
        returns (uint256 shares)
    {
        return _open(vault, stakeUsdg, managementBps, performanceBps, msg.sender);
    }

    /// @notice Owner: the batch rhythm (a cut-off every `interval` seconds, `offset` after midnight UTC). Applies
    ///         to batches opened from now on. Default: daily at 21:00 UTC.
    function setSchedule(address vault, uint64 interval, uint64 offset) external nonReentrant {
        _onlyOwner(vault);
        if (interval < MIN_INTERVAL || interval > MAX_INTERVAL || offset >= interval) revert BadSchedule();
        FundState storage st = _funds[vault];
        st.interval = interval;
        st.offset = offset;
        emit ScheduleSet(vault, interval, offset);
    }

    /// @notice Owner: close the Fund for good. From now on it takes no deposit (`WindingDown`), and every deposit
    ///         still waiting is paid back at its next settlement. Exits, cash and in kind, go on as before, for the
    ///         owner as for everyone. Takes effect at once: it only stops money coming in, so nobody needs notice.
    function windDown(address vault) external nonReentrant {
        _onlyOwner(vault);
        FundState storage st = _funds[vault];
        if (!st.opened) revert NotOpen();
        if (st.windDownAt == 0) st.windDownAt = uint64(block.timestamp);
        emit WindDown(vault, st.windDownAt);
    }

    // ================================================================ requests

    /// @notice Queue a deposit of `amount` USDG (at least `minDeposit`) for the next settlement, which mints shares
    ///         for it at the ask NAV per share read then. It waits until it can go in (see the contract notes); it
    ///         is never sent back by a settlement, and its owner can take it back while its batch is open.
    ///         `minShares` (above zero) is the least shares for the whole amount: a price limit. A depositor other
    ///         than the Fund's owner latches the Fund's outside-holder flag while the deposit waits. One address may
    ///         have at most `maxLive` requests waiting per Fund (`TooManyRequests`). Refused while the manager is
    ///         paused. The caller pays and owns the request: `requestDeposit` with a receiver.
    function requestDeposit(address vault, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 id)
    {
        return _deposit(vault, amount, minShares, msg.sender, 0);
    }

    /// @notice `requestDeposit` paid by the caller for `receiver`, who owns the request: the shares, a refund, a
    ///         cancel (only `receiver` may cancel while the batch is open) and the 7-day stale return all go to
    ///         `receiver`, and its custody counts for `receiver` in pockets. The caller cannot cancel or claim it for
    ///         itself. `maxLive` counts per payer and receiver pair, so a payer fills only its own places: nobody can
    ///         use up another's. The outside-holder flag latches unless `receiver` is the Fund's owner. `referrer`
    ///         (0: none) is attribution only, emitted in `Referred`; it changes nothing on chain.
    function requestDeposit(address vault, uint256 amount, uint256 minShares, address receiver, bytes32 referrer)
        external
        nonReentrant
        returns (uint256 id)
    {
        return _deposit(vault, amount, minShares, receiver, referrer);
    }

    function _deposit(address vault, uint256 amount, uint256 minShares, address receiver, bytes32 referrer)
        private
        returns (uint256 id)
    {
        FundState storage st = _funds[vault];
        if (!st.opened) revert NotOpen();
        if (st.windDownAt != 0) revert WindingDown();
        IFundController c = _controller(vault);
        if (c.paused()) revert DepositsPaused();
        if (amount < minDeposit || amount > type(uint128).max || minShares == 0 || minShares > type(uint128).max) {
            revert BadAmount();
        }
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), amount);
        uint64 b;
        (id, b) = _queue(vault, Kind.Deposit, amount, minShares, receiver);
        if (receiver != c.owner()) {
            IFundVault(vault).latchOutsideHolder();
            _outside[id] = true;
            ++outsideQueued[vault];
        }
        Batch storage bt = _batches[vault][b];
        bt.deposits += amount;
        uint256 t = TellerQueue.tight(minShares, amount);
        if (t > bt.depTight) bt.depTight = t;
        owed[usdg] += amount;
        emit DepositRequested(vault, id, receiver, b, amount, minShares);
        if (referrer != 0) emit Referred(vault, id, referrer);
    }

    /// @notice Queue a cash exit for the next settlement, paid from the Fund's USDG at the bid NAV per share read
    ///         then; shares the Fund's USDG cannot cover come back for an exit in kind. The shares wait here
    ///         (approve them first); `minUsdg` is required (a price: least USDG for all the shares, judged on the
    ///         part paid in cash). At least `minDeposit * 1e12` shares (for 6-decimal USDG: `minDeposit`'s worth at
    ///         one share per USDG). For an exit in kind use `redeemInKind`: it needs no queue and has no minimum.
    function requestRedeem(address vault, uint256 shares, uint256 minUsdg) external nonReentrant returns (uint256 id) {
        return _redeem(vault, shares, minUsdg, msg.sender);
    }

    /// @notice `requestRedeem` of the caller's own shares (always taken from the caller, never from anyone else) for
    ///         `receiver`, who owns the request: the USDG, any shares handed back for an exit in kind, a cancel's or
    ///         a stale return's shares, and the escrow's part of pockets all go to `receiver`, and only `receiver`
    ///         may cancel while the batch is open. `maxLive` counts per payer and receiver pair.
    function requestRedeem(address vault, uint256 shares, uint256 minUsdg, address receiver)
        external
        nonReentrant
        returns (uint256 id)
    {
        return _redeem(vault, shares, minUsdg, receiver);
    }

    function _redeem(address vault, uint256 shares, uint256 minUsdg, address receiver) private returns (uint256 id) {
        if (!_funds[vault].opened) revert NotOpen();
        if (
            shares < minDeposit * _shareScale || minUsdg == 0 || shares > type(uint128).max
                || minUsdg > type(uint128).max
        ) {
            revert BadAmount();
        }
        // A Fund nobody else holds yet keeps the owner's instant powers (terms, dial, adapters): a cash exit paid to
        // someone else there would give that someone a claim the 7-day notice never covers. Pay yourself, or wait
        // until the Fund has outside holders.
        if (receiver != msg.sender && IFundVault(vault).outsideHolderSince() == 0) revert BadReceiver();
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);
        uint64 b;
        (id, b) = _queue(vault, Kind.Redeem, shares, minUsdg, receiver);
        _requests[id].snap = uint32(IFundVault(vault).currentSnapshotId());
        Batch storage bt = _batches[vault][b];
        bt.redeems += shares;
        uint256 t = TellerQueue.tight(minUsdg, shares);
        if (t > bt.redTight) bt.redTight = t;
        if (bt.redLow == 0 || shares < bt.redLow) bt.redLow = shares;
        owed[vault] += shares;
        emit RedeemRequested(vault, id, receiver, b, shares, minUsdg);
    }

    /// @notice Withdraw a request while its batch is open (its owner, the receiver; never the payer), or once it has
    ///         waited `STALE_AFTER` since it was made (anyone; it goes back to its owner, so escrow is never stuck).
    ///         After a cut-off the batch is frozen until it is settled. A deposit that waits after a round is open
    ///         again until the batch's new cut-off; a cash exit is paid at the first round. The request's place in
    ///         the batch is freed.
    function cancel(uint256 id) external nonReentrant {
        Request storage r = _requests[id];
        if (r.status != Status.Pending || r.kind == Kind.None || r.round != 0) revert BadRequest(id);
        address vault = r.vault;
        uint64 bid = r.batch;
        Batch storage b = _batches[vault][bid];
        if (b.settled || (b.rounds != 0 && r.kind == Kind.Redeem)) revert AlreadySettled();
        bool stale = block.timestamp >= r.madeAt + STALE_AFTER;
        if (block.timestamp >= b.cutoff && !stale) revert NotReady();
        if (r.owner != msg.sender && !stale) revert BadRequest(id);
        r.status = Status.Cancelled;
        --b.count;
        TellerQueue.unlist(_ids[vault], _pos, bid, id);
        uint256 amt = r.amount;
        if (r.kind == Kind.Redeem) {
            b.redeems -= amt;
            _assign(vault, r.owner, amt, r.snap, _snapNow(vault));
            _pay(vault, r.owner, amt, 0);
        } else {
            b.deposits -= amt;
            if (b.deposits == 0 && b.rounds != 0) b.settled = true; // nothing waits in it any more
            _pay(vault, r.owner, 0, amt);
            _dropOutside(vault, id);
        }
        emit Cancelled(vault, id);
    }

    /// @notice Pay a settled request to its owner, the receiver (anyone may call): shares for a deposit (or its
    ///         USDG back on a wind-down) once its round is done, USDG and any shares handed back for an exit in kind
    ///         for a cash exit, everything back for a request that could not move on (its limit failed twice, or the
    ///         next batch was full). Also hands the owner its part of every pocket taken while its shares were in the
    ///         teller's custody.
    function claim(uint256 id) external nonReentrant returns (uint256 shares, uint256 usdgOut) {
        Request storage r = _requests[id];
        address vault = r.vault;
        Batch storage b = _batches[vault][r.batch];
        bool skipped = r.status == Status.Skipped;
        if (r.kind == Kind.None || (!skipped && r.status != Status.Pending)) revert BadRequest(id);
        uint256 amt = r.amount;
        uint256 now_ = _snapNow(vault);
        if (r.kind == Kind.Deposit) {
            if (skipped) {
                usdgOut = amt;
            } else {
                uint16 rd = r.round != 0 ? r.round : (b.settled ? b.rounds : 0);
                if (rd == 0) revert BadRequest(id);
                Round storage ro = _rounds[vault][r.batch][rd];
                RoundLeft storage left = _left[vault][r.batch][rd];
                bool lastOne = left.dep == amt;
                if (ro.refund) {
                    usdgOut = amt;
                } else {
                    shares = lastOne ? left.minted : ro.minted * amt / ro.dep;
                    left.minted -= shares;
                    _assign(vault, r.owner, shares, ro.snap, now_);
                }
                left.dep -= amt;
            }
            _dropOutside(vault, id);
        } else if (skipped) {
            shares = amt;
            _assign(vault, r.owner, amt, r.snap, now_);
        } else {
            if (b.rounds == 0) revert BadRequest(id);
            Remaining storage left = _remaining[vault][r.batch];
            bool lastOne = left.red == amt;
            usdgOut = lastOne ? left.out : b.usdgOut * amt / b.redIncluded;
            shares = lastOne ? left.back : b.sharesBack * amt / b.redIncluded;
            left.red -= amt;
            left.out -= usdgOut;
            left.back -= shares;
            _assign(vault, r.owner, amt, r.snap, b.snap);
            _assign(vault, r.owner, shares, b.snap, now_);
        }
        r.status = Status.Claimed;
        _pay(vault, r.owner, shares, usdgOut);
        emit Claimed(vault, id, r.owner, shares, usdgOut);
    }

    function _pay(address vault, address to, uint256 shares, uint256 usdgOut) private {
        if (shares != 0) {
            owed[vault] -= shares;
            IERC20(vault).safeTransfer(to, shares);
        }
        if (usdgOut != 0) {
            owed[usdg] -= usdgOut;
            IERC20(usdg).safeTransfer(to, usdgOut);
        }
    }

    // ================================================================ settlement

    /// @dev One settlement round's figures, kept in memory to stay within the stack.
    struct Run {
        uint16 round;
        bool first; // the batch's first round: its leavers are in it
        bool allIn; // every waiting deposit goes in this round
        uint256 waiting; // USDG of the deposits waiting at the start of the round, as requested (none listed)
        uint256 skipped; // USDG of the deposits the keeper listed (they leave the batch after the round)
        uint256 deposits; // USDG of the deposits taken, as requested
        uint256 redeems; // shares of the cash exits taken
        uint256 supply; // after fees
        FundBook.Navs n;
        uint256 usdgBid; // USD (1e18) of one whole USDG at bid
        uint256 usdgAsk;
        uint256 usdgFair;
        uint8 hold; // `Hold`, from the settlement's one reading
        bool closed; // a market the Fund holds is closed: the closure's caps apply
        address why;
        uint8 wait; // why deposits wait this round, if any
        uint256 matchedShares;
        uint256 matchedUsdg;
        uint256 price; // fair NAV per share of the match
        uint256 netIn; // USDG that went into the vault as cash
        uint256 newShares; // shares minted at ask
        uint256 askPerShare;
        uint256 cashShares; // the net leavers' shares paid from the Fund's cash (burned)
        uint256 cashOut; // what they got
        uint256 bidPerShare;
        uint256 back; // the net leavers' shares handed back for an exit in kind
        bool refund; // a Fund winding down pays every deposit back
    }

    /**
     * @notice Settle a closed batch, or a later round of one whose deposits wait (a listed keeper, or anyone once
     *         settlement is open): fees, the match at fair NAV, the net entrants minted at ask NAV with their USDG
     *         going into the Fund as cash, the net leavers paid from the Fund's USDG at bid NAV with the rest of
     *         their shares handed back for an exit in kind. No swaps, no adapter is touched.
     * @param  skip requests whose limit the result cannot meet; they move to the next batch (once; a request moved
     *              before is paid back in full instead). Every other request must meet its limit and every listed
     *              one must fail it, or nothing settles. In a later round only waiting deposits can be listed.
     */
    function settle(address vault, uint64 id, uint256[] calldata skip) external nonReentrant {
        if (!openSettlement && !isKeeper[msg.sender]) revert NotKeeper();
        Batch storage b = _closed(vault, id);
        if (b.settled) revert AlreadySettled();
        Run memory r;
        r.first = b.rounds == 0;
        r.round = ++b.rounds;
        (uint256 skDep, uint256 skRed) = TellerQueue.mark(_requests, vault, id, skip, !r.first);
        r.skipped = skDep;
        r.waiting = b.deposits - skDep;
        if (r.first) r.redeems = b.redeems - skRed;
        address router = _warm(vault);
        _read(vault, r);
        if (r.waiting != 0) _admit(vault, id, r);
        if (r.deposits != 0 && r.redeems != 0 && r.n.fairOk && !r.refund) {
            (r.matchedShares, r.matchedUsdg, r.price) =
                TellerMath.matchAt(r.usdgFair, _unit, r.supply, r.deposits, r.redeems, r.n.fair);
        }
        if (r.deposits > r.matchedUsdg && !r.refund) _enter(vault, id, r);
        if (r.redeems > r.matchedShares) _leave(vault, id, r);
        _record(vault, id, b, r);
        _checkLimits(vault, id, b, r, skip);
        _release(router);
        if (skip.length != 0) _moveSkipped(vault, skip);
        _solvent(vault);
        emit Settled(vault, id, msg.sender, r.round, r.deposits, r.redeems, r.matchedShares + r.newShares, b.usdgOut, r.back);
    }

    /// @dev Requests whose limit failed move to the open batch, once; paid back in full if it is full or the request
    ///      was moved before, so a limit no settlement can meet never holds a place for long.
    function _moveSkipped(address vault, uint256[] calldata skip) private {
        uint64 next = _currentBatch(vault);
        TellerQueue.move(_requests, _batches[vault], _ids[vault], _pos, _moved, vault, next, MAX_REQUESTS, skip);
    }

    /// @dev The settlement's one reading: every adapter read once, NAV priced on every side from that, the hold
    ///      check, and fees accrued at bid. Fees wait while a holding valued at zero is above dust: fee shares
    ///      minted then would take a slice of it too (they accrue in full at the next settlement after the pocket).
    function _read(address vault, Run memory r) private {
        IFundController c = _controller(vault);
        IPriceRouter router = c.router();
        Snap memory s = TellerMath.snapshotAll(c, vault);
        FundBook.Rows memory rows;
        (r.n, rows) = FundBook.navs(s.tracked, s.balances, s.ok, s.assets, s.debts, router);
        (r.hold, r.why, r.closed) = TellerMath.holdFrom(router, rows, s, writeOffMaxWad);
        if (r.hold != HOLD_NO_MARKET) TellerOps.accrue(_ctx(vault), fees, r.n.bid, r.n.bidOk);
        r.supply = IERC20(vault).totalSupply();
        (uint256[3] memory v,, bool ok,) = FundBook.valuesOf(router, usdg, _unit);
        if (ok) (r.usdgFair, r.usdgBid, r.usdgAsk) = (v[0], v[1], v[2]);
    }

    /// @dev Which waiting deposits go in this round. A Fund winding down pays them all back. They all wait while a
    ///      holding valued at zero is above dust (a pocket must run first) or a price is missing; while a market
    ///      the Fund holds is closed, those beyond the closure's inflow cap wait, oldest taken first.
    function _admit(address vault, uint64 id, Run memory r) private {
        if (_funds[vault].windDownAt != 0) {
            (r.deposits, r.allIn, r.refund) = (r.waiting, true, true);
            return;
        }
        uint256 budget = r.waiting;
        if (r.hold == HOLD_NO_MARKET) {
            r.wait = HOLD_NO_MARKET;
        } else if (!r.n.askOk || !r.n.fairOk || r.n.ask == 0 || r.usdgBid == 0 || r.usdgFair == 0) {
            r.wait = WAIT_NO_PRICE;
        } else {
            if (r.closed) {
                Closure storage cl = _closure(vault, r);
                uint256 cap = cl.nav * weekendInflowBps / BPS;
                budget = (cap > cl.inflow ? cap - cl.inflow : 0) * _unit / r.usdgFair;
                if (budget < r.waiting) r.wait = WAIT_INFLOW_CAP;
            }
            if (r.n.pooled != 0) {
                Flow storage f = _flow(vault, r);
                uint256 room = (f.cap > f.inflow ? f.cap - f.inflow : 0) * _unit / r.usdgFair;
                if (room < budget) budget = room;
                if (room < r.waiting && r.wait == 0) r.wait = WAIT_POOL_FLOW;
            }
        }
        if (r.wait == 0) {
            (r.deposits, r.allIn) = (r.waiting, true);
        } else if ((r.wait == WAIT_INFLOW_CAP || r.wait == WAIT_POOL_FLOW) && budget != 0) {
            // Only under the pool-price flow cap does the first deposit too large go in in part (a deposit waiting for
            // a closed market goes in whole when it opens).
            uint256 split;
            uint256 minPart = r.wait == WAIT_POOL_FLOW ? minDeposit : type(uint256).max;
            (r.deposits, split) =
                TellerQueue.select(_requests, _ids[vault][id], _pos, id, r.round, budget, minPart, nextId);
            if (split != 0) {
                uint256 part = nextId++;
                if (_outside[split]) {
                    _outside[part] = true;
                    ++outsideQueued[vault];
                }
            }
        }
        if (r.deposits == 0) return;
        // Every deposit taken under a cap counts, matched or not: a matched entrant pays the same fair price that
        // a closed market or a trailing pool price sets as much as a net one pays the ask.
        uint256 usd = r.deposits * r.usdgBid / _unit;
        if (r.closed) _closures[vault].inflow += usd;
        if (r.n.pooled != 0) _flows[vault].inflow += uint128(usd);
    }

    /// @dev The Fund's flows in the current 24-hour window (UTC days, whatever the Fund's cut-offs), started afresh at
    ///      the window's first settlement: its fair NAV and the share of it priced from pools then size the cap, never
    ///      under `poolFlowFloorUsd` (while `poolFlowBps` is above zero), so a small Fund still takes a normal deposit.
    function _flow(address vault, Run memory r) private returns (Flow storage f) {
        f = _flows[vault];
        uint64 until = uint64((block.timestamp / 1 days + 1) * 1 days);
        if (f.until != until) {
            f.until = until;
            uint256 cap = r.n.fair * poolFlowBps / BPS * r.n.fair / r.n.pooled;
            if (poolFlowBps != 0 && cap < poolFlowFloorUsd) cap = poolFlowFloorUsd;
            f.cap = cap > type(uint192).max ? type(uint192).max : uint192(cap);
            f.inflow = 0;
            f.outflow = 0;
        }
    }

    /// @dev The Fund's current market closure, started afresh at the first settlement of a new one (its fair NAV
    ///      then sizes both caps).
    function _closure(address vault, Run memory r) private returns (Closure storage cl) {
        cl = _closures[vault];
        uint64 since;
        try IClosureCalendar(address(_controller(vault).router())).lastClosedSince() returns (uint256 t) {
            since = uint64(t);
        } catch {}
        if (cl.since != since) {
            cl.since = since;
            cl.nav = r.n.fair;
            cl.inflow = 0;
            cl.outflow = 0;
        }
    }

    /// @dev The net entrants: their USDG goes into the vault as cash, and shares are minted at the ask NAV per share.
    function _enter(address vault, uint64 id, Run memory r) private {
        r.netIn = r.deposits - r.matchedUsdg;
        r.newShares = TellerMath.mintFor(r.netIn, r.usdgBid, _unit, r.n.ask, r.supply);
        r.askPerShare = r.n.ask * WAD / r.supply;
        IERC20(usdg).safeTransfer(vault, r.netIn);
        if (r.newShares != 0) IFundVault(vault).mint(address(this), r.newShares);
        emit Minted(vault, id, r.netIn, r.newShares, r.askPerShare);
    }

    /// @dev The net leavers: paid from the vault's USDG at the bid NAV per share, as far as it reaches (and, while a
    ///      market the Fund holds is closed, as far as the closure's outflow cap allows); the rest of their shares is
    ///      handed back for an exit in kind. Without a complete bid NAV or a USDG price nothing can be priced, so
    ///      every share goes back.
    function _leave(address vault, uint64 id, Run memory r) private {
        uint256 net = r.redeems - r.matchedShares;
        if (r.n.bidOk && r.n.bid != 0 && r.usdgAsk != 0) {
            r.bidPerShare = r.n.bid * WAD / r.supply;
            uint256 cash_ = IERC20(usdg).balanceOf(vault);
            if (r.closed) {
                Closure storage cl = _closure(vault, r);
                uint256 cap = cl.nav * weekendOutflowBps / BPS;
                uint256 room = (cap > cl.outflow ? cap - cl.outflow : 0) * _unit / r.usdgAsk;
                if (room < cash_) cash_ = room;
            }
            if (r.n.pooled != 0 && r.n.fairOk) {
                Flow storage f = _flow(vault, r);
                uint256 room = (f.cap > f.outflow ? f.cap - f.outflow : 0) * _unit / r.usdgAsk;
                if (room < cash_) cash_ = room;
            }
            uint256 value = TellerMath.payFor(net, r.usdgAsk, _unit, r.n.bid, r.supply);
            if (value <= cash_) {
                (r.cashShares, r.cashOut) = (net, value);
            } else {
                r.cashShares = net * cash_ / value;
                r.cashOut = TellerMath.payFor(r.cashShares, r.usdgAsk, _unit, r.n.bid, r.supply);
            }
            if (r.closed) _closures[vault].outflow += r.cashOut * r.usdgAsk / _unit;
            if (r.n.pooled != 0 && r.n.fairOk) _flows[vault].outflow += uint128(r.cashOut * r.usdgAsk / _unit);
        }
        r.back = net - r.cashShares;
        if (r.cashShares != 0) {
            IFundVault(vault).burn(address(this), r.cashShares);
            if (r.cashOut != 0) IFundVault(vault).pay(usdg, address(this), r.cashOut);
        }
        emit Paid(vault, id, r.cashShares, r.cashOut, r.bidPerShare, r.back);
    }

    /// @dev Record the round and what the teller now owes. Matched shares and USDG stay owed, to the other side.
    ///      Deposits that did not go in wait in the batch for the Fund's next cut-off.
    function _record(address vault, uint64 id, Batch storage b, Run memory r) private {
        uint32 snap = uint32(_snapNow(vault));
        if (r.first) {
            b.snap = snap;
            b.redIncluded = r.redeems;
            b.matchedShares = r.matchedShares;
            b.matchedUsdg = r.matchedUsdg;
            b.navPerShare = r.matchedShares == 0 ? 0 : r.price;
            b.usdgOut = r.matchedUsdg + r.cashOut;
            b.bidPerShare = r.bidPerShare;
            b.sharesBack = r.back;
            _remaining[vault][id] = Remaining(r.redeems, b.usdgOut, r.back);
            if (r.matchedShares != 0) emit Matched(vault, id, r.matchedShares, r.matchedUsdg, r.price);
        }
        if (r.deposits != 0) {
            uint256 minted = r.matchedShares + r.newShares;
            _rounds[vault][id][r.round] = Round(r.deposits, minted, r.askPerShare, r.refund, snap);
            _left[vault][id][r.round] = RoundLeft(r.deposits, minted);
        }
        owed[usdg] = owed[usdg] - r.netIn + r.cashOut;
        owed[vault] = owed[vault] - r.cashShares + r.newShares;
        uint256 left = r.waiting - r.deposits;
        b.deposits = left + r.skipped; // the listed ones leave with `TellerQueue.move`
        if (left == 0) {
            b.settled = true;
        } else {
            uint64 to = _currentBatch(vault);
            b.cutoff = _batches[vault][to].cutoff;
            emit DepositsWait(vault, id, to, left, r.wait, r.why);
        }
        FundState storage st = _funds[vault];
        uint256 nav = r.n.fair + r.netIn * r.usdgFair / _unit;
        uint256 out = r.cashOut * r.usdgFair / _unit;
        st.lastNav = nav > out ? nav - out : 0;
        st.lastCash = IERC20(usdg).balanceOf(vault);
        st.lastAt = uint64(block.timestamp);
    }

    /// @dev Every request the round took meets its limit; every listed one would have failed it (judged against fair
    ///      NAV when its side kept nobody). When the round's price beats the batch's tightest deposit limit and it
    ///      has no leavers, no request needs reading.
    function _checkLimits(address vault, uint64 id, Batch storage b, Run memory r, uint256[] calldata skip)
        private
        view
    {
        TellerQueue.Result memory res = _result(b, r);
        if (res.depFast && res.redFast && skip.length == 0) return;
        uint256 perShare;
        if (skip.length != 0 && r.n.fairOk && r.usdgFair != 0) {
            perShare = r.n.fair * _unit / r.usdgFair * WAD / r.supply;
        }
        TellerQueue.checkLimits(_requests, _ids[vault][id], id, res, skip, perShare);
    }

    /// @dev The round's result for the limits. Every leaver gets `usdgOut * amount / redeems` rounded down: when that
    ///      beats the tightest limit by a raw unit even on the smallest cash exit, no leaver needs reading; the same
    ///      for the deposits against the round's shares per USDG.
    function _result(Batch storage b, Run memory r) private view returns (TellerQueue.Result memory res) {
        res.round = r.round;
        res.allIn = r.allIn;
        res.base = r.deposits;
        res.shares = r.matchedShares + r.newShares;
        res.refunded = r.refund;
        res.first = r.first;
        res.redIncluded = r.redeems;
        res.usdgOut = r.matchedUsdg + r.cashOut;
        res.back = r.back;
        res.depFast = r.deposits == 0 || r.refund || res.shares * WAD / r.deposits >= b.depTight;
        res.depWait = r.waiting != 0 && r.deposits == 0;
        res.noCash = r.redeems > r.matchedShares && r.bidPerShare == 0;
        uint256 price = r.redeems == 0 ? 0 : res.usdgOut * WAD / r.redeems;
        res.redFast =
            r.redeems == 0 || (r.back == 0 && price > b.redTight && (price - b.redTight) * b.redLow >= WAD);
    }

    // ================================================================ exits in kind

    /// @notice Leave now with your slice of everything the Fund holds, sent to `to`. Burns the caller's shares.
    ///         If the slice's debt needs more of a token than the slice holds, the caller brings the difference
    ///         (approve it; `inKindNeeds` shows how much). A Fund too large for one transaction: `startInKind`.
    function redeemInKind(address vault, uint256 shares, address to) external nonReentrant {
        _inKindNow(vault, shares, to, new address[](0));
    }

    /// @notice `redeemInKind`, leaving behind the listed adapters and tokens (one that cannot be split or
    ///         transferred right now). What is left behind stays with the other holders: use it only when the
    ///         alternative is not leaving at all.
    function redeemInKindLeaving(address vault, uint256 shares, address to, address[] calldata leave)
        external
        nonReentrant
    {
        _inKindNow(vault, shares, to, leave);
    }

    /// @notice An exit in kind in parts, for a Fund too large to leave in one transaction (at least `minDeposit *
    ///         1e12` shares, as a cash exit): the shares burn and the slice of every vault token is paid to `to` now (less escrow for its slices' debt repayment, plus
    ///         `EXIT_MARGIN_BPS`); each adapter's slice is set aside (the Fund's book stops counting it) and paid
    ///         out later by `claimInKind`, which anyone may call. Until then that adapter changes only by `split`.
    ///         An adapter that holds and owes nothing (`TellerMath.holdsNothing`) gets no slice and needs no step;
    ///         when none is left (`pending` 0) the exit is complete in this one call.
    function startInKind(address vault, uint256 shares, address to, address[] calldata leave)
        external
        nonReentrant
        returns (uint256 exitId)
    {
        if (shares < minDeposit * _shareScale) revert BadAmount(); // as for a cash exit: a dust exit leaves at once
        uint256 f = shares * WAD / IERC20(vault).totalSupply();
        TellerOps.ExitStart memory e = _startExit(vault, shares, to, leave, EXIT_MARGIN_BPS, true);
        exitId = nextExitId++;
        uint16 n;
        for (uint256 k; k < e.adapters.length; ++k) {
            if (e.units[k] == 0) continue;
            exitUnits[exitId][e.adapters[k]] = e.units[k];
            Amount[] storage es = _escrow[exitId][e.adapters[k]];
            for (uint256 j; j < e.escrow[k].length; ++j) {
                if (e.escrow[k][j].amount != 0) es.push(e.escrow[k][j]);
            }
            ++n;
        }
        _exits[exitId] = Exit(vault, to, msg.sender, uint64(block.timestamp), n, uint64(f));
        emit ExitStarted(exitId, vault, msg.sender, to, n);
    }

    /// @notice Pay out exit `exitId`'s slices of `adapters` to its recipient (each adapter's fees collected first,
    ///         its slice split off and measured): its owner or recipient at any time, anyone `EXIT_OPEN_AFTER` after
    ///         it began, or at once when the exit is under `SMALL_EXIT_WAD` of the Fund. Until `STALE_AFTER`, anyone
    ///         but the owner or recipient completes a slice only when it pays in full (`TellerMath.NotPaid`
    ///         otherwise: it stays pending); after it, anyone completes it as far as it pays (a split that skips a
    ///         broken position pays the rest; the leaver keeps what was paid), so a partly splittable slice never
    ///         freezes the adapter. A shortfall in the escrow (interest beyond the margin) is brought by the caller;
    ///         what the escrow does not need goes to the recipient.
    function claimInKind(uint256 exitId, address[] calldata adapters) external nonReentrant {
        Exit storage x = _exits[exitId];
        if (x.vault == address(0)) revert BadRequest(exitId);
        if (
            msg.sender != x.owner && msg.sender != x.to && block.timestamp < x.madeAt + EXIT_OPEN_AFTER
                && x.fraction >= SMALL_EXIT_WAD
        ) revert NotReady();
        TellerOps.Ctx memory c = _ctx(x.vault);
        // Someone other than the leaver may only finalise a slice that pays in full (`TellerOps.FULL`), until the
        // exit has waited `STALE_AFTER`.
        uint8 flags =
            msg.sender != x.owner && msg.sender != x.to && block.timestamp < x.madeAt + STALE_AFTER ? 4 : 0;
        for (uint256 i; i < adapters.length; ++i) {
            (uint256 units, Amount[] memory esc) = _takeSlice(exitId, adapters[i]);
            TellerOps.exitClaim(c, adapters[i], units, esc, x.to, flags, owed);
            --x.pending;
            emit ExitClaimed(exitId, adapters[i], false);
        }
    }

    /// @notice A slice that will not be paid out goes back to the Fund, with its escrow (which repays the slice's
    ///         share of the adapter's debt the Fund takes back; the leaver gives up both): at any
    ///         time by the exit's owner (leaving that adapter behind), or by anyone once the exit has waited
    ///         `STALE_AFTER` and the slice still cannot be split in full, so a broken adapter never stays frozen for
    ///         good.
    function releaseInKind(uint256 exitId, address adapter) external nonReentrant {
        Exit storage x = _exits[exitId];
        if (x.vault == address(0)) revert BadRequest(exitId);
        if (msg.sender != x.owner) {
            if (block.timestamp < x.madeAt + STALE_AFTER) revert NotReady();
            if (_splits(exitId, adapter)) revert NotReady();
        }
        (uint256 units, Amount[] memory esc) = _takeSlice(exitId, adapter);
        TellerOps.exitRelease(_ctx(x.vault), adapter, units, esc, owed);
        --x.pending;
        emit ExitClaimed(exitId, adapter, true);
    }

    /// @notice Self-call for `releaseInKind`: whether the slice can be paid out now (the try is rolled back).
    function trySplit(uint256 exitId, address adapter) external {
        if (msg.sender != address(this)) revert BadRequest(exitId);
        Exit storage x = _exits[exitId];
        (uint256 units, Amount[] memory esc) = (exitUnits[exitId][adapter], _escrow[exitId][adapter]);
        TellerOps.exitClaim(_ctx(x.vault), adapter, units, esc, x.to, 6, owed); // PROBE | FULL
        revert NotReady(); // never keep it: only the answer matters
    }

    /// @dev Whether the slice can be split in full now, for a release by someone other than the leaver. Too little
    ///      gas to give the probe `PROBE_GAS` fails (`ShortGas`), and a probe that ran out of gas is no proof the
    ///      slice cannot be split: both refuse the release, so a caller can never make a working slice look broken
    ///      by the gas it sends. An out-of-gas several calls deep still uses most of `PROBE_GAS` (each call keeps
    ///      only 1/64 back), so a revert without data that used at least half of it counts as one; one that left
    ///      more unused is a real failure (a bare `require`, a pause without a reason), and the release goes on.
    function _splits(uint256 exitId, address adapter) private returns (bool) {
        if (gasleft() < PROBE_GAS + PROBE_GAS / 32) revert ShortGas();
        uint256 g = gasleft();
        try this.trySplit{gas: PROBE_GAS}(exitId, adapter) {
            return true;
        } catch (bytes memory err) {
            if (err.length == 4 && bytes4(err) == NotReady.selector) return true;
            return err.length == 0 && g - gasleft() >= PROBE_GAS / 2;
        }
    }

    function _takeSlice(uint256 exitId, address adapter) private returns (uint256 units, Amount[] memory esc) {
        units = exitUnits[exitId][adapter];
        if (units == 0) revert BadRequest(exitId);
        esc = _escrow[exitId][adapter];
        delete exitUnits[exitId][adapter];
        delete _escrow[exitId][adapter];
    }

    function _inKindNow(address vault, uint256 shares, address to, address[] memory leave) private {
        TellerOps.ExitStart memory e = _startExit(vault, shares, to, leave, 0, false);
        TellerOps.Ctx memory c = _ctx(vault);
        for (uint256 k; k < e.adapters.length; ++k) {
            if (e.units[k] == 0) continue;
            TellerOps.exitClaim(c, e.adapters[k], e.units[k], e.escrow[k], to, 1, owed); // FRESH
        }
    }

    function _startExit(address vault, uint256 shares, address to, address[] memory leave, uint256 margin, bool parts)
        private
        returns (TellerOps.ExitStart memory)
    {
        if (!_funds[vault].opened) revert NotOpen();
        if (to == address(0) || to == vault || to == address(this)) revert BadAmount();
        if (shares == 0 || IERC20(vault).balanceOf(msg.sender) < shares) revert BadAmount();
        uint256 supply = IERC20(vault).totalSupply();
        lastInKindAt[vault] = uint64(block.timestamp);
        return TellerOps.exitStart(_ctx(vault), TellerOps.ExitArgs(shares, supply, to, leave, margin, parts), owed);
    }

    // ================================================================ holders' pockets and dust

    /// @notice Set aside a holding NAV values at zero for the holders of this moment (see `TellerOps.pocket`).
    ///         Anyone. `adapters` names the adapters that hold `token` (as an asset, or as a claim valued at zero);
    ///         `into` adds to a pocket opened for it within a day, when one transaction cannot take every adapter,
    ///         and no exit in kind began since it was opened (0: a new pocket).
    function pocket(address vault, address token, address[] calldata adapters, uint256 into)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!_funds[vault].opened) revert NotOpen();
        if (into != 0) {
            (,,, uint64 openedAt) = pockets.pocketInfo(vault, into);
            if (lastInKindAt[vault] >= openedAt) revert NotReady(); // pocket the rest afresh (`into` 0)
        }
        (id,) = TellerOps.pocket(_ctx(vault), token, adapters, writeOffMaxWad, pockets, into);
    }

    /**
     * @notice Stop counting a holding that is worth less than `dustUsd`, or that cannot be priced and is no more
     *         than `writeOffMaxWad` whole tokens. Anyone. The crumbs stay in the vault, uncounted.
     */
    function writeOff(address vault, address token) external nonReentrant {
        if (!_funds[vault].opened) revert NotOpen();
        uint256 bal = TellerOps.writeOff(_ctx(vault), token, dustUsd, writeOffMaxWad);
        emit WrittenOff(vault, token, bal);
    }

    // ================================================================ views

    /// @notice True while the teller is inside one of its own calls. A Fund's controller refuses the manager's
    ///         actions meanwhile, so nothing can act on a Fund between a teller's plan and its measurement (for
    ///         example from a token's transfer hook during an exit).
    function busy() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    function request(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }

    /// @inheritdoc ITeller
    function due(uint256 id) external view returns (uint256 shares, uint256 usdgOut, bool waiting) {
        Request storage r = _requests[id];
        if (r.kind == Kind.None || r.status == Status.Cancelled || r.status == Status.Claimed) return (0, 0, false);
        uint256 amt = r.amount;
        bool dep = r.kind == Kind.Deposit;
        if (r.status == Status.Skipped) return dep ? (uint256(0), amt, false) : (amt, uint256(0), false);
        Batch storage b = _batches[r.vault][r.batch];
        if (dep) {
            uint16 rd = r.round != 0 ? r.round : (b.settled ? b.rounds : 0);
            if (rd == 0) return (0, amt, true);
            Round storage ro = _rounds[r.vault][r.batch][rd];
            RoundLeft storage left = _left[r.vault][r.batch][rd];
            if (ro.refund) return (0, amt, false);
            return (left.dep == amt ? left.minted : ro.minted * amt / ro.dep, 0, false);
        }
        if (b.rounds == 0) return (amt, 0, true);
        Remaining storage rem = _remaining[r.vault][r.batch];
        if (rem.red == amt) return (rem.back, rem.out, false);
        return (b.sharesBack * amt / b.redIncluded, b.usdgOut * amt / b.redIncluded, false);
    }

    function batch(address vault, uint64 id) external view returns (Batch memory) {
        return _batches[vault][id];
    }

    function round(address vault, uint64 batch_, uint16 round_) external view returns (Round memory) {
        return _rounds[vault][batch_][round_];
    }

    function exit(uint256 exitId) external view returns (Exit memory) {
        return _exits[exitId];
    }

    /// @notice The escrow exit `exitId` holds for its slice of `adapter`'s debt repayment.
    function exitEscrow(uint256 exitId, address adapter) external view returns (Amount[] memory) {
        return _escrow[exitId][adapter];
    }

    function batchRequests(address vault, uint64 id) external view returns (uint256[] memory) {
        return _ids[vault][id];
    }

    function fund(address vault) external view returns (FundState memory) {
        return _funds[vault];
    }

    /// @notice The current market closure a Fund's net inflow is counted in: when it began, the NAV the cap is
    ///         sized on, the inflow so far.
    function closure(address vault) external view returns (Closure memory) {
        return _closures[vault];
    }

    /// @notice A Fund's flows in the current 24-hour window under the pool-price flow cap: when the window ends,
    ///         the cap, the deposits taken and the cash paid so far (USD, 1e18).
    function flow(address vault) external view returns (Flow memory) {
        return _flows[vault];
    }

    /// @notice The batch a request made now would join (the open one, or a later one while it is full), and its
    ///         cut-off.
    function currentBatch(address vault) external view returns (uint64 id, uint64 cutoff) {
        FundState storage st = _funds[vault];
        mapping(uint64 => Batch) storage bs = _batches[vault];
        id = st.openBatch;
        cutoff = bs[id].cutoff;
        if (block.timestamp >= cutoff) {
            ++id;
            while (bs[id].cutoff != 0 && block.timestamp >= bs[id].cutoff) ++id;
            cutoff = bs[id].cutoff != 0 ? bs[id].cutoff : _cutoffAfter(st, uint64(block.timestamp));
        }
        for (uint256 k; k < MAX_SPILL && bs[id].count >= MAX_REQUESTS; ++k) {
            ++id;
            cutoff = bs[id].cutoff != 0 ? bs[id].cutoff : _cutoffAfter(st, cutoff);
        }
    }

    /// @notice Whether a settlement now would take new money, and why not (see `TellerMath.depositHold`):
    ///         `NoMarket` until someone pockets the token (`pocket`), `MarketClosed` while weekend pricing and the
    ///         closure's inflow cap apply (deposits still settle). Exits are never held.
    function depositHold(address vault) external view returns (Hold, address) {
        (uint8 why, address token) = TellerMath.depositHold(_controller(vault), vault, writeOffMaxWad);
        return (Hold(why), token);
    }

    /// @inheritdoc ITeller
    function cash(address vault)
        external
        view
        returns (
            uint256 usdgNow,
            uint256 queuedUsdg,
            uint256 queuedShares,
            uint256 lastNav,
            uint256 lastCash,
            uint64 lastAt
        )
    {
        FundState storage st = _funds[vault];
        usdgNow = IERC20(usdg).balanceOf(vault);
        mapping(uint64 => Batch) storage bs = _batches[vault];
        uint64 from = st.openBatch > 3 ? st.openBatch - 3 : 1;
        for (uint64 k = from; k <= st.openBatch + uint64(MAX_SPILL); ++k) {
            Batch storage b = bs[k];
            if (b.cutoff == 0 || b.settled) continue;
            queuedUsdg += b.deposits;
            queuedShares += b.redeems;
        }
        return (usdgNow, queuedUsdg, queuedShares, st.lastNav, st.lastCash, st.lastAt);
    }

    /// @notice For an exit in kind of `shares` now in one transaction: what the leaver must bring to cover its
    ///         slices' debt beyond its slice of the vault (tokens it must approve). In parts the escrow carries
    ///         `EXIT_MARGIN_BPS` more: `inKindNeedsInParts`.
    function inKindNeeds(address vault, uint256 shares) external view returns (Amount[] memory bring) {
        return TellerMath.inKindNeeds(vault, shares, 0);
    }

    function inKindNeedsInParts(address vault, uint256 shares) external view returns (Amount[] memory bring) {
        return TellerMath.inKindNeeds(vault, shares, EXIT_MARGIN_BPS);
    }

    /// @notice The adapters an exit in kind in parts of `shares` now (`startInKind`) would set a slice aside of: one
    ///         `claimInKind` step each. Adapters that hold and owe nothing are not among them.
    function inKindSteps(address vault, uint256 shares) external view returns (address[] memory adapters) {
        uint256 supply = IERC20(vault).totalSupply();
        if (supply == 0 || shares == 0 || shares > supply) return adapters;
        IFundController c = IFundController(IFundVault(vault).controller());
        return TellerMath.exitPlan(c, shares * WAD / supply, new address[](0), 0, true).adapters;
    }

    /// @notice How many requests `owner` has waiting in this Fund's unsettled batches that it paid for itself (at
    ///      most `maxLive`).
    function liveRequests(address vault, address owner) external view returns (uint256) {
        return _liveOf(_live[vault][owner][owner]);
    }

    /// @notice How many requests `payer` has waiting for `receiver` in this Fund (at most `maxLive` per pair).
    function liveRequests(address vault, address payer, address receiver) external view returns (uint256) {
        return _liveOf(_live[vault][payer][receiver]);
    }

    function _liveOf(uint256[MAX_LIVE] storage slots) private view returns (uint256 n) {
        for (uint256 k; k < MAX_LIVE; ++k) {
            if (slots[k] != 0 && _waiting(slots[k])) ++n;
        }
    }

    /// @notice Decode an adapter's `positions` reply. External so a malformed reply can be caught.
    function decodePositions(bytes calldata data) external pure returns (Amount[] memory, Amount[] memory) {
        return abi.decode(data, (Amount[], Amount[]));
    }

    /// @notice Decode an adapter's `unvalued` reply. External so a malformed reply can be caught.
    function decodeAmounts(bytes calldata data) external pure returns (Amount[] memory) {
        return abi.decode(data, (Amount[]));
    }

    // ================================================================ internals: opening, requests

    function _open(address vault, uint256 stakeUsdg, uint16 managementBps, uint16 performanceBps, address recipient)
        private
        returns (uint256 shares)
    {
        if (!factory.isFund(vault) || IFundVault(vault).teller() != address(this)) revert NotFund();
        IFundController c = _controller(vault);
        if (c.owner() != msg.sender) revert NotOwner();
        if (c.baseAsset() != usdg) revert NotFund();
        FundState storage st = _funds[vault];
        uint256 supply = IERC20(vault).totalSupply();
        if (supply > DEAD_SHARES) revert AlreadyOpen();
        if (stakeUsdg < minOpeningStake) revert StakeTooSmall();
        if (supply != 0) {
            // Reopening a Fund every holder left: what is still in it belongs to the dead shares and would pass
            // to the new owner's shares, so it must be no more than crumbs.
            (uint256 rest, bool ok) = TellerMath.navOf(c, Side.Fair);
            if (!ok || rest >= dustUsd) revert NotEmpty();
            // Reopening sets fee terms at once (`fees.start`), so not over a deposit someone else still has
            // waiting: it was queued under the old terms and may be past its cut-off, where it cannot be cancelled.
            if (outsideQueued[vault] != 0) revert NotEmpty();
        }
        IERC20(usdg).safeTransferFrom(msg.sender, vault, stakeUsdg);
        IFundVault(vault).track(usdg);
        if (supply == 0) IFundVault(vault).mint(address(this), DEAD_SHARES); // never owed, never redeemed
        shares = stakeUsdg * _shareScale;
        IFundVault(vault).mint(msg.sender, shares); // the owner's own shares: no latch (`FundVault._update`)
        st.opened = true;
        st.windDownAt = 0;
        if (st.openBatch == 0) {
            st.openBatch = 1;
            _batches[vault][1].cutoff = _cutoffAfter(st, uint64(block.timestamp));
        }
        fees.start(vault, managementBps, performanceBps, recipient);
        emit Opened(vault, msg.sender, stakeUsdg, shares);
    }

    /// @dev Queue a request owned by `owner` in the open batch, or, while it is full, in the next batch with room (at
    ///      most `MAX_SPILL` ahead), giving that batch its cut-off on the schedule.
    function _queue(address vault, Kind kind, uint256 amount, uint256 min, address owner)
        private
        returns (uint256 id, uint64 b)
    {
        if (owner == address(0) || owner == vault || owner == address(this)) revert BadReceiver();
        b = _currentBatch(vault);
        mapping(uint64 => Batch) storage bs = _batches[vault];
        for (uint256 k; bs[b].count >= MAX_REQUESTS; ++k) {
            if (k == MAX_SPILL) revert BatchFull();
            uint64 prev = bs[b].cutoff;
            ++b;
            if (bs[b].cutoff == 0) bs[b].cutoff = _cutoffAfter(_funds[vault], prev);
        }
        ++bs[b].count;
        id = nextId++;
        _takeSlot(_live[vault][msg.sender][owner], id);
        _requests[id] = Request(
            vault, b, kind, Status.Pending, 0, owner, uint64(block.timestamp), 0, uint128(amount), uint128(min)
        );
        _ids[vault][b].push(id);
        _pos[id] = _ids[vault][b].length;
    }

    /// @dev Give request `id` one of the payer and owner pair's `maxLive` places in this Fund: a free one, or one
    ///      whose request no longer waits (settled, cancelled, paid back or claimed). Keyed by both, so a payer
    ///      filling places for someone else never touches that someone's own places, or another payer's for them.
    function _takeSlot(uint256[MAX_LIVE] storage slots, uint256 id) private {
        uint256 n = maxLive;
        for (uint256 k; k < n; ++k) {
            uint256 old = slots[k];
            if (old == 0 || !_waiting(old)) {
                slots[k] = id;
                return;
            }
        }
        revert TooManyRequests();
    }

    /// @dev A request still waiting: a deposit until a round of its batch takes it, a cash exit until its batch's
    ///      first round.
    function _waiting(uint256 id) private view returns (bool) {
        Request storage r = _requests[id];
        if (r.status != Status.Pending) return false;
        Batch storage b = _batches[r.vault][r.batch];
        return r.kind == Kind.Deposit ? r.round == 0 && !b.settled : b.rounds == 0;
    }

    /// @dev The open batch, rolling on once its cut-off has passed (past any later batch that already closed).
    function _currentBatch(address vault) private returns (uint64 id) {
        FundState storage st = _funds[vault];
        mapping(uint64 => Batch) storage bs = _batches[vault];
        id = st.openBatch;
        if (block.timestamp >= bs[id].cutoff) {
            ++id;
            while (bs[id].cutoff != 0 && block.timestamp >= bs[id].cutoff) ++id;
            if (bs[id].cutoff == 0) bs[id].cutoff = _cutoffAfter(st, uint64(block.timestamp));
            st.openBatch = id;
        }
    }

    /// @dev The first cut-off on the Fund's schedule strictly after `t`.
    function _cutoffAfter(FundState storage st, uint64 t) private view returns (uint64) {
        uint64 interval = st.interval == 0 ? DEFAULT_INTERVAL : st.interval;
        uint64 offset = st.interval == 0 ? DEFAULT_OFFSET : st.offset;
        if (t < offset) return offset;
        return offset + ((t - offset) / interval + 1) * interval;
    }

    /// @dev A deposit queued by an outsider is no longer waiting: once none is, the latch it set may be undone
    ///      (the vault keeps it if a share ever reached an outsider).
    function _dropOutside(address vault, uint256 id) private {
        if (!_outside[id]) return;
        delete _outside[id];
        if (--outsideQueued[vault] == 0) IFundVault(vault).unlatchOutsideHolder();
    }

    function _closed(address vault, uint64 id) private view returns (Batch storage b) {
        if (!_funds[vault].opened) revert NotOpen();
        b = _batches[vault][id];
        if (b.cutoff == 0 || block.timestamp < b.cutoff) revert NotReady();
    }

    // ================================================================ internals: pockets

    function _snapNow(address vault) private view returns (uint256) {
        return IFundVault(vault).currentSnapshotId();
    }

    /// @dev Record that `shares` sat in the teller's custody for `to` over the snapshots after `from` up to `until`:
    ///      `to` counts them in every pocket taken meanwhile (`custodyAt`, read by `Pockets`). One write however
    ///      many snapshots were taken, so no claim or cancel depends on their number; a record that
    ///      continues the account's last one with the same shares extends it instead.
    function _assign(address vault, address to, uint256 shares, uint256 from, uint256 until) private {
        if (shares == 0 || until <= from) return;
        Custody[] storage list = _custody[vault][to];
        uint256 n = list.length;
        if (n != 0) {
            Custody storage last = list[n - 1];
            if (last.shares == shares && last.until == from) {
                last.until = uint32(until);
                return;
            }
        }
        list.push(Custody(uint128(shares), uint32(from), uint32(until)));
    }

    /// @notice Shares the teller held in custody for `account` at snapshot `id` of `vault` (escrowed cash exits,
    ///         minted shares not yet claimed), once that custody has ended: what `Pockets` adds to the account's own
    ///         snapshot balance.
    function custodyAt(address vault, uint256 id, address account) external view returns (uint256 shares) {
        Custody[] storage list = _custody[vault][account];
        for (uint256 i; i < list.length; ++i) {
            Custody memory c = list[i];
            if (c.from < id && id <= c.until) shares += c.shares;
        }
    }

    // ================================================================ internals: tokens

    function _ctx(address vault) private view returns (TellerOps.Ctx memory) {
        return TellerOps.Ctx(vault, _controller(vault), usdg);
    }

    /// @dev Price the Fund's counted tokens once for a settlement (`PriceRouter.warm`): every adapter values its
    ///      positions at them and NAV prices every side, so each later read is a transient load. `release` ends it
    ///      before the settlement returns. A router without the cache ignores both.
    function _warm(address vault) private returns (address router) {
        router = address(_controller(vault).router());
        (bool ok,) = router.call(abi.encodeWithSignature("warm(address[])", IFundVault(vault).trackedTokens()));
        ok;
    }

    function _release(address router) private {
        (bool ok,) = router.call(abi.encodeWithSignature("release()"));
        ok;
    }

    /// @dev The teller still holds at least what it owes in USDG and in this Fund's shares.
    function _solvent(address vault) private view {
        if (IERC20(usdg).balanceOf(address(this)) < owed[usdg]) revert EscrowTouched(usdg);
        if (IERC20(vault).balanceOf(address(this)) < owed[vault]) revert EscrowTouched(vault);
    }

    // ================================================================ internals: misc

    function _controller(address vault) private view returns (IFundController) {
        return IFundController(IFundVault(vault).controller());
    }

    function _onlyOwner(address vault) private view {
        if (!_funds[vault].opened && !factory.isFund(vault)) revert NotFund();
        if (_controller(vault).owner() != msg.sender) revert NotOwner();
    }
}
