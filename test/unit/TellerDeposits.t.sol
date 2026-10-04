// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Teller} from "../../src/core/Teller.sol";
import {TellerQueue} from "../../src/core/TellerQueue.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {FundController} from "../../src/core/FundController.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

contract TellerOpenTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function test_OpeningDepositMintsOneSharePerUsdgToTheOwnersWallet() public view {
        assertEq(vault.totalSupply(), 1000e18 + tel.DEAD_SHARES(), "the opening deposit plus the supply floor");
        assertEq(vault.balanceOf(address(tel)), tel.DEAD_SHARES(), "only the floor is held by the teller");
        assertEq(vault.balanceOf(owner), 1000e18, "ordinary shares in the owner's wallet");
        assertEq(tel.owed(address(vault)), 0, "nothing in custody");
        assertEq(usdg.balanceOf(address(vault)), STAKE);
        assertFalse(vault.hadOutsideHolder(), "the owner's own shares are not an outside holder");
        assertEq(vault.outsideHolderSince(), 0);
    }

    function test_DefaultMinimumIsTenUsdgAndAdminCanRaiseItForNewFunds() public {
        assertEq(tel.minOpeningStake(), 10e6);
        usdg.mint(alice, 9e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 9e6);
        vm.expectRevert(Teller.StakeTooSmall.selector);
        tel.createFund("A", "A", _openDial(), 9e6, 0, 0);
        vm.stopPrank();
        tel.setParams(50e6, 1e6, 1e18, 1e14, 500);
        // A Fund already open is untouched; a new one needs the new minimum.
        assertEq(vault.balanceOf(owner), 1000e18);
        usdg.mint(alice, 41e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 50e6);
        tel.createFund("A", "A", _openDial(), 50e6, 0, 0);
        vm.stopPrank();
    }

    function test_OnlyOwnerOpensAFactoryFundOnce() public {
        (FundVault v,) = factory.create("X", "X", owner, address(tel), _openDial());
        usdg.mint(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(Teller.NotOwner.selector);
        tel.open(address(v), 100e6, 0, 0);
        // A vault that names another teller cannot be opened here.
        (FundVault w,) = factory.create("Y", "Y", owner, address(teller), _openDial());
        vm.prank(owner);
        vm.expectRevert(Teller.NotFund.selector);
        tel.open(address(w), 100e6, 0, 0);
        // Opened once only.
        usdg.mint(owner, 100e6);
        vm.prank(owner);
        usdg.approve(address(tel), 100e6);
        vm.prank(owner);
        vm.expectRevert(Teller.AlreadyOpen.selector);
        tel.open(address(vault), 100e6, 0, 0);
    }

    function test_DepositsWaitForOpening() public {
        (FundVault v,) = factory.create("X", "X", owner, address(tel), _openDial());
        usdg.mint(alice, 10e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.NotOpen.selector);
        tel.requestDeposit(address(v), 10e6, 1);
        vm.stopPrank();
    }

    function test_OwnerOnlyFundStillChangesAtOnce() public {
        // The stake sits in the teller's custody, yet the dial shortcut (no outside holders) still applies.
        Dial memory d = _openDial();
        d.dailyLossBps = 10_000;
        d.maxThinBps = 0;
        vm.prank(owner);
        controller.setDial(d);
        assertEq(controller.pendingDialAt(), 0);
        d.maxThinBps = 10_000; // a raise
        vm.prank(owner);
        controller.setDial(d);
        assertEq(controller.pendingDialAt(), 0, "raise applies at once with no outside holder");
    }
}

