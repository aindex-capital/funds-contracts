// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {FundTestBase} from "../utils/FundTestBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockSwap} from "../utils/MockAdapters.sol";
import {FundController} from "../../src/core/FundController.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {IPriceRouter, PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {ISessionSource} from "../../src/interfaces/ISessionSource.sol";
import {ILookThrough} from "../../src/interfaces/ILookThrough.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {IndexLookThrough} from "../../src/adapters/index/IndexLookThrough.sol";
import {MockFolio} from "../adapters/index/IndexMocks.sol";

/// @dev A stock feed: `price` is ok only while the reading is fresh (the test says when it is stale);
///      `lastPrice` gives the last reading regardless of age.
contract MockStockSource is IPriceSource, ISessionSource {
    uint256 public usd;
    uint64 public at;
    bool public stale;

    function set(uint256 usd_, uint64 at_) external {
        usd = usd_;
        at = at_;
    }

    function setStale(bool s) external {
        stale = s;
    }

    function price(address) external view returns (uint256, uint64, bool) {
        return stale ? (0, 0, false) : (usd, at, true);
    }

    function lastPrice(address) external view returns (uint256, uint64, bool) {
        return (usd, at, usd != 0);
    }

    function name() external pure returns (string memory) {
        return "stock";
    }
}

