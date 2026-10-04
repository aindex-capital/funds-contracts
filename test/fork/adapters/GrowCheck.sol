// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdapter, Amount} from "../../../src/interfaces/IAdapter.sol";
import {IPriceRouter} from "../../../src/interfaces/IPriceRouter.sol";

interface IApprovingVault {
    function approveFor(address token, address spender, uint256 amount) external;
}

/**
 * @notice The suite's grow check for fork tests, against live venues: run `grow(0)` (fees out), deal the vault
 *         what `growInputs(f)` asks for, approve it as the controller, `grow(f)`, then require the approval used
 *         up, every position and debt grown by at least `f` (less `tol` raw units), every debt by no more than `f`
 *         plus the teller's two raw units (TellerMath.TOLERANCE: old holders must not carry new debt), and nothing
 *         loose in the adapter.
 */
abstract contract GrowCheck is Test {
    function _growChecked(
        IAdapter a,
        address vault_,
        address controller_,
        IPriceRouter router_,
        uint256 f,
        uint256 tol
    ) internal returns (Amount[] memory needs, Amount[] memory used) {
        vm.prank(controller_);
        a.grow(0);
        (Amount[] memory held0, Amount[] memory owed0) = a.positions(router_);
        needs = a.growInputs(f);
        for (uint256 i; i < needs.length; ++i) _fundForGrow(needs[i].token, vault_, needs[i].amount);
        vm.startPrank(controller_);
        for (uint256 i; i < needs.length; ++i) {
            IApprovingVault(vault_).approveFor(needs[i].token, address(a), needs[i].amount);
        }
        used = a.grow(f);
        vm.stopPrank();
        for (uint256 i; i < needs.length; ++i) {
            assertEq(IERC20(needs[i].token).allowance(vault_, address(a)), 0, "grow did not pull growInputs");
            emit log_named_address("grow input token", needs[i].token);
            emit log_named_uint("  declared", needs[i].amount);
        }
        for (uint256 i; i < used.length; ++i) emit log_named_uint("  used", used[i].amount);
        (Amount[] memory held1, Amount[] memory owed1) = a.positions(router_);
        _grew(held0, held1, f, tol, "a position grew by less than the fraction");
        _grew(owed0, owed1, f, tol, "a debt grew by less than the fraction");
        for (uint256 i; i < owed0.length; ++i) {
            uint256 x = _sum(owed0, owed0[i].token);
            uint256 y = _sum(owed1, owed0[i].token);
            assertLe(y * 1e18, x * (1e18 + f) + 2e18, "a debt grew by more than the teller's slack");
        }
        for (uint256 i; i < needs.length; ++i) {
            assertEq(IERC20(needs[i].token).balanceOf(address(a)), 0, "adapter holds loose tokens after grow");
        }
    }

    /// @dev Stands in for the teller's purchases. Override for tokens `deal` cannot write (tokenized stocks).
    function _fundForGrow(address token, address vault_, uint256 amount) internal virtual {
        deal(token, vault_, IERC20(token).balanceOf(vault_) + amount);
    }

    function _grew(Amount[] memory b, Amount[] memory a, uint256 f, uint256 tol, string memory why) internal {
        for (uint256 i; i < b.length; ++i) {
            uint256 x = _sum(b, b[i].token);
            uint256 y = _sum(a, b[i].token);
            emit log_named_address("position token", b[i].token);
            emit log_named_uint("  before", x);
            emit log_named_uint("  after", y);
            assertGe((y + tol) * 1e18, x * (1e18 + f), why);
        }
    }

    function _sum(Amount[] memory l, address t) internal pure returns (uint256 s) {
        for (uint256 i; i < l.length; ++i) {
            if (l[i].token == t) s += l[i].amount;
        }
    }
}
