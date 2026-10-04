// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {MockERC20} from "../utils/Mocks.sol";

/// @notice Cash in at NAV: deposits enter as cash and are minted at the ask NAV, leavers are paid from the Fund's
///         USDG at the bid NAV, matched inside a batch at fair.
contract TellerCashInTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function test_DepositEntersAsCashAtAsk() public {
        _price(address(tokA), 100e18, PriceClass.Feed, 100); // 1% haircut: ask 101
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 500e6);
        _hold(tokA, 5e18); // $500 of A next to $500 of USDG
        uint256 expect = _sharesAtAsk(1000e6);
        uint256 cashBefore = usdg.balanceOf(address(vault));
        uint256 id = _deposit(alice, 1000e6, 1);
        _settle(_batchOf(id));
        (uint256 shares, uint256 back) = _claim(id);
        assertEq(back, 0);
        assertEq(shares, expect, "minted at the ask NAV per share");
        assertEq(usdg.balanceOf(address(vault)), cashBefore + 1000e6, "the USDG went into the vault as cash");
        assertLt(shares, 1000e18, "below fair: the holders it joins are not diluted");
    }

    function test_MatchedAtFairAndNetLeaverPaidFromCashAtBid() public {
        uint256 bobShares = _join(bob, 1000e6);
        uint256 r = _redeem(bob, bobShares, 1);
        uint256 a = _deposit(alice, 300e6, 1);
        uint64 bt = _batchOf(r);
        assertEq(bt, _batchOf(a));
        _settle(bt);
        ITeller.Batch memory b = tel.batch(address(vault), bt);
        assertGt(b.matchedShares, 0);
        assertEq(b.matchedUsdg, 300e6);
        (uint256 sa,) = _claim(a);
        assertEq(sa, b.matchedShares);
        (uint256 back, uint256 out) = _claim(r);
        assertEq(back, 0);
        assertApproxEqAbs(out, 1000e6, 2, "leaver gets its shares' worth");
    }

    function test_CashShortHandsSharesBack() public {
        uint256 bobShares = _join(bob, 1000e6);
        // The manager invested almost all the cash.
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 1900e6);
        _hold(tokA, 19e18);
        uint256 r = _redeem(bob, bobShares, 1);
        _settle(_batchOf(r));
        (uint256 back, uint256 out) = _claim(r);
        assertApproxEqAbs(out, 100e6, 1, "every USDG the Fund had");
        assertGt(back, 0, "the rest back in shares");
        // Bob leaves in kind with what came back.
        vm.prank(bob);
        tel.redeemInKind(address(vault), back, bob);
        assertGt(tokA.balanceOf(bob), 0);
    }

    function test_InKindInPartsPaysEachAdapterLater() public {
        MockBook bk = _book(0);
        bk.seed(address(tokA), 2e18);
        uint256 shares = _join(alice, 1000e6);
        uint256 navBefore = _navPerShare();
        uint256 want = 2e18 * shares / vault.totalSupply();
        vm.prank(alice);
        uint256 id = tel.startInKind(address(vault), shares, alice, new address[](0));
        assertApproxEqRel(_navPerShare(), navBefore, 1e12, "the book stops counting the leaver's slice at once");
        assertGt(tel.exitUnits(id, address(bk)), 0);
        // The manager cannot touch the adapter until the slice is paid out.
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(bk), "");
        address[] memory one = new address[](1);
        one[0] = address(bk);
        vm.prank(alice);
        tel.claimInKind(id, one);
        assertApproxEqAbs(tokA.balanceOf(alice), want, 2, "her slice of the adapter's A");
        assertApproxEqRel(_navPerShare(), navBefore, 1e12);
        vm.prank(manager);
        controller.act(address(bk), "");
    }

    function test_PocketSetsANoMarketTokenAsideAndDepositsWaitUntilThen() public {
        uint256 bobShares = _join(bob, 1000e6);
        MockERC20 tokN = new MockERC20("N", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        _hold(tokN, 100e18);
        uint256 a = _deposit(alice, 500e6, 1);
        uint64 bt = _batchOf(a);
        _settle(bt);
        (,, bool waiting) = tel.due(a);
        assertTrue(waiting, "nobody minted while N is held");
        uint256 id = tel.pocket(address(vault), address(tokN), new address[](0), 0);
        assertEq(tokN.balanceOf(address(vault)), 0);
        _settle(bt);
        (uint256 sa,,) = tel.due(a);
        assertGt(sa, 0, "the deposit goes in after the pocket");
        pockets.claim(address(vault), id, bob);
        assertApproxEqRel(tokN.balanceOf(bob), 100e18 * bobShares / (bobShares + STAKE * 1e12), 1e15);
        _claim(a);
        assertEq(pockets.due(address(vault), id, alice), 0, "the new depositor has no claim on it");
    }
}
