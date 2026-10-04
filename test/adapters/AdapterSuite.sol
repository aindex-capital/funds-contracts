// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../utils/FundTestBase.sol";
import {IAdapter, Amount} from "../../src/interfaces/IAdapter.sol";
import {Side} from "../../src/interfaces/IPriceRouter.sol";

/**
 * @title  AdapterSuite
 * @notice The tests every adapter must pass (docs/ADAPTERS.md). An adapter's test inherits this, builds its
 *         world in `_setUpAdapter` (mocks, or a fork of Robinhood Chain), and supplies valid actions.
 *
 * @dev    Hooks to implement:
 *         - `_setUpAdapter()`: deploy and register the implementation, set prices, create and fund the Fund
 *           (use `_setUpCore` and `_createFund`), enable the adapter, and return the instance.
 *         - `_action(uint256 seed)`: one valid action for the current state, chosen from `seed`.
 *         - `_touchedTokens()`: every token the adapter can hold or move, to check nothing is left loose.
 *
 *         Optional hooks:
 *         - `_liquid()`: true (default) when a full unwind or split always empties every position. An adapter
 *           whose venue can only partly unwind (a lending supply at 100% utilisation) returns false; the
 *           suite then checks conservation instead (what came back plus what is left equals what was
 *           reported) rather than emptiness. The default is the strict check.
 *         - `_valueSent(sent)`: the fair USD value of what `split` handed over. Default: each amount priced by
 *           the router. Override when `split` hands over a position token the router does not price.
 *         - `_growTolerance()`: raw units per token a grown position may read short of the fraction. Default 0.
 *           Liquidity adapters return a couple of units: a range side holding only a few raw units at the fair
 *           price can read a unit short after rounding (see GrowMath), and the teller allows for that.
 *         - `_fundVault(token, amount)`: give the vault `amount` more of `token`, standing in for the teller's
 *           purchases before `grow`. Default: forge's `deal`. Override for a token `deal` cannot write.
 */
