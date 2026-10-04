// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase} from "./TellerBase.t.sol";
import {Teller} from "../../src/core/Teller.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {MockERC20} from "../utils/Mocks.sol";

/// @notice A Fund holding tokens priced from pools (classes Pool and Thin) takes deposits and pays cash per 24-hour
///         window up to `poolFlowBps` of NAV divided by the share of NAV in such tokens (never under the floor,
///         `poolFlowFloorUsd`), so a pool price held off market for a whole window can cost the holders at most that
///         much times how far it was bent. A deposit larger than the room left goes in in part over the windows.
contract TellerPoolFlowTest is TellerBase {
    MockERC20 internal tokP;

    function setUp() public {
        _setUpTeller();
        tokP = new MockERC20("Pool token", "P", 18);
        _price(address(tokP), 100e18, PriceClass.Pool, 0);
        _hold(tokP, 10e18); // $1,000 of a $2,000 Fund: half in a pool-priced token
        vm.warp(_next(MON, 15 hours));
        tel.setPoolFlowFloor(0); // the cap alone; the floor has its own tests below
    }

    function test_DepositsOverTheCapWaitForTheNextCutoff() public {
        // Cap: 5% of $2,000 / 50% = $200 this interval.
        uint256 a = _deposit(alice, 150e6, 1);
        uint256 b = _deposit(bob, 100e6, 1);
        uint256 part = tel.nextId();
        uint64 bt = _batchOf(a);
        vm.expectEmit(true, true, false, false, address(tel));
        emit ITeller.DepositsWait(address(vault), bt, 0, 0, 0, address(0));
        _settle(bt);
        assertEq(tel.request(a).round, 1, "within the cap");
        assertEq(tel.request(b).round, 0, "over it: the rest waits");
        assertApproxEqAbs(tel.request(part).amount, 50e6, 1e3, "the room left went in as a part of bob's");
        Teller.Flow memory f = tel.flow(address(vault));
        assertApproxEqAbs(f.cap, 200e18, 1e12);
        assertApproxEqAbs(f.inflow, 200e18, 1e12);
        // The next cut-off is in a new day, with a fresh cap.
        _settle(bt);
        assertTrue(tel.batch(address(vault), bt).settled);
        (uint256 sb,) = _claim(b);
        assertGt(sb, 0);
    }

    function test_WaitReasonIsThePoolFlowCap() public {
        uint256 a = _deposit(alice, 300e6, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        (uint64 next,) = tel.currentBatch(address(vault));
        // $200 of the cap goes in (a part); the other $100 waits.
        vm.expectEmit(true, true, false, false, address(tel));
        emit ITeller.DepositsWait(address(vault), bt, next, 100e6, tel.WAIT_POOL_FLOW(), address(0));
        vm.prank(keeper);
        tel.settle(address(vault), bt, _noSkip());
    }

    function test_CapScalesWithTheShareInPoolTokens() public {
        _hold(tokP, 30e18); // now $4,000 of $5,000: 80%
        uint256 a = _deposit(alice, 400e6, 1);
        _settle(_batchOf(a));
        // Cap: 5% of $5,000 / 80% = $312.50.
        assertApproxEqAbs(tel.flow(address(vault)).cap, 312.5e18, 1e12);
        assertEq(tel.request(a).round, 0, "a single deposit over the cap: the rest of it waits");
        assertApproxEqAbs(tel.request(a).amount, 87.5e6, 1e3, "the cap's worth went in");
    }

    function test_NoPoolTokensNoCap() public {
        _price(address(tokP), 100e18, PriceClass.Feed, 0); // the same token, now priced by a feed
        uint256 a = _deposit(alice, 5_000e6, 1);
        _settle(_batchOf(a));
        assertTrue(tel.batch(address(vault), _batchOf(a)).settled);
        assertEq(tel.flow(address(vault)).cap, 0, "never started");
    }

    function test_CashOutOverTheCapComesBackAsShares() public {
        tel.setPoolFlowBps(10_000);
        uint256 bobShares = _join(bob, 1_000e6);
        tel.setPoolFlowBps(500);
        vm.warp(_next(MON, 15 hours)); // a new interval
        uint256 navFair = _nav(0);
        uint256 r = _redeem(bob, bobShares, 1);
        _settle(_batchOf(r));
        (uint256 back, uint256 out) = _claim(r);
        Teller.Flow memory f = tel.flow(address(vault));
        assertLe(out * 1e12, f.cap + 1e12, "cash within the cap");
        assertApproxEqAbs(f.cap, navFair * 500 / 10_000 * navFair / 1_000e18, 1e15);
        assertGt(back, 0, "the rest back in shares, to leave in kind");
        vm.prank(bob);
        tel.redeemInKind(address(vault), back, bob);
    }

    /// @notice A Fund mostly in pool-priced tokens with a small NAV takes a normal
    ///         deposit: the cap is never under the floor, and a deposit above it goes in in parts over the days,
    ///         keeping its id and limit for the rest.
    function test_FloorAndPartsTakeAnHonestDepositAboveTheCap() public {
        tel.setPoolFlowFloor(250e18); // the cap alone would be 5% of $2,000 / 50% = $200
        uint256 a = _deposit(alice, 600e6, 1);
        uint64 bt = _batchOf(a);
        uint256 p1 = tel.nextId();
        _settle(bt);
        assertApproxEqAbs(tel.flow(address(vault)).cap, 250e18, 1, "the floor");
        assertEq(tel.request(p1).amount, 250e6, "a part went in");
        assertEq(tel.request(a).amount, 350e6);
        uint256 p2 = tel.nextId();
        _settle(bt); // the next day
        assertGt(tel.request(p2).amount, 0, "another part");
        for (uint256 d; d < 3 && !tel.batch(address(vault), bt).settled; ++d) _settle(bt);
        assertTrue(tel.batch(address(vault), bt).settled, "all of it went in within days");
        (,, bool waits) = tel.due(a);
        assertFalse(waits, "the last of it went in under its own id");
        (uint256 s1,) = _claim(p1);
        (uint256 s2,) = _claim(p2);
        (uint256 s3,) = _claim(a);
        assertGt(s1 * s2 * s3, 0);
    }

    /// @notice The cap is per 24-hour window whatever the Fund's cut-offs: hourly cut-offs
    ///         share one cap a day, and changing the schedule does not start a new one.
    function test_CapIsPerDayWhateverTheCutoffs() public {
        vm.prank(owner);
        tel.setSchedule(address(vault), 1 hours, 0);
        uint256 a = _deposit(alice, 150e6, 1);
        _settle(_batchOf(a));
        uint256 taken = tel.flow(address(vault)).inflow;
        uint64 until = tel.flow(address(vault)).until;
        assertEq(until % 1 days, 0, "ends at 00:00 UTC");
        for (uint256 h; h < 4; ++h) {
            uint256 d = _deposit(makeAddr(string(abi.encode(h))), 100e6, 1);
            _settle(_batchOf(d));
        }
        assertApproxEqAbs(tel.flow(address(vault)).inflow, 200e18, 1e12, "one cap for the day");
        assertGt(tel.flow(address(vault)).inflow, taken);
        vm.prank(owner);
        tel.setSchedule(address(vault), 2 hours, 0);
        assertEq(tel.flow(address(vault)).until, until, "a new schedule does not reset it");
    }

    function test_FloorSetterAdminOnlyAndBounded() public {
        vm.prank(alice);
        vm.expectRevert(Teller.NotAdmin.selector);
        tel.setPoolFlowFloor(100e18);
        uint256 max = tel.MAX_POOL_FLOW_FLOOR();
        vm.expectRevert(Teller.BadParams.selector);
        tel.setPoolFlowFloor(max + 1);
        tel.setPoolFlowFloor(max);
        assertEq(tel.poolFlowFloorUsd(), 1_000e18);
    }

    function test_SetterAdminOnlyAndZeroTakesNothing() public {
        vm.prank(alice);
        vm.expectRevert(Teller.NotAdmin.selector);
        tel.setPoolFlowBps(100);
        vm.expectRevert(Teller.BadParams.selector);
        tel.setPoolFlowBps(10_001);
        tel.setPoolFlowBps(0);
        tel.setPoolFlowFloor(250e18); // no floor under a cap of zero
        uint256 a = _deposit(alice, 50e6, 1);
        _settle(_batchOf(a));
        assertEq(tel.request(a).round, 0, "nothing goes in while it holds pool-priced tokens");
    }
}
