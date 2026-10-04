// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerFundedBase} from "./TellerExits.t.sol";
import {MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {Amount, IAdapter} from "../../src/interfaces/IAdapter.sol";
import {Teller} from "../../src/core/Teller.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

/// @notice A MockBook that can be handed tokens without minting (as a manager's move from the vault would), and that
///         may report claims valued at zero (`IUnvalued`): mode 0 none, 1 `unvaluedAmt` of `unvaluedToken`, 2 a
///         revert with a reason, 3 a revert after burning gas, 4 malformed data.
contract MockBookU is MockBook {
    uint8 public uMode;
    address public unvaluedToken;
    uint256 public unvaluedAmt;

    function setUnvalued(uint8 m, address t, uint256 a) external {
        (uMode, unvaluedToken, unvaluedAmt) = (m, t, a);
    }

    /// @dev Tokens already sent to this adapter become a position (no mint).
    function credit(address token, uint256 amount) external {
        if (amt[token] == 0 && fee[token] == 0) held.push(token);
        amt[token] += amount;
    }

    /// @dev A zero row for `token` (an emptied position, or an unvalued claim's row).
    function zeroRow(address token) external {
        held.push(token);
    }

    function unvalued() external view returns (Amount[] memory out) {
        if (uMode == 2) revert("broken");
        if (uMode == 3) {
            uint256 x;
            while (gasleft() > 5000) ++x;
            revert();
        }
        if (uMode == 4) {
            assembly {
                mstore(0, 7)
                return(0, 3)
            }
        }
        out = new Amount[](1);
        out[0] = Amount(unvaluedToken, uMode == 1 ? unvaluedAmt : 0);
    }
}

/// @notice An exit in kind gives no slice of an adapter that holds and owes nothing, and needs no step for it; every
///         adapter that holds anything, or cannot be read, still gets its slice.
contract TellerEmptySkipTest is TellerFundedBase {
    MockBookU internal implU;
    MockBookU internal empty;
    MockBookU internal e2;

    /// @dev `_setUpFunded`, with two more adapters that hold nothing, enabled before anyone else holds a share.
    function setUp() public {
        _setUpTeller();
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 300e6);
        _hold(tokA, 2e18);
        book = _book(0);
        book.seed(address(tokA), 1e18);
        book.seed(address(tokB), 0.002e8);
        implU = new MockBookU();
        registry.register(address(implU), "");
        empty = _bookU();
        e2 = _bookU();
        _join(alice, 1000e6);
    }

    function _bookU() internal returns (MockBookU b) {
        vm.prank(owner);
        b = MockBookU(controller.addAdapter(address(implU), abi.encode(uint8(0), makeAddr("sink"))));
    }

    function _start(uint256 sh) internal returns (uint256 id) {
        vm.prank(alice);
        id = tel.startInKind(address(vault), sh, alice, new address[](0));
    }

    /// @dev What alice holds, valued at the test prices, in USD (1e18).
    function _aliceUsd() internal view returns (uint256) {
        return usdg.balanceOf(alice) * 1e12 + tokA.balanceOf(alice) * 100 + tokB.balanceOf(alice) * 1e10 * 50_000;
    }

    function test_EmptyAdapterGetsNoSliceAndNoStep() public {
        uint256 id = _start(vault.balanceOf(alice) / 2);
        assertEq(tel.exit(id).pending, 1, "only the book that holds something");
        assertGt(tel.exitUnits(id, address(book)), 0);
        assertEq(tel.exitUnits(id, address(empty)), 0, "no slice of the empty adapter");
        (uint256 fund, uint256 total) = controller.unitsOf(address(empty));
        assertEq(fund, total, "nothing set aside in the controller");
        assertEq(controller.pendingExits(), 1);
        // Nothing to claim or release for it.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, id));
        tel.claimInKind(id, _list(address(empty)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, id));
        tel.releaseInKind(id, address(empty));
        // The empty adapter stays free for the manager meanwhile.
        vm.prank(manager);
        controller.act(address(empty), "");
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
        assertEq(tel.exit(id).pending, 0);
        assertEq(controller.pendingExits(), 0);
    }

    function test_InKindStepsListsOnlyAdaptersThatHoldSomething() public view {
        address[] memory s = tel.inKindSteps(address(vault), vault.balanceOf(alice));
        assertEq(s.length, 1);
        assertEq(s[0], address(book));
        assertEq(tel.inKindSteps(address(vault), 0).length, 0);
        assertEq(tel.inKindSteps(address(vault), vault.totalSupply() + 1).length, 0);
    }

    function test_EveryAdapterEmptyCompletesAtOnce() public {
        vm.prank(manager);
        controller.unwindAdapter(address(book), WAD); // the book now reports rows of zero
        empty.zeroRow(address(tokA)); // and so does the other adapter
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 s = vault.totalSupply();
        uint256 vA = tokA.balanceOf(address(vault));
        uint256 vB = tokB.balanceOf(address(vault));
        assertEq(tel.inKindSteps(address(vault), sh).length, 0);
        uint256 id = _start(sh);
        assertEq(tel.exit(id).pending, 0, "complete in the one call");
        assertEq(controller.pendingExits(), 0);
        assertEq(tokA.balanceOf(alice), vA * sh / s);
        assertEq(tokB.balanceOf(alice), vB * sh / s);
    }

    /// @dev In one transaction every adapter is split as before (reading each first would cost more).
    function test_OneTransactionExitWithEmptyAdapters() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256[5] memory before = _perShare();
        uint256 usdBefore = _navPerShare() * sh / WAD;
        vm.prank(alice);
        tel.redeemInKind(address(vault), sh, alice);
        assertApproxEqRel(_aliceUsd(), usdBefore, 1e12, "the leaver lost nothing");
        _assertNoOneElseLost(before);
        assertEq(controller.pendingExits(), 0);
    }

    function test_AZeroRowWithAnUnvaluedClaimIsStillSetAside() public {
        MockERC20 tokN = new MockERC20("N", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        tokN.mint(address(empty), 5e18);
        empty.zeroRow(address(tokN));
        empty.setUnvalued(1, address(tokN), 5e18);
        uint256 id = _start(vault.balanceOf(alice) / 2);
        assertGt(tel.exitUnits(id, address(empty)), 0, "a claim valued at zero is still a slice");
        assertEq(tel.exit(id).pending, 2);
    }

    function test_AnUnvaluedThatFailsIsNotTakenAsEmpty() public {
        empty.zeroRow(address(tokA));
        for (uint8 m = 2; m <= 4; ++m) {
            empty.setUnvalued(m, address(0), 0);
            assertEq(tel.inKindSteps(address(vault), vault.balanceOf(alice)).length, 2, "set aside");
        }
        empty.setUnvalued(3, address(0), 0); // reverts with no data, but after burning its gas
        uint256 id = _start(vault.balanceOf(alice) / 2);
        assertGt(tel.exitUnits(id, address(empty)), 0, "out of gas is not 'no such function'");
        // An answer of nothing at all is empty.
        empty.setUnvalued(0, address(tokA), 0);
        assertEq(tel.inKindSteps(address(vault), vault.balanceOf(alice)).length, 1);
    }

    function test_ARevertingPositionsReadIsStillSetAside() public {
        vm.mockCallRevert(address(empty), abi.encodeWithSelector(IAdapter.positions.selector), "down");
        uint256 id = _start(vault.balanceOf(alice) / 2);
        assertGt(tel.exitUnits(id, address(empty)), 0, "unreadable is not empty");
        assertEq(tel.exit(id).pending, 2);
        vm.clearMockedCalls();
        vm.prank(alice);
        tel.claimInKind(id, _list(address(empty)));
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
        assertEq(controller.pendingExits(), 0);
    }

    function test_MalformedPositionsIsStillSetAside() public {
        vm.mockCall(address(empty), abi.encodeWithSelector(IAdapter.positions.selector), hex"0102");
        assertEq(tel.inKindSteps(address(vault), vault.balanceOf(alice)).length, 2);
        vm.clearMockedCalls();
    }

    function test_ADebtAloneIsNotEmpty() public {
        empty.borrow(address(usdg), 10e6);
        uint256 id = _start(vault.balanceOf(alice) / 2);
        assertGt(tel.exitUnits(id, address(empty)), 0);
        assertGt(tel.exitEscrow(id, address(empty)).length, 0, "its debt repayment is escrowed");
    }

    /// @dev The answer never depends on the gas sent: with too little to read `unvalued` the call fails (a gas
    ///      estimate then goes higher) instead of setting a slice aside.
    function test_TheSkipDoesNotDependOnTheGasSent() public {
        empty.zeroRow(address(tokA)); // a row of zero, no `unvalued`: empty
        uint256 sh = vault.balanceOf(alice) / 2;
        for (uint256 g = 300_000; g < 6_000_000; g += 100_000) {
            uint256 snap = vm.snapshotState();
            uint256 id = tel.nextExitId();
            vm.prank(alice);
            (bool ok,) = address(tel).call{gas: g}(
                abi.encodeCall(Teller.startInKind, (address(vault), sh, alice, new address[](0)))
            );
            if (ok) assertEq(tel.exitUnits(id, address(empty)), 0, "skipped at every gas that lands");
            vm.revertToState(snap);
        }
        (bool ok2, bytes memory ret) =
            address(tel).staticcall{gas: 1_500_000}(abi.encodeCall(Teller.inKindSteps, (address(vault), sh)));
        assertFalse(ok2, "a view with too little gas fails rather than over-counting");
        ret;
        assertEq(tel.inKindSteps(address(vault), sh).length, 1);
    }

    // ---------------------------------------------------------------- attacks

    /// @dev Skipped while empty, filled after the exit began: the value belongs to those who still hold, and the
    ///      leaver already took its full slice (the vault tokens the fill came from).
    function test_FilledAfterTheSkipStaysWithTheHolders() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 usdBefore = _navPerShare() * sh / WAD;
        uint256 id = _start(sh);
        uint256 ps = _navPerShare();
        // The manager moves 1 A from the vault into the skipped adapter.
        vm.prank(address(tel));
        vault.pay(address(tokA), address(empty), 1e18);
        empty.credit(address(tokA), 1e18);
        assertApproxEqRel(_navPerShare(), ps, 1e12, "a move, not a gain or a loss");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Teller.BadRequest.selector, id));
        tel.claimInKind(id, _list(address(empty)));
        vm.prank(alice);
        tel.claimInKind(id, _list(address(book)));
        assertApproxEqRel(_aliceUsd(), usdBefore, 1e12, "the leaver got its full share");
    }

    /// @dev Someone donates to the adapter between the read and the exit: it is then not empty and is set aside.
    function test_FilledJustBeforeTheExitIsSetAside() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        vm.prank(address(tel));
        vault.pay(address(tokA), address(empty), 1e18);
        empty.credit(address(tokA), 1e18);
        uint256 usdBefore = _navPerShare() * sh / WAD;
        uint256 id = _start(sh);
        assertGt(tel.exitUnits(id, address(empty)), 0);
        address[] memory both = new address[](2);
        (both[0], both[1]) = (address(book), address(empty));
        vm.prank(alice);
        tel.claimInKind(id, both);
        assertApproxEqRel(_aliceUsd(), usdBefore, 1e12, "the leaver got its share of the filled adapter");
    }

    /// @dev The manager empties an adapter into the vault right before an exit: the leaver takes its slice of the
    ///      vault instead, worth the same.
    function test_EmptiedJustBeforeTheExitPaysFromTheVault() public {
        uint256 sh = vault.balanceOf(alice) / 2;
        uint256 usdBefore = _navPerShare() * sh / WAD;
        vm.prank(manager);
        controller.unwindAdapter(address(book), WAD);
        uint256[5] memory before = _perShare();
        uint256 id = _start(sh);
        assertEq(tel.exit(id).pending, 0);
        assertApproxEqRel(_aliceUsd(), usdBefore, 1e12, "nothing lost by the skip");
        _assertNoOneElseLost(before);
    }

    /// @dev A leaver with a pending slice of an adapter that is later emptied by its own claim: a second exit skips
    ///      it, the first exit's slice stays claimable and whole.
    function test_PendingSliceOfAnotherExitIsNotSkippedAway() public {
        uint256 bs = _join(bob, 1000e6);
        uint256 ia = _start(vault.balanceOf(alice));
        vm.prank(bob);
        uint256 ib = tel.startInKind(address(vault), bs, bob, new address[](0));
        assertGt(tel.exitUnits(ib, address(book)), 0, "the Fund's part still holds something");
        vm.prank(alice);
        tel.claimInKind(ia, _list(address(book)));
        vm.prank(bob);
        tel.claimInKind(ib, _list(address(book)));
        assertEq(controller.pendingExits(), 0);
    }
}
