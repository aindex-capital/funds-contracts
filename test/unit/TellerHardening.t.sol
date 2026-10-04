// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {DialPresets} from "../../src/core/DialPresets.sol";
import {FundController} from "../../src/core/FundController.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {TellerOps} from "../../src/core/TellerOps.sol";

/// @notice A token whose transfers make one call of the test's choosing, once armed (a transfer hook).
contract HookToken is MockERC20 {
    address public target;
    bytes public data;
    bool public armed;
    bool public tried;
    bool public succeeded;

    constructor() MockERC20("Hook", "HOOK", 18) {}

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (!armed || from == address(0)) return;
        armed = false;
        tried = true;
        (bool ok,) = target.call(data);
        succeeded = ok;
    }
}

/**
 * @notice What a keeper, an owner, an adapter or a token can no longer do to depositors and holders: reentry, the
 *         busy flag, the teller's doors into a Fund, escrow kept apart between Funds, and dust.
 */
contract TellerHardeningTest is TellerBase {
    HookToken internal hook;
    MockBook internal book;

    function setUp() public {
        _setUpTeller();
        hook = new HookToken();
        _price(address(hook), 1e18, PriceClass.Feed, 0);
        _hold(MockERC20(address(hook)), 1_000e18);
        book = _book(0);
        book.seed(address(tokA), 1e18);
    }

    function test_TokenHookCannotActDuringAnExit() public {
        vm.prank(owner);
        controller.setManager(address(hook), uint64(block.timestamp + 30 days));
        vm.prank(owner);
        tel.releaseStake(address(vault));
        hook.arm(address(controller), abi.encodeWithSignature("act(address,bytes)", address(book), bytes("")));
        vm.prank(owner);
        tel.redeemInKind(address(vault), 100e18, owner);
        assertTrue(hook.tried(), "the hook ran inside the exit");
        assertFalse(hook.succeeded(), "the controller refused the manager while the teller was busy");
    }

    function test_TokenHookCannotReenterTheTeller() public {
        uint256 a = _deposit(alice, 100e6, 1);
        vm.prank(owner);
        tel.releaseStake(address(vault));
        hook.arm(address(tel), abi.encodeWithSignature("claim(uint256)", a));
        vm.prank(owner);
        tel.redeemInKind(address(vault), 100e18, owner);
        assertTrue(hook.tried());
        assertFalse(hook.succeeded(), "reentrancy refused");
        hook.arm(address(tel), abi.encodeWithSignature("settle(address,uint64,uint256[])", address(vault), 1, _noSkip()));
        vm.prank(owner);
        tel.redeemInKind(address(vault), 100e18, owner);
        assertFalse(hook.succeeded());
    }

    function test_BusyOnlyInsideACall() public view {
        assertFalse(tel.busy());
    }

    function test_TellerDoorsAreTellerOnly() public {
        vm.startPrank(manager);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.reserveFor(address(book), 1e17);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.splitUnitsFor(address(book), 1, manager);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.releaseUnits(address(book), 1);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.collectFor(address(book));
        vm.expectRevert(FundController.NotTeller.selector);
        controller.unwindFor(address(book), 1e18);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.pocketFor(address(book), address(tokA), address(pockets), 1);
        vm.expectRevert(FundController.NotTeller.selector);
        controller.noteDebt(address(book));
        vm.stopPrank();
        vm.prank(manager);
        vm.expectRevert(FundVault.NotTeller.selector);
        vault.snapshot();
    }

    function test_EscrowIsKeptApartBetweenFunds() public {
        address v1 = address(vault);
        uint256 a = _deposit(alice, 300e6, 1);
        _openFund(0, 0);
        uint256 c = _deposit(carol, 500e6, 1);
        assertEq(tel.owed(address(usdg)), 800e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        tel.settle(v1, tel.request(a).batch, _noSkip());
        assertEq(tel.owed(address(usdg)), 500e6, "only the first Fund's deposit left escrow");
        assertGe(usdg.balanceOf(address(tel)), tel.owed(address(usdg)));
        _settle(_batchOf(c));
        assertEq(tel.owed(address(usdg)), 0);
        assertEq(usdg.balanceOf(address(tel)), 0);
    }

    function test_OwedTracksEverythingThroughAFullCycle() public {
        uint256 bs = _join(bob, 400e6);
        uint256 r = _redeem(bob, bs, 1);
        uint256 a = _deposit(alice, 100e6, 1);
        uint256 stake = tel.fund(address(vault)).stake;
        assertEq(tel.owed(address(vault)), stake + bs);
        _settle(_batchOf(r));
        _claim(r);
        _claim(a);
        assertEq(tel.owed(address(vault)), stake, "only the stake is left in custody");
        assertEq(tel.owed(address(usdg)), 0);
        assertEq(vault.balanceOf(address(tel)), stake + tel.DEAD_SHARES());
    }

    function test_WriteOffRefusesATokenTheFundOwesOrAnAdapterHolds() public {
        MockERC20 tokC = new MockERC20("C", "C", 18);
        _price(address(tokC), 100e18, PriceClass.Feed, 0);
        book.borrow(address(tokC), 1e18);
        vm.prank(address(controller));
        vault.track(address(tokC));
        vm.prank(address(vault));
        tokC.transfer(address(0xdead), 1e18);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotDust.selector, address(tokC)));
        tel.writeOff(address(vault), address(tokC));
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotDust.selector, address(tokA)));
        tel.writeOff(address(vault), address(tokA));
    }

    function test_OwnerOnlyTimeIsNotCharged() public {
        _openFund(200, 0);
        vm.warp(block.timestamp + 365 days);
        uint256 s0 = vault.totalSupply();
        uint256 a = _deposit(alice, 100e6, 1);
        _settle(_batchOf(a));
        uint256 feeShares = vault.balanceOf(owner) + vault.balanceOf(aix) + vault.balanceOf(treasury);
        assertLt(feeShares, s0 * 2 / 100 * 2 / 365, "at most a couple of days, not the owner-only year");
    }

    function test_OpenPresetLosesAtMostAQuarterADay() public pure {
        assertEq(DialPresets.open().dailyLossBps, 2_500);
    }
}