contract TellerRequestTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function test_DepositEscrowsInTellerNeverInVaultAndLatches() public {
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        _deposit(alice, 500e6, 0);
        assertEq(usdg.balanceOf(address(tel)), 500e6);
        assertEq(usdg.balanceOf(address(vault)), vaultBefore);
        assertEq(tel.owed(address(usdg)), 500e6);
        assertTrue(vault.hadOutsideHolder(), "a queued outsider latches");
        // From now on a riskier dial waits the notice.
        Dial memory d = _openDial();
        d.maxThinBps = 1000;
        vm.prank(owner);
        controller.setDial(d);
        d.maxThinBps = 2000;
        vm.prank(owner);
        controller.setDial(d);
        assertGt(controller.pendingDialAt(), 0);
    }

    function test_OwnerDepositDoesNotLatch() public {
        _deposit(owner, 100e6, 0);
        assertFalse(vault.hadOutsideHolder());
    }

    function test_MinimumDepositAndPause() public {
        assertEq(tel.minDeposit(), 10e6, "10 USDG at deployment");
        assertEq(tel.minOpeningStake(), 10e6, "the opening stake is not tied to it");
        usdg.mint(alice, 10e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.requestDeposit(address(vault), 10e6 - 1, 1);
        vm.stopPrank();
        vm.prank(guardian);
        controller.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert(Teller.DepositsPaused.selector);
        tel.requestDeposit(address(vault), 10e6, 0);
        vm.stopPrank();
    }

    function test_CancelBeforeCutoffThenFrozenThenStale() public {
        uint256 a = _deposit(alice, 100e6, 0);
        uint256 b = _deposit(bob, 100e6, 0);
        vm.prank(alice);
        tel.cancel(a);
        assertEq(usdg.balanceOf(alice), 100e6);
        assertEq(tel.owed(address(usdg)), 100e6);
        _toCutoff(_batchOf(b));
        vm.prank(bob);
        vm.expectRevert(Teller.NotReady.selector);
        tel.cancel(b);
        vm.warp(block.timestamp + tel.STALE_AFTER());
        vm.prank(bob);
        tel.cancel(b);
        assertEq(usdg.balanceOf(bob), 100e6);
        assertEq(tel.owed(address(usdg)), 0);
    }

    function test_OnlyRequesterCancels() public {
        uint256 a = _deposit(alice, 100e6, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, a));
        tel.cancel(a);
    }

    function test_DefaultCutoffIsDaily2100Utc() public {
        vm.warp(10 days + 3 hours);
        uint256 a = _deposit(alice, 100e6, 0);
        uint64 bt = _batchOf(a);
        assertEq(tel.batch(address(vault), bt).cutoff, 10 days + 21 hours);
        vm.warp(10 days + 21 hours);
        uint256 b = _deposit(bob, 100e6, 0);
        assertEq(tel.batch(address(vault), _batchOf(b)).cutoff, 11 days + 21 hours);
        assertEq(_batchOf(b), bt + 1);
    }

    function test_ShorterIntervalsForNewBatches() public {
        vm.prank(owner);
        tel.setSchedule(address(vault), 4 hours, 1 hours);
        vm.warp(20 days + 30 minutes);
        _deposit(alice, 100e6, 0); // joins the batch opened under the old schedule
        vm.warp(21 days + 22 hours);
        uint256 b = _deposit(bob, 100e6, 0);
        assertEq(tel.batch(address(vault), _batchOf(b)).cutoff, 22 days + 1 hours);
        vm.prank(owner);
        vm.expectRevert(Teller.BadSchedule.selector);
        tel.setSchedule(address(vault), 30 minutes, 0);
    }

    function test_SettleOnlyAfterCutoffAndOnce() public {
        uint256 a = _deposit(alice, 100e6, 0);
        uint64 bt = _batchOf(a);
        uint64 b = bt;
        vm.expectRevert(Teller.NotReady.selector);
        tel.settle(address(vault), b, _noSkip());
        _settle(b);
        vm.expectRevert(Teller.AlreadySettled.selector);
        tel.settle(address(vault), b, _noSkip());
    }

    function test_BatchHoldsAtMostMaxRequests() public {
        uint256 first = _deposit(address(uint160(0x5000)), 10e6, 0);
        for (uint256 i = 1; i < tel.MAX_REQUESTS(); ++i) {
            _deposit(address(uint160(0x5000 + i)), 10e6, 0);
        }
        uint64 b = _batchOf(first);
        assertEq(tel.batch(address(vault), b).count, tel.MAX_REQUESTS());
        uint256 late = _deposit(alice, 10e6, 0);
        assertEq(_batchOf(late), b + 1, "a full batch sends the next request on");
    }
}

