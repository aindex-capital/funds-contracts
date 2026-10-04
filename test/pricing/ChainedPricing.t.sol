// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {UniswapV3TwapSource, IUniswapV3PoolOracle} from "../../src/pricing/sources/UniswapV3TwapSource.sol";
import {SessionPoolSource, IUniswapV3PoolSession} from "../../src/pricing/sources/SessionPoolSource.sol";
import {PoolMath} from "../../src/pricing/sources/PoolMath.sol";
import {IPriceSource, IRatioSource} from "../../src/interfaces/IPriceSource.sol";
import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {IPriceRouter, PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";
import {ILookThrough} from "../../src/interfaces/ILookThrough.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {MockV3Pool} from "./PricingMocks.sol";

/// @notice A ratio source tests set by hand: `token` priced as `ratio` whole `quote` per whole token.
contract MockRatioSource is IPriceSource, IRatioSource {
    struct R {
        address quote;
        uint256 ratio;
        bool down;
    }

    mapping(address => R) public r;

    function set(address token, address quote, uint256 ratio_) external {
        r[token] = R(quote, ratio_, false);
    }

    function setDown(address token, bool d) external {
        r[token].down = d;
    }

    function ratio(address token) external view returns (address, uint256, uint64, bool) {
        R memory x = r[token];
        return (x.quote, x.ratio, uint64(block.timestamp), !x.down && x.ratio != 0);
    }

    function price(address) external pure returns (uint256, uint64, bool) {
        return (0, 0, false);
    }

    function name() external pure returns (string memory) {
        return "mock ratio";
    }
}

contract EmptyLookThrough is ILookThrough {
    function underlying(address, uint256) external pure returns (Amount[] memory a) {
        return a;
    }
}

/**
 * @notice Pool prices in any token the router prices (owner decision 2026-10-02): the router converts a ratio
 *         source's price through its own quote of the quote token, side by side, caps the class at the quote's, and
 *         refuses loops and chains longer than `MAX_HOPS`. While a US market is closed, every qualifying weekend pool
 *         (any pair) is converted the same way and the worst of them and the last price sets the bid and the ask.
 */
contract ChainedPricingTest is Test {
    PriceRouter internal router;
    MockPriceSource internal usd;
    MockRatioSource internal ratios;
    UniswapV3TwapSource internal twap;
    SessionPoolSource internal sessions;
    MockERC20 internal usdg;
    MockERC20 internal weth;
    MockERC20 internal stock;
    MockERC20 internal other;

    function setUp() public {
        vm.warp(1_790_860_852);
        router = new PriceRouter(address(this));
        usd = new MockPriceSource();
        ratios = new MockRatioSource();
        twap = new UniswapV3TwapSource(address(this));
        sessions = new SessionPoolSource(address(this));
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        stock = new MockERC20("Stock", "STK", 18);
        other = new MockERC20("Other stock", "OTH", 18);
        _usd(address(usdg), 1e18, PriceClass.Feed, 0);
        _usd(address(weth), 2_000e18, PriceClass.Feed, 50); // bid 1990, ask 2010
    }

    // ------------------------------------------------ helpers

    function _cfg(IPriceSource p, PriceClass c, uint16 h, uint8 chained)
        internal
        pure
        returns (PriceRouter.Config memory)
    {
        return PriceRouter.Config({
            primary: p,
            check: IPriceSource(address(0)),
            class_: c,
            haircutBps: h,
            maxDeviationBps: 0,
            decimals: 0,
            chained: chained
        });
    }

    function _apply(address token, PriceRouter.Config memory c) internal {
        router.propose(token, c);
        if (router.pendingAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(token);
        }
    }

    function _usd(address token, uint256 price, PriceClass c, uint16 h) internal {
        usd.set(token, price);
        _apply(token, _cfg(usd, c, h, 0));
    }

    function _chained(address token, address quote, uint256 r, PriceClass c, uint16 h) internal {
        ratios.set(token, quote, r);
        _apply(token, _cfg(ratios, c, h, 1));
    }

    function _pool(address base, address quote, int24 tick) internal returns (MockV3Pool p) {
        p = new MockV3Pool(base, quote);
        p.setTick(tick, block.timestamp - 10 days);
        p.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
    }

    function _toSaturday() internal {
        uint256 day = block.timestamp / 1 days + 1;
        while (day % 7 != 2) ++day; // 1970-01-01 was a Thursday: day 2 a Saturday
        vm.warp(day * 1 days + 12 hours);
    }

    function _toWeekday() internal {
        uint256 day = block.timestamp / 1 days + 1;
        while (day % 7 == 2 || day % 7 == 3) ++day;
        vm.warp(day * 1 days + 15 hours);
    }

    // ------------------------------------------------ a pool quoted in WETH

    /// @notice A stock/WETH pool (TWAP source): fair is the pool's WETH price times WETH's fair price, the bid
    ///         takes WETH's bid and the ask WETH's ask, then the stock's own haircut on top.
    function test_WethQuotedPoolEachSideThroughTheRoutersWeth() public {
        // token0 = stock, token1 = weth: tick -23028 is about 0.1 WETH per stock.
        MockV3Pool p = _pool(address(stock), address(weth), -23028);
        twap.propose(address(stock), IUniswapV3PoolOracle(address(p)), 30 minutes, false);
        vm.warp(block.timestamp + 1 days);
        twap.applyPending(address(stock));
        _apply(address(stock), _cfg(twap, PriceClass.Pool, 100, 1));
        p.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);

        uint256 r = PoolMath.ratioAtTick(-23028, 18, true, 18);
        assertApproxEqRel(r, 0.1e18, 0.0002e18);
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(uint8(q.class_), uint8(PriceClass.Pool), "the worse of Pool and WETH's Feed");
        assertEq(q.fair, r * 2_000e18 / 1e18);
        assertEq(q.bid, (r * 1_990e18 / 1e18) * 9_900 / 10_000, "WETH's bid, then the stock's haircut");
        assertEq(q.ask, (r * 2_010e18 / 1e18) * 10_100 / 10_000, "WETH's ask, then the stock's haircut");

        usd.set(address(weth), 3_000e18);
        assertEq(router.quote(address(stock)).fair, r * 3_000e18 / 1e18, "follows WETH's price live");
        usd.setDown(address(weth), true);
        assertFalse(router.quote(address(stock)).available, "no WETH price, no stock price");
    }

    /// @notice A pool price trails the market. The bid is the lower of the 30-minute average and the pool's
    ///         last minute, the ask the higher; fair stays the average. An entrant who saw the pool jump pays the
    ///         new price, and a leaver who saw it fall gets the new price.
    function test_PoolPriceEntrantsAtTheHigherOfAverageAndRecent() public {
        MockV3Pool p = _pool(address(stock), address(weth), -23028); // about 0.1 WETH
        twap.propose(address(stock), IUniswapV3PoolOracle(address(p)), 30 minutes, false);
        vm.warp(block.timestamp + 1 days);
        twap.applyPending(address(stock));
        _apply(address(stock), _cfg(twap, PriceClass.Pool, 100, 1));
        p.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        uint256 avg = PoolMath.ratioAtTick(-23028, 18, true, 18);

        // The pool jumped 10% two minutes ago: the 30-minute average has barely moved.
        p.setLateTick(-23028 + 953, 2 minutes);
        (uint256 recent, bool ok) = twap.recentRatio(address(stock));
        assertTrue(ok);
        assertApproxEqRel(recent, avg * 110 / 100, 0.001e18);
        (, uint256 mean,, bool okMean) = twap.ratio(address(stock));
        assertTrue(okMean);
        assertLt(mean, avg * 101 / 100, "the average trails");
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertEq(q.fair, mean * 2_000e18 / 1e18, "fair: the average");
        assertEq(q.ask, (recent * 2_010e18 / 1e18) * 10_100 / 10_000, "ask: the recent price");
        assertEq(q.bid, (mean * 1_990e18 / 1e18) * 9_900 / 10_000, "bid: the average");

        // It fell 10% instead: leavers get the recent price.
        p.setLateTick(-23028 - 1054, 2 minutes);
        (recent,) = twap.recentRatio(address(stock));
        (, mean,,) = twap.ratio(address(stock));
        q = router.quote(address(stock));
        assertEq(q.bid, (recent * 1_990e18 / 1e18) * 9_900 / 10_000, "bid: the recent price");
        assertEq(q.ask, (mean * 2_010e18 / 1e18) * 10_100 / 10_000, "ask: the average");
    }

    /// @notice A ratio source without a recent price (an outside `IRatioSource`) prices on its answer alone, and a
    ///         source that gives one but cannot now makes the token unavailable.
    function test_RecentPriceOptionalButBinding() public {
        _chained(address(other), address(usdg), 100e18, PriceClass.Pool, 0);
        IPriceRouter.Quote memory q = router.quote(address(other));
        assertEq(q.bid, 100e18);
        assertEq(q.ask, 100e18);

        MockV3Pool p = _pool(address(stock), address(weth), -23028);
        twap.propose(address(stock), IUniswapV3PoolOracle(address(p)), 30 minutes, false);
        vm.warp(block.timestamp + 1 days);
        twap.applyPending(address(stock));
        _apply(address(stock), _cfg(twap, PriceClass.Pool, 100, 1));
        p.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        p.setLateTick(PoolMath.MAX_ABS_TICK + 1, 1 minutes); // the last minute beyond any real market
        assertFalse(router.quote(address(stock)).available);
    }

    /// @notice A two-step chain: a stock priced in another stock's pool, that stock in a WETH pool, WETH by feed.
    function test_TwoHopChain() public {
        _chained(address(other), address(weth), 0.05e18, PriceClass.Pool, 0); // $100
        _chained(address(stock), address(other), 3e18, PriceClass.Feed, 0); // three of `other`
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.fair, 300e18);
        assertEq(q.bid, 298.5e18, "3 x 0.05 WETH at WETH's bid of 1,990");
        assertEq(q.ask, 301.5e18, "at WETH's ask of 2,010");
        assertEq(uint8(q.class_), uint8(PriceClass.Pool), "the worst class along the chain");
    }

    function test_CycleRefused() public {
        _chained(address(stock), address(other), 1e18, PriceClass.Pool, 0);
        _chained(address(other), address(stock), 1e18, PriceClass.Pool, 0);
        assertFalse(router.quote(address(stock)).available, "A in B in A");
        assertFalse(router.quote(address(other)).available, "B in A in B");
        (,, bool ok) = router.value(address(stock), 1e18, Side.Fair);
        assertFalse(ok);
    }

    function test_SelfQuoteRefused() public {
        _chained(address(stock), address(stock), 1e18, PriceClass.Pool, 0);
        assertFalse(router.quote(address(stock)).available);
    }

    function test_ChainLongerThanMaxHopsRefused() public {
        assertEq(router.MAX_HOPS(), 3);
        MockERC20 t1 = new MockERC20("T1", "T1", 18);
        MockERC20 t2 = new MockERC20("T2", "T2", 18);
        MockERC20 t3 = new MockERC20("T3", "T3", 18);
        // stock -> t1 -> t2 -> weth (USD): three steps, priced.
        _chained(address(t2), address(weth), 1e18, PriceClass.Feed, 0);
        _chained(address(t1), address(t2), 1e18, PriceClass.Feed, 0);
        _chained(address(stock), address(t1), 1e18, PriceClass.Feed, 0);
        assertTrue(router.quote(address(stock)).available, "three steps");
        assertEq(router.quote(address(stock)).fair, 2_000e18);
        // Put one more step in the middle: stock -> t1 -> t2 -> t3 -> weth.
        _chained(address(t3), address(weth), 1e18, PriceClass.Feed, 0);
        ratios.set(address(t2), address(t3), 1e18);
        assertFalse(router.quote(address(stock)).available, "four steps");
        assertTrue(router.quote(address(t1)).available, "three from t1");
    }

    function test_ClassIsTheWorseOfTokenAndQuote() public {
        MockERC20 thin = new MockERC20("Thin", "THN", 18);
        _usd(address(thin), 1e18, PriceClass.Thin, 0);
        _chained(address(stock), address(thin), 5e18, PriceClass.Feed, 0);
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(uint8(q.class_), uint8(PriceClass.Thin));
        assertEq(q.fair, 5e18);
        (, PriceClass c, bool ok) = router.value(address(stock), 1e18, Side.Fair);
        assertTrue(ok);
        assertEq(uint8(c), uint8(PriceClass.Thin));
    }

    function test_NoMarketQuoteMakesTheTokenWorthZero() public {
        MockERC20 none = new MockERC20("None", "NONE", 18); // never configured: class None
        _chained(address(stock), address(none), 5e18, PriceClass.Pool, 0);
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available, "a known value");
        assertEq(uint8(q.class_), uint8(PriceClass.None));
        assertEq(q.fair, 0);
        (uint256 v, PriceClass c, bool ok) = router.value(address(stock), 1e18, Side.Bid);
        assertTrue(ok);
        assertEq(v, 0);
        assertEq(uint8(c), uint8(PriceClass.None));
    }

    function test_ChainedFlagChangeWaits() public {
        _chained(address(stock), address(weth), 0.1e18, PriceClass.Pool, 0);
        router.propose(address(stock), _cfg(ratios, PriceClass.Pool, 0, 0));
        assertGt(router.pendingAt(address(stock)), 0, "a source read another way can move the price either way");
        assertEq(uint256(router.config(address(stock)).chained), 1);
    }

    // ------------------------------------------------ values() and the cache

    function test_ValuesMatchValueOnEverySideWithFlags() public {
        _chained(address(stock), address(weth), 0.1e18, PriceClass.Pool, 100);
        (uint256[3] memory v, PriceClass c, bool ok, uint8 flags) = router.values(address(stock), 3e18);
        assertTrue(ok);
        assertEq(uint8(c), uint8(PriceClass.Pool));
        (uint256 f,,) = router.value(address(stock), 3e18, Side.Fair);
        (uint256 b,,) = router.value(address(stock), 3e18, Side.Bid);
        (uint256 a,,) = router.value(address(stock), 3e18, Side.Ask);
        assertEq(v[0], f);
        assertEq(v[1], b);
        assertEq(v[2], a);
        assertEq(uint256(flags), 0);

        // Flags: 1 while its US market is closed, 2 once it has a look-through.
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 400,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(0))
            })
        );
        vm.warp(block.timestamp + 1 days);
        router.applySession(address(stock));
        router.proposeLookThrough(address(stock), new EmptyLookThrough());
        vm.warp(block.timestamp + 1 days);
        router.applyLookThrough(address(stock));
        _toWeekday();
        (,,, flags) = router.values(address(stock), 1e18);
        assertEq(uint256(flags), 2);
        _toSaturday();
        usd.set(address(weth), 2_000e18);
        (,,, flags) = router.values(address(stock), 1e18);
        assertEq(uint256(flags), 3);
        (PriceClass hc, bool closed, address lt) = router.holdInfo(address(stock));
        assertEq(uint8(hc), uint8(PriceClass.Pool));
        assertTrue(closed);
        assertTrue(lt != address(0));
        // Warmed: the same answer from the cache, flags included.
        address[] memory list = new address[](1);
        list[0] = address(stock);
        router.warm(list);
        (uint256[3] memory w,,, uint8 wf) = router.values(address(stock), 1e18);
        router.release();
        (uint256[3] memory cold,,,) = router.values(address(stock), 1e18);
        assertEq(w[0], cold[0]);
        assertEq(uint256(wf), 3);
    }

    /// @notice A warmed settlement prices the quote token once: a chained token warmed after its quote converts at
    ///         the cached quote, and keeps its own cached price until `release`.
    function test_WarmCacheServesChainedQuotes() public {
        _chained(address(stock), address(weth), 0.1e18, PriceClass.Pool, 0);
        address[] memory w = new address[](1);
        w[0] = address(weth);
        router.warm(w);
        usd.set(address(weth), 3_000e18); // the feed moves inside the transaction
        w[0] = address(stock);
        router.warm(w);
        assertEq(router.quote(address(stock)).fair, 200e18, "converted at the cached WETH");
        usd.set(address(weth), 4_000e18);
        assertEq(router.quote(address(stock)).fair, 200e18, "and kept until release");
        router.release();
        assertEq(router.quote(address(stock)).fair, 400e18);
    }

    // ------------------------------------------------ the weekend: worse-of across converted pools

    /// @dev `stock` at a $100 feed, a US-session token with weekend pools `pools`, spread 100, clamp 300, fallback
    ///      400 on top of a 50 haircut.
    function _weekendStock(SessionPoolSource.Spec[] memory pools) internal {
        _usd(address(stock), 100e18, PriceClass.Feed, 50);
        sessions.propose(address(stock), pools);
        vm.warp(block.timestamp + 1 days);
        sessions.applyPending(address(stock));
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 400,
                closedSpreadBps: 100,
                closedClampBps: 300,
                closedSource: IClosedMarketSource(address(sessions))
            })
        );
        vm.warp(block.timestamp + 1 days);
        router.applySession(address(stock));
    }

    function _spec(MockV3Pool p) internal pure returns (SessionPoolSource.Spec memory) {
        return SessionPoolSource.Spec(IUniswapV3PoolSession(address(p)), 1e17);
    }

    /// @dev A pool of stock against `quote` at about `price` quote per stock (token0 = stock when it sorts first).
    function _tickFor(uint256 priceWad) internal pure returns (int24) {
        // ln(price) / ln(1.0001), from a small table good to a tick for the prices used here.
        if (priceWad == 0.051e18) return -29761;
        if (priceWad == 0.0495e18) return -30060;
        if (priceWad == 0.06e18) return -28136;
        revert("no tick");
    }

    function test_WeekendWorseOfWithAWethPool() public {
        MockV3Pool p = _pool(address(stock), address(weth), _tickFor(0.051e18)); // about $102
        SessionPoolSource.Spec[] memory s = new SessionPoolSource.Spec[](1);
        s[0] = _spec(p);
        _weekendStock(s);
        _toSaturday();
        p.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        uint256 r = PoolMath.ratioAtTick(_tickFor(0.051e18), 18, true, 18);
        uint256 hiPool = r * 2_010e18 / 1e18; // converted at WETH's ask
        uint256 loPool = r * 1_990e18 / 1e18; // at WETH's bid
        assertGt(loPool, 100e18, "the pool says the stock rose");
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertTrue(q.available);
        assertEq(q.bid, 100e18 * 9_900 / 10_000, "leavers: the lower of the pool and Friday, less s");
        assertEq(q.ask, hiPool * 10_100 / 10_000, "entrants: the higher, plus s");
        assertEq(q.fair, (100e18 + hiPool) / 2);
    }

    /// @notice Two qualifying pools: the worst of both and the last price sets each side. Bending either pool up
    ///         only raises the ask, bending it down only lowers the bid: nobody gains by bending one.
    function test_WeekendTwoPoolsWorstWins() public {
        MockV3Pool up = _pool(address(stock), address(weth), _tickFor(0.051e18)); // about $102
        MockV3Pool down = _pool(address(stock), address(weth), _tickFor(0.0495e18)); // about $99
        SessionPoolSource.Spec[] memory s = new SessionPoolSource.Spec[](2);
        s[0] = _spec(up);
        s[1] = _spec(down);
        _weekendStock(s);
        _toSaturday();
        up.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        down.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        uint256 rUp = PoolMath.ratioAtTick(_tickFor(0.051e18), 18, true, 18);
        uint256 rDown = PoolMath.ratioAtTick(_tickFor(0.0495e18), 18, true, 18);
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertEq(q.bid, (rDown * 1_990e18 / 1e18) * 9_900 / 10_000, "the lowest pool");
        assertEq(q.ask, (rUp * 2_010e18 / 1e18) * 10_100 / 10_000, "the highest pool");

        // Bend the high pool further up (within the band): the bid does not move.
        up.setTick(_tickFor(0.06e18), block.timestamp - 10 days);
        IPriceRouter.Quote memory q2 = router.quote(address(stock));
        assertEq(q2.bid, q.bid, "bending up never raises the leavers' price");
        assertGe(q2.ask, q.ask, "only the entrants pay more");
        // Bend the low pool down: the ask does not move.
        down.setTick(-40_000, block.timestamp - 10 days);
        IPriceRouter.Quote memory q3 = router.quote(address(stock));
        assertEq(q3.ask, q2.ask, "bending down never lowers the entrants' price");
        assertLe(q3.bid, q2.bid);
    }

    function test_WeekendPoolHeldWithinTheBand() public {
        MockV3Pool p = _pool(address(stock), address(weth), _tickFor(0.06e18)); // about $120, 20% off
        SessionPoolSource.Spec[] memory s = new SessionPoolSource.Spec[](1);
        s[0] = _spec(p);
        _weekendStock(s);
        _toSaturday();
        p.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertEq(q.ask, 103e18 * 10_100 / 10_000, "clamped to 3% over the last price");
        assertEq(q.bid, 100e18 * 9_900 / 10_000);
    }

    function test_WeekendShallowOrShortPoolFallsBack() public {
        MockV3Pool p = _pool(address(stock), address(weth), _tickFor(0.051e18));
        SessionPoolSource.Spec[] memory s = new SessionPoolSource.Spec[](1);
        s[0] = _spec(p);
        _weekendStock(s);
        _toSaturday();
        p.setLiquidity(1e17 - 1); // under minLiquidity over the window
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertEq(q.fair, 100e18, "the last price");
        assertEq(q.bid, 100e18 * (10_000 - 450) / 10_000, "fallback: haircut plus closed haircut");
        assertEq(q.ask, 100e18 * (10_000 + 450) / 10_000);
        p.setLiquidity(1e18);
        p.setObserveReverts(true); // less history than the window
        assertEq(router.quote(address(stock)).bid, 100e18 * (10_000 - 450) / 10_000);
        p.setObserveReverts(false);
        usd.setDown(address(weth), true); // the quote token has no price: the pool cannot be converted
        assertEq(router.quote(address(stock)).bid, 100e18 * (10_000 - 450) / 10_000);
    }

    function test_WeekdayIgnoresWeekendPools() public {
        MockV3Pool p = _pool(address(stock), address(weth), _tickFor(0.06e18));
        SessionPoolSource.Spec[] memory s = new SessionPoolSource.Spec[](1);
        s[0] = _spec(p);
        _weekendStock(s);
        _toWeekday();
        IPriceRouter.Quote memory q = router.quote(address(stock));
        assertEq(q.fair, 100e18);
        assertEq(q.ask, 100e18 * 10_050 / 10_000, "only the normal haircut");
    }

    // ------------------------------------------------ session changes

    function _session(uint16 fallbackBps, uint16 s, uint16 clamp, address src)
        internal
        pure
        returns (PriceRouter.Session memory)
    {
        return PriceRouter.Session({
            usSession: true,
            closedHaircutBps: fallbackBps,
            closedSpreadBps: s,
            closedClampBps: clamp,
            closedSource: IClosedMarketSource(src)
        });
    }

    function test_SessionInstantOnlyWhenItWidensWithTheSameSourceAndBand() public {
        _usd(address(stock), 100e18, PriceClass.Feed, 50);
        router.proposeSession(address(stock), _session(400, 100, 300, address(sessions)));
        assertGt(router.pendingSessionAt(address(stock)), 0, "a first session waits");
        vm.warp(block.timestamp + 1 days);
        router.applySession(address(stock));

        router.proposeSession(address(stock), _session(500, 200, 300, address(sessions)));
        assertEq(router.pendingSessionAt(address(stock)), 0, "wider spreads, same source and band: at once");
        assertEq(router.sessionOf(address(stock)).closedSpreadBps, 200);

        router.proposeSession(address(stock), _session(500, 150, 300, address(sessions)));
        assertGt(router.pendingSessionAt(address(stock)), 0, "a narrower spread waits");
        router.proposeSession(address(stock), _session(400, 200, 300, address(sessions)));
        assertGt(router.pendingSessionAt(address(stock)), 0, "a narrower fallback waits");
        router.proposeSession(address(stock), _session(500, 200, 400, address(sessions)));
        assertGt(router.pendingSessionAt(address(stock)), 0, "another band waits");
        router.proposeSession(address(stock), _session(500, 200, 300, address(0)));
        assertGt(router.pendingSessionAt(address(stock)), 0, "dropping the source waits");
        router.proposeSession(address(stock), _session(500, 200, 300, address(0xBEEF)));
        assertGt(router.pendingSessionAt(address(stock)), 0, "another source waits");
        assertEq(router.sessionOf(address(stock)).closedSpreadBps, 200, "nothing applied meanwhile");

        vm.expectRevert(PriceRouter.BadConfig.selector);
        router.proposeSession(address(stock), _session(500, 200, 10_000, address(sessions)));
        vm.expectRevert(PriceRouter.BadConfig.selector);
        router.proposeSession(
            address(stock),
            PriceRouter.Session({
                usSession: false,
                closedHaircutBps: 0,
                closedSpreadBps: 0,
                closedClampBps: 0,
                closedSource: IClosedMarketSource(address(sessions))
            })
        );
    }
}
