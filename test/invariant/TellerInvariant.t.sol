// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TellerBase, MockBook} from "../unit/TellerBase.t.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {Teller} from "../../src/core/Teller.sol";
import {FundFees} from "../../src/core/Fees.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {FundController} from "../../src/core/FundController.sol";

/// @notice A closed-market source tests set by hand: one ratio per token, in USDG.
contract MockClosedSource is IClosedMarketSource {
    mapping(address => uint256) public ratio;
    address public usdg;

    constructor(address usdg_) {
        usdg = usdg_;
    }

    function set(address token, uint256 r) external {
        ratio[token] = r;
    }

    function closedRatios(address token) external view returns (Ratio[] memory out) {
        if (ratio[token] == 0) return out;
        out = new Ratio[](1);
        out[0] = Ratio(usdg, ratio[token]);
    }
}

/**
 * @notice Drives the teller with four holders, a keeper, a manager and moving prices and time (weekends included,
 *         with a closed-market source). After every teller operation the handler checks that what one share of the
 *         Fund is worth at fair, fee shares set aside, did not fall: entrants pay the ask, leavers get the bid,
 *         matched pairs trade at fair inside the teller, exits in kind take their slice pro rata, and a slice set
 *         aside for an exit in parts is no longer counted. The invariants read the ghosts.
 */
