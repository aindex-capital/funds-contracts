// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FundTestBase} from "../../utils/FundTestBase.sol";
import {AdapterSuite} from "../AdapterSuite.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "./MockMorpho.sol";
import {MorphoBlueAdapter} from "../../../src/adapters/lending/MorphoBlueAdapter.sol";
import {MorphoMarketRegistry} from "../../../src/adapters/lending/MorphoMarketRegistry.sol";
import {IAdapter, Amount} from "../../../src/interfaces/IAdapter.sol";
import {IMorpho, MarketParams} from "../../../src/interfaces/external/morpho/IMorpho.sol";
import {PriceClass, Side} from "../../../src/interfaces/IPriceRouter.sol";
import {Dial} from "../../../src/interfaces/IFundController.sol";
import {FundController} from "../../../src/core/FundController.sol";
import {BaseAdapter as BaseAdapterErrors} from "../../../src/adapters/BaseAdapter.sol";

/// @dev The shared world: a Fund with USDG and NVDA, a mock Morpho with one USDG market against NVDA at
///      62.5% LLTV, and an outside lender so the Fund can borrow.
abstract contract MorphoWorld is FundTestBase {
    uint8 constant SUPPLY = 0;
    uint8 constant WITHDRAW = 1;
    uint8 constant SUPPLY_COLLATERAL = 2;
    uint8 constant WITHDRAW_COLLATERAL = 3;
    uint8 constant BORROW = 4;
    uint8 constant REPAY = 5;
    uint8 constant REPAY_SHARES = 6;
    uint256 constant ALL = type(uint256).max;

    MockERC20 nvda;
    MockMorpho morpho;
    MockIrm irm;
    MockMorphoOracle oracle;
    MarketParams mkt;
    MorphoBlueAdapter impl;
    MorphoBlueAdapter mb;
    MorphoMarketRegistry markets;
    address aindex = makeAddr("aindex");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    function _cfg(bytes32[] memory ids) internal view returns (bytes memory) {
        return abi.encode(address(markets), ids);
    }

    function _any() internal view returns (bytes memory) {
        return _cfg(new bytes32[](0));
    }

    function _world(Dial memory dial, bytes32[] memory ids) internal {
        _setUpCore();
        nvda = new MockERC20("NVIDIA", "NVDA", 18);
        _price(address(nvda), 200e18, PriceClass.Feed, 0);
        morpho = new MockMorpho();
        irm = new MockIrm();
        irm.set(uint256(0.1e18) / 365 days); // about 10% a year
        oracle = new MockMorphoOracle();
        oracle.set(200e24); // $200: 200e6 raw USDG per 1e18 raw NVDA, times 1e36
        mkt = MarketParams(address(usdg), address(nvda), address(oracle), address(irm), 0.625e18);
        morpho.createMarket(mkt);
        bytes32[] memory seed = new bytes32[](1);
        seed[0] = morpho.id(mkt);
        markets = new MorphoMarketRegistry(aindex, IMorpho(address(morpho)), seed);

        _createFund(dial, 100_000e6);
        nvda.mint(address(vault), 100e18); // $20k of NVDA
        vm.prank(address(controller));
        vault.track(address(nvda));

        impl = new MorphoBlueAdapter(IMorpho(address(morpho)));
        registry.register(address(impl), "");
        vm.prank(guardian); // the registry's reviewer in these tests: AINDEX's own adapter is verified
        registry.setVerified(address(impl), true);
        mb = MorphoBlueAdapter(_enable(address(impl), _cfg(ids)));

        // An outside lender, so borrowing has liquidity beyond the Fund's own supply.
        usdg.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.supply(mkt, 1_000_000e6, 0, lender, "");
        vm.stopPrank();
    }

    function _a(uint8 id, uint256 amount) internal view returns (bytes memory) {
        return abi.encode(id, mkt, amount);
    }

    function _do(uint8 id, uint256 amount) internal {
        vm.prank(manager);
        controller.act(address(mb), _a(id, amount));
    }

    /// @dev Someone else borrows most of the market's free liquidity.
    function _drain(uint256 leaveFree) internal {
        nvda.mint(borrower, 1_000_000e18);
        (uint128 ts,, uint128 tb,,,) = morpho.market(morpho.id(mkt));
        vm.startPrank(borrower);
        nvda.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(mkt, 1_000_000e18, borrower, "");
        morpho.borrow(mkt, uint256(ts) - tb - leaveFree, 0, borrower, borrower);
        vm.stopPrank();
    }

    /// @dev Keep this Fund to what AINDEX reviewed. Lowers risk, so it applies at once.
    function _reviewedOnly() internal {
        Dial memory d = controller.dial();
        d.allowUnreviewed = false;
        vm.prank(owner);
        controller.setDial(d);
        assertFalse(controller.dial().allowUnreviewed);
    }

    function _approveExit(uint256 f) internal {
        Amount[] memory needs = mb.unwindInputs(f);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) vault.approveFor(needs[i].token, address(mb), needs[i].amount);
        vm.stopPrank();
    }
}

