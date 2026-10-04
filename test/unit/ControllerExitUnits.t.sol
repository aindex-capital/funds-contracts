// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {FundController} from "../../src/core/FundController.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";

/// @notice The controller's exit units: a leaver's slice of an adapter set aside (`reserveFor`), paid out
///         (`splitUnitsFor`) or handed back (`releaseUnits`); the book stops counting it at once, and nothing but a split
///         may change that adapter meanwhile.
contract ControllerExitUnitsTest is TellerBase {
    MockBook internal bk;

    function setUp() public {
        _setUpTeller();
        bk = _book(0);
        bk.seed(address(tokA), 10e18); // $1,000 next to the 1,000 USDG stake
    }

    function _reserve(uint256 f) internal returns (uint256 units) {
        vm.prank(address(tel));
        units = controller.reserveFor(address(bk), f);
    }

    function test_OnlyTheTeller() public {
        vm.expectRevert(FundController.NotTeller.selector);
        controller.reserveFor(address(bk), 0.1e18);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.splitUnitsFor(address(bk), 1, alice);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.releaseUnits(address(bk), 1);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.collectFor(address(bk));
    }

    function test_ReserveScalesTheBookAtOnce() public {
        assertEq(_nav(0), 2000e18);
        (uint256 fund, uint256 total) = controller.unitsOf(address(bk));
        assertEq(fund, total, "wholly the Fund's");
        assertEq(controller.pendingExits(), 0);
        uint256 units = _reserve(0.25e18);
        assertEq(units, 0.25e18);
        (fund, total) = controller.unitsOf(address(bk));
        assertEq(total, 1e18);
        assertEq(fund, 0.75e18);
        assertEq(controller.pendingExits(), 1);
        assertEq(_nav(0), 1750e18, "the slice is no longer counted");
        // A second slice is a fraction of what is still the Fund's.
        uint256 u2 = _reserve(0.5e18);
        assertEq(u2, 0.375e18);
        assertEq(controller.pendingExits(), 1, "one adapter");
        assertEq(_nav(0), 1375e18);
    }

    function test_SplitPaysTheSliceAndClears() public {
        uint256 units = _reserve(0.25e18);
        vm.prank(address(tel));
        (, uint256 f) = controller.splitUnitsFor(address(bk), units, alice);
        assertEq(f, 0.25e18);
        assertEq(tokA.balanceOf(alice), 2.5e18);
        (uint256 fund, uint256 total) = controller.unitsOf(address(bk));
        assertEq(fund, total);
        assertEq(controller.pendingExits(), 0);
        assertEq(_nav(0), 1750e18);
    }

    function test_SplitInAnyOrderKeepsEveryonesPart() public {
        uint256 u1 = _reserve(0.2e18); // 0.2 of the adapter
        uint256 u2 = _reserve(0.5e18); // 0.4 of the adapter
        vm.prank(address(tel));
        controller.splitUnitsFor(address(bk), u2, bob);
        assertApproxEqAbs(tokA.balanceOf(bob), 4e18, 2);
        assertEq(controller.pendingExits(), 1);
        vm.prank(address(tel));
        controller.splitUnitsFor(address(bk), u1, alice);
        assertApproxEqAbs(tokA.balanceOf(alice), 2e18, 2);
        assertApproxEqAbs(bk.amt(address(tokA)), 4e18, 2, "the Fund keeps 0.4");
        assertEq(controller.pendingExits(), 0);
    }

    function test_ReleaseGivesTheSliceBackToTheFund() public {
        uint256 units = _reserve(0.25e18);
        vm.prank(address(tel));
        controller.releaseUnits(address(bk), units);
        assertEq(controller.pendingExits(), 0);
        assertEq(_nav(0), 2000e18);
    }

    function test_BadUnitsRefused() public {
        uint256 units = _reserve(0.25e18);
        vm.startPrank(address(tel));
        vm.expectRevert(FundController.BadFraction.selector);
        controller.splitUnitsFor(address(bk), 0, alice);
        vm.expectRevert(FundController.BadFraction.selector);
        controller.splitUnitsFor(address(bk), units + 1, alice);
        vm.expectRevert(FundController.BadFraction.selector);
        controller.releaseUnits(address(bk), units + 1);
        vm.expectRevert(FundController.BadFraction.selector);
        controller.reserveFor(address(bk), 0);
        vm.expectRevert(FundController.BadFraction.selector);
        controller.reserveFor(address(bk), 1e18 + 1);
        vm.expectRevert(FundController.UnknownAdapter.selector);
        controller.reserveFor(address(0xBEEF), 0.1e18);
        vm.stopPrank();
    }

    function test_TinySliceSetsNothingAside() public {
        assertEq(_reserve(1), 1, "a raw unit of a 1e18 total");
        vm.prank(address(tel));
        controller.releaseUnits(address(bk), 1);
        // Below one unit of the Fund's part: nothing.
        uint256 u = _reserve(0.5e18);
        vm.prank(address(tel));
        assertEq(controller.reserveFor(address(bk), 1), 0);
        vm.prank(address(tel));
        controller.releaseUnits(address(bk), u);
    }

    function test_NothingButASplitWhileASliceWaits() public {
        uint256 units = _reserve(0.25e18);
        bytes memory pending = abi.encodeWithSelector(FundController.ExitPending.selector, address(bk));
        vm.prank(manager);
        vm.expectRevert(pending);
        controller.act(address(bk), "");
        vm.prank(manager);
        vm.expectRevert(pending);
        controller.unwindAdapter(address(bk), 0.5e18);
        vm.prank(owner);
        vm.expectRevert(pending);
        controller.unwindAdapter(address(bk), 0.5e18);
        vm.prank(address(tel));
        vm.expectRevert(pending);
        controller.unwindFor(address(bk), 1e18);
        vm.prank(address(tel));
        vm.expectRevert(pending);
        controller.pocketFor(address(bk), address(tokA), address(pockets), 1);
        vm.prank(owner);
        controller.disableAdapter(address(bk));
        vm.prank(owner);
        vm.expectRevert(pending);
        controller.removeAdapter(address(bk));
        // Paid out, the adapter is free again.
        vm.prank(address(tel));
        controller.splitUnitsFor(address(bk), units, alice);
        vm.prank(owner);
        controller.unwindAdapter(address(bk), 1e18);
    }

    function test_OtherAdaptersStayFree() public {
        MockBook other = _book(0);
        other.seed(address(tokA), 1e18);
        _reserve(0.25e18);
        vm.prank(manager);
        controller.act(address(other), "");
    }

    function test_DebtScaledUpAssetsDown() public {
        bk.borrow(address(usdg), 300e6); // vault gets 300 USDG, adapter owes 300
        assertEq(_nav(0), 2000e18);
        _reserve(uint256(1e18) / 3);
        // Fund's part: 2/3 of $1,000 assets and of $300 debt, debt rounded up.
        uint256 nav = _nav(0);
        assertLe(nav, 1300e18 + 666.666666666666667e18 - 200e18);
        assertApproxEqAbs(nav, 1300e18 + 666.666666666666667e18 - 200e18, 1e13);
    }

    function test_CollectForCollectsFeesOnly() public {
        bk.addFees(address(tokA), 1e18);
        uint256 before = tokA.balanceOf(address(vault));
        vm.prank(address(tel));
        controller.collectFor(address(bk));
        assertEq(tokA.balanceOf(address(vault)), before + 1e18);
        assertEq(bk.amt(address(tokA)), 10e18, "positions untouched");
        vm.prank(owner);
        controller.disableAdapter(address(bk));
        vm.prank(address(tel));
        vm.expectRevert(FundController.UnknownAdapter.selector);
        controller.collectFor(address(bk));
    }

    function test_DisabledAdapterStillSplits() public {
        uint256 units = _reserve(0.5e18);
        vm.prank(owner);
        controller.disableAdapter(address(bk));
        vm.prank(address(tel));
        controller.splitUnitsFor(address(bk), units, alice);
        assertEq(tokA.balanceOf(alice), 5e18);
    }
}

