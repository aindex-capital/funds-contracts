// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {Teller} from "../../src/core/Teller.sol";
import {TellerMath} from "../../src/core/TellerMath.sol";
import {TellerOps} from "../../src/core/TellerOps.sol";
import {TellerQueue} from "../../src/core/TellerQueue.sol";
import {FundController} from "../../src/core/FundController.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

/// @notice A Fund holding USDG and A in the vault and A and B in an adapter, with Alice holding about half of it.
abstract contract TellerFundedBase is TellerBase {
    MockBook internal book;

    function _setUpFunded() internal {
        _setUpTeller();
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 300e6);
        _hold(tokA, 2e18);
        book = _book(0);
        book.seed(address(tokA), 1e18);
        book.seed(address(tokB), 0.002e8);
        _join(alice, 1000e6);
    }

    /// @dev Everything the Fund holds per share (vault balances and adapter positions), for "no one else lost".
    function _perShare() internal view returns (uint256[5] memory p) {
        uint256 s = vault.totalSupply();
        p[0] = usdg.balanceOf(address(vault)) * 1e30 / s;
        p[1] = tokA.balanceOf(address(vault)) * 1e30 / s;
        p[2] = book.amt(address(tokA)) * 1e30 / s;
        p[3] = book.amt(address(tokB)) * 1e30 / s;
        p[4] = book.debt() * 1e30 / s;
    }

    function _assertNoOneElseLost(uint256[5] memory before) internal view {
        uint256[5] memory now_ = _perShare();
        for (uint256 i; i < 4; ++i) {
            assertGe(now_[i] + 1e12, before[i], "a holding per share fell");
        }
        assertLe(now_[4], before[4] + 1e12, "debt per share rose");
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }
}