contract MorphoBlueAdapterTest is MorphoWorld {
    function setUp() public {
        _world(_openDial(), new bytes32[](0));
    }

    function test_SupplyAndWithdrawAll() public {
        _do(SUPPLY, 10_000e6);
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertEq(a.length, 1);
        assertEq(a[0].token, address(usdg));
        assertApproxEqAbs(a[0].amount, 10_000e6, 1);
        assertEq(d.length, 0);
        assertEq(mb.markets().length, 1);

        _do(WITHDRAW, ALL);
        (a,) = mb.positions(router);
        assertEq(a.length, 0);
        assertEq(mb.markets().length, 0, "empty market not forgotten");
        assertApproxEqAbs(usdg.balanceOf(address(vault)), 100_000e6, 1);
        assertEq(usdg.balanceOf(address(mb)), 0);
    }

    function test_SupplyEarnsInterestInView() public {
        _do(SUPPLY, 10_000e6);
        _drain(100_000e6); // the market is now mostly borrowed, so suppliers earn
        vm.warp(block.timestamp + 365 days);
        (Amount[] memory a,) = mb.positions(router);
        uint256 viewed = a[0].amount;
        assertGt(viewed, 10_500e6, "no interest in view");
        // After a real accrual the stored balance equals what the view said.
        morpho.accrueInterest(mkt);
        (a,) = mb.positions(router);
        assertEq(a[0].amount, viewed, "view differs from accrual");
    }

    function test_InterestViewMatchesAccrualWithFee() public {
        morpho.setFee(mkt, 0.1e18);
        _do(SUPPLY, 10_000e6);
        _do(SUPPLY_COLLATERAL, 50e18);
        _do(BORROW, 3_000e6);
        _drain(50_000e6);
        vm.warp(block.timestamp + 200 days);
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        morpho.accrueInterest(mkt);
        (Amount[] memory a2, Amount[] memory d2) = mb.positions(router);
        assertEq(a[0].amount, a2[0].amount);
        assertEq(d[0].amount, d2[0].amount);
        assertGt(d[0].amount, 3_000e6);
    }

    function test_CollateralBorrowRepayAll() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6); // LTV 50% of $20k, LLTV 62.5%
        assertEq(usdg.balanceOf(address(vault)), 110_000e6);
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertEq(a[0].token, address(nvda));
        assertEq(a[0].amount, 100e18);
        assertEq(d[0].token, address(usdg));
        assertGe(d[0].amount, 10_000e6);
        (uint256 nav,) = controller.nav(uint8(Side.Fair));
        assertApproxEqAbs(nav, 120_000e18, 1e12);

        vm.warp(block.timestamp + 30 days);
        (, d) = mb.positions(router);
        uint256 owed = d[0].amount;
        _do(REPAY_SHARES, ALL);
        (, d) = mb.positions(router);
        assertEq(d.length, 0, "debt left after repay all");
        assertEq(usdg.balanceOf(address(vault)), 110_000e6 - owed, "repay cost differs from reported debt");

        _do(WITHDRAW_COLLATERAL, ALL);
        assertEq(nvda.balanceOf(address(vault)), 100e18);
        assertEq(mb.markets().length, 0);
    }

    function test_RepayByAssetsPartial() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        _do(REPAY, 4_000e6);
        (, Amount[] memory d) = mb.positions(router);
        assertApproxEqAbs(d[0].amount, 6_000e6, 1);
    }

    function test_BorrowOverLltvReverts() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        vm.prank(manager);
        vm.expectRevert(bytes("insufficient collateral"));
        controller.act(address(mb), _a(BORROW, 12_600e6)); // 63% of $20k
    }

    function test_BorrowInsideLltvButPastBufferReverts() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        vm.prank(manager);
        // 60% LTV: Morpho would allow it (62.5% LLTV) but the adapter keeps 90% of LLTV, 56.25%.
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.TooCloseToLiquidation.selector, 0.6e18, 0.5625e18));
        controller.act(address(mb), _a(BORROW, 12_000e6));
        _do(BORROW, 11_250e6); // exactly at the buffer
    }

    function test_WithdrawCollateralPastBufferReverts() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        vm.prank(manager);
        vm.expectRevert(); // 90 NVDA left: LTV 55.6% is fine; 85 left: 58.8% is not
        controller.act(address(mb), _a(WITHDRAW_COLLATERAL, 15e18));
        _do(WITHDRAW_COLLATERAL, 10e18);
    }

    function test_MarketHealth() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        MorphoBlueAdapter.MarketHealth memory h = mb.marketHealth(mkt);
        assertEq(h.collateral, 100e18);
        assertEq(h.oraclePrice, 200e24);
        assertApproxEqAbs(h.ltv, 0.5e18, 1e9);
        assertEq(h.maxBorrow, 12_500e6);
        // Liquidation when NVDA falls to $160: 10k / (100 x 0.625).
        assertApproxEqRel(h.liquidationPrice, 160e24, 1e9);
        assertEq(h.liquidity, 1_000_000e6 - 10_000e6);
    }

    function test_UnwindAllWithDebt() public {
        _do(SUPPLY, 5_000e6);
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        vm.warp(block.timestamp + 10 days);
        (uint256 navBefore,) = controller.nav(uint8(Side.Fair));
        _approveExit(1e18);
        vm.prank(address(controller));
        Amount[] memory got = mb.unwind(1e18);
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertEq(a.length + d.length, 0, "positions left");
        assertEq(mb.markets().length, 0);
        assertEq(got.length, 2);
        assertEq(nvda.balanceOf(address(vault)), 100e18);
        (uint256 navAfter,) = controller.nav(uint8(Side.Fair));
        assertApproxEqAbs(navAfter, navBefore, 1e13);
        assertEq(usdg.balanceOf(address(mb)), 0);
        assertEq(nvda.balanceOf(address(mb)), 0);
    }

    /// The utilisation caveat: supply in a fully borrowed market comes back only as far as liquidity allows.
    function test_UnwindPartialWhenMarketIsFullyBorrowed() public {
        _do(SUPPLY, 10_000e6);
        _drain(2_000e6); // only 2k USDG free in the whole market
        _approveExit(1e18);
        vm.prank(address(controller));
        Amount[] memory got = mb.unwind(1e18); // must not revert
        assertEq(got.length, 1);
        assertEq(got[0].amount, 2_000e6);
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 1, "remaining supply must still be reported");
        assertApproxEqAbs(a[0].amount, 8_000e6, 2);
        assertEq(mb.markets().length, 1);
    }

    /// Through the controller: a partial unwind of an illiquid supply costs nothing against the loss
    /// budget, because what could not be withdrawn is still reported.
    function test_ControllerUnwindAdapterPartial() public {
        _do(SUPPLY, 10_000e6);
        _drain(2_000e6);
        vm.prank(manager);
        Amount[] memory got = controller.unwindAdapter(address(mb), 1e18);
        assertEq(got[0].amount, 2_000e6);
        (Amount[] memory a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 8_000e6, 2);
    }

    function test_UnwindNothingFreeDoesNotRevert() public {
        _do(SUPPLY, 10_000e6);
        _drain(0);
        _approveExit(1e18);
        vm.prank(address(controller));
        Amount[] memory got = mb.unwind(1e18);
        assertEq(got.length, 0);
        (Amount[] memory a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 10_000e6, 1);
    }

    function test_UnwindWithoutRepayMoneyKeepsCollateral() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 11_000e6);
        // No approval given: repay cannot be paid, so the collateral cannot leave either; no revert.
        vm.prank(address(controller));
        Amount[] memory got = mb.unwind(1e18);
        assertEq(got.length, 0);
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertEq(a[0].amount, 100e18);
        assertGe(d[0].amount, 11_000e6);
    }

    function test_SplitHalf() public {
        _do(SUPPLY, 10_000e6);
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        address leaver = makeAddr("leaver");
        Amount[] memory needs = mb.unwindInputs(0.5e18);
        assertEq(needs.length, 1);
        assertApproxEqAbs(needs[0].amount, 5_000e6, 1);
        uint256 vaultUsdg = usdg.balanceOf(address(vault));
        _approveExit(0.5e18);
        vm.prank(address(controller));
        Amount[] memory sent = mb.split(0.5e18, leaver);
        assertEq(sent.length, 2);
        assertEq(nvda.balanceOf(leaver), 50e18);
        assertApproxEqAbs(usdg.balanceOf(leaver), 5_000e6, 1);
        assertEq(usdg.balanceOf(address(vault)), vaultUsdg - needs[0].amount, "vault paid more than the debt slice");
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 5_000e6, 1);
        assertEq(a[1].amount, 50e18);
        assertApproxEqAbs(d[0].amount, 5_000e6, 1);
        // The remaining position's LTV did not get worse.
        assertLe(mb.marketHealth(mkt).ltv, 0.5e18 + 1e9);
    }

    function test_SplitWithDebtUnfundedReverts() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        Amount[] memory needs = mb.unwindInputs(0.5e18);
        vm.prank(address(controller));
        vm.expectRevert(
            abi.encodeWithSelector(MorphoBlueAdapter.SplitUnfunded.selector, address(usdg), needs[0].amount, 0)
        );
        mb.split(0.5e18, makeAddr("leaver"));
    }

    function test_SplitAllWithDebtLeavesNoCollateralBehindDebt() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 10_000e6);
        vm.warp(block.timestamp + 7 days);
        _approveExit(0.5e18);
        vm.prank(address(controller));
        mb.split(0.5e18, makeAddr("a"));
        _approveExit(1e18);
        vm.prank(address(controller));
        mb.split(1e18, makeAddr("b"));
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertEq(a.length + d.length, 0);
        assertEq(nvda.balanceOf(makeAddr("a")) + nvda.balanceOf(makeAddr("b")), 100e18);
    }

    function test_SplitFractionsSumToWhole() public {
        _do(SUPPLY, 9_999e6);
        _do(SUPPLY_COLLATERAL, 77e18);
        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");
        vm.startPrank(address(controller));
        mb.split(0.3e18, a1);
        mb.split(1e18, a2);
        vm.stopPrank();
        assertEq(nvda.balanceOf(a1) + nvda.balanceOf(a2), 77e18);
        assertApproxEqAbs(usdg.balanceOf(a1) + usdg.balanceOf(a2), 9_999e6, 2);
        assertEq(mb.markets().length, 0);
    }

    function test_BadFraction() public {
        vm.prank(address(controller));
        vm.expectRevert(MorphoBlueAdapter.BadFraction.selector);
        mb.unwind(1e18 + 1);
    }

    function test_UncreatedMarketReverts() public {
        MarketParams memory other = MarketParams(address(usdg), address(nvda), address(oracle), address(irm), 0.5e18);
        bytes32 otherId = mb.marketId(other);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.MarketNotCreated.selector, otherId));
        controller.act(address(mb), abi.encode(SUPPLY, other, uint256(1e6)));
    }

    function test_TooManyMarkets() public {
        uint256 max = mb.MAX_MARKETS();
        for (uint256 i; i <= max; ++i) {
            MarketParams memory p = MarketParams(address(usdg), address(nvda), address(oracle), address(irm), 0.5e18 + i);
            morpho.createMarket(p);
            vm.prank(manager);
            if (i == max) vm.expectRevert(MorphoBlueAdapter.TooManyMarkets.selector);
            controller.act(address(mb), abi.encode(SUPPLY, p, uint256(1e6)));
        }
        // With every slot full, valuing the clone stays far under the controller's positions gas cap.
        vm.warp(block.timestamp + 1 days);
        uint256 g = gasleft();
        mb.positions(router);
        g -= gasleft();
        emit log_named_uint("positions gas, 16 markets", g);
        assertLt(g, 1_000_000);
    }

    // ------------------------------------------------------------ market registry and pricing gate

    /// @dev A market the manager made itself, priced by an oracle it controls.
    function _evilMarket() internal returns (MarketParams memory evil, MockMorphoOracle evilOracle) {
        vm.startPrank(manager);
        evilOracle = new MockMorphoOracle();
        evilOracle.set(1e40);
        evil = MarketParams(address(usdg), address(nvda), address(evilOracle), address(irm), 0.625e18);
        morpho.createMarket(evil);
        vm.stopPrank();
    }

    function test_ManagerOwnedMarketRefused() public {
        _reviewedOnly();
        (MarketParams memory evil,) = _evilMarket();
        bytes32 eid = morpho.id(evil);
        uint8[3] memory ids = [SUPPLY, SUPPLY_COLLATERAL, BORROW];
        for (uint256 i; i < 3; ++i) {
            vm.prank(manager);
            vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.MarketNotApproved.selector, eid));
            controller.act(address(mb), abi.encode(ids[i], evil, uint256(1e6)));
        }
    }

    /// The badge model: with `allowUnreviewed` on, the manager may use a market AINDEX has not approved, and
    /// its supply counts as nothing, so the cost shows in NAV inside the action and a later theft changes nothing.
    function test_UnapprovedMarketAllowedByDialAndValuedAtZero() public {
        assertTrue(controller.dial().allowUnreviewed);
        (MarketParams memory evil, MockMorphoOracle evilOracle) = _evilMarket();
        assertFalse(markets.isApproved(morpho.id(evil)));
        (uint256 nav0,) = controller.nav(uint8(Side.Fair));

        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, evil, uint256(10_000e6)));
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 1);
        assertEq(a[0].amount, 0, "an unapproved market's supply counts as nothing");
        (uint256 nav1,) = controller.nav(uint8(Side.Fair));
        assertApproxEqAbs(nav0 - nav1, 10_000e18, 1e12, "the cost shows at once");

        address thief = makeAddr("thief");
        evilOracle.set(1e60);
        nvda.mint(thief, 1);
        vm.startPrank(thief);
        nvda.approve(address(morpho), 1);
        morpho.supplyCollateral(evil, 1, thief, "");
        morpho.borrow(evil, 10_000e6, 0, thief, thief);
        vm.stopPrank();
        (uint256 nav2,) = controller.nav(uint8(Side.Fair));
        assertApproxEqAbs(nav2, nav1, 1e12, "the theft was already counted");
    }

    /// The same drained claim in an approved market keeps its full value: Morpho owes it and the market is sound.
    function test_ApprovedMarketSupplyCountedInFull() public {
        _do(SUPPLY, 10_000e6);
        _drain(0);
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 1);
        assertApproxEqAbs(a[0].amount, 10_000e6, 1);
    }

    /// Turning unreviewed instruments on is a risk increase: it waits the notice once anyone else holds shares.
    function test_AllowUnreviewedWaitsNoticeOnceShared() public {
        _reviewedOnly();
        (MarketParams memory evil,) = _evilMarket();
        vm.prank(owner);
        vault.transfer(makeAddr("holder"), 1e18); // an outside holder
        Dial memory d = controller.dial();
        d.allowUnreviewed = true;
        vm.prank(owner);
        controller.setDial(d);
        assertFalse(controller.dial().allowUnreviewed, "applied before the notice");
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(mb), abi.encode(SUPPLY, evil, uint256(1e6)));
        vm.warp(block.timestamp + controller.RISK_NOTICE());
        controller.applyPendingDial();
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, evil, uint256(1e6)));
    }

    function test_MarketApprovedAfterDelayWorks() public {
        _reviewedOnly();
        (MarketParams memory evil,) = _evilMarket();
        bytes32 id = morpho.id(evil);
        vm.prank(aindex);
        markets.propose(id);
        vm.expectRevert(MorphoMarketRegistry.NotReady.selector);
        markets.applyPending(id);
        vm.warp(block.timestamp + 1 days);
        markets.applyPending(id); // anyone may apply
        assertTrue(markets.isApproved(id));
        assertTrue(markets.isApprovedMarket(evil));
        assertEq(markets.marketId(evil), id);
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, evil, uint256(1e6)));
    }

    function test_RegistryOnlyOwnerAndCancel() public {
        bytes32 id = morpho.id(mkt);
        vm.expectRevert(MorphoMarketRegistry.NotOwner.selector);
        markets.propose(id);
        vm.expectRevert(MorphoMarketRegistry.NotOwner.selector);
        markets.remove(id);
        bytes32 missing = keccak256("no such market");
        vm.expectRevert(abi.encodeWithSelector(MorphoMarketRegistry.NoMarket.selector, missing));
        vm.prank(aindex);
        markets.propose(missing);
        (MarketParams memory other,) = _evilMarket();
        bytes32 oid = morpho.id(other);
        vm.startPrank(aindex);
        markets.propose(oid);
        markets.cancel(oid);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(MorphoMarketRegistry.NotPending.selector);
        markets.applyPending(oid);
        assertFalse(markets.isApproved(oid));
    }

    function test_RegistrySeedMustExist() public {
        bytes32[] memory seed = new bytes32[](1);
        seed[0] = keccak256("no such market");
        vm.expectRevert(abi.encodeWithSelector(MorphoMarketRegistry.NoMarket.selector, seed[0]));
        new MorphoMarketRegistry(aindex, IMorpho(address(morpho)), seed);
    }

    /// Delisting is instant and blocks new exposure, but the Fund can always get out.
    function test_RemovedMarketBlocksEntryNotExit() public {
        _reviewedOnly();
        _do(SUPPLY, 10_000e6);
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 5_000e6);
        bytes32 mid = morpho.id(mkt);
        vm.prank(aindex);
        markets.remove(mid);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.MarketNotApproved.selector, mid));
        controller.act(address(mb), _a(SUPPLY, 1e6));
        _do(REPAY_SHARES, ALL);
        _do(WITHDRAW_COLLATERAL, ALL);
        _do(WITHDRAW, ALL);
        assertEq(mb.markets().length, 0);
    }

    /// A token with no market may be lent or posted (it is worth zero, a known value), but never borrowed:
    /// a debt nobody can price would leave the Fund's book incomplete.
    function test_UnpricedTokenOnlyRefusedForBorrow() public {
        MockERC20 junk = new MockERC20("Junk", "JNK", 18);
        junk.mint(address(vault), 1_000e18);
        vm.prank(address(controller));
        vault.track(address(junk));
        (uint256 nav0,) = controller.nav(uint8(Side.Fair));

        // Junk as collateral: allowed, still worth zero.
        MarketParams memory p = MarketParams(address(usdg), address(junk), address(oracle), address(irm), 0.625e18);
        morpho.createMarket(p);
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY_COLLATERAL, p, uint256(500e18)));
        // Junk lent: allowed, still worth zero.
        MarketParams memory q = MarketParams(address(junk), address(nvda), address(oracle), address(irm), 0.625e18);
        morpho.createMarket(q);
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, q, uint256(500e18)));
        (uint256 nav1, bool complete) = controller.nav(uint8(Side.Fair));
        assertTrue(complete);
        assertEq(nav1, nav0, "junk counted at zero wherever it sits");

        // Junk borrowed: refused.
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY_COLLATERAL, q, uint256(10e18)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.TokenNotPriced.selector, address(junk)));
        controller.act(address(mb), abi.encode(BORROW, q, uint256(1e18)));
    }

    function test_ConfigNeedsRegistry() public {
        vm.prank(owner);
        vm.expectRevert();
        controller.addAdapter(address(impl), abi.encode(address(0), new bytes32[](0)));
    }

    function test_UnknownAction() public {
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.UnknownAction.selector, uint8(7)));
        mb.inputs(abi.encode(uint8(7), mkt, uint256(1)));
    }

    function test_ImplementationLocked() public {
        vm.expectRevert();
        impl.initialize(address(1), address(2), "");
    }

    function test_DescribeAndName() public view {
        assertEq(mb.name(), "Morpho Blue v1");
        assertGt(bytes(mb.describe()).length, 500);
    }

    function test_IrmFailureDoesNotBreakValuation() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 1_000e6);
        vm.warp(block.timestamp + 1 days);
        vm.mockCallRevert(address(irm), abi.encodeWithSelector(MockIrm.borrowRateView.selector), "");
        (, Amount[] memory d) = mb.positions(router);
        assertApproxEqAbs(d[0].amount, 1_000e6, 1);
        (, bool complete) = controller.nav(uint8(Side.Fair));
        assertTrue(complete);
    }
}