/// @notice A slice of an exit in parts that is given back (`releaseInKind`) returns to the Fund with its escrow: the
///         escrow repays the slice's share of the adapter's debt, so a leaver cannot leave an underwater adapter's
///         debt to the holders (found by the teller invariant, 2026-10-02).
contract TellerExitReleaseTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function test_ReleaseLeavesTheEscrowWithTheFund() public {
        MockBook bk = _book(0);
        bk.seed(address(tokA), 1e18); // $100 of A
        bk.borrow(address(usdg), 300e6); // $300 owed: the adapter is $200 underwater
        uint256 shares = _join(alice, 1000e6);
        usdg.mint(alice, 1000e6);
        vm.prank(alice);
        usdg.approve(address(tel), type(uint256).max);
        vm.prank(alice);
        uint256 id = tel.startInKind(address(vault), shares, alice, new address[](0));
        uint256 ps = _navPerShare();
        uint256 aliceUsdg = usdg.balanceOf(alice);
        uint256 vaultUsdg = usdg.balanceOf(address(vault));
        assertGt(tel.owed(address(usdg)), 0, "escrow held for the slice's debt");
        vm.prank(alice);
        tel.releaseInKind(id, address(bk));
        assertEq(usdg.balanceOf(alice), aliceUsdg, "the leaver gets nothing back");
        assertGt(usdg.balanceOf(address(vault)), vaultUsdg, "the escrow went into the vault");
        assertGe(_navPerShare(), ps, "the holders take back the slice and its debt, paid");
        assertEq(controller.pendingExits(), 0);
    }
}