/// @dev Says an index share holds `thinPer` THIN and `feedPer` FEED per whole share; or reverts when told to.
contract MockLookThrough is ILookThrough {
    address public thin;
    address public feed;
    uint256 public thinPer;
    uint256 public feedPer;
    bool public broken;

    constructor(address thin_, address feed_, uint256 thinPer_, uint256 feedPer_) {
        (thin, feed, thinPer, feedPer) = (thin_, feed_, thinPer_, feedPer_);
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function underlying(address, uint256 amount) external view returns (Amount[] memory a) {
        require(!broken, "broken");
        a = new Amount[](2);
        a[0] = Amount(thin, amount * thinPer / 1e18);
        a[1] = Amount(feed, amount * feedPer / 1e18);
    }
}

contract SessionsTest is FundTestBase {
    MockERC20 stock;
    MockStockSource feedSrc;
    uint256 monday; // a Monday, as a UTC day number

    function setUp() public {
        _setUpCore();
        stock = new MockERC20("Stock", "STK", 18);
        feedSrc = new MockStockSource();
        // Start on a Wednesday well after the epoch: day 20_005 is a Wednesday ((d - 2) % 7 == 4).
        uint256 wed = 20_005;
        assertEq((wed - 2) % 7, 4);
        vm.warp(wed * 1 days + 12 hours);
        monday = wed + 5;
        feedSrc.set(100e18, uint64(block.timestamp));
        router.propose(
            address(stock),
            PriceRouter.Config({
                primary: IPriceSource(address(feedSrc)),
                check: IPriceSource(address(0)),
                class_: PriceClass.Feed,
                haircutBps: 50,
                maxDeviationBps: 0,
                decimals: 0,
                chained: 0
            })
        );
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 1000,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
        assertGt(router.pendingSessionAt(address(stock)), 0, "a new session waits");
        uint256[] memory days_ = new uint256[](1);
        days_[0] = monday;
        router.addHolidays(days_);
        vm.warp(block.timestamp + 1 days); // Thursday 12:00
        router.applyPending(address(stock));
        router.applySession(address(stock));
    }

    function _at(uint256 day, uint256 secs) internal {
        vm.warp(day * 1 days + secs);
    }

    function test_MondayHoliday() public {
        uint256 friday = monday - 3;
        // Friday 19:55: the last reading before the long weekend.
        _at(friday, 19 hours + 55 minutes);
        feedSrc.set(100e18, uint64(block.timestamp));
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 99.5e18, "open market: normal haircut");
        assertFalse(router.marketClosed(address(stock)));

        // Saturday: the source still calls it fresh (weekend rule); the spread widens.
        _at(friday + 1, 10 hours);
        assertTrue(router.marketClosed(address(stock)));
        q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 89.5e18);
        assertEq(q.ask, 110.5e18);

        // Monday holiday: the source calls it stale; the router still uses Friday's close, widened.
        _at(monday, 15 hours);
        feedSrc.setStale(true);
        assertTrue(router.marketClosed(address(stock)));
        q = router.quote(address(stock));
        assertTrue(q.available, "frozen on a holiday");
        assertEq(q.fair, 100e18);
        assertEq(q.bid, 89.5e18);

        // Tuesday 01:00: the market reopened (Monday 20:00 New York, 00:00 UTC in summer), but the feed has no
        // round of the new session yet: still the closure's price and spread.
        _at(monday + 1, 1 hours);
        assertTrue(router.marketClosed(address(stock)), "no round since the reopening");
        q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 89.5e18);
        // The first round of the new session opens it.
        feedSrc.setStale(false);
        feedSrc.set(101e18, uint64(block.timestamp));
        assertFalse(router.marketClosed(address(stock)));
        assertEq(router.quote(address(stock)).bid, 101e18 * 9_950 / 10_000);
        // A feed that never comes back is unavailable `REOPEN_GRACE` after the reopening, as on any working day.
        feedSrc.set(100e18, uint64((monday - 3) * 1 days + 19 hours + 55 minutes));
        feedSrc.setStale(true);
        _at(monday + 1, router.REOPEN_GRACE());
        assertFalse(router.quote(address(stock)).available);
    }

    function test_ReadingTooOldWhenClosureBeganIsNotUsed() public {
        // Last reading Thursday 12:00: 36 hours before the weekend began.
        _at(monday - 4, 12 hours);
        feedSrc.set(100e18, uint64(block.timestamp));
        _at(monday, 15 hours);
        feedSrc.setStale(true);
        assertFalse(router.quote(address(stock)).available);
    }

    function test_HolidayAddedLateDoesNotCount() public {
        uint256 nextMonday = monday + 7;
        uint256[] memory days_ = new uint256[](1);
        days_[0] = nextMonday;
        _at(nextMonday - 1, 6 hours); // Sunday: too late, it counts from Monday 06:00
        router.addHolidays(days_);
        _at(nextMonday, 3 hours);
        feedSrc.set(100e18, uint64(block.timestamp)); // the feed's first round of the week
        assertFalse(router.isHoliday(nextMonday));
        assertFalse(router.marketClosed(address(stock)));
        _at(nextMonday, 7 hours);
        assertTrue(router.isHoliday(nextMonday));
    }

    function test_HolidayRemovedAtOnce() public {
        uint256[] memory days_ = new uint256[](1);
        days_[0] = monday;
        router.removeHolidays(days_);
        _at(monday, 15 hours);
        assertTrue(router.marketClosed(address(stock)), "open by the calendar, but no round of the week yet");
        feedSrc.set(100e18, uint64(block.timestamp));
        assertFalse(router.marketClosed(address(stock)));
    }

    function test_SessionLoweringsAtOnceRaisesWait() public {
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 2000,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
        assertEq(router.sessionOf(address(stock)).closedHaircutBps, 2000, "wider spread at once");
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 500,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
        assertEq(router.sessionOf(address(stock)).closedHaircutBps, 2000, "narrower waits");
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: false,
                closedHaircutBps: 0,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
        assertTrue(router.sessionOf(address(stock)).usSession, "dropping the session waits: it narrows the spread");
        assertGt(router.pendingSessionAt(address(stock)), 0);
        vm.expectRevert(PriceRouter.NotOwner.selector);
        vm.prank(makeAddr("x"));
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 0,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
    }

    function test_FundHoldingAStockKeepsWorkingOnAMondayHoliday() public {
        _createFund(_openDial(), 1000e6);
        MockSwap impl = new MockSwap();
        registry.register(address(impl), "");
        source.set(address(stock), 100e18); // the venue's own price
        address swap = _enable(address(impl), abi.encode(source, uint256(0)));
        _at(monday - 3, 19 hours + 55 minutes);
        feedSrc.set(100e18, uint64(block.timestamp));
        vm.prank(manager);
        controller.act(swap, abi.encode(address(usdg), address(stock), uint256(100e6)));
        _at(monday, 15 hours);
        feedSrc.setStale(true);
        (, bool complete) = controller.nav(uint8(Side.Bid));
        assertTrue(complete);
        vm.prank(manager);
        controller.act(swap, abi.encode(address(usdg), address(usdg), uint256(1e6)));
        // After the reopening with no new round the Fund still works at the closure's prices, until
        // `REOPEN_GRACE` after the reopening (Tuesday 00:00 UTC); then it waits for the feed.
        _at(monday + 1, 1 hours);
        vm.prank(manager);
        controller.act(swap, abi.encode(address(usdg), address(usdg), uint256(1e6)));
        _at(monday + 1, router.REOPEN_GRACE());
        vm.prank(manager);
        vm.expectRevert(FundController.PriceUnavailable.selector);
        controller.act(swap, abi.encode(address(usdg), address(usdg), uint256(1e6)));
    }
}

