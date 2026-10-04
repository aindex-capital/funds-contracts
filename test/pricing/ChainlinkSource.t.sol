// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {Test} from "forge-std/Test.sol";
import {ChainlinkSource, IChainlinkFeed} from "../../src/pricing/sources/ChainlinkSource.sol";
import {SourceAdmin} from "../../src/pricing/sources/SourceAdmin.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {IPriceRouter, PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {MockAggregator, MockStockToken} from "./PricingMocks.sol";

contract ChainlinkSourceTest is Test {
    ChainlinkSource internal src;
    MockAggregator internal feed;
    MockStockToken internal stock;
    MockERC20 internal weth;

    // Thursday 2026-10-01 13:20:52 UTC, the day these were written.
    uint256 internal constant THURSDAY = 1_790_860_852;
    // Friday 2026-09-25 19:55:53 UTC and Monday 2026-09-28 00:00:11 UTC: NVDA's last and first rounds around
    // the weekend, read from the feed on chain.
    uint256 internal constant FRIDAY_CLOSE = 1_790_366_153;
    uint256 internal constant MONDAY_OPEN = 1_790_553_611;

    function setUp() public {
        vm.warp(THURSDAY);
        src = new ChainlinkSource(address(this));
        feed = new MockAggregator(8);
        stock = new MockStockToken();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        feed.set(230_42347652, block.timestamp - 100);
        _configure(address(stock), feed, 26 hours, true, true);
    }

    function _feed(MockAggregator f, uint32 maxAge, bool pause, bool weekend)
        internal
        pure
        returns (ChainlinkSource.Feed memory)
    {
        return ChainlinkSource.Feed(
            IChainlinkFeed(address(f)), maxAge, pause, weekend, IPriceSource(address(0)), address(0), 0
        );
    }

    /// @dev Propose and apply now (warping back first so the delay never ages the feed).
    function _configure(address token, MockAggregator f, uint32 maxAge, bool pause, bool weekend) internal {
        uint256 now_ = block.timestamp;
        vm.warp(now_ - src.CONFIG_DELAY());
        src.propose(token, _feed(f, maxAge, pause, weekend));
        vm.warp(now_);
        if (src.pendingAt(token) != 0) src.applyPending(token);
    }

    // ---- readings ----

    function test_pricesIn18Decimals() public view {
        (uint256 usd, uint64 at, bool ok) = src.price(address(stock));
        assertTrue(ok);
        assertEq(usd, 230.42347652e18);
        assertEq(at, block.timestamp - 100);
        assertEq(src.name(), "Chainlink");
    }

    function test_eighteenDecimalFeed() public {
        MockAggregator f = new MockAggregator(18);
        f.set(1.05e18, block.timestamp);
        _configure(address(weth), f, 26 hours, false, false);
        (uint256 usd,, bool ok) = src.price(address(weth));
        assertTrue(ok);
        assertEq(usd, 1.05e18);
    }

    function test_unknownTokenIsUnavailable() public view {
        (uint256 usd, uint64 at, bool ok) = src.price(address(weth));
        assertFalse(ok);
        assertEq(usd, 0);
        assertEq(at, 0);
    }

    function test_zeroOrNegativeAnswerIsUnavailable() public {
        feed.set(0, block.timestamp);
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok);
        feed.set(-1, block.timestamp);
        (,, ok) = src.price(address(stock));
        assertFalse(ok);
    }

    function test_staleness() public {
        feed.set(100e8, block.timestamp - 26 hours);
        (,, bool ok) = src.price(address(stock));
        assertTrue(ok, "exactly maxAge is usable");
        feed.set(100e8, block.timestamp - 26 hours - 1);
        (,, ok) = src.price(address(stock));
        assertFalse(ok, "one second over is stale");
    }

    function test_incompleteRoundIsUnavailable() public {
        feed.set(100e8, block.timestamp);
        feed.setRound(10, 9); // answered in an earlier round
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok);
        feed.set(100e8, 0); // never updated
        (,, ok) = src.price(address(stock));
        assertFalse(ok);
        feed.set(100e8, block.timestamp + 1); // from the future
        (,, ok) = src.price(address(stock));
        assertFalse(ok);
    }

    function test_revertingFeedIsUnavailableNotARevert() public {
        feed.setReverts(true);
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok);
    }

    // ---- stock token pause ----

    function test_pausedStockTokenIsUnavailable() public {
        stock.setPaused(true);
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok);
        stock.setPaused(false);
        (,, ok) = src.price(address(stock));
        assertTrue(ok);
    }

    function test_pauseCheckOnTokenWithoutPauseIsUnavailable() public {
        _configure(address(weth), feed, 26 hours, true, false); // WETH has no oraclePaused()
        (,, bool ok) = src.price(address(weth));
        assertFalse(ok);
    }

    function test_pauseIgnoredWhenNotAStockToken() public {
        stock.setPaused(true);
        _configure(address(stock), feed, 26 hours, false, true); // dropping the check waits, then applies
        (,, bool ok) = src.price(address(stock));
        assertTrue(ok);
    }

    // ---- weekends ----

    function test_weekendIsNotCountedForAClosedFeed() public {
        feed.set(100e8, FRIDAY_CLOSE);
        vm.warp(MONDAY_OPEN); // 52 hours later, before Monday's first round
        (,, bool ok) = src.price(address(stock));
        assertTrue(ok, "weekend skipped");
        assertEq(src.countedAge(address(stock), FRIDAY_CLOSE), MONDAY_OPEN - FRIDAY_CLOSE - 2 days);

        _configure(address(stock), feed, 26 hours, true, false);
        (,, ok) = src.price(address(stock));
        assertFalse(ok, "same reading on a 24/7 feed is stale");
    }

    function test_weekendSkipStillCatchesAStoppedFeed() public {
        feed.set(100e8, FRIDAY_CLOSE);
        vm.warp(MONDAY_OPEN + 1 days); // feed silent through Monday too (or a Monday holiday)
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok);

        feed.set(100e8, THURSDAY - 27 hours); // mid-week: no skip
        vm.warp(THURSDAY);
        (,, ok) = src.price(address(stock));
        assertFalse(ok);
    }

    function testFuzz_weekendSecondsNeverExceedAge(uint32 a, uint32 b) public {
        uint256 from = bound(a, 1_700_000_000, 1_900_000_000);
        uint256 to = bound(b, from, from + 30 days);
        vm.warp(to);
        uint256 counted = src.countedAge(address(stock), from);
        assertLe(counted, to - from);
        // At most 2 of every 7 days are skipped (plus one partial weekend).
        assertGe(counted + ((to - from) / 7 days + 1) * 2 days, to - from);
    }

    // ---- sequencer ----

    function test_sequencerDownOrJustRestartedIsUnavailable() public {
        MockAggregator seq = new MockAggregator(0);
        src.setSequencer(address(seq));

        seq.set(1, block.timestamp - 2 hours); // down
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok);

        seq.set(0, block.timestamp - 10 minutes); // up, but inside the grace period
        (,, ok) = src.price(address(stock));
        assertFalse(ok);

        seq.set(0, block.timestamp - 1 hours); // up for an hour
        (,, ok) = src.price(address(stock));
        assertTrue(ok);

        seq.setReverts(true);
        (,, ok) = src.price(address(stock));
        assertFalse(ok);

        src.setSequencer(address(0));
        (,, ok) = src.price(address(stock));
        assertTrue(ok);
    }

    // ---- exchange-rate feeds ----

    function test_exchangeRateFeedIsMultipliedByQuotePrice() public {
        MockPriceSource quote = new MockPriceSource();
        quote.set(address(weth), 2_000e18);
        MockAggregator rate = new MockAggregator(18);
        rate.set(1.2e18, block.timestamp - 50);
        MockERC20 wsteth = new MockERC20("wstETH", "wstETH", 18);

        ChainlinkSource.Feed memory f = _feed(rate, 26 hours, false, false);
        f.quoteSource = quote;
        f.quoteToken = address(weth);
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        src.propose(address(wsteth), f);
        vm.warp(now_);
        src.applyPending(address(wsteth));

        (uint256 usd, uint64 at, bool ok) = src.price(address(wsteth));
        assertTrue(ok);
        assertEq(usd, 2_400e18);
        assertEq(at, block.timestamp - 50);

        quote.setDown(address(weth), true);
        (,, ok) = src.price(address(wsteth));
        assertFalse(ok);
    }

    // ---- configuration ----

    function test_newFeedWaitsForDelay() public {
        MockAggregator f = new MockAggregator(8);
        f.set(2_000e8, block.timestamp);
        src.propose(address(weth), _feed(f, 26 hours, false, false));
        (,, bool ok) = src.price(address(weth));
        assertFalse(ok, "not live yet");
        vm.expectRevert(SourceAdmin.NotReady.selector);
        src.applyPending(address(weth));

        vm.warp(block.timestamp + 1 days);
        f.set(2_000e8, block.timestamp);
        vm.prank(makeAddr("anyone"));
        src.applyPending(address(weth));
        (,, ok) = src.price(address(weth));
        assertTrue(ok);
    }

    function test_swappingAFeedWaits() public {
        MockAggregator other = new MockAggregator(8);
        other.set(1e8, block.timestamp);
        src.propose(address(stock), _feed(other, 26 hours, true, true));
        assertGt(src.pendingAt(address(stock)), 0);
        (uint256 usd,,) = src.price(address(stock));
        assertEq(usd, 230.42347652e18, "old feed still in force");
    }

    function test_looseningWaitsTighteningAndRemovalAreInstant() public {
        src.propose(address(stock), _feed(feed, 30 hours, true, true));
        assertGt(src.pendingAt(address(stock)), 0, "longer maxAge waits");

        src.propose(address(stock), _feed(feed, 25 hours, true, true));
        assertEq(src.pendingAt(address(stock)), 0, "shorter maxAge applies at once");
        assertEq(src.feedOf(address(stock)).maxAge, 25 hours);

        src.propose(address(stock), _feed(feed, 25 hours, true, false));
        assertEq(src.pendingAt(address(stock)), 0, "dropping the weekend skip applies at once");

        src.propose(address(stock), _feed(MockAggregator(address(0)), 0, false, false));
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok, "removed at once");
    }

    function test_badConfigReverts() public {
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(weth), _feed(feed, 0, false, false));
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(weth), _feed(feed, 3 days + 1, false, false));
        ChainlinkSource.Feed memory f = _feed(feed, 1 days, false, false);
        f.quoteToken = address(weth); // quote token without a source
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(weth), f);
    }

    function test_onlyOwner() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(SourceAdmin.NotOwner.selector);
        src.propose(address(weth), _feed(feed, 1 days, false, false));
        vm.expectRevert(SourceAdmin.NotOwner.selector);
        src.setSequencer(address(1));
        vm.expectRevert(SourceAdmin.NotOwner.selector);
        src.cancelPending(address(weth));
        vm.stopPrank();
    }

    function test_cancelAndOwnershipTransfer() public {
        src.propose(address(weth), _feed(feed, 1 days, false, false));
        src.cancelPending(address(weth));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(SourceAdmin.NotReady.selector);
        src.applyPending(address(weth));

        address next = makeAddr("next");
        src.transferOwnership(next);
        vm.expectRevert(SourceAdmin.NotOwner.selector);
        src.acceptOwnership();
        vm.prank(next);
        src.acceptOwnership();
        assertEq(src.owner(), next);
    }
}

