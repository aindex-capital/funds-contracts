// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {TellerBase} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Teller} from "../../src/core/Teller.sol";

/// @notice Requests paid by one address for another (partner apps, zaps, embedded wallets): the receiver owns the
///         request, the payer keeps no claim on it, `maxLive` counts per payer and receiver pair, and a referrer is
///         only an event.
contract TellerReceiverTest is TellerBase {
    MockERC20 internal tokN;
    address internal zap = makeAddr("zap");

    function setUp() public {
        _setUpTeller();
        tokN = new MockERC20("No market", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
    }

    function _depositFor(address payer, address receiver, uint256 amount, bytes32 referrer)
        internal
        returns (uint256 id)
    {
        usdg.mint(payer, amount);
        vm.startPrank(payer);
        usdg.approve(address(tel), amount);
        id = tel.requestDeposit(address(vault), amount, 1, receiver, referrer);
        vm.stopPrank();
    }

    function _redeemFor(address payer, address receiver, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(payer);
        vault.approve(address(tel), shares);
        id = tel.requestRedeem(address(vault), shares, 1, receiver);
        vm.stopPrank();
    }

    function _pocketN() internal returns (uint256) {
        _hold(tokN, 100e18);
        return tel.pocket(address(vault), address(tokN), new address[](0), 0);
    }

    // ------------------------------------------------------------ deposits

    function test_DepositForReceiverGivesTheReceiverTheShares() public {
        uint256 id = _depositFor(zap, alice, 100e6, 0);
        assertEq(tel.request(id).owner, alice, "the receiver owns the request");
        assertEq(usdg.balanceOf(zap), 0, "the payer paid");
        _settle(_batchOf(id));
        (uint256 shares,) = _claim(id);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares, "the receiver got the shares");
        assertEq(vault.balanceOf(zap), 0, "the payer got none");
    }

    function test_PayerCannotCancelAndCancelRefundsTheReceiver() public {
        uint256 id = _depositFor(zap, alice, 100e6, 0);
        vm.prank(zap);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, id));
        tel.cancel(id);
        vm.prank(alice);
        tel.cancel(id);
        assertEq(usdg.balanceOf(alice), 100e6, "the refund went to the receiver");
        assertEq(usdg.balanceOf(zap), 0);
    }

    function test_StaleReturnGoesToTheReceiver() public {
        uint256 id = _depositFor(zap, alice, 100e6, 0);
        vm.warp(block.timestamp + tel.STALE_AFTER());
        vm.prank(carol); // anyone, once stale
        tel.cancel(id);
        assertEq(usdg.balanceOf(alice), 100e6);
        assertEq(usdg.balanceOf(zap), 0);
    }

    function test_SkippedDepositPaidBackToTheReceiver() public {
        usdg.mint(zap, 100e6);
        vm.startPrank(zap);
        usdg.approve(address(tel), 100e6);
        uint256 id = tel.requestDeposit(address(vault), 100e6, type(uint128).max, alice, 0);
        vm.stopPrank();
        _settleSkip(_batchOf(id), _one(id)); // moved once
        _settleSkip(_batchOf(id), _one(id)); // fails again: paid back
        assertEq(uint8(tel.request(id).status), uint8(ITeller.Status.Skipped));
        _claim(id);
        assertEq(usdg.balanceOf(alice), 100e6);
        assertEq(usdg.balanceOf(zap), 0);
    }

    function test_OutsideLatchFollowsTheReceiver() public {
        _depositFor(alice, owner, 100e6, 0); // an outsider paying for the owner: the owner gets the shares
        assertFalse(vault.hadOutsideHolder(), "shares for the owner latch nothing");
        _depositFor(owner, alice, 100e6, 0); // the owner paying for an outsider
        assertTrue(vault.hadOutsideHolder(), "shares for an outsider latch");
    }

    function test_BadReceiverRefused() public {
        address[3] memory bad = [address(0), address(vault), address(tel)];
        for (uint256 i; i < 3; ++i) {
            usdg.mint(zap, 100e6);
            vm.startPrank(zap);
            usdg.approve(address(tel), 100e6);
            vm.expectRevert(Teller.BadReceiver.selector);
            tel.requestDeposit(address(vault), 100e6, 1, bad[i], 0);
            vm.stopPrank();
        }
    }

    function test_OldSignaturesActForTheCaller() public {
        uint256 d = _deposit(alice, 100e6, 1);
        assertEq(tel.request(d).owner, alice);
        uint256 s = _join(bob, 100e6);
        uint256 r = _redeem(bob, s, 1);
        assertEq(tel.request(r).owner, bob);
    }

    // ------------------------------------------------------------ cash exits

    function test_RedeemForReceiverPaysTheReceiver() public {
        uint256 s = _join(bob, 500e6);
        uint256 id = _redeemFor(bob, carol, s);
        assertEq(tel.request(id).owner, carol);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, id));
        tel.cancel(id);
        _settle(_batchOf(id));
        (, uint256 out) = _claim(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(carol), out, "the USDG went to the receiver");
        assertEq(usdg.balanceOf(bob), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    /// @notice While nobody but the owner holds the Fund, the owner's cash exit pays only the owner: a claim for
    ///         someone else would escape the 7-day notice that guards outside holders. Once others hold, it may.
    function test_OwnerOnlyFundCashExitsPayOnlyTheCaller() public {
        assertFalse(vault.hadOutsideHolder());
        uint256 s = _join(owner, 500e6) / 2; // the owner adds to its own Fund: still nobody else
        vm.startPrank(owner);
        vault.approve(address(tel), s);
        vm.expectRevert(Teller.BadReceiver.selector);
        tel.requestRedeem(address(vault), s, 1, carol);
        tel.requestRedeem(address(vault), s, 1, owner); // paying itself is fine
        vm.stopPrank();
        uint256 b = _join(bob, 500e6);
        assertTrue(vault.hadOutsideHolder());
        uint256 id = _redeemFor(bob, carol, b); // with outside holders, a receiver is allowed
        assertEq(tel.request(id).owner, carol);
    }

    function test_CancelledRedeemReturnsSharesToTheReceiver() public {
        uint256 s = _join(bob, 500e6);
        uint256 id = _redeemFor(bob, carol, s);
        vm.prank(carol);
        tel.cancel(id);
        assertEq(vault.balanceOf(carol), s);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_StrangerCannotRedeemAnothersShares() public {
        uint256 s = _join(bob, 500e6);
        vm.prank(bob);
        vault.approve(address(tel), s); // bob is ready to redeem: his allowance is the teller's
        vm.startPrank(carol);
        vm.expectRevert();
        tel.requestRedeem(address(vault), s, 1, carol);
        vm.expectRevert();
        tel.requestRedeem(address(vault), s, 1, bob);
        vm.expectRevert();
        tel.requestRedeem(address(vault), s, 1);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), s, "bob's shares stay his");
    }

    // ------------------------------------------------------------ maxLive

    function test_NobodyFillsAnothersPlaces() public {
        uint256 max = tel.maxLive();
        for (uint256 i; i < max; ++i) {
            _depositFor(carol, alice, 10e6, 0); // carol fills her places for alice
        }
        usdg.mint(carol, 10e6);
        vm.startPrank(carol);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.TooManyRequests.selector);
        tel.requestDeposit(address(vault), 10e6, 1, alice, 0);
        vm.stopPrank();
        assertEq(tel.liveRequests(address(vault), carol, alice), max);
        assertEq(tel.liveRequests(address(vault), alice), 0, "alice's own places are untouched");
        // Alice still has all her own places, and another payer has its own for her.
        for (uint256 i; i < max; ++i) {
            _deposit(alice, 10e6, 1);
            _depositFor(zap, alice, 10e6, 0);
        }
        assertEq(tel.liveRequests(address(vault), alice), max);
        assertEq(tel.liveRequests(address(vault), zap, alice), max);
        // And carol's own places are hers alone, too.
        _deposit(carol, 10e6, 1);
        assertEq(tel.liveRequests(address(vault), carol), 1);
    }

    function test_PlacesPerPayerAndReceiverForCashExits() public {
        uint256 s = _join(bob, 500e6);
        uint256 max = tel.maxLive();
        uint256 part = s / (max + 1);
        for (uint256 i; i < max; ++i) {
            _redeemFor(bob, carol, part);
        }
        vm.startPrank(bob);
        vault.approve(address(tel), part);
        vm.expectRevert(Teller.TooManyRequests.selector);
        tel.requestRedeem(address(vault), part, 1, carol);
        vm.stopPrank();
        _redeem(bob, part, 1); // bob's own place for himself is still free
    }

    // ------------------------------------------------------------ referrer

    function test_ReferrerOnlyEmitted() public {
        bytes32 ref = bytes32(uint256(uint160(makeAddr("partner"))));
        uint256 expected = tel.nextId();
        usdg.mint(zap, 100e6);
        vm.startPrank(zap);
        usdg.approve(address(tel), 100e6);
        vm.expectEmit(true, true, true, true, address(tel));
        emit ITeller.Referred(address(vault), expected, ref);
        uint256 a = tel.requestDeposit(address(vault), 100e6, 1, alice, ref);
        vm.stopPrank();
        uint256 b = _depositFor(zap, bob, 100e6, 0);
        // The referrer is in no storage: both requests read alike.
        ITeller.Request memory ra = tel.request(a);
        ITeller.Request memory rb = tel.request(b);
        assertEq(ra.amount, rb.amount);
        assertEq(ra.min, rb.min);
        assertEq(ra.batch, rb.batch);
        _settle(_batchOf(a));
        (uint256 sa,) = _claim(a);
        (uint256 sb,) = _claim(b);
        assertEq(sa, sb, "a referred deposit gets exactly what an unreferred one does");
    }

    function test_NoReferredEventWithoutReferrer() public {
        vm.recordLogs();
        _depositFor(zap, alice, 100e6, 0);
        _deposit(alice, 100e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ITeller.Referred.selector, "no Referred event");
        }
    }

    // ------------------------------------------------------------ pockets

    function test_UnclaimedDepositCustodyIsTheReceivers() public {
        uint256 d = _depositFor(zap, alice, 200e6, 0);
        _settle(_batchOf(d));
        (uint256 shares,,) = tel.due(d);
        uint256 p = _pocketN();
        _claim(d);
        assertEq(tel.custodyAt(address(vault), p, alice), shares);
        assertEq(tel.custodyAt(address(vault), p, zap), 0);
        assertGt(pockets.due(address(vault), p, alice), 0);
        assertEq(pockets.due(address(vault), p, zap), 0);
    }

    function test_EscrowedCashExitCustodyIsTheReceivers() public {
        uint256 s = _join(bob, 500e6);
        uint256 r = _redeemFor(bob, carol, s);
        uint256 p = _pocketN(); // while the exit waits
        _settle(_batchOf(r));
        _claim(r);
        assertEq(tel.custodyAt(address(vault), p, carol), s);
        assertEq(tel.custodyAt(address(vault), p, bob), 0);
        assertGt(pockets.due(address(vault), p, carol), 0);
        assertEq(pockets.due(address(vault), p, bob), 0);
    }
}
