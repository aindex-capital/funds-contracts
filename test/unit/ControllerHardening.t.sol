// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../utils/FundTestBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockSwap, MockLending, MockThief, MockBroken} from "../utils/MockAdapters.sol";
import {FundController} from "../../src/core/FundController.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {DialPresets} from "../../src/core/DialPresets.sol";
import {PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";

contract ControllerHardeningTest is FundTestBase {
    MockERC20 thin; // $2, Thin, 5% haircut
    MockERC20 pool; // $10, Pool, 1% haircut
    MockERC20 feed; // $100, Feed, 0.5% haircut
    MockERC20 junk; // no market

    MockSwap swapImpl;
    MockLending lendImpl;
    MockThief thiefImpl;
    MockBroken brokenImpl;
    address swap; // no fee
    address lossy; // 10% fee
    address lend;

    address holder = makeAddr("holder");
    address sink = makeAddr("sink");
    address stranger = makeAddr("stranger");

    function setUp() public {
        _setUpCore();
        thin = new MockERC20("Thin", "THIN", 18);
        pool = new MockERC20("Pool", "POOL", 18);
        feed = new MockERC20("Feed", "FEED", 18);
        junk = new MockERC20("Junk", "JUNK", 18);
        _price(address(thin), 2e18, PriceClass.Thin, 500);
        _price(address(pool), 10e18, PriceClass.Pool, 100);
        _price(address(feed), 100e18, PriceClass.Feed, 50);
        source.set(address(junk), 1e18); // the venue trades it; the router does not price it
        swapImpl = new MockSwap();
        lendImpl = new MockLending();
        thiefImpl = new MockThief();
        brokenImpl = new MockBroken();
        registry.register(address(swapImpl), "");
        registry.register(address(lendImpl), "");
        registry.register(address(thiefImpl), "");
        registry.register(address(brokenImpl), "");
    }

    // ------------------------------------------------------------ helpers

    function _fund(Dial memory d) internal {
        _createFund(d, 1000e6);
        swap = _enable(address(swapImpl), abi.encode(source, uint256(0)));
        lossy = _enable(address(swapImpl), abi.encode(source, uint256(1000)));
        lend = _enable(address(lendImpl), "");
    }

    function _outsider() internal {
        vm.prank(owner);
        vault.transfer(holder, 1e18);
    }

    function _swap(address venue, address tin, address tout, uint256 amt) internal {
        vm.prank(manager);
        controller.act(venue, abi.encode(tin, tout, amt));
    }

    function _swapReverts(address venue, address tin, address tout, uint256 amt, bytes memory err) internal {
        vm.prank(manager);
        if (err.length == 0) vm.expectRevert();
        else vm.expectRevert(err);
        controller.act(venue, abi.encode(tin, tout, amt));
    }

    function _lend(uint8 op, address t, uint256 amt) internal {
        vm.prank(manager);
        controller.act(lend, abi.encode(op, t, amt));
    }

    function _navFair() internal view returns (uint256 n) {
        (n,) = controller.nav(uint8(Side.Fair));
    }

    // ------------------------------------------------------------ dial: each field

    function test_NoMarketZeroCapBlocksBuyingButNotLeftovers() public {
        _fund(_openDial());
        _swap(swap, address(usdg), address(junk), 10e6); // allowed under the open dial
        Dial memory d = _openDial();
        d.maxNoMarketBps = 0;
        vm.prank(owner);
        controller.setDial(d); // tightening: at once
        _swapReverts(swap, address(usdg), address(junk), 1e6, abi.encodeWithSelector(FundController.ClassCap.selector, 0, 1, 0));
        // Unrelated actions and selling the junk still work.
        _swap(swap, address(usdg), address(feed), 10e6);
        _swap(swap, address(junk), address(usdg), 5e18);
        // A crumb donated by anyone does not block the Fund either.
        junk.mint(address(vault), 1);
        _swap(swap, address(usdg), address(feed), 10e6);
    }

    function test_ThinCapAndBreachMayOnlyShrink() public {
        Dial memory d = _openDial();
        d.maxThinBps = 1000;
        _fund(d);
        _swap(swap, address(usdg), address(thin), 90e6);
        _swapReverts(swap, address(usdg), address(thin), 20e6, "");
        d.maxThinBps = 500;
        vm.prank(owner);
        controller.setDial(d);
        _swapReverts(swap, address(usdg), address(thin), 1e6, "");
        _swap(swap, address(usdg), address(feed), 10e6); // unrelated: fine though thin is over the cap
        _swap(swap, address(thin), address(usdg), 5e18); // reducing: fine
    }

    function test_PoolCap() public {
        Dial memory d = _openDial();
        d.maxPoolBps = 2000;
        _fund(d);
        _swap(swap, address(usdg), address(pool), 150e6);
        _swapReverts(swap, address(usdg), address(pool), 100e6, "");
    }

    function test_PerTokenCapWithCashExempt() public {
        Dial memory d = _openDial();
        d.maxPerTokenBps = 2000;
        _fund(d);
        // The Fund is 100% cash and that is fine.
        _swap(swap, address(usdg), address(feed), 150e6);
        vm.prank(manager);
        vm.expectPartialRevert(FundController.OverCap.selector);
        controller.act(swap, abi.encode(address(usdg), address(feed), uint256(100e6)));
        // The cap counts a token wherever it is: in the vault and supplied to the lending adapter.
        _lend(0, address(feed), 1e18);
        _swapReverts(swap, address(usdg), address(feed), 60e6, "");
    }

    function test_DailyLossBudgetIsCumulative() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 100; // 1% of $1000 = $10
        _fund(d);
        _swap(lossy, address(usdg), address(usdg), 50e6); // $5
        _swap(lossy, address(usdg), address(usdg), 50e6); // $10 total
        _swapReverts(lossy, address(usdg), address(usdg), 1e6, "");
        assertEq(controller.windowLoss(), 10e18);
    }

    function test_LossWindowRollsOverWithoutDoubleSpend() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 100;
        vm.warp(10 days + 23 hours); // late in a day
        _fund(d);
        _swap(lossy, address(usdg), address(usdg), 100e6); // the whole $10
        vm.warp(11 days + 1); // just past midnight
        _swapReverts(lossy, address(usdg), address(usdg), 10e6, ""); // $1: yesterday's loss still counts
        vm.warp(11 days + 12 hours); // half of yesterday faded: $5 used of $9.90
        _swap(lossy, address(usdg), address(usdg), 40e6); // $4
        _swapReverts(lossy, address(usdg), address(usdg), 10e6, ""); // $1 more would be $10 > $9.90
        vm.warp(12 days + 12 hours); // two days on: yesterday's $4 half faded, budget ~ $9.86
        _swap(lossy, address(usdg), address(usdg), 70e6); // $7: 2 + 7 = 9 used
        assertEq(controller.prevWindowLoss(), 4e18);
    }

    function test_EmptyFundDoesNotLeaveZeroBudgetForTheDay() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 100;
        (vault, controller) = factory.create("F", "F", owner, address(teller), d);
        vm.startPrank(owner);
        controller.setManager(manager, uint64(block.timestamp + 30 days));
        lossy = controller.addAdapter(address(swapImpl), abi.encode(source, uint256(1000)));
        vm.stopPrank();
        _swap(lossy, address(usdg), address(usdg), 0); // an action on an empty Fund opens the day at 0
        assertEq(controller.windowStartNav(), 0);
        usdg.mint(owner, 1000e6);
        vm.startPrank(owner);
        usdg.approve(address(teller), 1000e6);
        teller.seed(vault, address(usdg), 1000e6, 6, owner);
        vm.stopPrank();
        _swap(lossy, address(usdg), address(usdg), 50e6); // $5 of a $10 budget, measured from the seeded NAV
        assertEq(controller.windowStartNav(), 1000e18);
    }

    function test_OutflowsShrinkTheBudget() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 100;
        _fund(d);
        _swap(lossy, address(usdg), address(usdg), 10e6); // $1; day opened at $1000
        // Half the Fund leaves (a redemption through the teller).
        vm.prank(address(teller));
        vault.pay(address(usdg), holder, 499e6);
        // Budget is now 1% of ($500 + $1) = $5.01, of which $1 is used.
        _swapReverts(lossy, address(usdg), address(usdg), 50e6, "");
        _swap(lossy, address(usdg), address(usdg), 40e6);
    }

    function test_BorrowNeedsAllowBorrow() public {
        Dial memory d = _openDial();
        d.allowBorrow = false;
        d.minHealthBps = 0;
        _fund(d);
        vm.prank(manager);
        vm.expectRevert(FundController.BorrowNotAllowed.selector);
        controller.act(lend, abi.encode(uint8(2), address(usdg), uint256(100e6)));
    }

    function test_HealthFloorWithDebts() public {
        Dial memory d = _openDial();
        d.minHealthBps = 15_000;
        _fund(d);
        _lend(2, address(usdg), 1000e6); // assets 2000, debts 1000: health 2.0
        _lend(2, address(usdg), 1000e6); // 3000 / 2000: exactly 1.5 passes
        vm.prank(manager);
        vm.expectPartialRevert(FundController.Unhealthy.selector);
        controller.act(lend, abi.encode(uint8(2), address(usdg), uint256(10e6)));
        // Tighten the floor beyond the current health: repaying is still allowed, borrowing is not.
        d.minHealthBps = 30_000;
        vm.prank(owner);
        controller.setDial(d);
        _lend(3, address(usdg), 500e6);
        vm.prank(manager);
        vm.expectPartialRevert(FundController.Unhealthy.selector);
        controller.act(lend, abi.encode(uint8(2), address(usdg), uint256(1e6)));
    }

    function test_DebtInNoMarketTokenIsUnpriceable() public {
        _fund(_openDial());
        vm.prank(manager);
        vm.expectRevert(FundController.PriceUnavailable.selector);
        controller.act(lend, abi.encode(uint8(2), address(junk), uint256(1e18)));
    }

    function test_DowngradingABorrowedTokenToNoneFreezesInsteadOfRaisingNav() public {
        _fund(_openDial());
        _lend(2, address(feed), 1e18);
        _price(address(feed), 100e18, PriceClass.None, 0);
        (, bool complete, address[] memory unpriced,) = controller.navReport(uint8(Side.Bid));
        assertFalse(complete, "a free-looking debt");
        assertEq(unpriced[0], address(feed));
        _swapReverts(swap, address(usdg), address(usdg), 1e6, abi.encodeWithSelector(FundController.PriceUnavailable.selector));
    }

    // ------------------------------------------------------------ setDial: notice and safer merge

    function test_SaferPartsApplyNowRiskierWait() public {
        Dial memory cur = _openDial();
        cur.maxThinBps = 2000;
        cur.dailyLossBps = 500;
        cur.minHealthBps = 15_000;
        _fund(cur);
        _outsider();
        Dial memory next = cur;
        next.maxThinBps = 5000; // looser
        next.maxPoolBps = 3000; // tighter
        next.maxNoMarketBps = 100; // tighter
        next.maxPerTokenBps = 4000; // tighter
        next.dailyLossBps = 1000; // looser
        next.allowBorrow = false; // tighter
        next.minHealthBps = 12_000; // looser (only matters if borrowing)
        vm.prank(owner);
        controller.setDial(next);
        Dial memory now_ = controller.dial();
        assertEq(now_.maxThinBps, 2000);
        assertEq(now_.maxPoolBps, 3000);
        assertEq(now_.maxNoMarketBps, 100);
        assertEq(now_.maxPerTokenBps, 4000);
        assertEq(now_.dailyLossBps, 500);
        assertFalse(now_.allowBorrow);
        assertEq(now_.minHealthBps, 15_000); // open debts are still held to it, so lowering it waits
        vm.expectRevert(FundController.NotReady.selector);
        controller.applyPendingDial();
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        controller.applyPendingDial();
        assertEq(controller.dial().maxThinBps, 5000);
        assertEq(controller.dial().dailyLossBps, 1000);
        assertEq(controller.dial().minHealthBps, 12_000);
    }

    function test_AllowUnreviewedOnWaitsOffIsInstant() public {
        Dial memory cur = _openDial();
        cur.allowUnreviewed = false;
        _fund(cur);
        _outsider();
        Dial memory next = cur;
        next.allowUnreviewed = true;
        next.maxThinBps = 5000; // tighter, applies now
        vm.prank(owner);
        controller.setDial(next);
        assertFalse(controller.dial().allowUnreviewed, "turned on without notice");
        assertEq(controller.dial().maxThinBps, 5000);
        (,,,,,,, bool pendingUnreviewed) = controller.pendingDial();
        assertTrue(pendingUnreviewed);
        vm.warp(block.timestamp + controller.RISK_NOTICE());
        controller.applyPendingDial();
        assertTrue(controller.dial().allowUnreviewed);

        // Off again: at once, nothing pending.
        next.allowUnreviewed = false;
        vm.prank(owner);
        controller.setDial(next);
        assertFalse(controller.dial().allowUnreviewed);
        assertEq(controller.pendingDialAt(), 0);
    }

    /// With `allowUnreviewed` off only verified adapters act; unwinding an unverified one always works.
    function test_UnverifiedAdapterNeedsAllowUnreviewed() public {
        _fund(_openDial());
        _lend(0, address(usdg), 100e6);
        Dial memory d = _openDial();
        d.allowUnreviewed = false;
        vm.prank(owner);
        controller.setDial(d);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FundController.Unreviewed.selector, swap));
        controller.act(swap, abi.encode(address(usdg), address(feed), uint256(1e6)));
        // The way out is never gated.
        vm.prank(manager);
        controller.unwindAdapter(lend, 1e18);

        // AINDEX verifies the swap implementation: it acts again. Withdrawing the review stops it at once.
        vm.prank(guardian);
        registry.setVerified(address(swapImpl), true);
        _swap(swap, address(usdg), address(feed), 1e6);
        vm.prank(guardian);
        registry.setVerified(address(swapImpl), false);
        _swapReverts(swap, address(usdg), address(feed), 1e6, abi.encodeWithSelector(FundController.Unreviewed.selector, swap));
    }

    /// Open to conservative: every cap applies at once; only the health floor (0 in the preset, unused while
    /// borrowing is off but still binding on debts already open) waits the notice.
    function test_OpenToConservativeTightensAtOnce() public {
        _fund(_openDial());
        _outsider();
        Dial memory c = DialPresets.conservative();
        vm.prank(owner);
        controller.setDial(c);
        Dial memory now_ = controller.dial();
        assertEq(now_.maxThinBps, 0);
        assertEq(now_.dailyLossBps, 300);
        assertFalse(now_.allowBorrow);
        assertFalse(now_.allowUnreviewed);
        assertEq(now_.minHealthBps, 10_000, "floor lowered without notice");
        vm.warp(block.timestamp + controller.RISK_NOTICE());
        controller.applyPendingDial();
        assertEq(keccak256(abi.encode(controller.dial())), keccak256(abi.encode(c)));
    }

    function test_PureTighteningLeavesNothingPending() public {
        _fund(_openDial());
        _outsider();
        Dial memory loose = _openDial();
        loose.maxThinBps = 5000;
        vm.prank(owner);
        controller.setDial(loose); // tightening from open
        assertEq(controller.pendingDialAt(), 0);
        assertEq(controller.dial().maxThinBps, 5000);
    }

    function test_LatestProposalReplacesAndCancel() public {
        Dial memory d = _openDial();
        d.maxThinBps = 1000;
        _fund(d);
        _outsider();
        Dial memory a = _openDial();
        a.maxThinBps = 5000;
        vm.prank(owner);
        controller.setDial(a);
        Dial memory b = _openDial();
        b.maxThinBps = 3000;
        vm.prank(owner);
        controller.setDial(b);
        (, uint16 pendingThin,,,,,,) = controller.pendingDial();
        assertEq(pendingThin, 3000);
        vm.prank(stranger);
        vm.expectRevert(FundController.NotOwner.selector);
        controller.cancelPendingDial();
        vm.prank(owner);
        controller.cancelPendingDial();
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(FundController.NotReady.selector);
        controller.applyPendingDial();
    }

    function test_ShortcutClosesForGoodOnceSomeoneElseHeldAShare() public {
        Dial memory d = _openDial();
        d.maxThinBps = 1000;
        _fund(d);
        _outsider();
        vm.prank(holder);
        vault.transfer(owner, 1e18); // the owner holds everything again
        vm.prank(owner);
        controller.setDial(_openDial());
        assertEq(controller.dial().maxThinBps, 1000, "risk raised without notice");
    }

    function test_BadDialRejected() public {
        _fund(_openDial());
        Dial memory d = _openDial();
        d.dailyLossBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(FundController.BadDial.selector);
        controller.setDial(d);
        vm.prank(stranger);
        vm.expectRevert(FundController.NotOwner.selector);
        controller.setDial(_openDial());
    }

    // ------------------------------------------------------------ adapters: notice, retire, max, disable, remove

    function test_AdapterEnableWaitsNoticeWithOutsiders() public {
        _fund(_openDial());
        _outsider();
        vm.prank(owner);
        address inst = controller.addAdapter(address(swapImpl), abi.encode(source, uint256(0)));
        assertFalse(controller.isAdapter(inst));
        vm.prank(manager);
        vm.expectRevert(FundController.UnknownAdapter.selector);
        controller.act(inst, abi.encode(address(usdg), address(usdg), uint256(1)));
        vm.expectRevert(FundController.NotReady.selector);
        controller.enablePendingAdapter(address(swapImpl));
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        controller.enablePendingAdapter(address(swapImpl));
        assertTrue(controller.isAdapter(inst));
    }

    function test_RetiredDuringNoticeIsNotEnabled() public {
        _fund(_openDial());
        _outsider();
        vm.prank(owner);
        controller.addAdapter(address(thiefImpl), abi.encode(uint8(1), sink));
        vm.prank(guardian);
        registry.retire(address(thiefImpl));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(FundController.RetiredAdapter.selector);
        controller.enablePendingAdapter(address(thiefImpl));
    }

    function test_CancelPendingAdapter() public {
        _fund(_openDial());
        _outsider();
        vm.prank(owner);
        controller.addAdapter(address(thiefImpl), abi.encode(uint8(1), sink));
        vm.prank(owner);
        controller.cancelPendingAdapter(address(thiefImpl));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(FundController.NotReady.selector);
        controller.enablePendingAdapter(address(thiefImpl));
    }

    function test_MaxAdapters() public {
        _fund(_openDial());
        uint256 max = controller.MAX_ADAPTERS();
        for (uint256 i = 3; i < max; ++i) _enable(address(swapImpl), abi.encode(source, uint256(0)));
        vm.prank(owner);
        vm.expectRevert(FundController.TooManyAdapters.selector);
        controller.addAdapter(address(swapImpl), abi.encode(source, uint256(0)));
        vm.startPrank(owner);
        controller.disableAdapter(lossy);
        controller.removeAdapter(lossy);
        vm.stopPrank();
        _enable(address(swapImpl), abi.encode(source, uint256(0)));
        assertEq(controller.adapters().length, max);
    }

    function test_DisableKeepsPositionsCountedAndUnwindable() public {
        _fund(_openDial());
        _lend(0, address(usdg), 300e6);
        uint256 navBefore = _navFair();
        vm.prank(stranger);
        vm.expectRevert(FundController.NotOwner.selector);
        controller.disableAdapter(lend);
        vm.prank(guardian);
        controller.disableAdapter(lend);
        assertEq(_navFair(), navBefore, "disabled positions still count");
        vm.prank(manager);
        vm.expectRevert(FundController.UnknownAdapter.selector);
        controller.act(lend, abi.encode(uint8(0), address(usdg), uint256(1e6)));
        vm.prank(manager);
        controller.unwindAdapter(lend, 1e18);
        assertEq(usdg.balanceOf(address(vault)), 1000e6);
        vm.prank(owner);
        controller.removeAdapter(lend); // empty: at once
        assertFalse(controller.isListed(lend));
    }

    function test_RemoveRules() public {
        _fund(_openDial());
        _outsider();
        _lend(0, address(usdg), 300e6);
        _lend(2, address(feed), 1e17);
        vm.prank(owner);
        vm.expectRevert(FundController.StillEnabled.selector);
        controller.removeAdapter(lend);
        vm.prank(owner);
        controller.disableAdapter(lend);
        vm.prank(owner);
        vm.expectRevert(FundController.AdapterOwes.selector);
        controller.removeAdapter(lend);
        // Repay the debt (unwind repays pro rata), keep the supply: a holding is written off only after notice.
        vm.prank(owner);
        controller.unwindAdapter(lend, 0.5e18);
        vm.prank(manager);
        controller.unwindAdapter(lend, 1e18);
        assertEq(MockLending(lend).debt(address(feed)), 0);
        _lend2Supply(100e6);
        vm.prank(owner);
        vm.expectRevert(FundController.NotReady.selector);
        controller.removeAdapter(lend);
        vm.warp(block.timestamp + 7 days);
        uint256 navBefore = _navFair();
        vm.prank(owner);
        controller.removeAdapter(lend);
        assertEq(navBefore - _navFair(), 100e18, "written off");
    }

    /// @dev Put a supply back into the disabled lending adapter directly (as if its unwind had been partial).
    function _lend2Supply(uint256 amt) internal {
        usdg.mint(lend, amt);
        vm.store(lend, keccak256(abi.encode(address(usdg), uint256(4))), bytes32(amt));
    }

    function test_BrokenAdapterMakesNavIncompleteAndCanBeRemoved() public {
        _fund(_openDial());
        address broken = _enable(address(brokenImpl), abi.encode(address(feed)));
        uint8[4] memory hows = [1, 2, 3, 5];
        for (uint256 k; k < hows.length; ++k) {
            uint8 how = hows[k];
            MockBroken(broken).set(how, 0);
            (uint256 n, bool complete, address[] memory unpriced, address[] memory failed) =
                controller.navReport(uint8(Side.Bid));
            assertFalse(complete);
            if (how == 5) {
                assertEq(unpriced.length, 1);
                assertEq(unpriced[0], address(feed));
                assertEq(failed.length, 0);
            } else {
                assertEq(failed.length, 1);
                assertEq(failed[0], broken);
            }
            assertEq(n, 1000e18, "everything else still valued");
            _swapReverts(swap, address(usdg), address(usdg), 1e6, abi.encodeWithSelector(FundController.PriceUnavailable.selector));
        }
        MockBroken(broken).set(1, 0);
        vm.startPrank(owner);
        controller.disableAdapter(broken);
        controller.removeAdapter(broken); // nobody else holds shares: at once
        vm.stopPrank();
        _swap(swap, address(usdg), address(usdg), 1e6);
    }

    function test_BrokenAdapterRemovalWaitsWithOutsiders() public {
        _fund(_openDial());
        address broken = _enable(address(brokenImpl), abi.encode(address(feed)));
        _outsider();
        MockBroken(broken).set(2, 0); // burns all gas
        vm.prank(owner);
        controller.disableAdapter(broken);
        vm.prank(owner);
        vm.expectRevert(FundController.NotReady.selector);
        controller.removeAdapter(broken);
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        controller.removeAdapter(broken);
        (, bool complete) = controller.nav(uint8(Side.Bid));
        assertTrue(complete);
    }

    // ------------------------------------------------------------ pause, revoke, expiry, roles

    function test_GuardianPauseOnlyGuardianLifts() public {
        _fund(_openDial());
        vm.prank(guardian);
        controller.setPaused(true);
        _swapReverts(swap, address(usdg), address(usdg), 1e6, abi.encodeWithSelector(FundController.IsPaused.selector));
        vm.prank(owner);
        controller.setPaused(false);
        assertTrue(controller.paused(), "owner lifted the guardian's pause");
        vm.prank(guardian);
        controller.setPaused(false);
        assertFalse(controller.paused());
        vm.prank(owner);
        controller.setPaused(true);
        vm.prank(guardian);
        controller.setPaused(false);
        assertTrue(controller.paused(), "guardian lifted the owner's pause");
        vm.prank(stranger);
        vm.expectRevert(FundController.NotGuardian.selector);
        controller.setPaused(false);
        vm.prank(owner);
        controller.setPaused(false);
        _swap(swap, address(usdg), address(usdg), 1e6);
    }

    function test_GuardianPauseBlocksOwnerUnwindOwnerPauseDoesNot() public {
        _fund(_openDial());
        _lend(0, address(usdg), 100e6);
        vm.prank(owner);
        controller.setPaused(true);
        vm.prank(manager);
        vm.expectRevert(FundController.IsPaused.selector);
        controller.unwindAdapter(lend, 0.5e18);
        vm.prank(owner);
        controller.unwindAdapter(lend, 0.5e18);
        vm.prank(guardian);
        controller.setPaused(true);
        vm.prank(owner);
        vm.expectRevert(FundController.IsPaused.selector);
        controller.unwindAdapter(lend, 0.5e18);
    }

    function test_RevokeAndExpiry() public {
        _fund(_openDial());
        vm.prank(guardian);
        controller.revokeManager();
        _swapReverts(swap, address(usdg), address(usdg), 1e6, abi.encodeWithSelector(FundController.NotManager.selector));
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(owner);
        controller.setManager(manager, exp);
        vm.warp(exp);
        _swap(swap, address(usdg), address(usdg), 1e6);
        vm.warp(exp + 1);
        _swapReverts(swap, address(usdg), address(usdg), 1e6, abi.encodeWithSelector(FundController.NotManager.selector));
        vm.prank(owner);
        vm.expectRevert(FundController.BadTerm.selector);
        controller.setManager(manager, uint64(block.timestamp + 367 days));
        vm.prank(owner);
        controller.revokeManager();
        vm.prank(stranger);
        vm.expectRevert(FundController.NotGuardian.selector);
        controller.revokeManager();
    }

    function test_OwnershipIsTwoStep() public {
        _fund(_openDial());
        vm.prank(owner);
        controller.transferOwnership(holder);
        assertEq(controller.owner(), owner);
        vm.prank(stranger);
        vm.expectRevert(FundController.NotOwner.selector);
        controller.acceptOwnership();
        vm.prank(holder);
        controller.acceptOwnership();
        assertEq(controller.owner(), holder);
    }

    function test_GuardianRecovery() public {
        _fund(_openDial());
        _outsider();
        address g2 = makeAddr("g2");
        // The guardian rotates its own key at once.
        vm.prank(guardian);
        controller.transferGuardian(g2);
        assertEq(controller.guardian(), g2);
        // A rogue guardian keeps the Fund paused; the owner replaces it after notice.
        vm.prank(g2);
        controller.setPaused(true);
        address g3 = makeAddr("g3");
        vm.prank(owner);
        controller.transferGuardian(g3);
        assertEq(controller.guardian(), g2);
        vm.expectRevert(FundController.NotReady.selector);
        controller.applyPendingGuardian();
        vm.warp(block.timestamp + 7 days);
        controller.applyPendingGuardian();
        assertEq(controller.guardian(), g3);
        vm.prank(g3);
        controller.setPaused(false);
        assertFalse(controller.paused());
        vm.prank(stranger);
        vm.expectRevert(FundController.NotGuardian.selector);
        controller.transferGuardian(stranger);
    }

    // ------------------------------------------------------------ approvals, hostile adapters, prices

    function test_ApprovalsSummedThenResetEvenWhenNotPulled() public {
        _fund(_openDial());
        address thief = _enable(address(thiefImpl), abi.encode(uint8(0), sink));
        vm.prank(manager);
        controller.act(thief, abi.encode(address(usdg), uint256(10e6)));
        assertEq(MockThief(thief).seenAllowance(), 10e6, "duplicate inputs not summed");
        assertEq(usdg.allowance(address(vault), thief), 0, "approval left after the call");
        assertEq(usdg.balanceOf(thief), 5e6);
    }

    function test_HostileAdapterReachesOnlyWhatItWasApproved() public {
        _fund(_openDial());
        address thief = _enable(address(thiefImpl), abi.encode(uint8(1), sink));
        vm.expectRevert();
        MockThief(thief).grab(address(usdg), 1);
        // Another Fund's vault is out of reach too.
        FundVault v1 = vault;
        _createFund(_openDial(), 500e6);
        vm.expectRevert();
        MockThief(thief).grab(address(usdg), 1);
        assertEq(usdg.balanceOf(address(v1)), 1000e6);
    }

    function test_HostileAdapterBoundedByLossBudget() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 200; // $20
        _fund(d);
        address thief = _enable(address(thiefImpl), abi.encode(uint8(1), sink));
        vm.prank(manager);
        controller.act(thief, abi.encode(address(usdg), uint256(40e6))); // steals $20
        vm.prank(manager);
        vm.expectPartialRevert(FundController.LossBudget.selector);
        controller.act(thief, abi.encode(address(usdg), uint256(2e6)));
        assertEq(usdg.balanceOf(sink), 20e6);
    }

    /// @dev The documented limit: an adapter that lies in `positions` can hide what it took. This is why
    ///      enabling an adapter waits the notice and unverified adapters are labelled.
    function test_MisreportingAdapterIsTrusted_DocumentedLimit() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 100;
        _fund(d);
        address liar = _enable(address(thiefImpl), abi.encode(uint8(2), sink));
        vm.prank(manager);
        controller.act(liar, abi.encode(address(usdg), uint256(400e6)));
        assertEq(usdg.balanceOf(sink), 200e6);
        assertEq(_navFair(), 1200e18, "the lie inflates NAV");
    }

    function test_UnavailablePriceOnlyMattersForNonzeroHoldings() public {
        _fund(_openDial());
        _swap(swap, address(usdg), address(pool), 10e6);
        _swap(swap, address(pool), address(usdg), 1e18); // pool balance back to zero, still tracked
        source.setDown(address(pool), true);
        _swap(swap, address(usdg), address(usdg), 1e6); // a zero balance of an unpriced token is fine
        pool.mint(address(vault), 1); // anyone can send a crumb
        (, bool complete, address[] memory unpriced,) = controller.navReport(uint8(Side.Bid));
        assertFalse(complete);
        assertEq(unpriced.length, 1);
        assertEq(unpriced[0], address(pool));
        _swapReverts(swap, address(usdg), address(usdg), 1e6, abi.encodeWithSelector(FundController.PriceUnavailable.selector));
        // AINDEX downgrades the token at once; the Fund works again.
        _price(address(pool), 10e18, PriceClass.None, 0);
        _swap(swap, address(usdg), address(usdg), 1e6);
    }

    function test_Untrack() public {
        _fund(_openDial());
        _swap(swap, address(usdg), address(pool), 10e6); // 1 POOL = $10
        _swap(swap, address(usdg), address(junk), 1e6);
        vm.startPrank(manager);
        vm.expectRevert(FundController.CannotUntrack.selector);
        controller.untrack(address(pool)); // $10 is not dust
        vm.expectRevert(FundController.CannotUntrack.selector);
        controller.untrack(address(junk)); // unpriced with a balance: holders keep an in-kind claim
        vm.expectRevert(FundController.CannotUntrack.selector);
        controller.untrack(address(usdg)); // cash, never
        controller.act(swap, abi.encode(address(pool), address(usdg), uint256(0.95e18)));
        controller.untrack(address(pool)); // $0.50 left: dust
        vm.stopPrank();
        assertFalse(vault.isTracked(address(pool)));
        vm.prank(stranger);
        vm.expectRevert(FundController.NotManager.selector);
        controller.untrack(address(junk));
    }

    // ------------------------------------------------------------ gas bounds

    function test_GasAtTheMaxima() public {
        _fund(_openDial());
        // 64 tracked tokens, each held and priced.
        uint256 maxT = vault.MAX_TRACKED();
        for (uint256 i = vault.trackedTokens().length; i < maxT; ++i) {
            MockERC20 t = new MockERC20("T", "T", 18);
            _price(address(t), 1e18, PriceClass.Feed, 10);
            t.mint(address(vault), 1e18);
            vm.prank(address(controller));
            vault.track(address(t));
        }
        // 16 adapters, each reporting four positions in tracked tokens.
        address[] memory tracked = vault.trackedTokens();
        uint256 maxA = controller.MAX_ADAPTERS();
        for (uint256 i = controller.adapters().length; i < maxA; ++i) {
            address l = _enable(address(lendImpl), "");
            for (uint256 j; j < 4; ++j) {
                address tok = tracked[(i * 4 + j) % tracked.length];
                if (tok == address(usdg)) tok = tracked[(i * 4 + j + 1) % tracked.length];
                MockERC20(tok).mint(l, 1e15);
                vm.prank(address(controller));
                MockLending(l).execute(abi.encode(uint8(0), tok, uint256(0)));
                vm.store(l, keccak256(abi.encode(tok, uint256(4))), bytes32(uint256(1e15)));
            }
        }
        vm.prank(manager);
        uint256 g = gasleft();
        controller.act(swap, abi.encode(address(usdg), address(usdg), uint256(1e6)));
        g -= gasleft();
        emit log_named_uint(string.concat("act gas at ", vm.toString(maxT), " tokens and ", vm.toString(maxA), " adapters"), g);
        assertLt(g, 15_000_000, "act too expensive at the maxima");
    }
}