/// The dial's borrowing rules, enforced by the controller from Fund-wide assets and debts.
contract MorphoBlueDialTest is MorphoWorld {
    function test_BorrowNotAllowedByDial() public {
        Dial memory d = _openDial();
        d.allowBorrow = false;
        _world(d, new bytes32[](0));
        _do(SUPPLY_COLLATERAL, 100e18);
        vm.prank(manager);
        vm.expectRevert(FundController.BorrowNotAllowed.selector);
        controller.act(address(mb), _a(BORROW, 1_000e6));
    }

    function test_MinHealthEnforced() public {
        Dial memory d = _openDial();
        d.minHealthBps = 140_000; // assets must be 14x debts
        _world(d, new bytes32[](0));
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 5_000e6); // assets 125k, debts 5k: health 25x
        vm.prank(manager);
        // Another 5k: assets 130k, debts 10k: health 13x, under 14x.
        vm.expectRevert(abi.encodeWithSelector(FundController.Unhealthy.selector, 130_000, 140_000));
        controller.act(address(mb), _a(BORROW, 5_000e6));
    }

    function test_RestrictedMarkets() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = keccak256("some other market");
        _world(_openDial(), ids);
        assertTrue(mb.restricted());
        bytes32 mid = mb.marketId(mkt);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.MarketNotAllowed.selector, mid));
        controller.act(address(mb), _a(SUPPLY, 1e6));
    }

    function test_RestrictedMarketAllowed() public {
        bytes32[] memory ids = new bytes32[](1);
        // Build the world first to learn the market id, then enable a second clone restricted to it.
        _world(_openDial(), new bytes32[](0));
        ids[0] = mb.marketId(mkt);
        vm.prank(owner);
        MorphoBlueAdapter r = MorphoBlueAdapter(controller.addAdapter(address(impl), _cfg(ids)));
        vm.prank(manager);
        controller.act(address(r), _a(SUPPLY, 1e6));
        assertEq(r.markets().length, 1);
    }

}

