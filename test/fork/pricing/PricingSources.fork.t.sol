// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ChainlinkSource, IChainlinkFeed} from "../../../src/pricing/sources/ChainlinkSource.sol";
import {UniswapV3TwapSource, IUniswapV3PoolOracle} from "../../../src/pricing/sources/UniswapV3TwapSource.sol";
import {PriceRecorder} from "../../../src/pricing/sources/PriceRecorder.sol";
import {PoolMath} from "../../../src/pricing/sources/PoolMath.sol";
import {PriceRouter} from "../../../src/pricing/PriceRouter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IPriceRouter, PriceClass, Side} from "../../../src/interfaces/IPriceRouter.sol";
import {IClosedMarketSource} from "../../../src/interfaces/IClosedMarketSource.sol";
import {SessionPoolSource, IUniswapV3PoolSession} from "../../../src/pricing/sources/SessionPoolSource.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IStockTokenView {
    function balanceOf(address) external view returns (uint256);
    function balanceOfUI(address) external view returns (uint256);
    function uiMultiplier() external view returns (uint256);
    function oraclePaused() external view returns (bool);
}

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
}

/// @notice The price sources against Robinhood Chain (4663) at the latest block. Skipped without
///         ROBINHOOD_RPC. Kept to a few dozen RPC reads: the public endpoint rate-limits.
contract PricingSourcesForkTest is Test {
    // tokens
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant CBBTC = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant NOVAAI = 0x51250B135174Ca09450EC01c4afF73CF69DBb590;
    // Chainlink feeds (cl-feeds.json)
    address constant NVDA_USD = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant SPY_USD = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant CBBTC_USD = 0x0009cD492adf8167f9eEBf1293556A673530a21a;
    address constant USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    // Uniswap
    address constant PONS_WETH_1PCT = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA;
    address constant PONS_WETH_03 = 0xEd50bDeeA8aDC232f159486192a4157281D722ff; // the deepest (2026-10-02)
    address constant NVDA_USDG_005 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant NVDA_WETH_005 = 0x62AB521f71431f78ac374CdbadC6cda3c8916b6C;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    ChainlinkSource cl;
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;

        cl = new ChainlinkSource(address(this));
        // Propose a day in the past so applying needs no warp that would age the feeds.
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        _feed(NVDA, NVDA_USD, true);
        _feed(SPY, SPY_USD, true);
        _feed(WETH, ETH_USD, false);
        _feed(CBBTC, CBBTC_USD, false);
        _feed(USDG, USDG_USD, false);
        vm.warp(now_);
        cl.applyPending(NVDA);
        cl.applyPending(SPY);
        cl.applyPending(WETH);
        cl.applyPending(CBBTC);
        cl.applyPending(USDG);
    }

    function _feed(address token, address feed, bool stock) internal {
        cl.propose(
            token,
            ChainlinkSource.Feed(IChainlinkFeed(feed), 26 hours, stock, stock, IPriceSource(address(0)), address(0), 0)
        );
    }

    function _price(IPriceSource s, address token, string memory label) internal view returns (uint256 usd) {
        bool ok;
        uint64 at;
        (usd, at, ok) = s.price(token);
        console2.log(label, usd, block.timestamp - at);
        assertTrue(ok, label);
    }

    function test_chainlinkPricesTheMainTokens() public {
        if (!live) vm.skip(true);
        assertEq(cl.feedOf(NVDA).decimals, 8);
        assertBetween(_price(cl, NVDA, "NVDA usd, age"), 50e18, 1_000e18);
        assertBetween(_price(cl, SPY, "SPY usd, age"), 300e18, 2_000e18);
        assertBetween(_price(cl, WETH, "WETH usd, age"), 500e18, 20_000e18);
        assertBetween(_price(cl, CBBTC, "cbBTC usd, age"), 10_000e18, 1_000_000e18);
        assertBetween(_price(cl, USDG, "USDG usd, age"), 0.98e18, 1.02e18);
        assertFalse(IStockTokenView(NVDA).oraclePaused());
    }

    /// @dev The multiplier question. `balanceOfUI` is `balanceOf` times `uiMultiplier`, and the feed is
    ///      already per raw token, so the router's `amount x price` takes the raw `balanceOf`.
    function test_stockFeedIsPerRawTokenAndUiBalanceAddsTheMultiplier() public {
        if (!live) vm.skip(true);
        IStockTokenView t = IStockTokenView(NVDA);
        uint256 raw = t.balanceOf(MORPHO);
        uint256 ui = t.balanceOfUI(MORPHO);
        uint256 m = t.uiMultiplier();
        console2.log("NVDA raw, ui, multiplier", raw, ui, m);
        assertGt(m, 1e18);
        assertApproxEqAbs(ui, raw * m / 1e18, 1, "balanceOfUI = balanceOf x uiMultiplier");

        PriceRouter router = new PriceRouter(address(this));
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        router.propose(NVDA, PriceRouter.Config(cl, IPriceSource(address(0)), PriceClass.Feed, 50, 0, 0, 0));
        vm.warp(now_);
        router.applyPending(NVDA);
        (uint256 usd,, bool ok) = router.value(NVDA, raw, Side.Fair);
        (uint256 p,,) = cl.price(NVDA);
        assertTrue(ok);
        assertEq(usd, raw * p / 1e18);
        console2.log("Morpho's NVDA collateral, USD", usd / 1e18);
    }

    /// @dev A router pricing USDG, WETH and NVDA from Chainlink (proposed a day back, applied now).
    function _router() internal returns (PriceRouter router) {
        router = new PriceRouter(address(this));
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        router.propose(USDG, PriceRouter.Config(cl, IPriceSource(address(0)), PriceClass.Feed, 0, 0, 0, 0));
        router.propose(WETH, PriceRouter.Config(cl, IPriceSource(address(0)), PriceClass.Feed, 50, 0, 0, 0));
        router.propose(NVDA, PriceRouter.Config(cl, IPriceSource(address(0)), PriceClass.Feed, 50, 0, 0, 0));
        vm.warp(now_);
        router.applyPending(USDG);
        router.applyPending(WETH);
        router.applyPending(NVDA);
    }

    function _chain(PriceRouter router, address token, IPriceSource s, PriceClass c) internal {
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        router.propose(token, PriceRouter.Config(s, IPriceSource(address(0)), c, 300, 0, 0, 1));
        vm.warp(now_);
        router.applyPending(token);
    }

    /// @notice PONS from its deepest pool, against WETH, converted by the router through its own WETH price; NVDA
    ///         from its USDG pool and from its WETH pool, both near the feed.
    function test_twapPricesPonsThroughTheRoutersWeth() public {
        if (!live) vm.skip(true);
        UniswapV3TwapSource twap = new UniswapV3TwapSource(address(this));
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        twap.propose(PONS, IUniswapV3PoolOracle(PONS_WETH_03), 30 minutes, false);
        twap.propose(NVDA, IUniswapV3PoolOracle(NVDA_WETH_005), 30 minutes, true);
        vm.warp(now_);
        twap.applyPending(PONS);
        twap.applyPending(NVDA);
        PriceRouter router = _router();
        _chain(router, PONS, twap, PriceClass.Pool);

        uint256 history = twap.historySeconds(IUniswapV3PoolOracle(PONS_WETH_03));
        console2.log("PONS/WETH 0.3% history seconds", history);
        assertGe(history, 30 minutes);
        (address quote, uint256 r,, bool ok) = twap.ratio(PONS);
        assertTrue(ok);
        assertEq(quote, WETH);
        IPriceRouter.Quote memory qw = router.quote(WETH);
        IPriceRouter.Quote memory q = router.quote(PONS);
        console2.log("PONS usd via WETH, ratio", q.fair, r);
        assertTrue(q.available);
        assertEq(q.fair, r * qw.fair / 1e18);
        assertEq(uint8(q.class_), uint8(PriceClass.Pool));
        assertLt(q.bid, q.fair);

        // NVDA through its WETH pool, converted at the ETH feed, sits near the NVDA feed.
        (, uint256 rn,, bool okN) = twap.ratio(NVDA);
        assertTrue(okN);
        uint256 viaWeth = rn * qw.fair / 1e18;
        (uint256 viaFeed,,) = cl.price(NVDA);
        console2.log("NVDA via WETH pool, via feed", viaWeth, viaFeed);
        assertApproxEqRel(viaWeth, viaFeed, 0.02e18, "a WETH pool converted at the ETH feed is within 2% of the feed");
    }

    /// @notice The weekend worse-of with NVDA's USDG and WETH pools on a Saturday: both convert near the last
    ///         feed price, and the router's bid and ask come from the worst of them.
    function test_weekendWorseOfWithUsdgAndWethPools() public {
        if (!live) vm.skip(true);
        PriceRouter router = _router();
        SessionPoolSource sessions = new SessionPoolSource(address(this));
        SessionPoolSource.Spec[] memory specs = new SessionPoolSource.Spec[](2);
        specs[0] = SessionPoolSource.Spec(IUniswapV3PoolSession(NVDA_USDG_005), 1);
        specs[1] = SessionPoolSource.Spec(IUniswapV3PoolSession(NVDA_WETH_005), 1);
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        sessions.propose(NVDA, specs);
        router.proposeSession(
            NVDA,
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: 450,
                closedSpreadBps: 100,
                closedClampBps: 300,
                closedSource: IClosedMarketSource(address(sessions))
            })
        );
        vm.warp(now_);
        sessions.applyPending(NVDA);
        router.applySession(NVDA);

        IClosedMarketSource.Ratio[] memory rs = sessions.closedRatios(NVDA);
        assertEq(rs.length, 2, "both pools qualify");
        IPriceRouter.Quote memory qw = router.quote(WETH);
        uint256 viaUsdg = rs[0].ratioWad * router.quote(USDG).fair / 1e18;
        uint256 viaWeth = rs[1].ratioWad * qw.fair / 1e18;
        console2.log("NVDA 30-min TWAP via USDG pool, via WETH pool", viaUsdg, viaWeth);
        assertApproxEqRel(viaUsdg, viaWeth, 0.01e18, "the converted pools track each other");

        // A Saturday: the router prices NVDA on the worst of the two pools and the last feed price.
        uint256 day = block.timestamp / 1 days + 1;
        while (day % 7 != 2) ++day;
        vm.warp(day * 1 days + 1 hours); // the Chainlink source skips weekend hours in its age
        (uint256 last,,) = cl.price(NVDA);
        IPriceRouter.Quote memory q = router.quote(NVDA);
        assertTrue(q.available);
        console2.log("Saturday: last, bid, ask", last, q.bid, q.ask);
        assertLe(q.bid, last * 9_900 / 10_000, "leavers: at most the last price less s");
        assertGe(q.ask, last * 10_100 / 10_000, "entrants: at least the last price plus s");
        assertLe(q.ask, last * 10_300 / 10_000 * 10_100 / 10_000 + 1, "within the band");
    }

    function test_recorderPricesAPonsPoolThroughTheRouter() public {
        if (!live) vm.skip(true);
        PriceRecorder rec = new PriceRecorder(address(this), IPoolManager(POOL_MANAGER));
        rec.setRecorder(address(this), true);
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(NOVAAI), 0, 200, IHooks(PONS_HOOK));
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        rec.propose(NOVAAI, key, WETH);
        vm.warp(now_);
        rec.applyPending(NOVAAI);

        (, int24 viewTick,,) = IStateView(STATE_VIEW).getSlot0(PoolId.unwrap(key.toId()));
        console2.log("NOVAAI/ETH tick via StateView");
        console2.logInt(viewTick);

        // Start at the next slot boundary, then mark and confirm in each of 100 slots.
        vm.warp((block.timestamp / 600 + 1) * 600 + 5);
        for (uint256 i; i < 100; ++i) {
            assertEq(uint8(rec.record(NOVAAI)), uint8(PriceRecorder.Recorded.Marked));
            vm.warp(block.timestamp + 61);
            vm.roll(block.number + 3);
            assertEq(uint8(rec.record(NOVAAI)), uint8(PriceRecorder.Recorded.Final));
            vm.warp(block.timestamp + 600 - 61);
            vm.roll(block.number + 3);
        }
        (int24 med, uint256 count,) = rec.medianTick(NOVAAI);
        assertEq(count, 100);
        assertEq(med, viewTick, "no trades on the fork: every reading is the pool's tick");

        uint256 g = gasleft();
        (address quote, uint256 r,, bool ok) = rec.ratio(NOVAAI);
        console2.log("recorder ratio() gas", g - gasleft());
        assertTrue(ok);
        assertEq(quote, WETH);
        assertEq(r, PoolMath.ratioAtTick(viewTick, 18, false, 18));
        _routerOverRecorder(rec, r);
    }

    /// @dev The router converts the recorder's ratio through a WETH price (a fixed one: the test runs 17 hours past
    ///      the fork block, where the feed is old).
    function _routerOverRecorder(PriceRecorder rec, uint256 r) internal {
        PriceRouter router = new PriceRouter(address(this));
        FixedPrice eth = new FixedPrice(2_700e18);
        vm.warp(block.timestamp - 1 days);
        router.propose(WETH, PriceRouter.Config(eth, IPriceSource(address(0)), PriceClass.Feed, 0, 0, 0, 0));
        router.propose(NOVAAI, PriceRouter.Config(rec, IPriceSource(address(0)), PriceClass.Thin, 1000, 0, 0, 1));
        vm.warp(block.timestamp + 1 days);
        router.applyPending(WETH);
        router.applyPending(NOVAAI);
        IPriceRouter.Quote memory q = router.quote(NOVAAI);
        assertTrue(q.available);
        assertEq(q.fair, r * 2_700e18 / 1e18);
        assertEq(uint8(q.class_), uint8(PriceClass.Thin));
    }

    function assertBetween(uint256 v, uint256 lo, uint256 hi) internal pure {
        assertGe(v, lo);
        assertLe(v, hi);
    }
}

contract FixedPrice is IPriceSource {
    uint256 internal immutable p;

    constructor(uint256 p_) {
        p = p_;
    }

    function price(address) external view returns (uint256, uint64, bool) {
        return (p, uint64(block.timestamp), true);
    }

    function name() external pure returns (string memory) {
        return "fixed";
    }
}
