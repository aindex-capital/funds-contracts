// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TellerBase} from "./TellerBase.t.sol";
import {TellerFundedBase} from "./TellerExits.t.sol";
import {Teller} from "../../src/core/Teller.sol";

/// @notice The owner's opening deposit is ordinary shares in its wallet (owner decision 2026-10-04): it may sell
///         part or all of them at any time, in cash or in kind, outside holders or not, and top up later, and its
///         own shares never set the outside-holder latch.
contract TellerOwnerSharesTest is TellerFundedBase {
    function setUp() public {
        _setUpFunded();
    }

    function test_OwnerSellsPartInKindWhileOthersHold() public {
        assertTrue(vault.hadOutsideHolder(), "alice holds");
        uint256[5] memory before = _perShare();
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(owner);
        tel.redeemInKind(address(vault), 400e18, owner);
        assertEq(vault.balanceOf(owner), 600e18);
        assertGt(usdg.balanceOf(owner), 0);
        assertGt(tokA.balanceOf(owner), 0);
        assertEq(vault.balanceOf(alice), aliceShares);
        _assertNoOneElseLost(before);
    }

    function test_OwnerSellsEverythingInKindWhileOthersHold() public {
        uint256[5] memory before = _perShare();
        vm.prank(owner);
        tel.redeemInKind(address(vault), 1000e18, owner);
        assertEq(vault.balanceOf(owner), 0);
        _assertNoOneElseLost(before);
        // The Fund goes on without the owner's money: a newcomer joins at NAV.
        uint256 d = _deposit(bob, 100e6, 1);
        _settle(_batchOf(d));
        (uint256 sb,) = _claim(d);
        assertGt(sb, 0);
    }

    function test_OwnerCashExitPartThenAllWhileOthersHold() public {
        uint256 fairBefore = _navPerShare();
        uint256 r = _redeem(owner, 300e18, 1);
        _settle(_batchOf(r));
        (uint256 back, uint256 got) = _claim(r);
        assertEq(back, 0, "the Fund's cash covers it");
        assertGt(got, 300e6, "about 1.1 USDG a share");
        assertEq(vault.balanceOf(owner), 700e18);
        assertGe(_navPerShare() + 1, fairBefore, "the holders who stay keep their fair NAV per share");
        uint256 r2 = _redeem(owner, 700e18, 1);
        _settle(_batchOf(r2));
        (, uint256 got2) = _claim(r2);
        assertGt(got2, 700e6);
        assertEq(vault.balanceOf(owner), 0, "the owner left in full");
        assertGe(_navPerShare() + 1, fairBefore);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_OwnerTopsUpLaterWithoutLatching() public {
        uint256 since = vault.outsideHolderSince();
        uint256 q = tel.outsideQueued(address(vault));
        uint256 d = _deposit(owner, 200e6, 1);
        assertEq(tel.outsideQueued(address(vault)), q, "the owner's deposit is not an outsider's");
        _settle(_batchOf(d));
        (uint256 s,) = _claim(d);
        assertEq(vault.balanceOf(owner), 1000e18 + s);
        assertEq(vault.outsideHolderSince(), since, "the latch did not move");
    }

    /// Closing for good stops deposits at once and pays waiting ones back; nobody waits a notice to leave.
    function test_WindDownStopsDepositsAndEveryoneLeavesAtOnce() public {
        uint256 d = _deposit(bob, 100e6, 1);
        vm.prank(owner);
        tel.windDown(address(vault));
        assertEq(tel.fund(address(vault)).windDownAt, block.timestamp);
        usdg.mint(carol, 10e6);
        vm.startPrank(carol);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.WindingDown.selector);
        tel.requestDeposit(address(vault), 10e6, 1);
        vm.stopPrank();
        // The owner's own top-up is refused too: closed is closed.
        usdg.mint(owner, 10e6);
        vm.startPrank(owner);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.WindingDown.selector);
        tel.requestDeposit(address(vault), 10e6, 1);
        vm.stopPrank();
        uint256 r = _redeem(owner, 500e18, 1);
        _settle(_batchOf(d));
        (uint256 s, uint256 refund) = _claim(d);
        assertEq(s, 0);
        assertEq(refund, 100e6, "queued deposits are paid back");
        (, uint256 got) = _claim(r);
        assertGt(got, 0, "the owner's cash exit is paid in the same settlement");
        vm.prank(owner);
        tel.redeemInKind(address(vault), 500e18, owner);
        uint256 a = vault.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), a, alice);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES(), "only the supply floor is left");
    }

    function test_AFundEveryoneLeftCanReopen() public {
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        vm.startPrank(owner);
        tel.redeemInKind(address(vault), 1000e18, owner);
        usdg.mint(owner, 50e6);
        usdg.approve(address(tel), 50e6);
        tel.open(address(vault), 50e6, 0, 0);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 50e18 + tel.DEAD_SHARES());
        assertEq(vault.balanceOf(owner), 50e18);
    }

    function test_ReopenRefusedWhileAnyoneHolds() public {
        usdg.mint(owner, 50e6);
        vm.startPrank(owner);
        usdg.approve(address(tel), 50e6);
        vm.expectRevert(Teller.AlreadyOpen.selector);
        tel.open(address(vault), 50e6, 0, 0);
        // The owner leaving is not enough while alice holds.
        tel.redeemInKind(address(vault), 1000e18, owner);
        vm.expectRevert(Teller.AlreadyOpen.selector);
        tel.open(address(vault), 50e6, 0, 0);
        vm.stopPrank();
    }

    function test_ReopenRefusedWhileValueIsLeft() public {
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        vm.prank(owner);
        tel.redeemInKind(address(vault), 1000e18, owner);
        usdg.mint(address(vault), 100e6); // the dead shares' now: a new opening must not take it
        usdg.mint(owner, 50e6);
        vm.startPrank(owner);
        usdg.approve(address(tel), 50e6);
        vm.expectRevert(Teller.NotEmpty.selector);
        tel.open(address(vault), 50e6, 0, 0);
        vm.stopPrank();
    }
}

