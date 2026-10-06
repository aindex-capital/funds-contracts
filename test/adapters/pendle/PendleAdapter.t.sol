// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../../utils/FundTestBase.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {Amount} from "../../../src/interfaces/IAdapter.sol";
import {Side} from "../../../src/interfaces/IPriceRouter.sol";
import {PendleAdapter} from "../../../src/adapters/pendle/PendleAdapter.sol";
import {
    IPendleMarketFactory,
    IPendlePYLpOracle,
    IPendleRouter
} from "../../../src/interfaces/external/pendle/IPendle.sol";
import {MockMarket, MockPendleFactory, MockPendleOracle, MockPendleRouter, MockSY, MockYT} from "./PendleMocks.sol";

/**
 * @notice The Pendle adapter against mocks. The shared `AdapterSuite` needs `grow` above zero, which this adapter refuses
 *         (deposits enter Funds as cash), so the suite's rules 1 to 5 are checked here directly: controller only, no loose
 *         tokens, value stays in the Fund, a full unwind returns what `positions` reported, and split slices sum to the
 *         whole. The fork test (test/fork/adapters/pendle) runs the same flows on Pendle itself.
 */
contract PendleAdapterTest is FundTestBase {
    MockPendleOracle internal oracle;
    MockPendleRouter internal pr;
    MockPendleFactory internal pf;
    MockERC20 internal reward;
    PendleAdapter internal impl;
    PendleAdapter internal p;
    MockMarket[5] internal mk;

    function setUp() public {
        _setUpCore();
        _createFund(_openDial(), 10_000e6);
        oracle = new MockPendleOracle();
        pr = new MockPendleRouter(oracle);
        pf = new MockPendleFactory();
        reward = new MockERC20("Pendle", "PENDLE", 6);
        for (uint256 i; i < 5; ++i) mk[i] = _market();
        impl = new PendleAdapter(IPendleRouter(address(pr)), IPendlePYLpOracle(address(oracle)), IPendleMarketFactory(address(pf)), IPendleMarketFactory(address(0)));
        registry.register(address(impl), "");
        p = PendleAdapter(_enable(address(impl), ""));
    }

    function _market() internal returns (MockMarket m) {
        MockSY sy = new MockSY(address(usdg));
        MockERC20 pt = new MockERC20("PT", "PT", 6);
        MockYT yt = new MockYT(sy, reward);
        m = new MockMarket(sy, pt, yt, reward);
        pf.add(address(m));
        oracle.set(address(m), 0.97e18, 0.03e18, 2e18);
        pr.link(address(yt), address(m));
    }

    function _act(uint8 id, MockMarket m, uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.prank(manager);
        return abi.decode(controller.act(address(p), abi.encode(id, address(m), address(usdg), amount, minOut)), (uint256));
    }

    function _held() internal view returns (uint256 usd) {
        (Amount[] memory a,) = p.positions(router);
        for (uint256 i; i < a.length; ++i) {
            (uint256 v,,) = router.value(a[i].token, a[i].amount, Side.Fair);
            usd += v;
        }
    }

    function _nav() internal view returns (uint256 n) {
        (n,) = controller.nav(uint8(Side.Fair));
    }

    function _noLoose() internal view {
        assertEq(usdg.balanceOf(address(p)), 0, "loose USDG");
        assertEq(reward.balanceOf(address(p)), 0, "loose reward");
        for (uint256 i; i < 5; ++i) assertEq(mk[i].sy().balanceOf(address(p)), 0, "loose SY");
    }

    function _enterAll() internal {
        _act(0, mk[0], 970e6, 1); // about 1000 PT
        _act(2, mk[0], 30e6, 1); // about 1000 YT
        _act(4, mk[1], 2000e6, 1); // about 1000 LP
    }

    // ---------------------------------------------------------------- the suite's rules

    function test_EachActionLeavesNothingLooseAndKeepsValue() public {
        uint256 before = _nav();
        _enterAll();
        _noLoose();
        assertApproxEqRel(_held(), 3000e18, 0.002e18, "held at the oracle rate, less the fee");
        assertGe(_nav() + before / 100, before, "an action lost more than 1% of NAV");
        assertEq(p.markets().length, 2);
        (Amount[] memory a,) = p.positions(router);
        assertEq(a.length, 6, "three rows per market");
    }

    function test_OnlyTheController() public {
        bytes memory a = abi.encode(uint8(0), address(mk[0]), address(usdg), uint256(1e6), uint256(1));
        vm.expectRevert();
        p.execute(a);
        vm.expectRevert();
        p.unwind(1e18);
        vm.expectRevert();
        p.split(1e18, address(this));
        vm.expectRevert();
        p.grow(0);
    }

    function test_FullUnwindReturnsWhatPositionsReported() public {
        _enterAll();
        uint256 reported = _held();
        uint256 navBefore = _nav();
        vm.prank(address(controller));
        Amount[] memory got = p.unwind(1e18);
        assertEq(got.length, 2);
        assertEq(p.markets().length, 0, "every market empties and is dropped");
        assertApproxEqRel(_nav(), navBefore, 0.002e18, "unwind returned what positions reported");
        assertApproxEqRel(got[0].amount + got[1].amount, reported / 1e12, 0.002e18);
        _noLoose();
    }

    function test_SplitSlicesSumToTheWhole() public {
        _enterAll();
        uint256 reported = _held();
        address a = makeAddr("a");
        address b = makeAddr("b");
        vm.startPrank(address(controller));
        Amount[] memory sa = p.split(0.5e18, a);
        p.split(1e18, b);
        vm.stopPrank();
        assertEq(sa.length, 6, "PT, YT and LP of each market");
        assertEq(p.markets().length, 0);
        uint256 got;
        for (uint256 i; i < 2; ++i) {
            MockMarket m = mk[i];
            (uint256 rPt, uint256 rYt, uint256 rLp) = (oracle.rates(address(m), 0), oracle.rates(address(m), 1), oracle.rates(address(m), 2));
            for (uint256 k; k < 2; ++k) {
                address who = k == 0 ? a : b;
                got += m.pt().balanceOf(who) * rPt / 1e18 + m.yt().balanceOf(who) * rYt / 1e18 + m.balanceOf(who) * rLp / 1e18;
            }
        }
        assertApproxEqRel(got * 1e12, reported, 0.0001e18, "the slices sum to what positions reported");
        _noLoose();
    }

    // ---------------------------------------------------------------- the oracle gate

    function test_RefusesToBuyWhereTheOracleIsNotReady() public {
        oracle.setReady(address(mk[0]), false);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.OracleNotReady.selector, address(mk[0])));
        controller.act(address(p), abi.encode(uint8(0), address(mk[0]), address(usdg), uint256(100e6), uint256(1)));
    }

    function test_HoldingsInAMarketWhoseOracleStopsAreUnvalued() public {
        _act(0, mk[0], 970e6, 1);
        oracle.setReady(address(mk[0]), false);
        assertEq(_held(), 0, "counted as zero, never at a number one trade can move");
        Amount[] memory u = p.unvalued();
        assertEq(u.length, 1);
        assertEq(u[0].token, address(mk[0].pt()));
        // An unwind skips it instead of selling blind; a split still hands it over.
        vm.prank(address(controller));
        p.unwind(1e18);
        assertGt(mk[0].pt().balanceOf(address(p)), 0);
        vm.prank(address(controller));
        p.split(1e18, makeAddr("leaver"));
        assertEq(mk[0].pt().balanceOf(address(p)), 0);
    }

    // ---------------------------------------------------------------- maturity, claims, limits

    function test_AfterMaturityPtIsRedeemedNotSold() public {
        _act(0, mk[0], 970e6, 1);
        mk[0].setExpiry(block.timestamp);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.Expired.selector, address(mk[0])));
        controller.act(address(p), abi.encode(uint8(1), address(mk[0]), address(usdg), type(uint256).max, uint256(1)));
        uint256 pt = mk[0].pt().balanceOf(address(p));
        uint256 out = _act(6, mk[0], type(uint256).max, pt);
        assertEq(out, pt, "one for one in the asset at maturity");
        assertEq(p.markets().length, 0);
    }

    function test_UnwindRedeemsAtMaturity() public {
        _act(0, mk[0], 970e6, 1);
        mk[0].setExpiry(block.timestamp);
        oracle.set(address(mk[0]), 1e18, 0, 2e18);
        vm.prank(address(controller));
        p.unwind(1e18);
        assertEq(mk[0].pt().balanceOf(address(p)), 0);
    }

    function test_ClaimAndGrowZeroPayInterestAndRewardsToTheVault() public {
        _act(2, mk[0], 30e6, 1);
        mk[0].yt().setInterest(5e6);
        uint256 v0 = usdg.balanceOf(address(vault));
        uint256 got = _act(7, mk[0], 0, 0);
        assertEq(got, 5e6, "YT interest, redeemed from SY to USDG");
        assertEq(usdg.balanceOf(address(vault)), v0 + 5e6);
        assertEq(reward.balanceOf(address(vault)), 1e6, "the YT's reward");
        mk[0].yt().setInterest(2e6);
        vm.prank(address(controller));
        p.grow(0);
        assertEq(usdg.balanceOf(address(vault)), v0 + 7e6);
        _noLoose();
        vm.prank(address(controller));
        vm.expectRevert(PendleAdapter.NoGrow.selector);
        p.grow(1);
        vm.expectRevert(PendleAdapter.NoGrow.selector);
        p.growInputs(1);
    }

    function test_AtMostFourMarketsAndEmptyOnesFreeTheirSlot() public {
        for (uint256 i; i < 4; ++i) _act(0, mk[i], 10e6, 1);
        vm.prank(manager);
        vm.expectRevert(PendleAdapter.TooManyMarkets.selector);
        controller.act(address(p), abi.encode(uint8(0), address(mk[4]), address(usdg), uint256(10e6), uint256(1)));
        _act(1, mk[0], type(uint256).max, 1);
        assertEq(p.markets().length, 3);
        _act(0, mk[4], 10e6, 1);
        assertEq(p.markets().length, 4);
    }

    function test_Guards() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.NotPendleMarket.selector, address(usdg)));
        controller.act(address(p), abi.encode(uint8(0), address(usdg), address(usdg), uint256(1e6), uint256(1)));
        MockERC20 other = new MockERC20("X", "X", 6);
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.BadToken.selector, address(other)));
        controller.act(address(p), abi.encode(uint8(0), address(mk[0]), address(other), uint256(1e6), uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.NotHeld.selector, address(mk[0])));
        controller.act(address(p), abi.encode(uint8(1), address(mk[0]), address(usdg), uint256(1e6), uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(PendleAdapter.UnknownAction.selector, uint8(9)));
        controller.act(address(p), abi.encode(uint8(9), address(mk[0]), address(usdg), uint256(1e6), uint256(1)));
        vm.stopPrank();
        // Settings are not taken: every Pendle market is allowed and the dial decides how much.
        PendleAdapter fresh = new PendleAdapter(IPendleRouter(address(pr)), IPendlePYLpOracle(address(oracle)), IPendleMarketFactory(address(pf)), IPendleMarketFactory(address(0)));
        registry.register(address(fresh), "");
        vm.prank(owner);
        vm.expectRevert();
        controller.addAdapter(address(fresh), abi.encode(uint256(1)));
    }

    function test_DescribeIsJsonAgentsCanRead() public {
        _act(0, mk[0], 100e6, 1);
        string memory d = p.describe();
        vm.parseJson(d);
        assertEq(vm.parseJsonUint(d, ".actions[7].id"), 7);
        assertEq(vm.parseJsonAddress(d, ".held[0]"), address(mk[0]));
    }
}
