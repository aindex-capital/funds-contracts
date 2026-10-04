// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase} from "./TellerBase.t.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Teller} from "../../src/core/Teller.sol";
import {TellerQueue} from "../../src/core/TellerQueue.sol";

/// @notice The queue and the keeper's rules: who settles, how many requests an address may hold, small requests,
///         limits that cannot be met, and what a keeper may list.
contract TellerProtectionsTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function test_OnlyListedKeepersSettleUnlessOpened() public {
        uint256 a = _deposit(alice, 100e6, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        vm.prank(carol);
        vm.expectRevert(Teller.NotKeeper.selector);
        tel.settle(address(vault), bt, _noSkip());
        tel.setOpenSettlement(true);
        vm.prank(carol);
        tel.settle(address(vault), bt, _noSkip());
        vm.prank(carol);
        vm.expectRevert(Teller.NotAdmin.selector);
        tel.setKeeper(carol, true);
    }

    function test_OneAddressHoldsAtMostMaxLive() public {
        for (uint256 i; i < tel.maxLive(); ++i) _deposit(alice, 10e6, 1);
        assertEq(tel.liveRequests(address(vault), alice), tel.maxLive());
        usdg.mint(alice, 10e6);
        vm.startPrank(alice);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.TooManyRequests.selector);
        tel.requestDeposit(address(vault), 10e6, 1);
        vm.stopPrank();
    }

    function test_SettledRequestsFreeTheirPlaces() public {
        uint256 first;
        for (uint256 i; i < tel.maxLive(); ++i) {
            uint256 id = _deposit(alice, 10e6, 1);
            if (i == 0) first = id;
        }
        _settle(_batchOf(first));
        assertEq(tel.liveRequests(address(vault), alice), 0);
        _deposit(alice, 10e6, 1);
    }

    function test_WaitingDepositsKeepTheirPlaces() public {
        source.setDown(address(usdg), true);
        uint256 a = _deposit(alice, 10e6, 1);
        for (uint256 i = 1; i < tel.maxLive(); ++i) _deposit(alice, 10e6, 1);
        _settle(_batchOf(a));
        (,, bool waiting) = tel.due(a);
        assertTrue(waiting);
        assertEq(tel.liveRequests(address(vault), alice), tel.maxLive(), "still waiting, still counted");
    }

    function test_MaxLiveIsTheAdminsWithinBounds() public {
        tel.setMaxLive(1);
        assertEq(tel.maxLive(), 1);
        vm.expectRevert(Teller.BadParams.selector);
        tel.setMaxLive(0);
        uint8 tooMany = uint8(tel.MAX_LIVE() + 1);
        vm.expectRevert(Teller.BadParams.selector);
        tel.setMaxLive(tooMany);
    }

    function test_SmallRequestsAreRefused() public {
        uint256 sh = _join(alice, 100e6);
        uint256 small = tel.minDeposit() - 1;
        usdg.mint(bob, 10e6);
        vm.startPrank(bob);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.requestDeposit(address(vault), small, 1);
        vm.stopPrank();
        uint256 least = tel.minDeposit() * 1e12;
        vm.startPrank(alice);
        vault.approve(address(tel), sh);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.requestRedeem(address(vault), least - 1, 1);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.requestRedeem(address(vault), least, 0); // a cash exit needs a limit
        tel.requestRedeem(address(vault), least, 1);
        vm.stopPrank();
    }

    function test_ParamsBounds() public {
        vm.expectRevert(Teller.BadParams.selector);
        tel.setParams(0, 10e6, 1e18, 1e14, 500);
        vm.expectRevert(Teller.BadParams.selector);
        tel.setParams(10e6, 0, 1e18, 1e14, 500);
        uint256 tooBig = tel.MAX_WRITE_OFF_WAD() + 1;
        vm.expectRevert(Teller.BadParams.selector);
        tel.setParams(10e6, 10e6, 1e18, tooBig, 500);
        vm.expectRevert(Teller.BadParams.selector);
        tel.setParams(10e6, 10e6, 1e18, 1e14, 10_001);
        tel.setParams(10e6, 10e6, 1e18, 1e14, 0);
        assertEq(tel.weekendInflowBps(), 0);
    }

    function test_KeeperCannotMoveAWholeSide() public {
        uint256 bs = _join(bob, 500e6);
        uint256 a = _deposit(alice, 1000e6, 1);
        uint256 r = _redeem(bob, bs, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        uint256[] memory skip = new uint256[](2);
        skip[0] = a;
        skip[1] = r;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.NeedlessSkip.selector, a));
        tel.settle(address(vault), bt, skip);
    }

    function test_LoneSaneLimitCannotBeListed() public {
        uint256 bs = _join(bob, 500e6);
        uint256 worth = bs * _nav(0) / vault.totalSupply() / 1e12;
        uint256 r = _redeem(bob, bs, worth / 2);
        uint64 bt = _batchOf(r);
        _toCutoff(bt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.NeedlessSkip.selector, r));
        tel.settle(address(vault), bt, _one(r));
    }

    function test_ImpossibleLimitCannotHoldABatchUp() public {
        uint256 bs = _join(bob, 500e6);
        uint256 r = _redeem(bob, bs, 1_000e6); // worth about 500 USDG
        uint256 a = _deposit(alice, 100e6, 1);
        uint64 bt = _batchOf(a);
        _settleSkip(bt, _one(r));
        assertGt(tel.request(r).batch, bt, "the impossible exit moved on");
        (uint256 shares,) = _claim(a);
        assertGt(shares, 0, "the deposit settled");
    }

    function test_InALaterRoundOnlyWaitingDepositsCanBeListed() public {
        uint256 bs = _join(bob, 500e6);
        source.setDown(address(usdg), true);
        uint256 a = _deposit(alice, 100e6, 1);
        uint256 r = _redeem(bob, bs, 1);
        uint64 bt = _batchOf(a);
        _settle(bt);
        assertEq(tel.batch(address(vault), bt).rounds, 1);
        source.setDown(address(usdg), false);
        _toCutoff(bt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.BadRequest.selector, r));
        tel.settle(address(vault), bt, _one(r));
        _settle(bt);
        assertTrue(tel.batch(address(vault), bt).settled);
    }

    function test_FullBatchSpillsIntoTheNext() public {
        (uint64 b, uint64 cut) = tel.currentBatch(address(vault));
        for (uint256 i; i < tel.MAX_REQUESTS(); ++i) {
            _deposit(address(uint160(0x10000 + i)), 10e6, 1);
        }
        (uint64 next, uint64 nextCut) = tel.currentBatch(address(vault));
        assertEq(next, b + 1);
        assertEq(nextCut, cut + 1 days);
        uint256 a = _deposit(alice, 1000e6, 1);
        assertEq(_batchOf(a), b + 1);
    }

    function test_CancelGivesThePlaceBackAndUnlatches() public {
        address griefer = makeAddr("griefer");
        usdg.mint(griefer, 10e6);
        vm.startPrank(griefer);
        usdg.approve(address(tel), type(uint256).max);
        for (uint256 i; i < tel.MAX_REQUESTS(); ++i) {
            uint256 id = tel.requestDeposit(address(vault), 10e6, 1);
            tel.cancel(id);
        }
        vm.stopPrank();
        (uint64 b,) = tel.currentBatch(address(vault));
        assertEq(tel.batch(address(vault), b).count, 0);
        assertFalse(vault.hadOutsideHolder(), "cancelled deposits leave no latch behind");
        uint256 a = _deposit(alice, 1000e6, 1);
        assertEq(_batchOf(a), b);
    }

    function test_WaitingDepositReopensForCancelUntilTheNewCutoff() public {
        source.setDown(address(usdg), true);
        uint256 a = _deposit(alice, 100e6, 1);
        uint64 bt = _batchOf(a);
        _settle(bt);
        uint64 newCut = tel.batch(address(vault), bt).cutoff;
        assertGt(newCut, block.timestamp);
        vm.prank(alice);
        tel.cancel(a);
        assertEq(usdg.balanceOf(alice), 100e6);
        assertTrue(tel.batch(address(vault), bt).settled, "nothing waits in it any more");
    }

    function test_StaleRequestReturnedByAnyone() public {
        uint256 a = _deposit(alice, 100e6, 1);
        _toCutoff(_batchOf(a));
        vm.prank(carol);
        vm.expectRevert(Teller.NotReady.selector);
        tel.cancel(a);
        vm.warp(tel.request(a).madeAt + tel.STALE_AFTER());
        vm.prank(carol);
        tel.cancel(a);
        assertEq(usdg.balanceOf(alice), 100e6, "back to its owner");
    }

    function test_CashExitCannotBeCancelledAfterItsRound() public {
        uint256 bs = _join(bob, 500e6);
        uint256 r = _redeem(bob, bs, 1);
        _settle(_batchOf(r));
        vm.warp(block.timestamp + tel.STALE_AFTER());
        vm.prank(bob);
        vm.expectRevert(Teller.AlreadySettled.selector);
        tel.cancel(r);
    }
}
