// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase} from "./TellerBase.t.sol";
import {Teller} from "../../src/core/Teller.sol";
import {FeeConfig, FundFees} from "../../src/core/Fees.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

/// @notice A Fund with 2% management and 20% performance: 500 USDG and 5 A ($100 each) for 1,000 shares. Fees
///         accrue at settlements only, at the bid NAV, before any share is minted or burned.
contract TellerFeesTest is TellerBase {
    uint256 internal constant YEAR = 365 days;

    function setUp() public {
        _setUpTeller();
        _openFund(200, 2000);
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 500e6);
        tokA.mint(address(vault), 5e18);
        vm.prank(address(controller));
        vault.track(address(tokA));
    }

    function _buyIn(address who, uint256 amount) internal returns (uint256 shares) {
        return _join(who, amount);
    }

    function _feeShares() internal view returns (uint256) {
        return
            vault.balanceOf(owner) + vault.balanceOf(aix) + vault.balanceOf(treasury) + vault.balanceOf(address(fees));
    }

    function test_NoFeesWhileOnlyTheOwnerHolds() public {
        vm.warp(block.timestamp + YEAR);
        _buyIn(owner, 100e6);
        uint256 s = vault.totalSupply();
        assertEq(vault.balanceOf(aix), 0);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(s, vault.balanceOf(owner) + vault.balanceOf(address(tel)));
    }

    function test_ManagementByDilutionSplit701515() public {
        _buyIn(alice, 1000e6);
        uint256 s0 = vault.totalSupply();
        uint256 fee0 = _feeShares();
        uint256 owner0 = vault.balanceOf(owner);
        uint256 aix0 = vault.balanceOf(aix);
        vm.warp(block.timestamp + YEAR);
        // Any settlement accrues; a batch with only a tiny deposit.
        uint256 id = _deposit(carol, 10e6, 0);
        uint64 bt = _batchOf(id);
        _toCutoff(bt);
        uint256 dt = block.timestamp - fees.terms(address(vault)).lastAccrual;
        _settle(bt); // a small deposit: any settlement accrues
        uint256 minted = _feeShares() - fee0;
        uint256 x = 200 * dt * WAD / (10_000 * YEAR);
        uint256 expected = s0 * x / (WAD - x);
        assertApproxEqAbs(minted, expected, 3);
        // After the mint, fee holders own exactly x of the Fund (from this accrual).
        assertApproxEqRel(minted * WAD / (s0 + minted), x, 1e9);
        assertApproxEqAbs(vault.balanceOf(owner) - owner0, minted * 7000 / 10_000, 2);
        assertApproxEqAbs(vault.balanceOf(aix) - aix0, minted * 1500 / 10_000, 2);
    }

    function test_SplitChangeAppliesFromTheNextAccrual() public {
        _buyIn(alice, 1000e6);
        feeConfig.setSplit(5000, 2500, 2500);
        uint256 a0 = vault.balanceOf(aix);
        uint256 t0 = vault.balanceOf(treasury);
        uint256 o0 = vault.balanceOf(owner);
        vm.warp(block.timestamp + YEAR);
        uint256 id = _deposit(carol, 10e6, 0);
        uint64 bt = _batchOf(id);
        _toCutoff(bt);
        _settle(bt); // a small deposit: any settlement accrues
        uint256 da = vault.balanceOf(aix) - a0;
        uint256 dtr = vault.balanceOf(treasury) - t0;
        uint256 dow = vault.balanceOf(owner) - o0;
        assertApproxEqAbs(da, dtr, 2);
        assertApproxEqAbs(dow, da * 2, 4);
        vm.prank(alice);
        vm.expectRevert(FeeConfig.NotAdmin.selector);
        feeConfig.setSplit(10_000, 0, 0);
        vm.expectRevert(FeeConfig.BadSplit.selector);
        feeConfig.setSplit(7000, 1500, 1501);
    }

    function test_PerformanceAboveTheMarkHalfLockedSevenDays() public {
        _buyIn(alice, 1000e6);
        uint256 hwm = fees.highWaterMark(address(vault));
        assertGt(hwm, 0);
        // A doubles: NAV per share rises well above the mark.
        source.set(address(tokA), 200e18);
        uint256 navBefore = _navBid();
        uint256 s0 = vault.totalSupply();
        uint256 fee0 = _feeShares();
        uint256 id = _deposit(carol, 10e6, 0);
        uint64 bt = _batchOf(id);
        _toCutoff(bt);
        uint256 mgmtUsd = navBefore * 200 * (block.timestamp - fees.terms(address(vault)).lastAccrual) / (10_000 * YEAR);
        _settle(bt); // a small deposit: any settlement accrues
        uint256 minted = _feeShares() - fee0;
        uint256 p0 = navBefore * WAD / s0;
        uint256 gainUsd = (p0 - hwm) * s0 / WAD;
        // Fee shares' value at the new price: 20% of the gain, plus the day's management.
        uint256 feeUsd = minted * (navBefore * WAD / (s0 + minted)) / WAD;
        assertApproxEqRel(feeUsd, gainUsd * 2000 / 10_000, 0.01e18);
        assertLe(feeUsd, gainUsd * 2000 / 10_000 + mgmtUsd + 1e12);
        // Half the manager's performance part is locked here.
        (uint256 locked,) = fees.locked(address(vault));
        assertApproxEqRel(locked, minted * 7000 / 10_000 / 2, 0.01e18);
        assertEq(vault.balanceOf(address(fees)), locked);
        // The mark moved up to NAV per share after the fee.
        assertGt(fees.highWaterMark(address(vault)), hwm);
        // Released to the manager's recipient (the owner) after 7 days.
        vm.expectRevert();
        fees.lockAt(address(vault), 1);
        uint256 o0 = vault.balanceOf(owner);
        vm.warp(block.timestamp + 7 days);
        fees.release(address(vault), 10);
        assertEq(vault.balanceOf(owner) - o0, locked);
        assertEq(vault.balanceOf(address(fees)), 0);
    }

    function test_FirstLossBurnsTheLockedStakeBeforeHoldersLose() public {
        _buyIn(alice, 1000e6);
        source.set(address(tokA), 200e18);
        uint256 id = _deposit(carol, 10e6, 0);
        uint64 bt = _batchOf(id);
        _toCutoff(bt);
        _settle(bt); // a small deposit: any settlement accrues
        (uint256 locked,) = fees.locked(address(vault));
        assertGt(locked, 0);
        uint256 hwm = fees.highWaterMark(address(vault));
        // A small fall: the locked stake absorbs it and NAV per share comes back to the mark.
        source.set(address(tokA), 199e18);
        uint256 id2 = _deposit(carol, 10e6, 0);
        uint64 bt2 = _batchOf(id2);
        _toCutoff(bt2);
        _settle(bt2);
        (uint256 left,) = fees.locked(address(vault));
        assertLt(left, locked, "stake burned");
        assertApproxEqRel(_navBid() * WAD / vault.totalSupply(), hwm, 0.0001e18);
        // A large fall: the stake is gone, holders take the rest.
        source.set(address(tokA), 50e18);
        uint256 id3 = _deposit(carol, 10e6, 0);
        uint64 bt3 = _batchOf(id3);
        _toCutoff(bt3);
        _settle(bt3);
        (left,) = fees.locked(address(vault));
        assertEq(left, 0);
        assertEq(vault.balanceOf(address(fees)), 0);
    }

    /// @notice A lock that has served its time still absorbs a loss that is already there. `release` refuses
    ///         while NAV per share is below the mark, and an accrual burns before it releases.
    function test_ExpiredLocksStillAbsorbALoss() public {
        _buyIn(alice, 1000e6);
        source.set(address(tokA), 200e18);
        uint256 id = _deposit(carol, 10e6, 0);
        _toCutoff(_batchOf(id));
        _settle(_batchOf(id));
        (uint256 locked,) = fees.locked(address(vault));
        assertGt(locked, 0);
        vm.warp(block.timestamp + 7 days); // the locks have served their time
        source.set(address(tokA), 190e18); // and NAV per share fell below the mark
        vm.expectRevert(FundFees.NotReady.selector);
        fees.release(address(vault), 10);
        uint256 id2 = _deposit(carol, 10e6, 0);
        _toCutoff(_batchOf(id2));
        vm.expectEmit(true, false, false, false, address(fees));
        emit FundFees.FirstLossBurned(address(vault), 0, 0, 0);
        _settle(_batchOf(id2));
        assertEq(vault.balanceOf(address(fees)), 0, "burned first, then the rest released");
    }

    function test_RaisesWaitThirtyDaysCutsAreInstantMaximaFixed() public {
        _buyIn(alice, 1000e6);
        vm.startPrank(owner);
        fees.setTerms(address(vault), 100, 1000); // lower: now
        assertEq(fees.terms(address(vault)).management, 100);
        assertEq(fees.terms(address(vault)).performance, 1000);
        fees.setTerms(address(vault), 150, 500); // management up waits, performance down now
        assertEq(fees.terms(address(vault)).management, 100);
        assertEq(fees.terms(address(vault)).performance, 500);
        vm.expectRevert(FundFees.NotReady.selector);
        fees.applyPendingTerms(address(vault));
        vm.expectRevert(FundFees.OverMaximum.selector);
        fees.setTerms(address(vault), 201, 0);
        vm.expectRevert(FundFees.OverMaximum.selector);
        fees.setTerms(address(vault), 0, 2001);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        fees.applyPendingTerms(address(vault));
        assertEq(fees.terms(address(vault)).management, 150);
        vm.prank(alice);
        vm.expectRevert(FundFees.NotOwner.selector);
        fees.setTerms(address(vault), 0, 0);
    }

    function test_TermsChangeAtOnceBeforeAnyOutsider() public {
        vm.prank(owner);
        fees.setTerms(address(vault), 200, 2000);
        vm.prank(owner);
        fees.setTerms(address(vault), 150, 1500);
        vm.prank(owner);
        fees.setTerms(address(vault), 200, 2000);
        assertEq(fees.terms(address(vault)).management, 200);
    }

    /// @notice Exits in kind no longer accrue fees: the next settlement charges the whole elapsed time.
    function test_InKindExitAccruesNothingNextSettlementChargesAll() public {
        _buyIn(alice, 1000e6);
        uint256 fee0 = _feeShares();
        uint64 last = fees.terms(address(vault)).lastAccrual;
        vm.warp(block.timestamp + 30 days);
        uint256 sh = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        assertEq(_feeShares(), fee0, "no fee at an exit in kind");
        assertEq(fees.terms(address(vault)).lastAccrual, last);
        uint256 id = _deposit(carol, 10e6, 0);
        _settle(_batchOf(id));
        assertGt(_feeShares(), fee0, "charged at the settlement");
    }

    /// @notice While the Fund holds a no-market token above dust, a settlement mints no fee shares (they would take
    ///         a slice of it); after the pocket, the next settlement charges the whole elapsed time.
    function test_FeesWaitForThePocketThenChargeInFull() public {
        _buyIn(alice, 1000e6);
        MockERC20 tokN = new MockERC20("N", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        _hold(tokN, 100e18);
        uint256 fee0 = _feeShares();
        uint64 last = fees.terms(address(vault)).lastAccrual;
        vm.warp(block.timestamp + 60 days);
        uint256 id = _deposit(carol, 10e6, 0);
        uint64 bt = _batchOf(id);
        _settle(bt);
        assertEq(_feeShares(), fee0, "no fee shares while N is held");
        assertEq(fees.terms(address(vault)).lastAccrual, last, "the clock is not consumed");
        tel.pocket(address(vault), address(tokN), new address[](0), 0);
        uint256 s0 = vault.totalSupply();
        _settle(bt); // the waiting deposit's round accrues
        uint256 minted = _feeShares() - fee0;
        uint256 dt = block.timestamp - last;
        uint256 x = 200 * dt * WAD / (10_000 * YEAR);
        assertApproxEqRel(minted, s0 * x / (WAD - x), 0.001e18, "the whole elapsed time charged");
    }

    /// @notice Fees never exceed the maxima: whatever time passes and however prices move.
    function testFuzz_FeesNeverExceedMaxima(uint32 dtSeed, uint16 priceBps) public {
        _buyIn(alice, 1000e6);
        uint256 dt = bound(dtSeed, 1 hours, 3 * YEAR);
        uint256 price = bound(priceBps, 2000, 50_000) * 1e18 / 100; // $20 to $500
        vm.warp(block.timestamp + dt);
        source.set(address(tokA), price);
        uint256 nav = _navBid();
        uint256 s0 = vault.totalSupply();
        uint256 hwm = fees.highWaterMark(address(vault));
        uint256 fee0 = _feeShares();
        uint256 id = _deposit(carol, 10e6, 0);
        uint64 bt = _batchOf(id);
        _toCutoff(bt);
        uint256 elapsedAtSettle = block.timestamp - fees.terms(address(vault)).lastAccrual;
        _settle(bt); // a small deposit: any settlement accrues
        uint256 minted = _feeShares() - fee0;
        uint256 p0 = nav * WAD / s0;
        uint256 perfUsd = p0 > hwm ? (p0 - hwm) * s0 / WAD * 2000 / 10_000 : 0;
        uint256 mgmtUsd = nav * 200 * elapsedAtSettle / (10_000 * YEAR);
        uint256 feeUsd = minted * nav / (s0 + minted);
        assertLe(feeUsd, mgmtUsd + perfUsd + 1e12, "fees above the maxima");
    }

    function _navBid() internal view returns (uint256 nav) {
        (nav,) = controller.nav(1);
    }
}