/// @notice `lastPrice` and the router's closed-market path, on NVDA's real weekend timestamps with Monday
///         2026-09-28 treated as a market holiday.
contract ChainlinkSessionTest is Test {
    ChainlinkSource internal src;
    MockAggregator internal feed;
    MockStockToken internal stock;
    PriceRouter internal router;

    uint256 internal constant FRIDAY_CLOSE = 1_790_366_153; // Fri 2026-09-25 19:55:53 UTC
    uint256 internal constant SATURDAY = 1_790_380_800; // Sat 2026-09-26 00:00 UTC
    uint256 internal constant MONDAY = 1_790_553_600; // Mon 2026-09-28 00:00 UTC
    uint256 internal constant TUESDAY = MONDAY + 1 days;

    function setUp() public {
        vm.warp(MONDAY - 10 days);
        src = new ChainlinkSource(address(this));
        router = new PriceRouter(address(this));
        feed = new MockAggregator(8);
        stock = new MockStockToken();
        feed.set(230e8, block.timestamp);
        src.propose(
            address(stock),
            ChainlinkSource.Feed(
                IChainlinkFeed(address(feed)), 26 hours, true, true, IPriceSource(address(0)), address(0), 0
            )
        );
        router.propose(
            address(stock),
            PriceRouter.Config({
                primary: src,
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
        uint256[] memory days_ = new uint256[](1);
        days_[0] = MONDAY / 1 days;
        router.addHolidays(days_);
        vm.warp(block.timestamp + 1 days);
        src.applyPending(address(stock));
        router.applyPending(address(stock));
        router.applySession(address(stock));

        feed.set(230e8, FRIDAY_CLOSE); // the last round before the long weekend
    }

    function test_lastPriceSkipsOnlyTheAgeCheck() public {
        vm.warp(TUESDAY + 2 days);
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok, "stale for price");
        (uint256 usd, uint64 at, bool lastOk) = src.lastPrice(address(stock));
        assertTrue(lastOk);
        assertEq(usd, 230e18);
        assertEq(at, FRIDAY_CLOSE, "the round's own time");

        stock.setPaused(true);
        (,, lastOk) = src.lastPrice(address(stock));
        assertFalse(lastOk, "pause still applies");
        stock.setPaused(false);

        feed.setRound(10, 9);
        (,, lastOk) = src.lastPrice(address(stock));
        assertFalse(lastOk, "round completeness still applies");

        feed.set(-1, FRIDAY_CLOSE);
        (,, lastOk) = src.lastPrice(address(stock));
        assertFalse(lastOk, "answer above zero still applies");
    }

    function test_mondayHolidayKeepsTheStockPricedWithAWiderSpread() public {
        vm.warp(MONDAY + 23 hours); // counted age past 26 hours, market still shut
        (,, bool ok) = src.price(address(stock));
        assertFalse(ok, "the source alone calls it stale");

        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available, "router accepts the pre-close reading");
        assertTrue(router.marketClosed(address(stock)));
        assertEq(q.fair, 230e18);
        assertEq(q.bid, 230e18 * (10_000 - 1050) / 10_000, "haircut plus the closed spread");
        assertEq(q.ask, 230e18 * (10_000 + 1050) / 10_000);
    }

    /// @notice With no holiday in the calendar the market reopens Monday (00:00 UTC in summer), but the feed
    ///         still has no round of the new session (an unlisted holiday): the token stays in the weekend closure,
    ///         priced at the closure's wider spread, and goes unavailable `REOPEN_GRACE` after the reopening.
    function test_withoutTheHolidayMondayStaysInTheWeekendUntilTheFeedReturns() public {
        uint256[] memory days_ = new uint256[](1);
        days_[0] = MONDAY / 1 days;
        router.removeHolidays(days_);
        vm.warp(MONDAY + 23 hours);
        assertTrue(router.marketClosed(address(stock)), "no round since the reopening");
        assertEq(router.lastClosedSince(), SATURDAY, "still the weekend's closure");
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 230e18 * (10_000 - 1050) / 10_000, "the closure's spread");
        vm.warp(MONDAY + router.REOPEN_GRACE());
        assertFalse(router.quote(address(stock)).available, "the feed never came back");
    }

    /// @notice After a holiday the market reopens Monday 20:00 New York (Tuesday 00:00 UTC in summer). Until
    ///         the feed's first round from then on, the token is still in the closure that began on Saturday.
    function test_marketOpenAgainNeedsAFreshRound() public {
        vm.warp(TUESDAY + 1 hours);
        assertTrue(router.marketClosed(address(stock)), "reopened, but no round of the new session yet");
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available, "the closure's last price");
        assertEq(q.bid, 230e18 * (10_000 - 1050) / 10_000, "and its spread");

        feed.set(231e8, TUESDAY + 30 minutes); // 20:30 in New York, after the reopening
        assertFalse(router.marketClosed(address(stock)));
        q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 231e18 * (10_000 - 50) / 10_000, "normal spread again");
    }

    function test_readingTooOldWhenTheClosureBeganIsRefused() public {
        feed.set(230e8, SATURDAY - 26 hours - 1); // already stale when the market shut
        vm.warp(MONDAY + 23 hours);
        assertFalse(router.quote(address(stock)).available);
    }
}