contract TellerInKindTest is TellerFundedBase {
    function setUp() public {
        _setUpFunded();
    }

    function test_InKindPaysTheSliceOfEveryTokenAndPosition() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 s = vault.totalSupply();
        uint256 vU = usdg.balanceOf(address(vault));
        uint256 vA = tokA.balanceOf(address(vault));
        uint256 bA = book.amt(address(tokA));
        uint256 bB = book.amt(address(tokB));
        uint256[5] memory before = _perShare();
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, carol);
        uint256 f = sh * WAD / s;
        assertEq(usdg.balanceOf(carol), vU * sh / s);
        assertEq(tokA.balanceOf(carol), vA * sh / s + bA * f / WAD);
        assertEq(tokB.balanceOf(carol), bB * f / WAD);
        assertEq(vault.totalSupply(), s - sh);
        _assertNoOneElseLost(before);
    }

    function test_DebtSliceIsChargedToTheLeaversOwnSlice() public {
        book.borrow(address(usdg), 200e6); // the vault now holds 200 more USDG, owed by the adapter
        uint256 sh = vault.balanceOf(alice);
        uint256 s = vault.totalSupply();
        uint256 vU = usdg.balanceOf(address(vault));
        uint256[5] memory before = _perShare();
        uint256 had = usdg.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        uint256 f = sh * WAD / s;
        uint256 debtShare = (200e6 * f + WAD - 1) / WAD;
        assertEq(usdg.balanceOf(alice) - had, vU * sh / s - debtShare);
        assertLe(book.debt(), 200e6 - 200e6 * f / WAD);
        _assertNoOneElseLost(before);
    }

    function test_LeaverBringsWhatItsSliceCannotCover() public {
        book.borrow(address(usdg), 2000e6);
        // The Fund spent the borrowed USDG: the vault keeps only 100 USDG.
        uint256 vU = usdg.balanceOf(address(vault));
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), vU - 100e6);
        tokA.mint(address(vault), 20e18); // what it bought
        uint256 sh = vault.balanceOf(alice);
        Amount[] memory bring = tel.inKindNeeds(address(vault), sh);
        uint256 need;
        for (uint256 i; i < bring.length; ++i) {
            if (bring[i].token == address(usdg)) need = bring[i].amount;
        }
        assertGt(need, 0);
        vm.prank(alice);
        vm.expectRevert();
        tel.redeemInKind(address(vault), sh, alice);
        uint256 had = usdg.balanceOf(alice);
        usdg.mint(alice, need);
        uint256[5] memory before = _perShare();
        vm.startPrank(alice);
        usdg.approve(address(tel), need);
        tel.redeemInKind(address(vault), sh, alice);
        vm.stopPrank();
        assertApproxEqAbs(usdg.balanceOf(alice), had, 2, "brought what was needed; the escrow's margin came back");
        assertGt(tokA.balanceOf(alice), 0);
        _assertNoOneElseLost(before);
    }

    function test_SplitTakingTooMuchIsCaught() public {
        book.setMode(2);
        uint256 sh = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vm.expectPartialRevert(TellerMath.NotShrunk.selector);
        tel.redeemInKind(address(vault), sh, alice);
    }

    function test_FeesSweptMidSplitAreNotAWindfall() public {
        book.addFees(address(tokA), 1e18);
        uint256 sh = vault.balanceOf(alice) / 4;
        uint256 s = vault.totalSupply();
        uint256 vA = tokA.balanceOf(address(vault));
        uint256 bA = book.amt(address(tokA));
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, carol);
        // Fees were collected first and count as vault holdings: the leaver gets its slice of them, no more.
        uint256 expected = (vA + 1e18) * sh / s + bA * (sh * WAD / s) / WAD;
        assertEq(tokA.balanceOf(carol), expected);
    }

    function test_LeaveBehindAnAdapterOrAToken() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        address[] memory leave = new address[](2);
        leave[0] = address(book);
        leave[1] = address(tokA);
        vm.prank(alice);
        tel.redeemInKindLeaving(address(vault), sh, carol, leave);
        assertEq(tokA.balanceOf(carol), 0);
        assertEq(tokB.balanceOf(carol), 0);
        assertGt(usdg.balanceOf(carol), 0);
    }

    function test_AdapterKeepingTheSliceOnlyHurtsTheLeaver() public {
        book.setMode(5); // split sends nothing
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256[5] memory before = _perShare();
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, carol);
        assertEq(tokB.balanceOf(carol), 0);
        _assertNoOneElseLost(before);
    }

    function test_InKindWorksWithTheManagerPausedAndTheAdapterDisabled() public {
        vm.startPrank(guardian);
        controller.setPaused(true);
        controller.disableAdapter(address(book));
        vm.stopPrank();
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        assertGt(tokB.balanceOf(alice), 0);
    }

    function test_InKindRefusesBadRecipientsAndOverdraw() public {
        uint256 sh = vault.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(Teller.BadAmount.selector);
        tel.redeemInKind(address(vault), sh, address(vault));
        vm.expectRevert(Teller.BadAmount.selector);
        tel.redeemInKind(address(vault), sh + 1, alice);
        vm.stopPrank();
    }
}