contract TellerHandler is Test {
    Teller public tel;
    FundVault public vault;
    FundController public controller;
    FundFees public fees;
    MockBook public book;
    MockPriceSource public src;
    MockClosedSource public closed;
    MockERC20 public usdg;
    MockERC20 public tokA;
    MockERC20 public tokB;
    address public owner;
    address public aix;
    address public treasury;
    address[4] public actors;
    uint256[] public ids;
    uint256[] public exits;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    // Ghosts.
    bool public diluted; // a share was worth less at fair after a teller operation (fees set aside)
    bool public feeOverMax; // an accrual took more than 2% a year plus 20% of the gain above the mark
    int256 public usdgNet; // USDG into the teller from users and the Fund, less what it paid out
    uint256 public usdgIn; // deposited into the teller
    uint256 public settlements;
    uint256 public weekendSettlements;
    uint256 public matched;
    uint256 public cashShort;
    uint256 public waited;
    uint256 public inKinds;
    uint256 public partsStarted;
    uint256 public slicesClaimed;
    uint256 public slicesReleased;
    uint256 public managerMoves;

    struct Snap {
        uint256 supply;
        uint256 feeShares;
        uint256 nav;
        bool navOk;
        uint256 navBid;
        uint256 hwm;
        uint256 since;
    }

    constructor(
        Teller tel_,
        FundVault vault_,
        FundFees fees_,
        MockBook book_,
        MockPriceSource src_,
        MockClosedSource closed_,
        MockERC20[3] memory t,
        address[3] memory people
    ) {
        tel = tel_;
        vault = vault_;
        controller = FundController(vault_.controller());
        fees = fees_;
        book = book_;
        src = src_;
        closed = closed_;
        usdg = t[0];
        tokA = t[1];
        tokB = t[2];
        owner = people[0];
        aix = people[1];
        treasury = people[2];
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0xA11CE + i));
            vm.startPrank(actors[i]);
            usdg.approve(address(tel), type(uint256).max);
            tokA.approve(address(tel), type(uint256).max);
            tokB.approve(address(tel), type(uint256).max);
            vault.approve(address(tel), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------ requests

    function deposit(uint256 who, uint256 amount) external {
        address a = actors[who % 4];
        amount = bound(amount, 10e6, 5000e6);
        usdg.mint(a, amount);
        uint256 t0 = usdg.balanceOf(address(tel));
        vm.prank(a);
        try tel.requestDeposit(address(vault), amount, 1) returns (uint256 id) {
            ids.push(id);
            usdgIn += amount;
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
        } catch {}
    }

    function redeemCash(uint256 who, uint256 frac) external {
        address a = actors[who % 4];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 sh = bal * bound(frac, 1, 100) / 100;
        vm.prank(a);
        try tel.requestRedeem(address(vault), sh, 1) returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    /// @dev A request paid by one actor for another (a partner app or a zap): the receiver owns it.
    function depositFor(uint256 who, uint256 to, uint256 amount) external {
        address a = actors[who % 4];
        amount = bound(amount, 10e6, 5000e6);
        usdg.mint(a, amount);
        uint256 t0 = usdg.balanceOf(address(tel));
        vm.prank(a);
        try tel.requestDeposit(address(vault), amount, 1, actors[to % 4], bytes32(to)) returns (uint256 id) {
            ids.push(id);
            usdgIn += amount;
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
        } catch {}
    }

    function redeemCashFor(uint256 who, uint256 to, uint256 frac) external {
        address a = actors[who % 4];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 sh = bal * bound(frac, 1, 100) / 100;
        vm.prank(a);
        try tel.requestRedeem(address(vault), sh, 1, actors[to % 4]) returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    function cancel(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        ITeller.Request memory r = tel.request(id);
        uint256 t0 = usdg.balanceOf(address(tel));
        vm.prank(r.owner);
        try tel.cancel(id) {
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
        } catch {}
    }

    function claim(uint256 seed) external {
        if (ids.length == 0) return;
        _claimOne(ids[seed % ids.length]);
    }

    function _claimOne(uint256 id) internal {
        uint256 t0 = usdg.balanceOf(address(tel));
        try tel.claim(id) {
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
        } catch {}
    }

    // ------------------------------------------------ exits in kind

    function inKind(uint256 who, uint256 frac) external {
        address a = actors[who % 4];
        uint256 sh = _sharesOf(a, frac);
        if (sh == 0) return;
        _fund(a);
        Snap memory s0 = _snap();
        uint256 t0 = usdg.balanceOf(address(tel));
        vm.prank(a);
        try tel.redeemInKind(address(vault), sh, a) {
            ++inKinds;
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
            _check(s0, _snap());
        } catch {}
    }

    function startParts(uint256 who, uint256 frac) external {
        address a = actors[who % 4];
        uint256 sh = _sharesOf(a, frac);
        if (sh == 0) return;
        _fund(a);
        Snap memory s0 = _snap();
        uint256 t0 = usdg.balanceOf(address(tel));
        vm.prank(a);
        try tel.startInKind(address(vault), sh, a, new address[](0)) returns (uint256 id) {
            ++partsStarted;
            exits.push(id);
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
            _check(s0, _snap());
        } catch {}
    }

    function claimSlice(uint256 seed, bool release) external {
        if (exits.length == 0) return;
        uint256 id = exits[seed % exits.length];
        if (tel.exitUnits(id, address(book)) == 0) return;
        ITeller.Exit memory x = tel.exit(id);
        _fund(x.owner);
        Snap memory s0 = _snap();
        uint256 t0 = usdg.balanceOf(address(tel));
        vm.prank(x.owner);
        if (release) {
            try tel.releaseInKind(id, address(book)) {
                ++slicesReleased;
            } catch {
                return;
            }
        } else {
            address[] memory one = new address[](1);
            one[0] = address(book);
            try tel.claimInKind(id, one) {
                ++slicesClaimed;
            } catch {
                return;
            }
        }
        usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
        _check(s0, _snap());
    }

    // ------------------------------------------------ the world

    /// @dev Time and prices move; sometimes on to a weekend, where tokA's closed-market pool says something else.
    function move(uint256 secs, uint256 priceA, uint256 priceB, uint256 pool, bool weekend) external {
        if (weekend) {
            uint256 day = block.timestamp / 1 days + 1;
            while (day % 7 != 2) ++day; // Saturday
            vm.warp(day * 1 days + bound(secs, 0, 1 days));
        } else {
            vm.warp(block.timestamp + bound(secs, 1 hours, 3 days));
        }
        uint256 a = bound(priceA, 50e18, 200e18);
        src.set(address(tokA), a);
        src.set(address(tokB), bound(priceB, 25_000e18, 100_000e18));
        closed.set(address(tokA), a * bound(pool, 85, 115) / 100);
    }

    /// @dev The manager's own trades: a gain into the book, or a USDG borrow (never while a slice of it waits:
    ///      the controller would refuse the manager then).
    function manage(uint256 amount, bool borrow) external {
        (uint256 fund, uint256 total) = controller.unitsOf(address(book));
        if (fund != total) return;
        ++managerMoves;
        if (borrow) book.borrow(address(usdg), bound(amount, 1e6, 200e6));
        else book.seed(address(tokA), bound(amount, 1e15, 1e18));
    }

    function settle() external {
        (uint64 open, uint64 cutoff) = tel.currentBatch(address(vault));
        ITeller.Batch memory cur = tel.batch(address(vault), open);
        if (cur.count != 0 && block.timestamp < cutoff) vm.warp(cutoff);
        uint64 bt;
        for (uint64 b = 1; b <= open; ++b) {
            ITeller.Batch memory x = tel.batch(address(vault), b);
            if (!x.settled && x.cutoff != 0 && block.timestamp >= x.cutoff) {
                bt = b;
                break;
            }
        }
        if (bt == 0) return;
        Snap memory s0 = _snap();
        uint256 t0 = usdg.balanceOf(address(tel));
        bool wk = (block.timestamp / 1 days) % 7 == 2 || (block.timestamp / 1 days) % 7 == 3;
        try tel.settle(address(vault), bt, new uint256[](0)) {
            ++settlements;
            if (wk) ++weekendSettlements;
            usdgNet += int256(usdg.balanceOf(address(tel))) - int256(t0);
            ITeller.Batch memory r = tel.batch(address(vault), bt);
            if (r.matchedShares != 0) ++matched;
            if (r.sharesBack != 0) ++cashShort;
            if (!r.settled) ++waited;
            _check(s0, _snap());
            uint256[] memory list = tel.batchRequests(address(vault), bt);
            for (uint256 i; i < list.length; ++i) {
                _claimOne(list[i]);
            }
        } catch {}
    }

    // ------------------------------------------------ helpers and checks

    function _sharesOf(address a, uint256 frac) internal view returns (uint256) {
        return vault.balanceOf(a) * bound(frac, 1, 100) / 100;
    }

    /// @dev Drain the Fund's cash to `keep` USDG (the manager invested it), so cash exits come back short.
    function invest(uint256 keep) external {
        uint256 bal = usdg.balanceOf(address(vault));
        keep = bound(keep, 0, 2000e6);
        if (bal <= keep) return;
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), bal - keep);
        tokA.mint(address(vault), (bal - keep) * 1e12 / 100);
    }

    /// @dev Enough to bring any debt shortfall of an exit in kind.
    function _fund(address a) internal {
        usdg.mint(a, 10_000e6);
    }

    function _snap() internal view returns (Snap memory s) {
        s.supply = vault.totalSupply();
        s.feeShares =
            vault.balanceOf(owner) + vault.balanceOf(aix) + vault.balanceOf(treasury) + vault.balanceOf(address(fees));
        (s.nav, s.navOk) = controller.nav(0);
        (s.navBid,) = controller.nav(1);
        s.hwm = fees.highWaterMark(address(vault));
        s.since = fees.terms(address(vault)).lastAccrual;
    }

    /// @dev Fees are accrued first, by minting (or, for first loss, burning) shares; after that the operation may
    ///      not lower what one share is worth at fair, beyond rounding. What the fees took is checked on its own.
    function _check(Snap memory a, Snap memory b) internal {
        if (!a.navOk || !b.navOk) return;
        int256 feeMinted = int256(b.feeShares) - int256(a.feeShares);
        uint256 base = uint256(int256(a.supply) + feeMinted);
        if (base == 0 || b.supply == 0) return;
        uint256 pa = a.nav * 1e18 / base;
        uint256 pb = b.nav * 1e18 / b.supply;
        // Rounding: a raw unit of a token per row both ways (a raw unit of tokB, 8 decimals at up to $100,000, is a
        // tenth of a cent; a slice set aside scales the book's rows down), so a cent of NAV, and the division.
        if (pb + 1e16 * 1e18 / b.supply + pa / 1e12 + 1 < pa) diluted = true;
        if (feeMinted > 0) {
            uint256 m = uint256(feeMinted);
            uint256 feeUsd = m * a.navBid / (a.supply + m);
            uint256 p0 = a.navBid * WAD / a.supply;
            uint256 perf = a.hwm != 0 && p0 > a.hwm ? (p0 - a.hwm) * a.supply / WAD * 2000 / 10_000 : 0;
            uint256 mgmt = a.navBid * 200 * (block.timestamp - a.since) / (10_000 * YEAR);
            if (feeUsd > perf + mgmt + 1e12) feeOverMax = true;
        }
    }

    function exitsLength() external view returns (uint256) {
        return exits.length;
    }
}