abstract contract AdapterSuite is FundTestBase {
    IAdapter internal adapter;

    function _setUpAdapter() internal virtual returns (IAdapter);
    function _action(uint256 seed) internal view virtual returns (bytes memory);
    function _touchedTokens() internal view virtual returns (address[] memory);

    function _liquid() internal view virtual returns (bool) {
        return true;
    }

    function _valueSent(Amount[] memory sent) internal view virtual returns (uint256 usd) {
        for (uint256 i; i < sent.length; ++i) {
            (uint256 v,,) = router.value(sent[i].token, sent[i].amount, Side.Fair);
            usd += v;
        }
    }

    function _reportedValue() internal view returns (uint256 usd) {
        (Amount[] memory held,) = adapter.positions(router);
        for (uint256 i; i < held.length; ++i) {
            (uint256 v,,) = router.value(held[i].token, held[i].amount, Side.Fair);
            usd += v;
        }
    }

    function setUp() public virtual {
        adapter = _setUpAdapter();
    }

    function _act(bytes memory action) internal {
        vm.prank(manager);
        controller.act(address(adapter), action);
    }

    /// Rule 3 and 4: after any action the adapter holds no loose tokens.
    function testSuite_NoLooseTokensAfterAction(uint256 seed) public {
        _act(_action(seed));
        address[] memory t = _touchedTokens();
        for (uint256 i; i < t.length; ++i) {
            assertEq(IERC20(t[i]).balanceOf(address(adapter)), 0, "adapter holds loose tokens");
        }
    }

    /// Rule 1: nobody but the controller may run actions, unwind or split.
    function testSuite_OnlyController(uint256 seed, address caller) public {
        vm.assume(caller != address(controller));
        bytes memory a = _action(seed);
        vm.prank(caller);
        vm.expectRevert();
        adapter.execute(a);
        vm.prank(caller);
        vm.expectRevert();
        adapter.unwind(1e18);
        vm.prank(caller);
        vm.expectRevert();
        adapter.split(1e18, caller);
    }

    /// Rule 2 and 3: an action never sends value outside the Fund. NAV at fair prices may only move by what
    /// the venue charges (fees, slippage), never by more than the Fund's own loss budget allows.
    function testSuite_ValueStaysInFund(uint256 seed) public {
        (uint256 before,) = controller.nav(uint8(Side.Fair));
        _act(_action(seed));
        (uint256 after_,) = controller.nav(uint8(Side.Fair));
        // The controller already enforces the budget; this documents the bound the suite expects.
        assertGe(after_ + before / 100, before, "an action lost more than 1% of NAV at fair prices");
    }

    /// Rule 5: unwinding everything returns what positions reported, within rounding and venue fees.
    function testSuite_UnwindMatchesPositions(uint256 seed) public {
        _act(_action(seed));
        (Amount[] memory held,) = adapter.positions(router);
        uint256 reported;
        for (uint256 i; i < held.length; ++i) {
            (uint256 usd,,) = router.value(held[i].token, held[i].amount, Side.Fair);
            reported += usd;
        }
        (uint256 navBefore,) = controller.nav(uint8(Side.Fair));
        Amount[] memory needs = adapter.unwindInputs(1e18);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) vault.approveFor(needs[i].token, address(adapter), needs[i].amount);
        adapter.unwind(1e18);
        vm.stopPrank();
        if (_liquid()) {
            (Amount[] memory left,) = adapter.positions(router);
            for (uint256 i; i < left.length; ++i) assertEq(left[i].amount, 0, "position left after full unwind");
        }
        (uint256 navAfter,) = controller.nav(uint8(Side.Fair));
        assertApproxEqRel(navAfter, navBefore, 0.01e18, "unwind did not return what positions reported");
        reported;
    }

    /// Rule 5: in-kind exit. Half the positions to one holder, then all the rest to another: together they
    /// receive what `positions` reported, and nothing is left (or, for an adapter that is not `_liquid`, what
    /// is left plus what was handed over still adds up).
    function testSuite_SplitSumsToWhole(uint256 seed) public {
        _act(_action(seed));
        uint256 reported = _reportedValue();
        address a = makeAddr("splitA");
        address b = makeAddr("splitB");
        vm.startPrank(address(controller));
        // A split of a borrowing position repays the leaver's slice of debt from the vault first, as an unwind
        // does, so approve what the adapter declares before each split (nothing, for adapters without debt).
        _approveUnwindInputs(0.5e18);
        Amount[] memory sentA = adapter.split(0.5e18, a);
        _approveUnwindInputs(1e18);
        Amount[] memory sentB = adapter.split(1e18, b);
        vm.stopPrank();
        uint256 got = _valueSent(sentA) + _valueSent(sentB);
        if (_liquid()) {
            (Amount[] memory left,) = adapter.positions(router);
            for (uint256 i; i < left.length; ++i) assertEq(left[i].amount, 0, "position left after full split");
            assertApproxEqRel(got, reported, 0.01e18, "split slices do not sum to what positions reported");
        } else {
            assertApproxEqRel(got + _reportedValue(), reported, 0.01e18, "split lost value");
        }
        address[] memory t = _touchedTokens();
        for (uint256 i; i < t.length; ++i) {
            assertEq(IERC20(t[i]).balanceOf(address(adapter)), 0, "adapter holds loose tokens after split");
        }
    }

    function _growTolerance() internal view virtual returns (uint256) {
        return 0;
    }

    function _fundVault(address token, uint256 amount) internal virtual {
        deal(token, address(vault), IERC20(token).balanceOf(address(vault)) + amount);
    }

    /// Deposits into the existing mix: `grow(f)` pulls exactly `growInputs(f)` (the approval is used up), grows
    /// every position and every debt by at least `f`, and leaves nothing loose. First 10%, then 100% (double).
    /// As the teller does, `grow(0)` runs first so fees leave the positions before the "before" snapshot.
    function testSuite_GrowByFraction(uint256 seed) public {
        _act(_action(seed));
        _growAndCheck(0.1e18);
        _growAndCheck(1e18);
    }

    function _growAndCheck(uint256 f) internal {
        vm.prank(address(controller));
        adapter.grow(0);
        (Amount[] memory heldBefore, Amount[] memory owedBefore) = adapter.positions(router);
        Amount[] memory needs = adapter.growInputs(f);
        for (uint256 i; i < needs.length; ++i) _fundVault(needs[i].token, needs[i].amount);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) vault.approveFor(needs[i].token, address(adapter), needs[i].amount);
        Amount[] memory used = adapter.grow(f);
        vm.stopPrank();
        for (uint256 i; i < needs.length; ++i) {
            assertEq(IERC20(needs[i].token).allowance(address(vault), address(adapter)), 0, "grow did not pull growInputs");
        }
        for (uint256 i; i < used.length; ++i) {
            assertLe(used[i].amount, _sumOf(needs, used[i].token), "grow used more than growInputs");
        }
        (Amount[] memory heldAfter, Amount[] memory owedAfter) = adapter.positions(router);
        _assertGrew(heldBefore, heldAfter, f, "a position grew by less than the fraction");
        _assertGrew(owedBefore, owedAfter, f, "a debt grew by less than the fraction");
        address[] memory t = _touchedTokens();
        for (uint256 i; i < t.length; ++i) {
            assertEq(IERC20(t[i]).balanceOf(address(adapter)), 0, "adapter holds loose tokens after grow");
        }
    }

    function _assertGrew(Amount[] memory before, Amount[] memory after_, uint256 f, string memory why) internal view {
        uint256 tol = _growTolerance();
        for (uint256 i; i < before.length; ++i) {
            uint256 b = _sumOf(before, before[i].token);
            uint256 a = _sumOf(after_, before[i].token);
            assertGe((a + tol) * 1e18, b * (1e18 + f), why);
        }
    }

    function _sumOf(Amount[] memory list, address token) internal pure returns (uint256 total) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i].token == token) total += list[i].amount;
        }
    }

    function _approveUnwindInputs(uint256 fractionWad) internal {
        Amount[] memory needs = adapter.unwindInputs(fractionWad);
        for (uint256 i; i < needs.length; ++i) vault.approveFor(needs[i].token, address(adapter), needs[i].amount);
    }
}