contract LookThroughTest is FundTestBase {
    MockERC20 thin;
    MockERC20 feed;
    MockERC20 index;
    MockLookThrough lt;
    address swap;

    function setUp() public {
        _setUpCore();
        thin = new MockERC20("Thin", "THIN", 18);
        feed = new MockERC20("Feed", "FEED", 18);
        index = new MockERC20("Index", "IDX", 18);
        _price(address(thin), 1e18, PriceClass.Thin, 0);
        _price(address(feed), 1e18, PriceClass.Feed, 0);
        _price(address(index), 2e18, PriceClass.Feed, 0); // one share: 1 THIN + 1 FEED = $2
        lt = new MockLookThrough(address(thin), address(feed), 1e18, 1e18);
        Dial memory d = _openDial();
        d.maxThinBps = 1000; // 10%
        _createFund(d, 1000e6);
        MockSwap impl = new MockSwap();
        registry.register(address(impl), "");
        swap = _enable(address(impl), abi.encode(source, uint256(0)));
    }

    function _setLookThrough(ILookThrough x) internal {
        router.proposeLookThrough(address(index), x);
        vm.expectRevert(PriceRouter.NotReady.selector);
        router.applyLookThrough(address(index));
        vm.warp(block.timestamp + 1 days);
        router.applyLookThrough(address(index));
    }

    function test_WithoutLookThroughWrappedThinEscapesTheCap() public {
        vm.prank(manager);
        controller.act(swap, abi.encode(address(usdg), address(index), uint256(400e6)));
    }

    function test_LookThroughCountsWrappedThin() public {
        _setLookThrough(lt);
        vm.startPrank(manager);
        controller.act(swap, abi.encode(address(usdg), address(index), uint256(200e6))); // $100 thin inside
        vm.expectPartialRevert(FundController.ClassCap.selector);
        controller.act(swap, abi.encode(address(usdg), address(index), uint256(10e6)));
        vm.stopPrank();
    }

    function test_BrokenLookThroughCountsAllAsThin() public {
        _setLookThrough(lt);
        lt.setBroken(true);
        vm.startPrank(manager);
        controller.act(swap, abi.encode(address(usdg), address(index), uint256(100e6))); // $100 all thin
        vm.expectPartialRevert(FundController.ClassCap.selector);
        controller.act(swap, abi.encode(address(usdg), address(index), uint256(2e6)));
        vm.stopPrank();
        // NAV still uses the index's own price.
        (uint256 n, bool complete) = controller.nav(uint8(Side.Fair));
        assertTrue(complete);
        assertEq(n, 1000e18);
    }

    function test_LookThroughChangesOnlyByOwnerAndWait() public {
        vm.prank(makeAddr("x"));
        vm.expectRevert(PriceRouter.NotOwner.selector);
        router.proposeLookThrough(address(index), lt);
        _setLookThrough(lt);
        assertEq(address(router.lookThrough(address(index))), address(lt));
        router.proposeLookThrough(address(index), ILookThrough(address(0)));
        assertEq(address(router.lookThrough(address(index))), address(lt), "clearing waits too");
    }

    function test_IndexLookThroughReadsTheBasket() public {
        address[] memory basket = new address[](2);
        basket[0] = address(thin);
        basket[1] = address(feed);
        MockFolio folio = new MockFolio(basket);
        thin.mint(address(folio), 300e18);
        feed.mint(address(folio), 100e18);
        folio.seed(address(this), 100e18);
        IndexLookThrough ilt = new IndexLookThrough();
        Amount[] memory parts = ilt.underlying(address(folio), 10e18);
        assertEq(parts.length, 2);
        assertEq(parts[0].token, address(thin));
        assertEq(parts[0].amount, 30e18);
        assertEq(parts[1].amount, 10e18);
        folio.setMidFill(true);
        vm.expectRevert(IndexLookThrough.Unreadable.selector);
        ilt.underlying(address(folio), 10e18);
    }
}