/// @notice Cash in at NAV: the net entrants' USDG goes into the vault as cash and they get shares at the ask NAV
///         per share; nobody is swapped for, no adapter is touched.
contract TellerCashEntryTest is TellerBase {
    MockBook internal book;

    function setUp() public {
        _setUpTeller();
        // The manager's past: 300 USDG of the stake became 2 A in the vault, and the adapter holds 1 A.
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 300e6);
        _hold(tokA, 2e18);
        book = _book(0);
        book.seed(address(tokA), 1e18);
        _price(address(tokA), 100e18, PriceClass.Feed, 200); // a 2% haircut: ask 102, bid 98
    }

    function test_MintsAtTheAskNavPerShare() public {
        uint256 supply = vault.totalSupply();
        uint256 askNav = _nav(2);
        uint256 id = _deposit(alice, 1000e6, 1);
        uint64 bt = _batchOf(id);
        _settle(bt);
        (uint256 shares,) = _claim(id);
        assertEq(shares, 1000e18 * supply / askNav, "shares = USD in x supply / ask NAV");
        ITeller.Round memory r = tel.round(address(vault), bt, 1);
        assertEq(r.dep, 1000e6);
        assertEq(r.minted, shares);
        assertEq(r.askPerShare, askNav * WAD / supply);
        assertTrue(tel.batch(address(vault), bt).settled);
    }

    function test_UsdgGoesIntoTheVaultAndNothingElseMoves() public {
        uint256 cash = usdg.balanceOf(address(vault));
        uint256 a = tokA.balanceOf(address(vault));
        uint256 inBook = book.amt(address(tokA));
        uint256 id = _deposit(alice, 700e6, 1);
        _settle(_batchOf(id));
        assertEq(usdg.balanceOf(address(vault)), cash + 700e6);
        assertEq(tokA.balanceOf(address(vault)), a, "nothing bought");
        assertEq(book.amt(address(tokA)), inBook, "no adapter grown");
        assertEq(usdg.balanceOf(address(tel)), 0, "nothing left in escrow");
        assertEq(tel.owed(address(usdg)), 0);
    }

    function test_HoldersAreNotDilutedAtFair() public {
        uint256 before = _navPerShare();
        _join(alice, 5000e6);
        assertGe(_navPerShare(), before, "the entrant pays the ask: fair NAV per share does not fall");
    }

    function test_DepositorsShareTheRoundProRata() public {
        uint256 a = _deposit(alice, 300e6, 1);
        uint256 b = _deposit(bob, 100e6, 1);
        _settle(_batchOf(a));
        (uint256 sa,) = _claim(a);
        (uint256 sb,) = _claim(b);
        assertApproxEqAbs(sa, sb * 3, 3);
        assertEq(vault.balanceOf(address(tel)), tel.DEAD_SHARES(), "all paid out");
    }

    function test_MissingPriceMakesDepositsWaitNotRefunded() public {
        uint256 a = _deposit(alice, 500e6, 1);
        uint64 bt = _batchOf(a);
        source.setDown(address(tokA), true);
        _settle(bt);
        (uint256 sh, uint256 usd, bool waiting) = tel.due(a);
        assertEq(sh, 0);
        assertEq(usd, 500e6);
        assertTrue(waiting);
        assertFalse(tel.batch(address(vault), bt).settled);
        assertEq(tel.batch(address(vault), bt).deposits, 500e6);
        // The owner can take it back before the new cut-off; the next round takes it once the price is back.
        source.setDown(address(tokA), false);
        _settle(bt);
        (sh,, waiting) = tel.due(a);
        assertGt(sh, 0);
        assertFalse(waiting);
        assertEq(tel.batch(address(vault), bt).rounds, 2);
    }

    function test_MinSharesIsAPriceAndAZeroLimitIsRefused() public {
        usdg.mint(alice, 100e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 100e6);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.requestDeposit(address(vault), 100e6, 0);
        vm.stopPrank();
        uint256 fair = _sharesAtAsk(100e6);
        uint256 tight = _deposit(alice, 100e6, fair + 1e18); // asks for more than the ask NAV gives
        uint256 ok = _deposit(bob, 100e6, fair / 2);
        uint64 bt = _batchOf(tight);
        _toCutoff(bt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.MinNotMet.selector, tight));
        tel.settle(address(vault), bt, _noSkip());
        _settleSkip(bt, _one(tight));
        assertEq(tel.request(tight).batch, bt + 1, "moved to the next batch");
        (uint256 sb,) = _claim(ok);
        assertGe(sb, fair / 2);
    }

    function test_SkipOnlyWhenTheLimitWouldFail() public {
        uint256 a = _deposit(alice, 100e6, 1);
        uint256 b = _deposit(bob, 100e6, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.NeedlessSkip.selector, a));
        tel.settle(address(vault), bt, _one(a));
        _settle(bt);
        assertGt(tel.round(address(vault), bt, 1).minted, 0);
        b;
    }

    function test_ImpossibleLimitMovesOnceThenIsPaidBack() public {
        uint256 x = _deposit(alice, 100e6, type(uint128).max);
        uint64 bt = _batchOf(x);
        _settleSkip(bt, _one(x));
        uint64 next = tel.request(x).batch;
        assertEq(next, bt + 1);
        _settleSkip(next, _one(x));
        assertEq(uint8(tel.request(x).status), uint8(ITeller.Status.Skipped));
        (uint256 sh, uint256 back) = _claim(x);
        assertEq(sh, 0);
        assertEq(back, 100e6);
        assertEq(usdg.balanceOf(alice), 100e6);
    }

    function test_FastPathAgreesWithTheFullLoop() public {
        // Limits just at the ask price: the tightest one sets `depTight`; the round meets it, so no request is read.
        uint256 fair = _sharesAtAsk(100e6);
        uint256 a = _deposit(alice, 100e6, fair - 1e9);
        uint256 b = _deposit(bob, 200e6, 1);
        uint64 bt = _batchOf(a);
        assertEq(tel.batch(address(vault), bt).depTight, TellerQueue.tight(fair - 1e9, 100e6));
        uint256 snap = vm.snapshotState();
        _settle(bt);
        (uint256 sa,) = _claim(a);
        assertGe(sa, fair - 1e9, "the fast path never lets a limit fail");
        vm.revertToState(snap);
        // A limit one share over what the round gives: the fast path does not apply and the loop catches it.
        uint256 c = _deposit(carol, 100e6, fair + 1e18);
        uint64 bc = _batchOf(c);
        if (bc == bt) {
            _toCutoff(bt);
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(TellerQueue.MinNotMet.selector, c));
            tel.settle(address(vault), bt, _noSkip());
        }
        b;
    }

    function test_WindDownPaysEveryDepositBack() public {
        uint256 a = _deposit(alice, 100e6, 1);
        vm.prank(owner);
        tel.windDown(address(vault));
        usdg.mint(bob, 10e6);
        vm.startPrank(bob);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.WindingDown.selector);
        tel.requestDeposit(address(vault), 10e6, 1);
        vm.stopPrank();
        uint256 cash = usdg.balanceOf(address(vault));
        _settle(_batchOf(a));
        (uint256 sh, uint256 back) = _claim(a);
        assertEq(sh, 0);
        assertEq(back, 100e6);
        assertEq(usdg.balanceOf(address(vault)), cash, "the Fund takes no more money");
    }

    function test_WorksWhileTheManagerIsRevoked() public {
        vm.prank(guardian);
        controller.revokeManager();
        uint256 a = _deposit(alice, 100e6, 1);
        _settle(_batchOf(a));
        (uint256 sh,) = _claim(a);
        assertGt(sh, 0);
    }

    function test_CashViewShowsNewCashToInvest() public {
        uint256 a = _deposit(alice, 250e6, 1);
        (uint256 cash_, uint256 queued, uint256 queuedShares,,, uint64 at) = tel.cash(address(vault));
        assertEq(cash_, usdg.balanceOf(address(vault)));
        assertEq(queued, 250e6);
        assertEq(queuedShares, 0);
        assertEq(at, 0);
        _settle(_batchOf(a));
        uint256 lastNav;
        uint256 lastCash;
        (cash_, queued,, lastNav, lastCash, at) = tel.cash(address(vault));
        assertEq(queued, 0);
        assertEq(cash_, lastCash);
        assertEq(at, block.timestamp);
        assertApproxEqRel(lastNav, _nav(0), 1e12, "NAV after the settlement");
    }

    function test_DonationCannotMakeAnEntrantLoseMoreThanRounding() public {
        // The owner leaves all but one wei of its shares, then donates: dead shares keep the supply from vanishing.
        uint256 st = vault.balanceOf(owner);
        vm.prank(owner);
        tel.redeemInKind(address(vault), st - 1, owner);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES() + 1);
        usdg.mint(address(vault), 10_000e6); // a donation
        uint256 a = _deposit(alice, 19_900e6, 1);
        _settle(_batchOf(a));
        (uint256 sh,) = _claim(a);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        uint256 got = usdg.balanceOf(alice) + tokA.balanceOf(alice) * 98 / 1e12; // A at bid
        assertGe(got, 19_900e6 * 9_799 / 10_000, "at most the ask spread and rounding");
    }
}