/// The shared adapter suite, run against the mock Morpho. The Fund starts with a borrow open, so every
/// action kind (including withdraw, repay and repay-all) is valid from the first call.
/// @notice `grow`: deposits buy the same fraction more of every market's supply, collateral and debt.
contract MorphoBlueGrowTest is MorphoWorld {
    function setUp() public {
        _world(_openDial(), new bytes32[](0));
    }

    // ---------------------------------------------------------------- grow (deposits into the existing mix)

    /// @dev What the teller does: give the vault what `growInputs` asks for, approve it, call `grow`.
    function _grow(uint256 f) internal returns (Amount[] memory used) {
        Amount[] memory needs = mb.growInputs(f);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            MockERC20(needs[i].token).mint(address(vault), needs[i].amount);
            vault.approveFor(needs[i].token, address(mb), needs[i].amount);
        }
        used = mb.grow(f);
        vm.stopPrank();
        for (uint256 i; i < needs.length; ++i) {
            assertEq(MockERC20(needs[i].token).allowance(address(vault), address(mb)), 0, "inputs not all pulled");
        }
    }

    function _leveraged() internal {
        _do(SUPPLY, 10_000e6);
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 5_000e6);
        vm.warp(block.timestamp + 7 days);
    }

    /// Supply, collateral and debt all grow by the fraction; the market's LTV stays put; the borrowed loan
    /// tokens land in the vault; `used` is exactly what was pulled.
    function test_GrowKeepsLtvAndSendsBorrowToVault() public {
        _leveraged();
        MorphoBlueAdapter.MarketHealth memory h0 = mb.marketHealth(mkt);
        Amount[] memory needs = mb.growInputs(0.5e18);
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        Amount[] memory used = _grow(0.5e18);
        MorphoBlueAdapter.MarketHealth memory h1 = mb.marketHealth(mkt);

        assertGe(h1.supplied * 2, h0.supplied * 3, "supply grew by less than half");
        assertGe(h1.collateral * 2, h0.collateral * 3, "collateral grew by less than half");
        assertGe(h1.borrowed * 2, h0.borrowed * 3, "debt grew by less than half");
        assertApproxEqAbs(h1.borrowed * 2, h0.borrowed * 3, 20, "debt grew by more than the fraction plus dust");
        assertApproxEqRel(h1.ltv, h0.ltv, 1e9, "LTV moved");
        // The supply money was minted to the vault and pulled, so the vault's USDG moved by the new debt only.
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - usdgBefore, h1.borrowed - h0.borrowed, 2, "borrow not sent to vault");
        assertEq(used.length, needs.length);
        for (uint256 i; i < used.length; ++i) assertEq(used[i].amount, needs[i].amount);
        assertEq(usdg.balanceOf(address(mb)), 0);
        assertEq(nvda.balanceOf(address(mb)), 0);
    }

    /// A batch may more than double a small Fund.
    function test_GrowByMoreThanDouble() public {
        _leveraged();
        MorphoBlueAdapter.MarketHealth memory h0 = mb.marketHealth(mkt);
        _grow(4e18);
        MorphoBlueAdapter.MarketHealth memory h1 = mb.marketHealth(mkt);
        assertGe(h1.supplied, h0.supplied * 5);
        assertGe(h1.collateral, h0.collateral * 5);
        assertGe(h1.borrowed, h0.borrowed * 5);
    }

    /// The teller measures a grown debt against what `positions` read before the batch: at least `(1 + f)` times
    /// it and at most two raw units more (TellerMath.TOLERANCE), for any fraction and any interest accrued, a
    /// batch many times a small Fund's size included. Found by the fork rehearsal: growing the borrow shares
    /// plus a fixed margin overshot the upper bound.
    function testFuzz_GrowDebtWithinTheTellersSlack(uint256 f, uint256 wait, uint256 borrowed) public {
        f = bound(f, 1e9, 20e18);
        _do(SUPPLY, 10_000e6);
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, bound(borrowed, 1, 5_000e6));
        vm.warp(block.timestamp + bound(wait, 0, 400 days));
        (, Amount[] memory d0) = mb.positions(router);
        _grow(f);
        (, Amount[] memory d1) = mb.positions(router);
        uint256 b = d0[0].amount;
        uint256 x = d1[0].amount;
        assertGe(x * 1e18, b * (1e18 + f), "debt grew by less than the fraction");
        assertLe(x * 1e18, b * (1e18 + f) + 2e18, "debt grew by more than the teller's slack");
    }

    /// Prices moved the market past the adapter's 90% buffer but not to the LLTV: growing proportionally adds
    /// no risk, so it still works (the buffer limits the manager's new risk only).
    function test_GrowAboveBufferStillWorks() public {
        _do(SUPPLY_COLLATERAL, 100e18); // $20k at the oracle
        _do(BORROW, 11_000e6); // 55% LTV, under the 56.25% buffer
        oracle.set(185e24); // NVDA falls: LTV about 59.5%, past the buffer, under 62.5%
        assertGt(mb.marketHealth(mkt).ltv, 0.5625e18);
        _grow(0.25e18);
        assertGe(mb.marketHealth(mkt).collateral, 125e18);
    }

    /// A market already past its LLTV refuses the borrow, so the whole grow (and the deposit batch) reverts:
    /// new money must not be added to a position that is being liquidated.
    function test_GrowPastLltvReverts() public {
        _do(SUPPLY_COLLATERAL, 100e18);
        _do(BORROW, 11_000e6);
        oracle.set(170e24); // LTV about 64.7%, past 62.5%
        Amount[] memory needs = mb.growInputs(0.1e18);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            MockERC20(needs[i].token).mint(address(vault), needs[i].amount);
            vault.approveFor(needs[i].token, address(mb), needs[i].amount);
        }
        vm.expectRevert();
        mb.grow(0.1e18);
        vm.stopPrank();
    }

    /// Growing is not new exposure: a market AINDEX has since delisted, in a Fund that only allows reviewed
    /// markets, still grows its collateral and debt in proportion; its supply now counts as nothing, so deposits
    /// stop buying more of it.
    function test_GrowIgnoresDelistedMarket() public {
        _reviewedOnly();
        _leveraged();
        bytes32 mid = morpho.id(mkt);
        vm.prank(aindex);
        markets.remove(mid);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.MarketNotApproved.selector, mid));
        controller.act(address(mb), _a(SUPPLY, 1e6));
        uint256 c0 = mb.marketHealth(mkt).collateral;
        _grow(0.2e18);
        assertGe(mb.marketHealth(mkt).collateral * 10, c0 * 12);
    }

    function test_GrowOnlyController() public {
        _leveraged();
        vm.expectRevert(BaseAdapterErrors.NotController.selector);
        mb.grow(0.1e18);
    }

    function test_GrowZeroAndNothingOpenAreNoOps() public {
        assertEq(mb.growInputs(1e18).length, 0);
        vm.prank(address(controller));
        assertEq(mb.grow(1e18).length, 0);
        _leveraged();
        assertEq(mb.growInputs(0).length, 0);
        MorphoBlueAdapter.MarketHealth memory h0 = mb.marketHealth(mkt);
        vm.prank(address(controller));
        mb.grow(0);
        assertEq(mb.marketHealth(mkt).collateral, h0.collateral);
    }
}

