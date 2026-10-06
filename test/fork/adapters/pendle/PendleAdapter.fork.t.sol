// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdapterRegistry} from "../../../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../../../src/core/FundFactory.sol";
import {FundVault} from "../../../../src/core/FundVault.sol";
import {FundController} from "../../../../src/core/FundController.sol";
import {SeedTeller} from "../../../../src/core/SeedTeller.sol";
import {Dial} from "../../../../src/interfaces/IFundController.sol";
import {DialPresets} from "../../../../src/core/DialPresets.sol";
import {Amount} from "../../../../src/interfaces/IAdapter.sol";
import {PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../../src/interfaces/IPriceSource.sol";
import {PendleAdapter} from "../../../../src/adapters/pendle/PendleAdapter.sol";
import {
    IPendleMarket,
    IPendleMarketFactory,
    IPendlePYLpOracle,
    IPendleRouter
} from "../../../../src/interfaces/external/pendle/IPendle.sol";
import {MockPriceSource} from "../../../utils/Mocks.sol";

/**
 * @notice The Pendle adapter against Pendle V2 on Robinhood Chain (4663): the live router, markets and oracle. Skipped
 *         when ROBINHOOD_RPC is unset. Prices come from a hand-set source (USDG $1, NVDA $239); the Pendle side is all
 *         real, so a wrong struct layout or call would revert here.
 */
contract PendleAdapterForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant SHROOM_ASSET = 0xab093dEF657F15dF31b33922A95e047aDd645B29;
    address constant ROUTER_PENDLE = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant ORACLE = 0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2;
    address constant FACTORY = 0x544BF81c855AE84c1e8b65d5E38770898D01EeE2;
    address constant M_USDG = 0xC2B89e6EcA583e2c232201ac557E9bE58AF55f4c;
    address constant M_NVDA = 0x206a5cD00E9FfaBb8CA564076B64799A78DF19b9;
    address constant M_SHROOM = 0x25f241538bC3de8F7130706827b3f6946dB51f5d;

    address guardian = makeAddr("guardian");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");

    bool forked;
    AdapterRegistry registry;
    PriceRouter router;
    MockPriceSource source;
    FundFactory factory;
    SeedTeller teller;
    FundVault vault;
    FundController controller;
    PendleAdapter pendle;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        uint256 t0 = block.timestamp;
        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        factory = new FundFactory(registry, router, guardian, USDG);
        teller = new SeedTeller();
        _price(USDG, 1e18);
        _price(NVDA, 239e18);
        vm.warp(t0); // router changes wait a day; back to the real time for Pendle and its oracle

        (vault, controller) = factory.create("Fork Fund", "FF", owner, address(teller), _openDial());
        deal(USDG, owner, 5000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), 5000e6);
        teller.seed(vault, USDG, 5000e6, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        PendleAdapter impl = new PendleAdapter(
            IPendleRouter(ROUTER_PENDLE), IPendlePYLpOracle(ORACLE), IPendleMarketFactory(FACTORY), IPendleMarketFactory(address(0))
        );
        registry.register(address(impl), "");
        vm.prank(owner);
        pendle = PendleAdapter(controller.addAdapter(address(impl), ""));
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _openDial() internal pure returns (Dial memory d) {
        d = DialPresets.open();
        d.allowBorrow = false;
    }

    function _price(address token, uint256 usdWad) internal {
        source.set(token, usdWad);
        router.propose(token, PriceRouter.Config({
            primary: IPriceSource(address(source)), check: IPriceSource(address(0)), class_: PriceClass.Feed,
            haircutBps: 0, maxDeviationBps: 0, decimals: 0, chained: 0
        }));
        if (router.pendingAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(token);
        }
    }

    function _act(uint8 id, address market, address token, uint256 amount, uint256 minOut) internal returns (uint256 out) {
        vm.prank(manager);
        bytes memory r = controller.act(address(pendle), abi.encode(id, market, token, amount, minOut));
        out = abi.decode(r, (uint256));
    }

    function _held() internal view returns (uint256 total) {
        (Amount[] memory a,) = pendle.positions(router);
        for (uint256 i; i < a.length; ++i) {
            (uint256 v,,) = router.value(a[i].token, a[i].amount, Side.Fair);
            total += v;
        }
    }

    function _noLoose(address market) internal view {
        PendleAdapter.MarketInfo memory x = pendle.marketInfo(market);
        assertEq(IERC20(USDG).balanceOf(address(pendle)), 0, "loose USDG");
        if (x.sy != address(0)) assertEq(IERC20(x.sy).balanceOf(address(pendle)), 0, "loose SY");
    }

    // ---------------------------------------------------------------- USDG: fixed rate, YT, LP

    function test_UsdgPtRoundTrip() public onFork {
        assertTrue(pendle.oracleReady(M_USDG), "USDG market oracle ready");
        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        uint256 pt = _act(0, M_USDG, USDG, 1000e6, 1);
        uint256 worth = _held();
        console.log("1000 USDG bought PT-USDG (raw):", pt);
        console.log("held, USD 1e18:", worth);
        assertApproxEqRel(worth, 1000e18, 0.01e18, "PT valued near what it cost");
        assertGt(pt, 1000e6, "PT trades below par: more PT than USDG");
        _noLoose(M_USDG);

        uint256 back = _act(1, M_USDG, USDG, type(uint256).max, 1);
        console.log("sold all PT for USDG (raw):", back);
        assertApproxEqRel(back, 1000e6, 0.01e18, "round trip within 1%");
        assertEq(IERC20(USDG).balanceOf(address(vault)), vaultBefore - 1000e6 + back);
        assertEq(pendle.markets().length, 0, "market pruned once empty");
    }

    function test_UsdgYtLpClaim() public onFork {
        uint256 yt = _act(2, M_USDG, USDG, 20e6, 1);
        uint256 lp = _act(4, M_USDG, USDG, 500e6, 1);
        console.log("20 USDG bought YT (raw):", yt);
        console.log("500 USDG added LP (raw):", lp);
        uint256 worth = _held();
        console.log("held, USD 1e18:", worth);
        assertApproxEqRel(worth, 520e18, 0.02e18, "YT and LP valued near cost");
        _noLoose(M_USDG);

        vm.warp(block.timestamp + 3 days);
        PendleAdapter.MarketInfo memory x = pendle.marketInfo(M_USDG);
        uint256 got = _act(7, M_USDG, USDG, 0, 0);
        console.log("claimed after 3 days, USDG raw:", got);
        _noLoose(M_USDG);
        assertEq(IERC20(x.yt).balanceOf(address(pendle)), yt, "claim keeps the YT");

        uint256 out = _act(5, M_USDG, USDG, type(uint256).max, 1);
        console.log("removed all LP, USDG raw:", out);
        assertApproxEqRel(out, 500e6, 0.01e18);
        uint256 ytOut = _act(3, M_USDG, USDG, type(uint256).max, 1);
        console.log("sold all YT, USDG raw:", ytOut);
        assertEq(pendle.markets().length, 0);
    }

    function test_UnwindAndSplit() public onFork {
        _act(0, M_USDG, USDG, 600e6, 1);
        _act(4, M_USDG, USDG, 300e6, 1);
        _act(2, M_USDG, USDG, 10e6, 1);
        uint256 worth = _held();
        PendleAdapter.MarketInfo memory x = pendle.marketInfo(M_USDG);
        address leaver = makeAddr("leaver");
        uint256 pt = IERC20(x.pt).balanceOf(address(pendle));
        vm.prank(address(controller));
        Amount[] memory sent = pendle.split(0.25e18, leaver);
        assertEq(sent.length, 3);
        assertEq(IERC20(x.pt).balanceOf(leaver), pt / 4, "a quarter of the PT, in kind");
        assertGt(IERC20(M_USDG).balanceOf(leaver), 0, "LP in kind");
        assertGt(IERC20(x.yt).balanceOf(leaver), 0, "YT in kind");
        assertApproxEqRel(_held(), worth * 3 / 4, 0.001e18, "three quarters stay");

        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        vm.prank(address(controller));
        Amount[] memory got = pendle.unwind(1e18);
        uint256 back = IERC20(USDG).balanceOf(address(vault)) - vaultBefore;
        console.log("unwound the rest, USDG raw:", back);
        assertEq(got[0].amount, back);
        assertApproxEqRel(back * 1e12, worth * 3 / 4, 0.02e18, "unwind returns what positions reported");
        assertEq(pendle.markets().length, 0, "nothing left");
        _noLoose(M_USDG);
    }

    function test_Grow() public onFork {
        _act(2, M_USDG, USDG, 20e6, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(controller));
        pendle.grow(0);
        _noLoose(M_USDG);
        vm.prank(address(controller));
        vm.expectRevert(PendleAdapter.NoGrow.selector);
        pendle.grow(0.1e18);
    }

    // ---------------------------------------------------------------- a stock market and a meme market

    function test_NvdaMarketNeedsItsOracleFirst() public onFork {
        deal(NVDA, address(vault), 10e18);
        bool ready = pendle.oracleReady(M_NVDA);
        console.log("NVDA market oracle ready before:", ready);
        if (!ready) {
            vm.prank(manager);
            vm.expectRevert(abi.encodeWithSelector(PendleAdapter.OracleNotReady.selector, M_NVDA));
            controller.act(address(pendle), abi.encode(uint8(0), M_NVDA, NVDA, uint256(1e18), uint256(1)));
            IPendleMarket(M_NVDA).increaseObservationsCardinalityNext(901);
            vm.warp(block.timestamp + 901);
        }
        console.log("NVDA market oracle ready after:", pendle.oracleReady(M_NVDA));
        if (!pendle.oracleReady(M_NVDA)) return; // observations only fill as the market trades
        uint256 pt = _act(0, M_NVDA, NVDA, 1e18, 1);
        console.log("1 NVDA bought PT-NVDA (raw):", pt);
        assertApproxEqRel(_held(), 239e18, 0.02e18, "PT-NVDA valued in NVDA at the router's price");
        uint256 back = _act(1, M_NVDA, NVDA, type(uint256).max, 1);
        console.log("sold PT-NVDA for NVDA (raw):", back);
    }

    function test_ShroomMarketRefusedUntilReady() public onFork {
        bool ready = pendle.oracleReady(M_SHROOM);
        console.log("SHROOM market oracle ready:", ready);
        deal(SHROOM_ASSET, address(vault), 1000e18);
        (, PriceClass c,) = router.value(SHROOM_ASSET, 1e18, Side.Fair);
        console.log("SHROOM asset class in this router (0 = none):", uint8(c));
        if (!ready) {
            vm.prank(manager);
            vm.expectRevert(abi.encodeWithSelector(PendleAdapter.OracleNotReady.selector, M_SHROOM));
            controller.act(address(pendle), abi.encode(uint8(0), M_SHROOM, SHROOM_ASSET, uint256(100e18), uint256(1)));
        }
    }

    // ---------------------------------------------------------------- guards

    function test_Guards() public onFork {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.NotPendleMarket.selector, USDG));
        controller.act(address(pendle), abi.encode(uint8(0), USDG, USDG, uint256(1e6), uint256(1)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.BadToken.selector, NVDA));
        controller.act(address(pendle), abi.encode(uint8(0), M_USDG, NVDA, uint256(1e6), uint256(1)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.NotHeld.selector, M_USDG));
        controller.act(address(pendle), abi.encode(uint8(1), M_USDG, USDG, uint256(1e6), uint256(1)));
        vm.expectRevert();
        pendle.execute(abi.encode(uint8(0), M_USDG, USDG, uint256(1e6), uint256(1)));
        vm.expectRevert();
        pendle.unwind(1e18);
        vm.expectRevert();
        pendle.split(1e18, address(this));
        string memory d = pendle.describe();
        assertGt(bytes(d).length, 1000);
        vm.parseJson(d); // valid JSON for agents
    }
}
