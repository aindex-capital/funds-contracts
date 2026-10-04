// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase} from "./TellerBase.t.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {IPriceRouter, PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {Teller} from "../../src/core/Teller.sol";
import {MockERC20} from "../utils/Mocks.sol";

/// @notice A closed-market source tests set by hand: each token's qualifying pool prices, in a quote token.
contract MockClosedSource is IClosedMarketSource {
    mapping(address => Ratio[]) internal _r;

    function set(address token, address quote, uint256[] memory ratios) external {
        delete _r[token];
        for (uint256 i; i < ratios.length; ++i) {
            _r[token].push(Ratio(quote, ratios[i]));
        }
    }

    function closedRatios(address token) external view returns (Ratio[] memory) {
        return _r[token];
    }
}

/// @notice Weekend pricing at settlement (the router's worse-of rule), deposits and exits settling while a held
///         market is closed, the closure's net inflow cap and the rounds deposits wait in.
contract TellerWeekendTest is TellerBase {
    MockClosedSource internal pools;

    uint16 internal constant SPREAD = 100; // 1%
    uint16 internal constant CLAMP = 300; // 3%
    uint16 internal constant FALLBACK = 450; // 4.5% on top of a zero haircut

    function setUp() public {
        _setUpTeller();
        pools = new MockClosedSource();
        _session(address(tokA), FALLBACK, SPREAD, CLAMP, IClosedMarketSource(address(pools)));
        // The Fund: 1,000 USDG and 10 A at $100.
        _hold(tokA, 10e18);
        vm.warp(_next(MON, 15 hours)); // a weekday, market open
    }

    function _pools(uint256 a, uint256 b) internal {
        uint256[] memory r = new uint256[](b == 0 ? (a == 0 ? 0 : 1) : 2);
        if (r.length > 0) r[0] = a;
        if (r.length > 1) r[1] = b;
        pools.set(address(tokA), address(usdg), r);
    }

    function _toSaturday() internal {
        vm.warp(_next(SAT, 10 hours));
        assertTrue(router.marketClosed(address(tokA)));
    }

    // ------------------------------------------------------------ the router's worse-of rule

    function test_WorseOfEntrantsAtHighLeaversAtLow() public {
        _pools(103e18, 98e18);
        _toSaturday();
        IPriceRouter.Quote memory q = router.quote(address(tokA));
        assertEq(q.ask, 103e18 * 10_100 / 10_000, "entrants: the highest pool times (1 + s)");
        assertEq(q.bid, 98e18 * 9_900 / 10_000, "leavers: the lowest pool times (1 - s)");
        assertEq(q.fair, (98e18 + 103e18) / 2);
    }

    function test_LastPriceBoundsBothSides() public {
        _pools(101e18, 0);
        _toSaturday();
        IPriceRouter.Quote memory q = router.quote(address(tokA));
        assertEq(q.ask, 101e18 * 10_100 / 10_000);
        assertEq(q.bid, 100e18 * 9_900 / 10_000, "a pool above the last price leaves leavers at the last price");
    }

    function test_PoolsClampedToTheBand() public {
        _pools(150e18, 50e18);
        _toSaturday();
        IPriceRouter.Quote memory q = router.quote(address(tokA));
        assertEq(q.ask, 103e18 * 10_100 / 10_000, "held within 3% above");
        assertEq(q.bid, 97e18 * 9_900 / 10_000, "held within 3% below");
    }

    function test_FallbackWhenNoPoolQualifies() public {
        _pools(0, 0);
        _toSaturday();
        IPriceRouter.Quote memory q = router.quote(address(tokA));
        assertEq(q.ask, 100e18 * (10_000 + uint256(FALLBACK)) / 10_000);
        assertEq(q.bid, 100e18 * (10_000 - uint256(FALLBACK)) / 10_000);
        assertEq(q.fair, 100e18);
    }

    function test_OpenMarketIgnoresPools() public {
        _pools(110e18, 0);
        IPriceRouter.Quote memory q = router.quote(address(tokA));
        assertEq(q.fair, 100e18);
        assertEq(q.ask, 100e18);
    }

    // ------------------------------------------------------------ settling at weekends

    function test_WeekendDepositMintedAtTheWorseAsk() public {
        _pools(102e18, 0);
        _toSaturday();
        (ITeller.Hold h, address t) = tel.depositHold(address(vault));
        assertEq(uint8(h), uint8(ITeller.Hold.MarketClosed), "informational: weekend pricing applies");
        assertEq(t, address(tokA));
        uint256 id = _deposit(alice, 50e6, 1);
        uint256 want = _sharesAtAsk(50e6);
        _settle(_batchOf(id));
        (uint256 sh,) = _claim(id);
        assertEq(sh, want, "minted at the weekend ask");
        // Holders lose nothing at the open, wherever the price lands inside the pool's range.
        assertLt(sh * _nav(0) / vault.totalSupply(), 50e18, "the entrant pays above fair");
    }

    function test_WeekendLeaverPaidAtTheWorseBid() public {
        uint256 bobShares = _join(bob, 500e6);
        _pools(97.5e18, 0);
        _toSaturday();
        tel.setWeekendOutflowBps(10_000); // this test is about the price, not the closure's outflow cap
        uint256 r = _redeem(bob, bobShares, 1);
        uint256 navBid = _nav(1);
        uint256 supply = vault.totalSupply();
        _settle(_batchOf(r));
        (uint256 back, uint256 out) = _claim(r);
        assertEq(back, 0);
        assertEq(out, bobShares * navBid / supply / 1e12, "paid at the weekend bid");
        assertLt(out, 500e6, "below what he paid in on a weekday");
    }

    function test_WeekendMatchingIsNotFrozen() public {
        uint256 bobShares = _join(bob, 500e6);
        _pools(101e18, 0);
        _toSaturday();
        uint256 r = _redeem(bob, bobShares, 1);
        uint256 a = _deposit(alice, 20e6, 1);
        _settle(_batchOf(a));
        ITeller.Batch memory b = tel.batch(address(vault), _batchOf(a));
        assertGt(b.matchedShares, 0, "entrant and leaver matched at fair at the weekend");
        assertTrue(b.settled);
        _claim(r);
        _claim(a);
    }

    // ------------------------------------------------------------ the closure's inflow cap

    function test_InflowCapOldestFirstRestWait() public {
        _pools(100e18, 0);
        _toSaturday();
        // Fair NAV about $2,000: the cap is 5%, about 100 USDG.
        uint256 a = _deposit(alice, 60e6, 1);
        uint256 b = _deposit(bob, 60e6, 1);
        uint256 c = _deposit(carol, 30e6, 1);
        uint64 bt = _batchOf(a);
        vm.expectEmit(true, true, false, false, address(tel));
        emit ITeller.DepositsWait(address(vault), bt, 0, 0, 0, address(0));
        _settle(bt);
        ITeller.Batch memory bb = tel.batch(address(vault), bt);
        assertFalse(bb.settled, "bob waits");
        assertEq(bb.deposits, 60e6);
        assertEq(bb.rounds, 1);
        assertEq(tel.request(a).round, 1);
        assertEq(tel.request(b).round, 0);
        assertEq(tel.request(c).round, 1, "taken in order while it fits");
        (uint256 sa,,) = tel.due(a);
        assertGt(sa, 0);
        _claim(a);
        _claim(c);
        (, uint256 wb, bool waiting) = tel.due(b);
        assertTrue(waiting);
        assertEq(wb, 60e6);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, b));
        tel.claim(b);
        Teller.Closure memory cl = tel.closure(address(vault));
        assertApproxEqAbs(cl.inflow, 90e18, 1e12);
        // The batch took the open batch's cut-off; bob may take his deposit back until then.
        (, uint64 next) = tel.currentBatch(address(vault));
        assertEq(bb.cutoff, next);
        assertTrue(router.marketClosed(address(tokA)));
        vm.prank(bob);
        tel.cancel(b);
        assertEq(usdg.balanceOf(bob), 60e6);
        assertTrue(tel.batch(address(vault), bt).settled, "nothing waits any more");
    }

    function test_WaitingDepositGoesInWhenTheMarketOpens() public {
        _pools(100e18, 0);
        _toSaturday();
        uint256 a = _deposit(alice, 90e6, 1);
        uint256 b = _deposit(bob, 60e6, 1);
        uint64 bt = _batchOf(a);
        _settle(bt);
        assertEq(tel.request(b).round, 0);
        // Sunday's cut-off: still the same closure, the cap is spent, bob waits again (reason 4).
        _settle(bt);
        assertEq(tel.batch(address(vault), bt).rounds, 2);
        assertFalse(tel.batch(address(vault), bt).settled);
        // Monday's cut-off: the market is open, he goes in in the last round.
        _settle(bt);
        ITeller.Batch memory bb = tel.batch(address(vault), bt);
        assertTrue(bb.settled);
        assertEq(bb.rounds, 3);
        assertFalse(router.marketClosed(address(tokA)));
        (uint256 sb,) = _claim(b);
        assertEq(tel.round(address(vault), bt, 3).minted, sb, "the last claim of a round takes all of it");
        _claim(a);
    }

    /// @notice After the reopening, until the feed's first round of the new session, the token is still in the
    ///         weekend's closure: worse-of prices and the same closure's caps, not a fresh cap and not Friday's price
    ///         as if open.
    function test_ReopenedWithoutANewRoundIsStillTheWeekend() public {
        _pools(100e18, 0);
        _toSaturday();
        uint256 a = _deposit(alice, 90e6, 1);
        _settle(_batchOf(a));
        uint64 since = tel.closure(address(vault)).since;
        source.setReadAt(address(tokA), uint64(since - 4 hours)); // Friday's last round
        vm.warp(_next(MON, 10 hours));
        assertEq(router.closedSince(), 0, "the calendar is open");
        assertTrue(router.marketClosed(address(tokA)), "no round of the new session yet");
        uint256 b = _deposit(bob, 60e6, 1);
        uint64 bt = _batchOf(b);
        vm.expectEmit(true, true, false, false, address(tel));
        emit ITeller.DepositsWait(address(vault), bt, 0, 0, 0, address(0));
        _settle(bt);
        assertEq(tel.request(b).round, 0, "over what is left of the weekend's cap");
        assertEq(tel.closure(address(vault)).since, since, "the same closure");
        // The feed's first round: open, and bob goes in at the next cut-off.
        source.setReadAt(address(tokA), uint64(block.timestamp));
        assertFalse(router.marketClosed(address(tokA)));
        _settle(bt);
        assertTrue(tel.batch(address(vault), bt).settled);
    }

    function test_NewClosureResetsTheCount() public {
        _pools(100e18, 0);
        _toSaturday();
        uint256 a = _deposit(alice, 90e6, 1);
        _settle(_batchOf(a));
        uint64 since = tel.closure(address(vault)).since;
        // The next weekend: a new closure, a fresh cap.
        vm.warp(_next(SAT, 10 hours));
        uint256 b = _deposit(bob, 90e6, 1);
        _settle(_batchOf(b));
        Teller.Closure memory cl = tel.closure(address(vault));
        assertGt(cl.since, since);
        assertApproxEqAbs(cl.inflow, 90e18, 1e12);
        assertTrue(tel.batch(address(vault), _batchOf(b)).settled);
    }

    /// @notice Every deposit taken while a market is closed counts against the cap, matched with a leaver or not: a
    ///         matched entrant pays the closed market's fair price too. The leaver still leaves.
    function test_CapCountsEveryDepositMatchedOrNot() public {
        uint256 bobShares = _join(bob, 500e6);
        _pools(100e18, 0);
        _toSaturday();
        uint256 r = _redeem(bob, bobShares, 1);
        uint256 a = _deposit(alice, 550e6, 1);
        uint64 bt = _batchOf(a);
        _settle(bt);
        (,, bool waiting) = tel.due(a);
        assertTrue(waiting, "over the cap even though a leaver could take it all");
        assertEq(tel.batch(address(vault), bt).matchedShares, 0);
        (uint256 back, uint256 out) = _claim(r);
        assertGt(out + back, 0, "the leaver is paid (cash within the outflow cap, the rest back in shares)");
    }

    /// @notice While a market is closed, cash paid to leavers per closure is capped too: the rest of
    ///         their shares comes back, to leave in kind, which no closed-market price touches.
    function test_OutflowCapHandsTheRestBack() public {
        uint256 bobShares = _join(bob, 500e6);
        _pools(100e18, 0);
        _toSaturday();
        uint256 navFair = _nav(0);
        uint256 r = _redeem(bob, bobShares, 1);
        _settle(_batchOf(r));
        (uint256 back, uint256 out) = _claim(r);
        assertLe(out * 1e12, navFair * tel.weekendOutflowBps() / 10_000 + 1e12, "cash within 5% of NAV");
        assertGt(back, 0, "the rest back in shares");
        vm.prank(bob);
        tel.redeemInKind(address(vault), back, bob);
    }

    function test_CapZeroTakesNothingWhileClosed() public {
        tel.setParams(tel.minOpeningStake(), tel.minDeposit(), tel.dustUsd(), tel.writeOffMaxWad(), 0);
        _pools(100e18, 0);
        _toSaturday();
        uint256 a = _deposit(alice, 50e6, 1);
        _settle(_batchOf(a));
        (,, bool waiting) = tel.due(a);
        assertTrue(waiting);
        assertEq(tel.batch(address(vault), _batchOf(a)).rounds, 1);
    }

    function test_WaitingDepositCountsForMaxLiveAndKeepsItsClock() public {
        tel.setParams(tel.minOpeningStake(), tel.minDeposit(), tel.dustUsd(), tel.writeOffMaxWad(), 0);
        _pools(100e18, 0);
        _toSaturday();
        uint256 a = _deposit(alice, 50e6, 1);
        _settle(_batchOf(a));
        assertEq(tel.liveRequests(address(vault), alice), 1);
        _deposit(alice, 10e6, 1);
        _deposit(alice, 10e6, 1);
        usdg.mint(alice, 10e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.TooManyRequests.selector);
        tel.requestDeposit(address(vault), 10e6, 1);
        vm.stopPrank();
        // Seven days after it was made anyone may return it, waiting or not.
        vm.warp(tel.request(a).madeAt + tel.STALE_AFTER());
        vm.prank(makeAddr("anyone"));
        tel.cancel(a);
        assertEq(usdg.balanceOf(alice), 60e6, "her 50 back, next to the 10 the refused request never took");
    }

    function test_WindDownPaysWaitingDepositsBack() public {
        _pools(100e18, 0);
        _toSaturday();
        uint256 a = _deposit(alice, 90e6, 1);
        uint256 b = _deposit(bob, 60e6, 1);
        uint64 bt = _batchOf(a);
        _settle(bt);
        vm.prank(owner);
        tel.windDown(address(vault));
        _settle(bt);
        ITeller.Round memory ro = tel.round(address(vault), bt, 2);
        assertTrue(ro.refund);
        (uint256 sb, uint256 ub) = _claim(b);
        assertEq(sb, 0);
        assertEq(ub, 60e6, "paid back in full");
        _claim(a);
    }

    // ------------------------------------------------------------ why deposits wait

    function test_NoPriceWaitsReasonThree() public {
        uint256 a = _deposit(alice, 50e6, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        source.setDown(address(tokA), true);
        vm.expectEmit(true, true, false, true, address(tel));
        emit ITeller.DepositsWait(address(vault), bt, _open(), 50e6, 3, address(0));
        vm.prank(keeper);
        tel.settle(address(vault), bt, _noSkip());
        source.setDown(address(tokA), false);
        _settle(bt);
        (uint256 s,) = _claim(a);
        assertGt(s, 0);
    }

    function test_NoMarketWaitsReasonTwo() public {
        MockERC20 tokN = new MockERC20("N", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        _hold(tokN, 5e18);
        uint256 a = _deposit(alice, 50e6, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        vm.expectEmit(true, true, false, true, address(tel));
        emit ITeller.DepositsWait(address(vault), bt, _open(), 50e6, 2, address(tokN));
        vm.prank(keeper);
        tel.settle(address(vault), bt, _noSkip());
    }

    /// @dev The batch a request made now would join.
    function _open() internal view returns (uint64 id) {
        (id,) = tel.currentBatch(address(vault));
    }
}