/// @notice A reopened market counts as open only once the feed has a round from the new session. Winter
///         Mondays reopen at 01:00 UTC, summer ones at 00:00 UTC (20:00 New York either way); until the round, the
///         token is still in the weekend's closure, priced on its rule and counted in its caps.
contract ReopeningRoundTest is Test {
    ChainlinkSource internal src;
    MockAggregator internal feed;
    MockStockToken internal stock;
    PriceRouter internal router;

    uint256 internal constant WINTER_SAT = 1_767_398_400; // Sat 2026-01-03 00:00 UTC
    uint256 internal constant WINTER_MON = 1_767_571_200; // Mon 2026-01-05 00:00 UTC
    uint256 internal constant SUMMER_MON = 1_790_553_600; // Mon 2026-09-28 00:00 UTC
    uint256 internal constant MARCH_MON = 1_773_014_400; // Mon 2026-03-09: summer time began Sunday 03-08
    uint256 internal constant NOVEMBER_MON = 1_793_577_600; // Mon 2026-11-02: summer time ended Sunday 11-01

    function setUp() public {
        vm.warp(WINTER_MON - 30 days);
        src = new ChainlinkSource(address(this));
        router = new PriceRouter(address(this));
        feed = new MockAggregator(8);
        stock = new MockStockToken();
        feed.set(230e8, block.timestamp);
        src.propose(
            address(stock),
            ChainlinkSource.Feed(
                IChainlinkFeed(address(feed)), 26 hours, true, true, IPriceSource(address(0)), address(0), 0
            )
        );
        router.propose(
            address(stock),
            PriceRouter.Config({
                primary: src,
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
                closedHaircutBps: 450,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
        vm.warp(block.timestamp + 1 days);
        src.applyPending(address(stock));
        router.applyPending(address(stock));
        router.applySession(address(stock));
    }

    /// @dev Friday's last round before `monday`'s weekend.
    function _friday(uint256 monday) internal {
        feed.set(230e8, monday - 2 days - 4 hours - 5 minutes);
    }

    function test_WinterMondayAtTheReopeningIsStillTheWeekend() public {
        _friday(WINTER_MON);
        vm.warp(WINTER_MON + 1 hours); // the calendar opens at 01:00 UTC
        assertEq(router.closedSince(), 0, "the calendar is open");
        assertTrue(router.marketClosed(address(stock)), "but the feed is still Friday's");
        assertEq(router.lastClosedSince(), WINTER_SAT, "the weekend's closure, for the caps");
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 230e18 * (10_000 - 500) / 10_000, "the closed fallback, not the open spread");
        assertEq(q.ask, 230e18 * (10_000 + 500) / 10_000);

        feed.set(232e8, WINTER_MON + 1 hours + 20); // the session's first round
        vm.warp(WINTER_MON + 1 hours + 30);
        assertFalse(router.marketClosed(address(stock)));
        q = router.quote(address(stock));
        assertEq(q.bid, 232e18 * (10_000 - 50) / 10_000, "open: the normal haircut");
    }

    /// @notice A round before 01:00 UTC on a winter Monday is before the reopening (19:xx in New York): it does not
    ///         open the market, whatever it says.
    function test_WinterRoundBeforeTheReopeningDoesNotCount() public {
        _friday(WINTER_MON);
        feed.set(230e8, WINTER_MON + 30 minutes);
        vm.warp(WINTER_MON + 1 hours + 10);
        assertTrue(router.marketClosed(address(stock)));
    }

    /// @notice In summer the market reopens at 00:00 UTC; the feed's round then (measured at 00:00:40 on 2026-09-28)
    ///         opens it as soon as the calendar does, at 01:00.
    function test_SummerRoundAtMidnightCounts() public {
        _friday(SUMMER_MON);
        feed.set(231e8, SUMMER_MON + 40);
        vm.warp(SUMMER_MON + 1 hours);
        assertFalse(router.marketClosed(address(stock)));
        assertEq(router.quote(address(stock)).bid, 231e18 * (10_000 - 50) / 10_000);
    }

    /// @notice Summer time begins on the second Sunday of March and ends on the first Sunday of November; the
    ///         evening of each switch is already on the new side.
    function test_SummerTimeSwitches() public {
        _friday(MARCH_MON);
        feed.set(231e8, MARCH_MON + 30 minutes);
        vm.warp(MARCH_MON + 1 hours);
        assertFalse(router.marketClosed(address(stock)), "March 8 evening is summer time: reopened at 00:00");

        _friday(NOVEMBER_MON);
        feed.set(231e8, NOVEMBER_MON + 30 minutes);
        vm.warp(NOVEMBER_MON + 1 hours);
        assertTrue(router.marketClosed(address(stock)), "November 1 evening is winter time: reopens at 01:00");
        feed.set(231e8, NOVEMBER_MON + 1 hours);
        assertFalse(router.marketClosed(address(stock)));
    }

    /// @notice A feed with no round `REOPEN_GRACE` after the reopening is unavailable: Friday's price never carries
    ///         on into the week.
    function test_FeedThatNeverReturnsGoesUnavailable() public {
        _friday(WINTER_MON);
        vm.warp(WINTER_MON + 1 hours + router.REOPEN_GRACE() - 1);
        assertTrue(router.quote(address(stock)).available);
        vm.warp(WINTER_MON + 1 hours + router.REOPEN_GRACE());
        assertFalse(router.quote(address(stock)).available);
    }

    /// @notice Later in the week a quiet feed (no round since Tuesday) is simply open: it has a round from this
    ///         session.
    function test_QuietFeedMidweekIsOpen() public {
        _friday(WINTER_MON);
        feed.set(231e8, WINTER_MON + 1 days);
        vm.warp(WINTER_MON + 2 days + 12 hours);
        assertFalse(router.marketClosed(address(stock)));
        assertEq(router.lastClosedSince(), WINTER_SAT);
    }
}
