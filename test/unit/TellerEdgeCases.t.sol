// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Teller} from "../../src/core/Teller.sol";
import {TellerQueue} from "../../src/core/TellerQueue.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {MockERC20} from "../utils/Mocks.sol";

/// @notice Edge cases of the cash-in teller: a keeper moving a sane request while prices are missing, and a dust exit
///         in parts that must not freeze the manager. The weekend caps are tested in TellerWeekend.t.sol.
contract TellerEdgeCasesTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    /// @notice USDG unpriced: deposits wait and leavers get their shares back, so no request's limit is judged and a
    ///         keeper may list none of them (an unknown NAV would otherwise let any listed request move).
    function test_PriceMissingNoRequestCanBeListed() public {
        uint256 bobShares = _join(bob, 500e6);
        uint256 a = _deposit(alice, 100e6, 1);
        uint256 c = _deposit(carol, 100e6, 1);
        uint256 r = _redeem(bob, bobShares, 1);
        uint64 bt = _batchOf(a);
        _toCutoff(bt);
        source.setDown(address(usdg), true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.NeedlessSkip.selector, a));
        tel.settle(address(vault), bt, _one(a));
        uint256[] memory both = new uint256[](2);
        (both[0], both[1]) = (a, c);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.NeedlessSkip.selector, a));
        tel.settle(address(vault), bt, both);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.NeedlessSkip.selector, r));
        tel.settle(address(vault), bt, _one(r));
        // Settled without a skip: everyone waits or comes back whole.
        vm.prank(keeper);
        tel.settle(address(vault), bt, _noSkip());
        (uint256 back, uint256 out) = _claim(r);
        assertEq(out, 0);
        assertEq(back, bobShares);
        (,, bool waiting) = tel.due(a);
        assertTrue(waiting);
    }

    /// @notice An exit in parts needs as many shares as a cash exit: a dust exit leaves in one transaction.
    function test_DustExitInPartsRefused() public {
        _book(0).seed(address(tokA), 1e18);
        _join(alice, 1000e6);
        uint256 dust = tel.minDeposit() * 1e12 - 1;
        vm.prank(alice);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.startInKind(address(vault), dust, alice, new address[](0));
    }

    /// @notice A small exit in parts (under `SMALL_EXIT_WAD` of the Fund) can be paid out by anyone at once, so a
    ///         manager never waits a day on it; a larger one only by its owner or recipient until `EXIT_OPEN_AFTER`.
    function test_SmallExitPaidOutByAnyoneAtOnce() public {
        MockBook bk = _book(0);
        bk.seed(address(tokA), 10e18);
        uint256 shares = _join(alice, 100_000e6);
        address[] memory one = new address[](1);
        one[0] = address(bk);

        uint256 small = tel.minDeposit() * 1e12; // 10 shares of about 100,000
        vm.prank(alice);
        uint256 id = tel.startInKind(address(vault), small, alice, new address[](0));
        assertLt(tel.exit(id).fraction, tel.SMALL_EXIT_WAD());
        vm.prank(manager);
        tel.claimInKind(id, one);
        vm.prank(manager);
        controller.act(address(bk), "");

        vm.prank(alice);
        uint256 big = tel.startInKind(address(vault), shares / 2, alice, new address[](0));
        vm.prank(manager);
        vm.expectRevert(Teller.NotReady.selector);
        tel.claimInKind(big, one);
        vm.warp(block.timestamp + tel.EXIT_OPEN_AFTER());
        vm.prank(manager);
        tel.claimInKind(big, one);
    }

    /// @notice The hold check sees a closed market even while the Fund also holds a no-market token, so the
    ///         closure's caps still apply to its cash exits (through a no-market holding).
    function test_OutflowCapAppliesWithANoMarketHolding() public {
        uint256 bobShares = _join(bob, 500e6);
        _usSession(address(tokA), 450);
        _hold(tokA, 1e18);
        MockERC20 n = new MockERC20("N", "N", 18);
        _price(address(n), 1e18, PriceClass.None, 0);
        _hold(n, 100e18);
        vm.warp(_next(SAT, 12 hours));
        assertTrue(router.marketClosed(address(tokA)));
        (ITeller.Hold hold,) = tel.depositHold(address(vault));
        assertEq(uint8(hold), uint8(ITeller.Hold.NoMarket));
        uint256 navFair = _nav(0);
        uint256 r = _redeem(bob, bobShares, 1);
        _settle(_batchOf(r));
        (uint256 back, uint256 out) = _claim(r);
        assertLe(out * 1e12, navFair * tel.weekendOutflowBps() / 10_000 + 1e12, "cash within the closure's cap");
        assertGt(back, 0);
    }
}