/// @notice Exits in kind in parts: shares burn and vault tokens are paid at once; each adapter's slice is set aside
///         in the controller's units (the book stops counting it) and paid out by `claimInKind`.
contract TellerInKindPartsTest is TellerFundedBase {
    function setUp() public {
        _setUpFunded();
    }

    function _start(uint256 sh) internal returns (uint256 id) {
        vm.prank(alice);
        id = tel.startInKind(address(vault), sh, alice, new address[](0));
    }

    function test_StartPaysTheVaultSliceAndSetsTheAdaptersAside() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 s = vault.totalSupply();
        uint256 vU = usdg.balanceOf(address(vault));
        uint256 vA = tokA.balanceOf(address(vault));
        uint256 ps = _navPerShare();
        uint256 id = _start(sh);
        assertEq(usdg.balanceOf(alice), vU * sh / s);
        assertEq(tokA.balanceOf(alice), vA * sh / s);
        assertEq(tokB.balanceOf(alice), 0, "the adapter's slice waits");
        assertEq(vault.totalSupply(), s - sh);
        assertGt(tel.exitUnits(id, address(book)), 0);
        assertEq(tel.exit(id).pending, 1);
        (uint256 fund, uint256 total) = controller.unitsOf(address(book));
        assertLt(fund, total);
        assertApproxEqRel(_navPerShare(), ps, 1e12, "NAV per share unchanged: the slice is no longer counted");
    }

    function test_ClaimPaysTheSlicePerAdapterAndFreesIt() public {
        uint256 sh = vault.balanceOf(alice);
        uint256 s = vault.totalSupply();
        uint256 bA = book.amt(address(tokA));
        uint256 bB = book.amt(address(tokB));
        uint256 ps = _navPerShare();
        uint256 id = _start(sh);
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
        uint256 f = sh * WAD / s;
        assertApproxEqAbs(tokB.balanceOf(alice), bB * f / WAD, 1);
        assertGe(tokA.balanceOf(alice), bA * f / WAD - 1);
        assertEq(tel.exitUnits(id, address(book)), 0);
        assertEq(tel.exit(id).pending, 0);
        assertEq(controller.pendingExits(), 0);
        (uint256 fund, uint256 total) = controller.unitsOf(address(book));
        assertEq(fund, total);
        assertApproxEqRel(_navPerShare(), ps, 1e12);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, id));
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
    }

    function test_PendingSliceFreezesTheAdapterButNothingElse() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FundController.ExitPending.selector, address(book)));
        controller.act(address(book), "");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FundController.ExitPending.selector, address(book)));
        controller.unwindAdapter(address(book), WAD);
        vm.startPrank(owner);
        controller.disableAdapter(address(book));
        vm.warp(block.timestamp + controller.RISK_NOTICE());
        vm.expectRevert(abi.encodeWithSelector(FundController.ExitPending.selector, address(book)));
        controller.removeAdapter(address(book));
        vm.stopPrank();
        // Deposits and other holders' exits go on meanwhile.
        _join(bob, 100e6);
        uint256 bs = vault.balanceOf(bob);
        vm.prank(bob);
        tel.redeemInKind(address(vault), bs, bob);
        assertGt(tokB.balanceOf(bob), 0, "bob takes his slice of the Fund's part");
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
    }

    function test_OthersMayClaimOnlyAfterADay() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.prank(carol);
        vm.expectRevert(Teller.NotReady.selector);
        tel.claimInKind(id, _list(address(book)));
        vm.warp(block.timestamp + tel.EXIT_OPEN_AFTER());
        vm.prank(carol);
        tel.claimInKind(id, _list(address(book)));
        assertGt(tokB.balanceOf(alice), 0, "paid to the exit's recipient, not the caller");
        assertEq(tokB.balanceOf(carol), 0);
    }

    function test_EscrowCoversTheDebtLeftoverGoesBackShortfallIsBrought() public {
        book.borrow(address(usdg), 200e6);
        uint256 sh = vault.balanceOf(alice);
        uint256 id = _start(sh);
        Amount[] memory esc = tel.exitEscrow(id, address(book));
        assertEq(esc.length, 1);
        assertEq(esc[0].token, address(usdg));
        uint256 owedBefore = tel.owed(address(usdg));
        assertGe(owedBefore, esc[0].amount);
        // A week of interest beyond the margin: the debt grows by 1%.
        vm.warp(block.timestamp + 7 days);
        book.borrow(address(usdg), 2e6);
        uint256 had = usdg.balanceOf(carol);
        usdg.mint(carol, 10e6);
        vm.startPrank(carol);
        usdg.approve(address(tel), 10e6);
        uint256 vaultUsdg = usdg.balanceOf(address(vault));
        tel.claimInKind(id, _list(address(book)));
        vm.stopPrank();
        assertLt(usdg.balanceOf(carol), had + 10e6, "the caller brought the shortfall");
        assertEq(usdg.balanceOf(address(vault)), vaultUsdg, "the holders' cash paid none of the leaver's debt");
        assertEq(tel.owed(address(usdg)), owedBefore - esc[0].amount);
    }

    function test_EscrowLeftOverGoesToTheLeaver() public {
        book.borrow(address(usdg), 200e6);
        uint256 sh = vault.balanceOf(alice);
        uint256 id = _start(sh);
        uint256 esc = tel.exitEscrow(id, address(book))[0].amount;
        uint256 had = usdg.balanceOf(alice);
        uint256 debt0 = book.debt();
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
        uint256 repaid = debt0 - book.debt();
        assertEq(usdg.balanceOf(alice) - had, esc - repaid, "the unused margin back");
        assertGt(esc, repaid);
    }

    function test_OwnerReleasesASliceToTheFund() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        uint256 bB = book.amt(address(tokB));
        vm.prank(alice);
        tel.releaseInKind(id, address(book));
        assertEq(book.amt(address(tokB)), bB, "left behind with the other holders");
        assertEq(controller.pendingExits(), 0);
        vm.prank(manager);
        controller.act(address(book), "");
    }

    function test_StaleReleaseOnlyWhenTheSplitFails() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.prank(carol);
        vm.expectRevert(Teller.NotReady.selector);
        tel.releaseInKind(id, address(book));
        vm.warp(block.timestamp + tel.STALE_AFTER());
        vm.prank(carol);
        vm.expectRevert(Teller.NotReady.selector);
        tel.releaseInKind(id, address(book)); // the split works: claim it instead
        vm.mockCallRevert(address(book), abi.encodeWithSelector(MockBook.split.selector), "stuck");
        vm.prank(carol);
        tel.releaseInKind(id, address(book));
        assertEq(controller.pendingExits(), 0);
        vm.clearMockedCalls();
    }

    /// @notice A release by anyone but the leaver probes whether the slice splits. Too little gas for the probe
    ///         fails (`ShortGas`), and a revert without data (out of gas, or an adapter that says nothing) is no proof
    ///         the slice cannot be split: the release is refused, so gas griefing never costs the leaver its slice.
    function test_StaleReleaseCannotBeForcedByGas() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.warp(block.timestamp + tel.STALE_AFTER());
        vm.prank(carol);
        (bool ok, bytes memory ret) =
            address(tel).call{gas: 5_000_000}(abi.encodeCall(tel.releaseInKind, (id, address(book))));
        assertFalse(ok);
        assertEq(bytes4(ret), Teller.ShortGas.selector);
        // A split that runs out of gas inside the probe proves nothing: refused, whatever gas the caller sends.
        book.setMode(7);
        vm.prank(carol);
        vm.expectRevert(Teller.NotReady.selector);
        tel.releaseInKind{gas: 30_000_000}(id, address(book));
        assertEq(controller.pendingExits(), 1);
    }

    /// @notice A split that fails without revert data but with gas to spare (a bare `require`, a pause without a
    ///         reason) is a real failure: after `STALE_AFTER` anyone releases the slice, so the adapter never stays
    ///         frozen for good.
    function test_SilentSplitFailureIsReleasedWhenStale() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        book.setMode(6);
        vm.prank(carol);
        vm.expectRevert(Teller.NotReady.selector);
        tel.releaseInKind(id, address(book)); // not stale yet
        vm.warp(block.timestamp + tel.STALE_AFTER());
        vm.prank(carol);
        tel.releaseInKind(id, address(book));
        assertEq(controller.pendingExits(), 0);
    }

    /// @notice A split that pays only part of the slice (a position skipped): until `STALE_AFTER` only the leaver
    ///         may take it; after it anyone may, paying what it pays (the leaver keeps that), and the FULL probe
    ///         failing lets anyone release it instead, so the adapter is never frozen.
    function test_PartlyPaidSliceIsClaimableOrReleasableWhenStale() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.warp(block.timestamp + tel.EXIT_OPEN_AFTER());
        book.setMode(5);
        vm.prank(carol);
        vm.expectPartialRevert(TellerMath.NotPaid.selector);
        tel.claimInKind(id, _list(address(book)));
        vm.warp(block.timestamp + tel.STALE_AFTER());
        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        tel.claimInKind(id, _list(address(book)));
        assertEq(tel.exit(id).pending, 0, "paid out as far as it pays");
        assertEq(controller.pendingExits(), 0);
        vm.revertToState(snap);
        vm.prank(carol);
        tel.releaseInKind(id, address(book));
        assertEq(controller.pendingExits(), 0, "or released");
    }

    /// @notice Someone other than the leaver may only finalise a slice that paid in full; a split that paid
    ///         short (a market emptied for one transaction) reverts and the slice stays pending. The leaver itself
    ///         may still take what it can.
    function test_OthersFinaliseOnlyASliceThatPaysInFull() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.warp(block.timestamp + tel.EXIT_OPEN_AFTER());
        book.setMode(5); // split sends nothing
        vm.prank(carol);
        vm.expectPartialRevert(TellerMath.NotPaid.selector);
        tel.claimInKind(id, _list(address(book)));
        assertEq(tel.exit(id).pending, 1, "still pending");
        book.setMode(0);
        vm.prank(carol);
        tel.claimInKind(id, _list(address(book)));
        assertGt(tokB.balanceOf(alice), 0);
    }

    function test_PocketWaitsForAPendingSlice() public {
        MockERC20 tokN = new MockERC20("N", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        book.seed(address(tokN), 5e18);
        uint256 id = _start(vault.balanceOf(alice) / 2);
        vm.expectRevert(abi.encodeWithSelector(FundController.ExitPending.selector, address(book)));
        tel.pocket(address(vault), address(tokN), _list(address(book)), 0);
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
        tel.pocket(address(vault), address(tokN), _list(address(book)), 0);
    }

    function test_TwoPendingExitsShareTheAdapterFairly() public {
        uint256 bs = _join(bob, 1000e6);
        uint256 s = vault.totalSupply();
        uint256 bB = book.amt(address(tokB));
        uint256 as_ = vault.balanceOf(alice);
        uint256 ia = _start(as_);
        vm.prank(bob);
        uint256 ib = tel.startInKind(address(vault), bs, bob, new address[](0));
        vm.prank(bob);
        tel.claimInKind(ib, _list(address(book)));
        vm.prank(alice);
        tel.claimInKind(ia, _list(address(book)));
        assertApproxEqAbs(tokB.balanceOf(alice), bB * as_ / s, 2);
        assertApproxEqAbs(tokB.balanceOf(bob), bB * bs / s, 2);
    }
}