/// @notice A Fund only its owner holds: the owner's own shares, wherever they move, never latch, the owner keeps
///         its instant powers, and new Funds resist the first-depositor and donation attacks.
contract TellerOwnerOnlyTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function _noLatch() internal view {
        assertFalse(vault.hadOutsideHolder(), "latched");
        assertEq(vault.outsideHolderSince(), 0);
        assertEq(tel.outsideQueued(address(vault)), 0);
    }

    function test_OwnerTopsUpAndSellsWithoutLatching() public {
        _noLatch();
        uint256 d = _deposit(owner, 500e6, 1);
        _noLatch();
        _settle(_batchOf(d));
        (uint256 s,) = _claim(d);
        assertEq(vault.balanceOf(owner), 1000e18 + s);
        _noLatch();
        // A cash exit escrows the shares here and pays the owner.
        uint256 r = _redeem(owner, 300e18, 1);
        _noLatch();
        _settle(_batchOf(r));
        (, uint256 got) = _claim(r);
        assertGt(got, 0);
        _noLatch();
        // Requested and cancelled: the shares go here and back.
        uint256 r2 = _redeem(owner, 100e18, 1);
        vm.prank(owner);
        tel.cancel(r2);
        _noLatch();
        // And everything in kind.
        uint256 rest = vault.balanceOf(owner);
        vm.prank(owner);
        tel.redeemInKind(address(vault), rest, owner);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES());
        _noLatch();
    }

    function test_OwnerKeepsInstantPowersWhileOnlyItHolds() public {
        uint256 d = _deposit(owner, 100e6, 1);
        _settle(_batchOf(d));
        _claim(d);
        vm.prank(owner);
        fees.setTerms(address(vault), 200, 2000);
        assertEq(fees.terms(address(vault)).management, 200, "a raise applies at once");
        assertTrue(address(_book(0)) != address(0), "a new adapter applies at once");
    }

    function test_OwnerOnlyCashExitPaysOnlyTheCaller() public {
        vm.startPrank(owner);
        vault.approve(address(tel), 100e18);
        vm.expectRevert(Teller.BadReceiver.selector);
        tel.requestRedeem(address(vault), 100e18, 1, bob);
        tel.requestRedeem(address(vault), 100e18, 1, owner);
        vm.stopPrank();
        _noLatch();
    }

    function test_SharesReachingSomeoneElseLatch() public {
        vm.prank(owner);
        vault.transfer(bob, 1e18);
        assertTrue(vault.hadOutsideHolder(), "a share in another wallet is an outside holder");
    }

    /// The management clock starts when an outsider arrives, never at the opening: a year owner-only is not charged.
    function test_ManagementFeeStartsAtTheLatchNotAtTheOpening() public {
        _openFund(200, 0);
        vm.warp(block.timestamp + 365 days);
        uint256 d0 = _deposit(owner, 100e6, 1);
        _settle(_batchOf(d0));
        _claim(d0);
        assertEq(vault.balanceOf(aix) + vault.balanceOf(treasury), 0, "no fee while only the owner holds");
        uint256 d = _deposit(bob, 100e6, 1);
        uint256 latchedAt = vault.outsideHolderSince();
        assertEq(latchedAt, block.timestamp);
        _settle(_batchOf(d));
        _claim(d);
        uint256 supply = vault.totalSupply();
        uint256 dt = block.timestamp - latchedAt;
        assertLt(dt, 2 days);
        // AINDEX's 30% of the fee, for at most the time since the latch (plus rounding).
        uint256 most = supply * 200 * 2 days / (10_000 * 365 days) * 3_000 / 10_000 + 1e6;
        assertLe(vault.balanceOf(aix) + vault.balanceOf(treasury), most, "only the time since the latch is charged");
    }

    // ------------------------------------------------ first-depositor and donation attacks

    /// The owner keeps one wei of share and donates a fortune before the first outsider: the dead shares hold the
    /// supply up, the donation stays with them, and the newcomer loses rounding only.
    function test_InflationByTheOwnerCostsTheNewcomerOnlyRounding() public {
        vm.prank(owner);
        tel.redeemInKind(address(vault), 1000e18 - 1, owner);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES() + 1);
        uint256 spent = 1_000_000e6;
        usdg.mint(address(vault), spent); // the donation
        uint256 a = _deposit(alice, 1_000e6, 1);
        _settle(_batchOf(a));
        (uint256 sh,) = _claim(a);
        assertGt(sh, 0, "never zero shares");
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        assertGe(usdg.balanceOf(alice), 1_000e6 - 1_000, "rounding only");
        // The attacker's one wei is worth a millionth of the donation's per-share value: it lost the donation.
        uint256 before = usdg.balanceOf(owner);
        vm.prank(owner);
        tel.redeemInKind(address(vault), 1, owner);
        assertLt(usdg.balanceOf(owner) - before, spent / 1e6, "the donation went to the dead shares");
    }

    /// The owner leaves in full (only the dead shares left) and a stranger donates: the next depositor still gets
    /// its money's worth, the donation stays behind.
    function test_DonationToAFundOnlyDeadSharesHold() public {
        vm.prank(owner);
        tel.redeemInKind(address(vault), 1000e18, owner);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES());
        usdg.mint(address(vault), 10_000e6);
        uint256 a = _deposit(alice, 1_000e6, 1);
        _settle(_batchOf(a));
        (uint256 sh,) = _claim(a);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        assertGe(usdg.balanceOf(alice), 1_000e6 - 1_000);
        assertLe(usdg.balanceOf(alice), 1_000e6 + 1_000, "and no windfall from the donation either");
    }

    /// A front-runner donates to a brand-new Fund before its first outside deposit: the depositor pays NAV, so the
    /// donation is shared by the holders of the moment (the owner and the dead shares), never taken from it.
    function test_DonationFrontRunOnANewFund() public {
        usdg.mint(address(vault), 50_000e6);
        uint256 a = _deposit(alice, 1_000e6, 1);
        _settle(_batchOf(a));
        (uint256 sh,) = _claim(a);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        assertGe(usdg.balanceOf(alice), 1_000e6 - 1_000);
        assertLe(usdg.balanceOf(alice), 1_000e6 + 1_000);
    }

    /// At the least opening, the floor still makes a single raw unit of USDG worth many share units.
    function test_MinimumOpeningKeepsTheFloor() public {
        address m = makeAddr("m");
        usdg.mint(m, 10e6);
        vm.startPrank(m);
        usdg.approve(address(tel), 10e6);
        (address v,) = tel.createFund("M", "M", _openDial(), 10e6, 0, 0);
        vm.stopPrank();
        assertEq(tel.owed(v), 0);
        assertEq(_bal(v, m), 10e18);
        assertEq(_bal(v, address(tel)), tel.DEAD_SHARES());
    }

    // ------------------------------------------------ reopening and ownership handover

    /// A deposit someone else has waiting was queued under the current terms: the owner cannot leave in kind and
    /// reopen with new fees (which apply at once) over it, even past its cut-off when it can no longer be cancelled.
    function test_ReopenRefusedWhileAnOutsideDepositWaits() public {
        uint256 id = _deposit(alice, 500e6, 1);
        _toCutoff(_batchOf(id));
        vm.startPrank(owner);
        tel.redeemInKind(address(vault), vault.balanceOf(owner), owner);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES());
        usdg.mint(owner, 10e6);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.NotEmpty.selector);
        tel.open(address(vault), 10e6, 200, 2000);
        vm.stopPrank();
        assertEq(fees.terms(address(vault)).management, 0, "the terms the deposit was queued under");
    }

    /// Once nothing of anyone else's waits, the Fund reopens as before.
    function test_ReopenAllowedOnceTheOutsideDepositIsCancelled() public {
        uint256 id = _deposit(alice, 500e6, 1);
        vm.prank(alice);
        tel.cancel(id);
        assertEq(tel.outsideQueued(address(vault)), 0);
        vm.startPrank(owner);
        tel.redeemInKind(address(vault), vault.balanceOf(owner), owner);
        usdg.mint(owner, 10e6);
        usdg.approve(address(tel), 10e6);
        tel.open(address(vault), 10e6, 200, 2000);
        vm.stopPrank();
        assertEq(fees.terms(address(vault)).management, 200);
    }

    function _handOver(address next) internal {
        vm.prank(owner);
        controller.transferOwnership(next);
        vm.prank(next);
        controller.acceptOwnership();
    }

    /// After a handover the former owner's shares never moved, so the vault never latched; they are still someone
    /// else's shares, so a fee rise waits the notice.
    function test_FeeRiseWaitsTheNoticeOverAFormerOwnersShares() public {
        address next = makeAddr("next");
        _handOver(next);
        assertFalse(vault.hadOutsideHolder());
        vm.prank(next);
        fees.setTerms(address(vault), 200, 2000);
        assertEq(fees.terms(address(vault)).management, 0, "not at once");
        assertEq(fees.terms(address(vault)).nextManagement, 200);
        vm.warp(block.timestamp + fees.INCREASE_NOTICE());
        fees.applyPendingTerms(address(vault));
        assertEq(fees.terms(address(vault)).management, 200);
    }

    /// And the management fee is charged on them, as on any outside holder's.
    function test_ManagementAccruesOverAFormerOwnersShares() public {
        vm.prank(owner);
        fees.setTerms(address(vault), 200, 0); // owner-only: at once
        address next = makeAddr("next");
        _handOver(next);
        vm.warp(block.timestamp + 30 days);
        uint256 d = _deposit(next, 100e6, 1);
        assertFalse(vault.hadOutsideHolder());
        _settle(_batchOf(d));
        assertGt(vault.balanceOf(aix) + vault.balanceOf(treasury), 0, "charged");
    }

    function _bal(address v, address who) internal view returns (uint256) {
        return IERC20(v).balanceOf(who);
    }
}
