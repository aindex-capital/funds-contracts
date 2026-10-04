// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {UniswapForkBase} from "./UniswapForkBase.sol";
import {IAdapter, Amount} from "../../../../../src/interfaces/IAdapter.sol";
import {IWETH9} from "../../../../../src/interfaces/external/uniswap/IWETH9.sol";
import {UniswapV4LiquidityAdapter} from "../../../../../src/adapters/liquidity/UniswapV4LiquidityAdapter.sol";
import {OraclePositionMath} from "../../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {V4Helper} from "../../../../adapters/liquidity/uniswap/UniswapMocks.sol";
import {GrowCheck} from "../../GrowCheck.sol";

/// @notice Mint, value, rebalance, move the pool, unwind and split on the live v4 PoolManager: the hookless
///         WETH/USDG 0.05% pool, and the native ETH/USDG 0.05% pool.
contract UniswapV4LiquidityForkTest is UniswapForkBase, GrowCheck {
    using StateLibrary for IPoolManager;

    IPoolManager internal pm = IPoolManager(V4_POOL_MANAGER);
    UniswapV4LiquidityAdapter internal lp;
    V4Helper internal helper;
    PoolKey internal wethKey;
    PoolKey internal ethKey;

    function setUp() public {
        if (!_fork()) return;
        wethKey = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 500, 10, IHooks(address(0)));
        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 500, 10, IHooks(address(0)));
        (uint160 sqrtP,,,) = pm.getSlot0(wethKey.toId());
        _setUpFund(_wethUsd(sqrtP), 100_000e6, 20 ether);
        lp = UniswapV4LiquidityAdapter(
            payable(_enable(address(new UniswapV4LiquidityAdapter(pm, IWETH9(WETH))), ""))
        );
        helper = new V4Helper(pm);
    }

    function test_Fork_V4_WethUsdg() public {
        assertEq(lp.poolProblem(wethKey), "", "hookless pool accepted");
        uint256 navStart = _nav();
        (, int24 tick,,) = pm.getSlot0(wethKey.toId());

        (int24 lo, int24 hi) = _range(tick, 10, 500);
        uint256 usdg = 2 * source.prices(WETH) / 1e12;
        bytes memory r =
            _act(address(lp), abi.encode(uint8(0), wethKey, lo, hi, uint256(2 ether), usdg, uint256(0), uint256(0)));
        (uint256 id,,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        assertApproxEqRel(_nav(), navStart, 0.0001e18, "minted at fair value");

        (int24 lo2, int24 hi2) = _range(tick, 10, 1000);
        r = _act(address(lp), abi.encode(uint8(4), id, lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0)));
        (id,) = abi.decode(r, (uint256, uint128));
        assertApproxEqRel(_nav(), navStart, 0.0001e18, "rebalanced at fair value");
        uint256 navBefore = _nav();
        uint256 wethBefore = _held(IAdapter(address(lp)), WETH);

        // Someone buys WETH until the pool is ~10% above fair.
        (uint160 sqrtFair,,,) = pm.getSlot0(wethKey.toId());
        uint160 limit = uint160(uint256(sqrtFair) * 1049 / 1000);
        deal(USDG, address(helper), 1e15);
        helper.swap(wethKey, false, 1e15, limit);
        (uint160 spot,,,) = pm.getSlot0(wethKey.toId());
        assertEq(spot, limit, "the pool moved");

        uint256 navAfter = _nav();
        assertGe(navAfter, navBefore, "only fees may change NAV");
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "NAV moved with the pool");
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        (uint128 l,,) = pm.getPositionInfo(wethKey.toId(), address(lp), p.tickLower, p.tickUpper, bytes32(p.id));
        (uint256 wethAtSpot,) = OraclePositionMath.amountsForLiquidity(
            spot, TickMath.getSqrtPriceAtTick(p.tickLower), TickMath.getSqrtPriceAtTick(p.tickUpper), l
        );
        emit log_named_decimal_uint("NAV before the pool moved (USD)", navBefore, 18);
        emit log_named_decimal_uint("NAV after the pool moved ~10% (USD)", navAfter, 18);
        emit log_named_decimal_uint("position WETH at fair price, before", wethBefore, 18);
        emit log_named_decimal_uint("position WETH at fair price, after", _held(IAdapter(address(lp)), WETH), 18);
        emit log_named_decimal_uint("position WETH at the pool's price, after", wethAtSpot, 18);
        assertLt(wethAtSpot, wethBefore * 3 / 4, "spot valuation would have swung");
        assertApproxEqRel(_held(IAdapter(address(lp)), WETH), wethBefore, 0.01e18, "fair valuation did not");

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 0.5e18);
        assertGe(_nav(), navAfter * 9999 / 10000, "removing at a moved price does not lose at fair prices");

        address holder = makeAddr("holder");
        vm.prank(address(controller));
        Amount[] memory sent = lp.split(0.25e18, holder);
        assertEq(sent.length, 2);
        assertGt(IERC20(USDG).balanceOf(holder) + IERC20(WETH).balanceOf(holder), 0);

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(lp.positionList().length, 0);
        assertEq(IERC20(USDG).balanceOf(address(lp)) + IERC20(WETH).balanceOf(address(lp)), 0);
    }

    function test_Fork_V4_NativeEther() public {
        uint256 navStart = _nav();
        (, int24 tick,,) = pm.getSlot0(ethKey.toId());
        (int24 lo, int24 hi) = _range(tick, 10, 500);
        uint256 usdg = 2 * source.prices(WETH) / 1e12;
        _act(address(lp), abi.encode(uint8(0), ethKey, lo, hi, uint256(2 ether), usdg, uint256(0), uint256(0)));
        assertGt(_held(IAdapter(address(lp)), WETH), 0, "native ether reported as WETH");
        assertEq(address(lp).balance, 0);
        // The native pool's price differs a little from the WETH pool the oracle read; that gap is the only
        // cost of the mint, and the loss budget sees it.
        assertApproxEqRel(_nav(), navStart, 0.001e18);

        address holder = makeAddr("holder");
        vm.prank(address(controller));
        lp.split(0.5e18, holder);
        assertGt(IERC20(WETH).balanceOf(holder) + IERC20(USDG).balanceOf(holder), 0);

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(lp.positionList().length, 0);
        assertEq(address(lp).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(lp)), 0);
    }

    /// Deposits into the existing mix on the live PoolManager: a WETH/USDG position and a native ETH/USDG one,
    /// with fees from real swaps, grow by 10% and then 100%. The pool takes exactly what `growInputs` declared.
    function test_Fork_V4_GrowByFraction() public {
        (, int24 tick,,) = pm.getSlot0(wethKey.toId());
        (int24 lo, int24 hi) = _range(tick, 10, 500);
        uint256 usdg = 2 * source.prices(WETH) / 1e12;
        _act(address(lp), abi.encode(uint8(0), wethKey, lo, hi, uint256(2 ether), usdg, uint256(0), uint256(0)));
        (, int24 etick,,) = pm.getSlot0(ethKey.toId());
        (int24 elo, int24 ehi) = _range(etick, 10, 800);
        _act(address(lp), abi.encode(uint8(0), ethKey, elo, ehi, uint256(2 ether), usdg, uint256(0), uint256(0)));

        (uint160 sqrtP,,,) = pm.getSlot0(wethKey.toId());
        deal(USDG, address(helper), 1e15);
        helper.swap(wethKey, false, 1e15, uint160(uint256(sqrtP) * 1003 / 1000));
        uint256 vaultUsdg = IERC20(USDG).balanceOf(address(vault));
        (Amount[] memory needs, Amount[] memory used) =
            _growChecked(IAdapter(address(lp)), address(vault), address(controller), router, 0.1e18, 2);
        assertGt(IERC20(USDG).balanceOf(address(vault)), vaultUsdg, "fees did not reach the vault");
        for (uint256 i; i < needs.length; ++i) assertEq(used[i].amount, needs[i].amount, "took other than declared");
        (needs, used) = _growChecked(IAdapter(address(lp)), address(vault), address(controller), router, 1e18, 2);
        for (uint256 i; i < needs.length; ++i) assertEq(used[i].amount, needs[i].amount, "took other than declared");
        assertEq(address(lp).balance, 0, "loose ether");
    }

    /// The Pons v2 hook acts on swaps only, so its pools pass the adapter's hook check.
    function test_Fork_PonsHookPassesTheCheck() public view {
        assertGt(PONS_V2_HOOK.code.length, 0);
        assertEq(uint160(PONS_V2_HOOK) & lp.UNSAFE_HOOK_FLAGS(), 0);
    }
}