contract TellerInvariantTest is TellerBase {
    TellerHandler internal handler;
    MockBook internal book;
    MockClosedSource internal closedSrc;

    function setUp() public {
        _setUpTeller();
        _openFund(200, 2000);
        tel.setParams(10e6, 1e6, 1e18, 1e14, 500); // a one-USDG minimum, so small holders' cash exits clear it
        // tokA trades at weekends: its pool says something else than Friday's feed (worse-of, 1% spread, 3% band).
        closedSrc = new MockClosedSource(address(usdg));
        closedSrc.set(address(tokA), 100e18);
        _session(address(tokA), 450, 100, 300, IClosedMarketSource(address(closedSrc)));
        // The manager's past: part of the stake became A in the vault; the adapter holds A and B and owes USDG.
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 400e6);
        _hold(tokA, 3e18);
        book = _book(0);
        book.seed(address(tokA), 1e18);
        book.seed(address(tokB), 0.002e8);
        book.borrow(address(usdg), 100e6);
        book.addFees(address(tokA), 0.01e18);

        MockERC20[3] memory t = [usdg, tokA, tokB];
        address[3] memory people = [owner, aix, treasury];
        // Every actor starts as a holder, so cash exits, matches and exits in kind happen from the first call.
        for (uint256 i; i < 4; ++i) {
            _join(address(uint160(0xA11CE + i)), 2000e6);
        }
        handler = new TellerHandler(tel, vault, fees, book, source, closedSrc, t, people);
        tel.setKeeper(address(handler), true);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](13);
        sel[0] = TellerHandler.deposit.selector;
        sel[1] = TellerHandler.redeemCash.selector;
        sel[2] = TellerHandler.cancel.selector;
        sel[3] = TellerHandler.claim.selector;
        sel[4] = TellerHandler.inKind.selector;
        sel[5] = TellerHandler.startParts.selector;
        sel[6] = TellerHandler.claimSlice.selector;
        sel[7] = TellerHandler.move.selector;
        sel[8] = TellerHandler.manage.selector;
        sel[9] = TellerHandler.settle.selector;
        sel[10] = TellerHandler.invest.selector;
        sel[11] = TellerHandler.depositFor.selector;
        sel[12] = TellerHandler.redeemCashFor.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    /// @notice No teller operation lowers what a share is worth at fair (fees set aside).
    function invariant_NoHolderDiluted() public view {
        assertFalse(handler.diluted(), "a share was worth less after a teller operation");
    }

    /// @notice Fees never exceed the maxima.
    function invariant_FeesWithinMaxima() public view {
        assertFalse(handler.feeOverMax(), "fees above 2% a year plus 20% of gains");
        FundFees.Terms memory t = fees.terms(address(vault));
        assertLe(t.management, fees.MAX_MANAGEMENT_BPS());
        assertLe(t.performance, fees.MAX_PERFORMANCE_BPS());
    }

    /// @notice The teller holds what it owes, and every USDG it took in is still held or went out (into the Fund,
    ///         back to its owner, or to a leaver), nothing else.
    function invariant_TellerHoldsWhatItOwes() public view {
        uint256 held = usdg.balanceOf(address(tel));
        assertGe(held, tel.owed(address(usdg)), "the teller holds less USDG than it owes");
        assertEq(int256(held), handler.usdgNet(), "USDG unaccounted for");
        assertGe(vault.balanceOf(address(tel)), tel.owed(address(vault)), "shares owed exceed shares held");
        assertGe(tokA.balanceOf(address(tel)), tel.owed(address(tokA)));
        assertGe(tokB.balanceOf(address(tel)), tel.owed(address(tokB)));
    }

    /// @notice The slices set aside for exits in parts are exactly the controller's units owed on the adapter.
    function invariant_PendingExitsMatchTheUnits() public view {
        uint256 sum;
        uint256 n = handler.exitsLength();
        for (uint256 i; i < n; ++i) {
            sum += tel.exitUnits(handler.exits(i), address(book));
        }
        (uint256 fund, uint256 total) = controller.unitsOf(address(book));
        assertEq(sum, total - fund, "exit units and controller units differ");
        assertEq(controller.pendingExits(), sum == 0 ? 0 : 1);
    }

    /// @dev Shows that a run did real work (visible with -vv).
    function afterInvariant() external view {
        console2.log("settlements", handler.settlements(), "at a weekend", handler.weekendSettlements());
        console2.log("with a match", handler.matched(), "cash short", handler.cashShort());
        console2.log("rounds where deposits waited", handler.waited());
        console2.log("in-kind exits", handler.inKinds(), "in parts", handler.partsStarted());
        console2.log("slices claimed", handler.slicesClaimed(), "released", handler.slicesReleased());
        console2.log("manager moves", handler.managerMoves());
    }
}