/// @notice Exits to cash at a settlement: paid from the Fund's USDG at the bid NAV per share; what the cash cannot
///         cover comes back as shares for an exit in kind. Matched with entrants at fair inside a batch.
/// @notice A token that takes a fee on every transfer.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee token", "FOT", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100;
        _burn(from, fee);
        return super.transferFrom(from, to, amount - fee);
    }
}

/// @notice Escrow pulled from a leaver is measured, so a token that arrives short (a fee on
///         transfer) cannot draw on what the teller holds for other Funds.
contract TellerEscrowArrivalTest is TellerFundedBase {
    function setUp() public {
        _setUpFunded();
    }

    function test_FeeOnTransferEscrowRefused() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        _price(address(fot), 1e18, PriceClass.Feed, 0);
        book.borrow(address(fot), 100e18); // a debt the vault does not count: the leaver brings its repayment
        uint256 sh = vault.balanceOf(alice);
        fot.mint(alice, 1_000e18);
        vm.startPrank(alice);
        fot.approve(address(tel), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.ShortArrival.selector, address(fot)));
        tel.redeemInKind(address(vault), sh, alice);
        vm.stopPrank();
    }
}

contract TellerCashExitTest is TellerFundedBase {
    function setUp() public {
        _setUpFunded();
        _price(address(tokA), 100e18, PriceClass.Feed, 200); // bid 98, ask 102
    }

    function test_PaidFromCashAtBid() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 bidNav = _nav(1);
        uint256 s = vault.totalSupply();
        uint256 cash_ = usdg.balanceOf(address(vault));
        uint256 r = _redeem(alice, sh, 1);
        uint64 bt = _batchOf(r);
        _settle(bt);
        (uint256 back, uint256 out) = _claim(r);
        assertEq(back, 0);
        assertEq(out, sh * bidNav / s / 1e12, "shares x bid NAV per share");
        assertEq(usdg.balanceOf(address(vault)), cash_ - out);
        assertEq(vault.totalSupply(), s - sh);
        assertEq(tel.batch(address(vault), bt).bidPerShare, bidNav * WAD / s);
    }

    function test_HoldersGainTheSpreadNeverLose() public {
        uint256 ps = _navPerShare();
        uint256 r = _redeem(alice, vault.balanceOf(alice), 1);
        _settle(_batchOf(r));
        assertGe(_navPerShare(), ps);
    }

    function test_ShortCashPaysWhatItHasAndHandsTheRestBack() public {
        uint256 sh = vault.balanceOf(alice);
        uint256 extra = usdg.balanceOf(address(vault)) - 50e6;
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), extra);
        uint256 r = _redeem(alice, sh, 1);
        uint64 bt = _batchOf(r);
        _settle(bt);
        (uint256 back, uint256 out) = _claim(r);
        assertApproxEqAbs(out, 50e6, 1, "every USDG the Fund had");
        assertGt(back, 0);
        assertEq(tel.batch(address(vault), bt).sharesBack, back);
        assertEq(vault.balanceOf(alice), back);
        // Then in kind.
        vm.prank(alice);
        tel.redeemInKind(address(vault), back, alice);
        assertGt(tokA.balanceOf(alice), 0);
        assertGt(tokB.balanceOf(alice), 0);
    }

    function test_MinUsdgIsAPriceOnThePartPaidInCash() public {
        uint256 sh = vault.balanceOf(alice);
        uint256 extra = usdg.balanceOf(address(vault)) - 50e6;
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), extra);
        // A floor near the full bid value is met: only half the shares are sold, at the bid price.
        uint256 full = sh * _nav(1) / vault.totalSupply() / 1e12;
        uint256 r = _redeem(alice, sh, full * 99 / 100);
        _settle(_batchOf(r));
        (, uint256 out) = _claim(r);
        assertGt(out, 0);
    }

    function test_FloorAboveTheBidMovesTheExitOnce() public {
        uint256 sh = vault.balanceOf(alice);
        uint256 worth = sh * _nav(1) / vault.totalSupply() / 1e12;
        uint256 r = _redeem(alice, sh, worth * 2);
        uint64 bt = _batchOf(r);
        _toCutoff(bt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TellerQueue.MinNotMet.selector, r));
        tel.settle(address(vault), bt, _noSkip());
        _settleSkip(bt, _one(r));
        assertEq(tel.request(r).batch, bt + 1);
    }

    function test_FastPathForLeaversAgreesWithTheLoop() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 worth = sh * _nav(1) / vault.totalSupply() / 1e12;
        uint256 r = _redeem(alice, sh, worth - 1);
        uint64 bt = _batchOf(r);
        ITeller.Batch memory b = tel.batch(address(vault), bt);
        assertEq(b.redTight, TellerQueue.tight(worth - 1, sh));
        assertEq(b.redLow, sh);
        _settle(bt);
        (, uint256 out) = _claim(r);
        assertGe(out, worth - 1);
    }

    function test_NoBidPriceHandsEverythingBack() public {
        uint256 sh = vault.balanceOf(alice);
        uint256 r = _redeem(alice, sh, 1);
        source.setDown(address(tokA), true);
        _settle(_batchOf(r));
        (uint256 back, uint256 out) = _claim(r);
        assertEq(out, 0);
        assertEq(back, sh, "leave in kind instead");
    }

    function test_MatchedAtFairTheFundUntouched() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 fairPs = _navPerShare();
        uint256 r = _redeem(alice, sh, 1);
        uint256 worth = sh * fairPs / WAD / 1e12;
        uint256 d = _deposit(bob, worth, 1); // exactly the leaver's value at fair
        uint64 bt = _batchOf(r);
        uint256 cash_ = usdg.balanceOf(address(vault));
        uint256 s = vault.totalSupply();
        _settle(bt);
        ITeller.Batch memory b = tel.batch(address(vault), bt);
        assertEq(b.navPerShare, fairPs);
        assertApproxEqAbs(b.matchedShares, sh, 1e12);
        assertApproxEqAbs(usdg.balanceOf(address(vault)), cash_, 2, "the Fund is not touched by the match");
        assertApproxEqAbs(vault.totalSupply(), s, 1e12);
        (uint256 sb,) = _claim(d);
        (, uint256 out) = _claim(r);
        assertApproxEqAbs(sb, sh, 1e12);
        assertApproxEqAbs(out, worth, 2);
    }

    function test_PartialMatchRestPaidAtBid() public {
        uint256 sh = vault.balanceOf(alice);
        uint256 r = _redeem(alice, sh, 1);
        uint256 d = _deposit(bob, 100e6, 1);
        uint64 bt = _batchOf(r);
        _settle(bt);
        ITeller.Batch memory b = tel.batch(address(vault), bt);
        assertEq(b.matchedUsdg, 100e6);
        assertGt(b.bidPerShare, 0);
        assertLt(b.bidPerShare, b.navPerShare);
        (uint256 sb,) = _claim(d);
        assertEq(sb, b.matchedShares);
        _claim(r);
    }

    function test_EscrowOfAnotherFundCannotPay() public {
        uint256 r = _redeem(alice, vault.balanceOf(alice), 1);
        // A second Fund's queued USDG sits in the same teller.
        address v1 = address(vault);
        _openFund(0, 0);
        _deposit(carol, 500e6, 1);
        uint256 tellerUsdg = usdg.balanceOf(address(tel));
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        tel.settle(v1, tel.request(r).batch, _noSkip());
        assertGe(usdg.balanceOf(address(tel)), tellerUsdg, "the other Fund's escrow is untouched");
    }
}

