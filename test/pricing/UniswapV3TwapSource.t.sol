// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TwapSource, IUniswapV3PoolOracle} from "../../src/pricing/sources/UniswapV3TwapSource.sol";
import {ChainlinkSource, IChainlinkFeed} from "../../src/pricing/sources/ChainlinkSource.sol";
import {SourceAdmin} from "../../src/pricing/sources/SourceAdmin.sol";
import {PoolMath} from "../../src/pricing/sources/PoolMath.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {MockV3Pool, MockAggregator, MockStockToken} from "./PricingMocks.sol";

/// @notice The v3 TWAP source reports a price in the pool's other token (`IRatioSource`); the router converts it.
contract UniswapV3TwapSourceTest is Test {
    UniswapV3TwapSource internal src;
    MockERC20 internal token; // 18 decimals
    MockERC20 internal usdg; // 6 decimals
    MockV3Pool internal pool;

    function setUp() public {
        vm.warp(1_790_860_852);
        src = new UniswapV3TwapSource(address(this));
        token = new MockERC20("Pons", "PONS", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        // token0 = token, token1 = usdg. Tick -276324 is about 1e-12 raw USDG per raw token: one USDG per token.
        pool = new MockV3Pool(address(token), address(usdg));
        pool.setTick(-276324, block.timestamp - 10 days);
        pool.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        _configure(address(token), pool, 30 minutes);
    }

    function _configure(address t, MockV3Pool p, uint32 window) internal {
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        src.propose(t, IUniswapV3PoolOracle(address(p)), window, false);
        vm.warp(now_);
        src.applyPending(t);
    }

    function _ratio(int24 tick) internal pure returns (uint256) {
        return PoolMath.ratioAtTick(tick, 18, true, 6);
    }

    function test_ratioInTheQuoteToken() public view {
        (address quote, uint256 r, uint64 at, bool ok) = src.ratio(address(token));
        assertTrue(ok);
        assertEq(quote, address(usdg), "the pool's other token");
        assertApproxEqRel(r, 1e18, 0.0001e18); // within one tick
        assertEq(r, _ratio(-276324));
        assertEq(at, block.timestamp);
        assertEq(src.name(), "Uniswap v3 TWAP");
    }

    function test_priceAnswersNothing() public view {
        (uint256 usd,, bool ok) = src.price(address(token));
        assertFalse(ok, "a USD price needs the router's conversion");
        assertEq(usd, 0);
    }

    function test_baseAsToken1() public {
        // token1 = the priced token, token0 = WETH, equal decimals; tick 6932 is 2 token1 per token0, so one token
        // is half a WETH.
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 meme = new MockERC20("Meme", "MEME", 18);
        MockV3Pool p = new MockV3Pool(address(weth), address(meme));
        p.setTick(6932, block.timestamp - 1 days);
        p.setHistory(0, 10, 1, uint32(block.timestamp - 1 days), true);
        _configure(address(meme), p, 1 hours);
        (address quote, uint256 r,, bool ok) = src.ratio(address(meme));
        assertTrue(ok);
        assertEq(quote, address(weth));
        assertApproxEqRel(r, 0.5e18, 0.001e18);
    }

    function test_usesTheTimeWeightedMeanNotSpot() public {
        pool.forceCumulatives(0, 1800 * 100);
        (, uint256 r,, bool ok) = src.ratio(address(token));
        assertTrue(ok);
        assertEq(r, _ratio(100));
    }

    function test_negativeMeanRoundsDown() public {
        pool.forceCumulatives(0, -1); // mean -1/1800: rounds to -1, not 0
        (, uint256 r,,) = src.ratio(address(token));
        assertEq(r, _ratio(-1));
        pool.forceCumulatives(0, -3600); // exact: -2
        (, r,,) = src.ratio(address(token));
        assertEq(r, _ratio(-2));
    }

    function test_ratioKeepsPrecisionForACheapTokenAgainstFewDecimals() public pure {
        // A token worth about 2e-7 of an 8-decimal quote: one whole token is 20 raw units, too coarse alone.
        int24 t = -276324 - 154_000;
        uint256 r = PoolMath.ratioAtTick(t, 18, true, 8);
        assertGt(r, 0);
        assertEq(PoolMath.quoteAtTick(t, 1e18, true), 0, "one whole token alone reads as nothing");
        uint256 fine = PoolMath.quoteAtTick(t, 1e36, true) / 1e8; // a trillion trillion tokens
        assertApproxEqRel(r, fine, 1e9);
        assertEq(PoolMath.ratioAtTick(700_000, 18, true, 6), 0, "beyond any real market");
    }

    // ---- cardinality / history ----

    function test_historyShorterThanWindowIsUnavailable() public {
        pool.setHistory(5, 100, 6, uint32(block.timestamp - 29 minutes), true);
        (,,, bool ok) = src.ratio(address(token));
        assertFalse(ok);
        assertEq(src.historySeconds(IUniswapV3PoolOracle(address(pool))), 29 minutes);
        pool.setHistory(5, 100, 6, uint32(block.timestamp - 30 minutes), true);
        (,,, ok) = src.ratio(address(token));
        assertTrue(ok, "exactly the window is enough");
    }

    function test_ringNotFullReadsSlotZero() public {
        MockV3Pool p = new MockV3Pool(address(token), address(usdg));
        p.setTick(0, block.timestamp - 1 days);
        p.setHistory(5, 100, 0, uint32(block.timestamp - 3 hours), false);
        assertEq(src.historySeconds(IUniswapV3PoolOracle(address(p))), 3 hours);
    }

    function test_cardinalityOfOneOnlyCoversItsLastWrite() public {
        MockV3Pool p = new MockV3Pool(address(token), address(usdg));
        p.setHistory(0, 1, 0, uint32(block.timestamp - 5 minutes), true);
        assertEq(src.historySeconds(IUniswapV3PoolOracle(address(p))), 5 minutes);
        _configure(address(token), p, 30 minutes);
        (,,, bool ok) = src.ratio(address(token));
        assertFalse(ok);
    }

    function test_observeRevertIsUnavailable() public {
        pool.setObserveReverts(true);
        (,,, bool ok) = src.ratio(address(token));
        assertFalse(ok);
    }

    // ---- configuration ----

    function test_windowUnderThirtyMinutesRefused() public {
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(token), IUniswapV3PoolOracle(address(pool)), 30 minutes - 1, false);
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(token), IUniswapV3PoolOracle(address(pool)), 7 days + 1, false);
    }

    function test_poolMustHoldTheToken() public {
        MockERC20 other = new MockERC20("Other", "O", 18);
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(other), IUniswapV3PoolOracle(address(pool)), 1 hours, false);
    }

    function test_changesWaitRemovalIsInstant() public {
        src.propose(address(token), IUniswapV3PoolOracle(address(pool)), 1 hours, false);
        assertGt(src.pendingAt(address(token)), 0);
        assertEq(src.twapOf(address(token)).window, 30 minutes, "old window in force");
        src.propose(address(token), IUniswapV3PoolOracle(address(0)), 0, false);
        (,,, bool ok) = src.ratio(address(token));
        assertFalse(ok);
        assertEq(src.pendingAt(address(token)), 0, "removal also drops the pending change");
    }

    // ---- un-fed Robinhood stock tokens ----

    function _stockPool(bool checkPause) internal returns (MockStockToken stock) {
        stock = new MockStockToken();
        MockV3Pool p = new MockV3Pool(address(stock), address(usdg));
        p.setTick(-276324, block.timestamp - 10 days);
        p.setHistory(0, 10, 1, uint32(block.timestamp - 1 days), true);
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        src.propose(address(stock), IUniswapV3PoolOracle(address(p)), 30 minutes, checkPause);
        vm.warp(now_);
        src.applyPending(address(stock));
    }

    function test_pausedStockTokenIsUnavailable() public {
        MockStockToken stock = _stockPool(true);
        (,,, bool ok) = src.ratio(address(stock));
        assertTrue(ok);
        stock.setPaused(true);
        (,,, ok) = src.ratio(address(stock));
        assertFalse(ok);
    }

    function test_pauseCheckOnTokenWithoutPauseIsUnavailable() public {
        src.propose(address(token), IUniswapV3PoolOracle(address(pool)), 30 minutes, true);
        (,,, bool ok) = src.ratio(address(token));
        assertFalse(ok);
    }

    function test_pauseCheckOnIsInstantOffWaits() public {
        MockStockToken stock = _stockPool(false);
        MockV3Pool p = MockV3Pool(address(src.twapOf(address(stock)).pool));
        src.propose(address(stock), IUniswapV3PoolOracle(address(p)), 30 minutes, true);
        assertEq(src.pendingAt(address(stock)), 0, "turning the check on applies at once");
        assertTrue(src.twapOf(address(stock)).checkPause);
        src.propose(address(stock), IUniswapV3PoolOracle(address(p)), 30 minutes, false);
        assertGt(src.pendingAt(address(stock)), 0, "turning it off waits");
        assertTrue(src.twapOf(address(stock)).checkPause);
    }

    // ---- with the router: Chainlink primary, TWAP check (chained through the router's USDG) ----

    function test_routerRefusesWhenFeedAndPoolDisagree() public {
        PriceRouter router = new PriceRouter(address(this));
        ChainlinkSource cl = new ChainlinkSource(address(this));
        MockPriceSource usd = new MockPriceSource();
        usd.set(address(usdg), 1e18);
        MockAggregator feed = new MockAggregator(8);
        feed.set(1e8, block.timestamp);
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        cl.propose(
            address(token),
            ChainlinkSource.Feed(
                IChainlinkFeed(address(feed)), 26 hours, false, false, IPriceSource(address(0)), address(0), 0
            )
        );
        router.propose(
            address(usdg),
            PriceRouter.Config({
                primary: usd,
                check: IPriceSource(address(0)),
                class_: PriceClass.Feed,
                haircutBps: 0,
                maxDeviationBps: 0,
                decimals: 0,
                chained: 0
            })
        );
        router.propose(
            address(token),
            PriceRouter.Config({
                primary: cl,
                check: src,
                class_: PriceClass.Feed,
                haircutBps: 50,
                maxDeviationBps: 200,
                decimals: 0,
                chained: 2
            })
        );
        vm.warp(now_);
        cl.applyPending(address(token));
        router.applyPending(address(usdg));
        router.applyPending(address(token));

        assertTrue(router.quote(address(token)).available, "feed $1, pool about $1");
        feed.set(1.03e8, block.timestamp); // 3% apart, over the 2% limit
        assertFalse(router.quote(address(token)).available);
        feed.set(1.015e8, block.timestamp); // 1.5% apart
        assertTrue(router.quote(address(token)).available);
        pool.setObserveReverts(true); // check source down
        assertFalse(router.quote(address(token)).available);
    }
}
