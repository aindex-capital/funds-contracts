// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {UniswapForkBase} from "./UniswapForkBase.sol";
import {IAdapter, Amount} from "../../../../../src/interfaces/IAdapter.sol";
import {
    IUniswapV3Pool,
    INonfungiblePositionManager
} from "../../../../../src/interfaces/external/uniswap/IUniswapV3.sol";
import {UniswapV3LiquidityAdapter} from "../../../../../src/adapters/liquidity/UniswapV3LiquidityAdapter.sol";
import {OraclePositionMath} from "../../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {GrowCheck} from "../../GrowCheck.sol";

/// @notice Mint, value, rebalance, move the pool, unwind and split a USDG/WETH position on the live v3 pool.
contract UniswapV3LiquidityForkTest is UniswapForkBase, GrowCheck {
    IUniswapV3Pool internal pool = IUniswapV3Pool(V3_USDG_WETH_500);
    INonfungiblePositionManager internal npm = INonfungiblePositionManager(V3_NPM);
    UniswapV3LiquidityAdapter internal lp;

    function setUp() public {
        if (!_fork()) return;
        (uint160 sqrtP,,,,,,) = pool.slot0();
        _setUpFund(_wethUsd(sqrtP), 100_000e6, 20 ether);
        lp = UniswapV3LiquidityAdapter(_enable(address(new UniswapV3LiquidityAdapter(npm)), ""));
    }

    function test_Fork_V3_UsdgWeth() public {
        assertEq(pool.token0(), WETH);
        uint256 navStart = _nav();
        (, int24 tick,,,,,) = pool.slot0();

        // Mint: 5 WETH and the matching USDG, +-5% around the price.
        (int24 lo, int24 hi) = _range(tick, 10, 500);
        uint256 usdg = 5 * source.prices(WETH) / 1e12;
        bytes memory r = _act(
            address(lp), abi.encode(uint8(0), WETH, USDG, uint24(500), lo, hi, uint256(5 ether), usdg, uint256(0), uint256(0))
        );
        (uint256 id,,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        assertEq(npm.ownerOf(id), address(lp), "the clone holds the NFT");
        uint256 positionUsd = _positionUsd(IAdapter(address(lp)));
        assertGt(positionUsd, 5 * source.prices(WETH));
        assertApproxEqRel(_nav(), navStart, 0.0001e18, "minted at fair value");

        // Rebalance to +-10%.
        (int24 lo2, int24 hi2) = _range(tick, 10, 1000);
        r = _act(address(lp), abi.encode(uint8(4), id, lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0)));
        (id,) = abi.decode(r, (uint256, uint128));
        assertEq(lp.positionIds().length, 1);
        assertEq(lp.positionIds()[0], id);
        assertApproxEqRel(_nav(), navStart, 0.0001e18, "rebalanced at fair value");
        uint256 navBefore = _nav();
        uint256 wethBefore = _held(IAdapter(address(lp)), WETH);

        // Someone buys WETH until the pool is ~10% above fair.
        (uint160 sqrtFair,,,,,,) = pool.slot0();
        uint160 limit = uint160(uint256(sqrtFair) * 1049 / 1000);
        pool.swap(address(this), false, int256(1e15), limit, "");
        (uint160 spot,,,,,,) = pool.slot0();
        assertEq(spot, limit, "the pool moved");

        uint256 navAfter = _nav();
        assertGe(navAfter, navBefore, "only fees may change NAV");
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "NAV moved with the pool");
        // At the pool's price the position has sold most of its WETH; at the fair price it has not.
        (,,,,, int24 pLo, int24 pHi, uint128 l,,,,) = npm.positions(id);
        (uint256 wethAtSpot,) = OraclePositionMath.amountsForLiquidity(
            spot, TickMath.getSqrtPriceAtTick(pLo), TickMath.getSqrtPriceAtTick(pHi), l
        );
        emit log_named_decimal_uint("NAV before the pool moved (USD)", navBefore, 18);
        emit log_named_decimal_uint("NAV after the pool moved ~10% (USD)", navAfter, 18);
        emit log_named_decimal_uint("position WETH at fair price, before", wethBefore, 18);
        emit log_named_decimal_uint("position WETH at fair price, after", _held(IAdapter(address(lp)), WETH), 18);
        emit log_named_decimal_uint("position WETH at the pool's price, after", wethAtSpot, 18);
        assertLt(wethAtSpot, wethBefore * 3 / 4, "spot valuation would have swung");
        assertApproxEqRel(_held(IAdapter(address(lp)), WETH), wethBefore, 0.01e18, "fair valuation did not");

        // Unwind half while the pool is still off: removing does not trade, so it cannot lose at fair prices.
        vm.prank(manager);
        controller.unwindAdapter(address(lp), 0.5e18);
        assertApproxEqRel(_liquidity(id), l / 2, 1e12);
        assertGe(_nav(), navAfter * 9999 / 10000);

        // In-kind exit of a quarter of what is left.
        address holder = makeAddr("holder");
        vm.prank(address(controller));
        Amount[] memory sent = lp.split(0.25e18, holder);
        assertGt(IERC20(USDG).balanceOf(holder) + IERC20(WETH).balanceOf(holder), 0);
        assertEq(sent.length, 2);

        // Close out.
        vm.prank(manager);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(lp.positionIds().length, 0);
        assertEq(IERC20(USDG).balanceOf(address(lp)) + IERC20(WETH).balanceOf(address(lp)), 0);
    }

    /// Deposits into the existing mix on the live pool, after swaps have paid the range fees and left the pool
    /// a little off the fair price: liquidity grows by 10%, then 100%, at the pool's price, and the position at
    /// fair prices grows by at least as much. `grow(0)` sends the fees to the vault first.
    function test_Fork_V3_GrowByFraction() public {
        (, int24 tick,,,,,) = pool.slot0();
        (int24 lo, int24 hi) = _range(tick, 10, 500);
        uint256 usdg = 5 * source.prices(WETH) / 1e12;
        bytes memory r = _act(
            address(lp), abi.encode(uint8(0), WETH, USDG, uint24(500), lo, hi, uint256(5 ether), usdg, uint256(0), uint256(0))
        );
        (uint256 id, uint128 l0,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        (uint160 sqrtFair,,,,,,) = pool.slot0();
        pool.swap(address(this), false, int256(1e15), uint160(uint256(sqrtFair) * 1005 / 1000), "");
        pool.swap(address(this), true, int256(1e15), uint160(uint256(sqrtFair) * 1002 / 1000), "");
        uint256 vaultUsdg = IERC20(USDG).balanceOf(address(vault));
        _growChecked(IAdapter(address(lp)), address(vault), address(controller), router, 0.1e18, 2);
        assertGt(IERC20(USDG).balanceOf(address(vault)), vaultUsdg, "fees did not reach the vault");
        _growChecked(IAdapter(address(lp)), address(vault), address(controller), router, 1e18, 2);
        assertGe(uint256(_liquidity(id)) * 10, uint256(l0) * 22, "liquidity did not grow 2.2x");
    }

    function _liquidity(uint256 id) internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = npm.positions(id);
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "not the pool");
        if (amount0 > 0) {
            deal(WETH, address(this), uint256(amount0));
            IERC20(WETH).transfer(msg.sender, uint256(amount0));
        }
        if (amount1 > 0) {
            deal(USDG, address(this), uint256(amount1));
            IERC20(USDG).transfer(msg.sender, uint256(amount1));
        }
    }
}
