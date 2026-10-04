// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V3World} from "./uniswap/UniswapV3LiquidityAdapter.t.sol";
import {FablesWorld} from "./fables/FablesLiquidityAdapter.t.sol";
import {MockNPM} from "./uniswap/UniswapMocks.sol";
import {MockFablesLedger} from "./fables/FablesMocks.sol";

/// @notice One liquidity position that cannot be exited must not stop a leaver taking its slice of the others.
contract V3ExitIsolationTest is V3World {
    function setUp() public {
        _setUpV3(false);
    }

    function test_StuckPositionIsSkippedInSplit() public {
        (int24 lo, int24 hi) = _range(600);
        (uint256 stuck,,,) =
            abi.decode(_act(address(lp), _mint(lo, hi, 1_000e6, 500e18)), (uint256, uint128, uint256, uint256));
        (lo, hi) = _range(1200);
        (uint256 fine, uint128 l,,) =
            abi.decode(_act(address(lp), _mint(lo, hi, 1_000e6, 500e18)), (uint256, uint128, uint256, uint256));
        vm.mockCallRevert(address(npm), abi.encodePacked(MockNPM.decreaseLiquidity.selector, stuck), "stuck");
        address holder = makeAddr("holder");
        vm.prank(address(controller));
        lp.split(0.25e18, holder);
        assertGt(IERC20(t0).balanceOf(holder) + IERC20(t1).balanceOf(holder), 0, "the other position paid its slice");
        // The fraction less at most the exit margin (GrowMath.taken: a unit of each token, at most l / 1e6 + 1).
        assertGe(_liquidity(fine), l - l / 4);
        assertLe(_liquidity(fine), l - l / 4 + l / 1e6 + 1);
        vm.clearMockedCalls();
    }

    function test_StuckPositionIsSkippedInUnwind() public {
        (int24 lo, int24 hi) = _range(600);
        (uint256 stuck, uint128 ls,,) =
            abi.decode(_act(address(lp), _mint(lo, hi, 1_000e6, 500e18)), (uint256, uint128, uint256, uint256));
        (lo, hi) = _range(1200);
        (uint256 fine, uint128 l,,) =
            abi.decode(_act(address(lp), _mint(lo, hi, 1_000e6, 500e18)), (uint256, uint128, uint256, uint256));
        vm.mockCallRevert(address(npm), abi.encodePacked(MockNPM.decreaseLiquidity.selector, stuck), "stuck");
        vm.prank(address(controller));
        lp.unwind(0.5e18);
        vm.clearMockedCalls();
        assertEq(_liquidity(stuck), ls, "the stuck position stays whole");
        assertGe(_liquidity(fine), l - l / 2);
        assertLe(_liquidity(fine), l - l / 2 + l / 1e6 + 1);
    }
}

contract FablesExitIsolationTest is FablesWorld {
    function setUp() public {
        _buildWorld();
    }

    function test_StuckRangeIsSkippedInSplit() public {
        _doAct(_dep(mid - 600, mid + 600, 50e18, 5_000e6));
        _doAct(_dep(mid - 1200, mid + 1200, 50e18, 5_000e6));
        uint256 stuck = _rid(mid - 600, mid + 600);
        uint256 fine = _rid(mid - 1200, mid + 1200);
        uint256 sStuck = ledger.balanceOf(address(fab), stuck);
        uint256 sFine = ledger.balanceOf(address(fab), fine);
        vm.mockCallRevert(
            address(ledger), abi.encodeWithSelector(MockFablesLedger.withdraw.selector, key, mid - 600), "stuck"
        );
        address leaver = makeAddr("leaver");
        vm.prank(address(controller));
        fab.split(0.25e18, leaver);
        vm.clearMockedCalls();
        assertEq(ledger.balanceOf(address(fab), stuck), sStuck, "the stuck range stays whole");
        uint256 left = ledger.balanceOf(address(fab), fine);
        assertGe(left, sFine - sFine / 4, "the other range paid its slice");
        assertLe(left, sFine - sFine / 4 + sFine / 1e6 + 1, "less at most the exit margin");
        assertGt(tkn.balanceOf(leaver), 0);
    }
}