contract TellerStakeTest is TellerFundedBase {
    function setUp() public {
        _setUpFunded();
    }

    function test_StakeLockedWhileOthersHold() public {
        vm.prank(owner);
        vm.expectRevert(Teller.StakeLocked.selector);
        tel.releaseStake(address(vault));
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        // The owner is now the last holder: the stake may leave, in kind.
        vm.prank(owner);
        tel.releaseStake(address(vault));
        vm.prank(owner);
        tel.redeemInKind(address(vault), 1000e18, owner);
        assertEq(vault.totalSupply(), tel.DEAD_SHARES(), "only the supply floor is left");
    }

    function test_WindDownStopsDepositsAndFreesTheStakeAfterNotice() public {
        uint256 d = _deposit(bob, 100e6, 1);
        vm.prank(owner);
        tel.windDown(address(vault));
        usdg.mint(carol, 10e6);
        vm.startPrank(carol);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.WindingDown.selector);
        tel.requestDeposit(address(vault), 10e6, 1);
        vm.stopPrank();
        _settle(_batchOf(d));
        (uint256 s, uint256 refund) = _claim(d);
        assertEq(s, 0);
        assertEq(refund, 100e6, "queued deposits are refunded");
        vm.prank(owner);
        vm.expectRevert(Teller.StakeLocked.selector);
        tel.releaseStake(address(vault));
        vm.warp(block.timestamp + tel.WIND_DOWN_NOTICE());
        vm.prank(owner);
        tel.releaseStake(address(vault));
        assertEq(vault.balanceOf(owner), 1000e18);
    }

    function test_AFundEveryoneLeftCanReopen() public {
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        vm.startPrank(owner);
        tel.releaseStake(address(vault));
        tel.redeemInKind(address(vault), 1000e18, owner);
        usdg.mint(owner, 50e6);
        usdg.approve(address(tel), 50e6);
        tel.open(address(vault), 50e6, 0, 0);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 50e18 + tel.DEAD_SHARES());
        assertEq(tel.fund(address(vault)).stake, 50e18);
    }
}

contract TellerDustTest is TellerFundedBase {
    MockERC20 internal tokC;
    MockERC20 internal tokD;

    function setUp() public {
        _setUpFunded();
        tokC = new MockERC20("C", "C", 18);
        tokD = new MockERC20("D", "D", 18);
        _price(address(tokC), 2e18, PriceClass.Feed, 0);
        tokC.mint(address(vault), 0.4e18); // $0.80
        tokD.mint(address(vault), 0.00005e18); // no price
        vm.startPrank(address(controller));
        vault.track(address(tokC));
        vault.track(address(tokD));
        vm.stopPrank();
    }

    function test_WriteOffUnpriceableCrumbsAndPricedDust() public {
        tel.writeOff(address(vault), address(tokD));
        assertFalse(vault.isTracked(address(tokD)));
        tel.writeOff(address(vault), address(tokC));
        assertFalse(vault.isTracked(address(tokC)));
    }

    function test_WriteOffRefusesRealHoldings() public {
        tokD.mint(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotDust.selector, address(tokD)));
        tel.writeOff(address(vault), address(tokD));
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotDust.selector, address(usdg)));
        tel.writeOff(address(vault), address(usdg));
    }
}