contract MorphoBlueAdapterSuite is AdapterSuite, MorphoWorld {
    function _setUpAdapter() internal override returns (IAdapter) {
        _world(_openDial(), new bytes32[](0));
        _do(SUPPLY, 20_000e6);
        _do(SUPPLY_COLLATERAL, 50e18);
        _do(BORROW, 2_000e6);
        vm.warp(block.timestamp + 3 days);
        return IAdapter(address(mb));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint8 kind = uint8(seed % 7);
        uint256 x = seed >> 8;
        if (kind == SUPPLY) return _a(SUPPLY, bound(x, 1, 50_000e6));
        if (kind == WITHDRAW) return _a(WITHDRAW, x % 5 == 0 ? ALL : bound(x, 1, 19_000e6));
        if (kind == SUPPLY_COLLATERAL) return _a(SUPPLY_COLLATERAL, bound(x, 1, 50e18));
        if (kind == WITHDRAW_COLLATERAL) return _a(WITHDRAW_COLLATERAL, bound(x, 1, 30e18));
        if (kind == BORROW) return _a(BORROW, bound(x, 1, 3_000e6));
        if (kind == REPAY) return _a(REPAY, bound(x, 1, 1_900e6));
        return _a(REPAY_SHARES, x % 2 == 0 ? ALL : bound(x, 1, 1e15));
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdg);
        t[1] = address(nvda);
    }

    /// `testSuite_SplitSumsToWhole` with the step a borrowing adapter needs: the caller approves
    /// `unwindInputs(f)` before each split, as the suite already does before `unwind`. Without it a split
    /// with debt reverts (SplitUnfunded) by design.
    function testMorphoSuite_SplitSumsToWholeFunded(uint256 seed) public {
        _act(_action(seed));
        uint256 reported = _reportedValue();
        address a = makeAddr("splitA");
        address b = makeAddr("splitB");
        _approveExit(0.5e18);
        vm.prank(address(controller));
        Amount[] memory sentA = adapter.split(0.5e18, a);
        _approveExit(1e18);
        vm.prank(address(controller));
        Amount[] memory sentB = adapter.split(1e18, b);
        uint256 got = _valueSent(sentA) + _valueSent(sentB);
        (Amount[] memory left, Amount[] memory owed) = adapter.positions(router);
        for (uint256 i; i < left.length; ++i) assertEq(left[i].amount, 0, "position left after full split");
        assertEq(owed.length, 0, "debt left after full split");
        assertApproxEqRel(got, reported, 0.01e18, "split slices do not sum to what positions reported");
        assertEq(usdg.balanceOf(address(adapter)), 0);
        assertEq(nvda.balanceOf(address(adapter)), 0);
    }
}
