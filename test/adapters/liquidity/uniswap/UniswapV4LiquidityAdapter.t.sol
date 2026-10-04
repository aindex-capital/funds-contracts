// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FundTestBase} from "../../../utils/FundTestBase.sol";
import {MockERC20} from "../../../utils/Mocks.sol";
import {AdapterSuite} from "../../AdapterSuite.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {IWETH9} from "../../../../src/interfaces/external/uniswap/IWETH9.sol";
import {UniswapV4LiquidityAdapter} from "../../../../src/adapters/liquidity/UniswapV4LiquidityAdapter.sol";
import {OraclePositionMath} from "../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {V4PoolManagerCode} from "./V4PoolManagerCode.sol";
import {V4Helper, MockWETH, AfterSwapHook, RefuseAddHook, RemoveHook} from "./UniswapMocks.sol";

/// @notice A Fund with 10,000 USDG and 5,000 TKN ($2 each), a real v4 PoolManager and a deep TKN/USDG pool at
///         the fair price.
abstract contract V4World is FundTestBase {
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    V4Helper internal helper;
    MockERC20 internal tkn;
    MockWETH internal weth;
    UniswapV4LiquidityAdapter internal impl;
    UniswapV4LiquidityAdapter internal lp;
    PoolKey internal key;

    function _setUpV4(bytes memory config) internal {
        _setUpCore();
        tkn = new MockERC20("Token", "TKN", 18);
        _price(address(tkn), 2e18, PriceClass.Feed, 0);
        weth = new MockWETH();
        _price(address(weth), 3000e18, PriceClass.Feed, 0);

        pm = IPoolManager(V4PoolManagerCode.deploy(address(this)));
        helper = new V4Helper(pm);
        tkn.mint(address(helper), 1e30);
        usdg.mint(address(helper), 1e30);
        vm.deal(address(helper), 1e9 ether);

        key = _key(address(tkn), address(usdg), address(0));
        _initAtFair(key);
        _seedLiquidity(key, 1_000_000e18);

        _createFund(_openDial(), 10_000e6);
        tkn.mint(address(vault), 5_000e18);
        vm.prank(address(controller));
        vault.track(address(tkn));

        impl = new UniswapV4LiquidityAdapter(pm, IWETH9(address(weth)));
        registry.register(address(impl), "");
        lp = UniswapV4LiquidityAdapter(payable(_enable(address(impl), config)));
    }

    // ------------------------------------------------------------ pools

    function _key(address a, address b, address hooks) internal pure returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(hooks));
    }

    function _asset(Currency c) internal view returns (address) {
        return c.isAddressZero() ? address(weth) : Currency.unwrap(c);
    }

    function _fairSqrt(PoolKey memory k) internal view returns (uint160) {
        address a0 = _asset(k.currency0);
        address a1 = _asset(k.currency1);
        return OraclePositionMath.sqrtPriceFromPrices(
            source.prices(a0), OraclePositionMath.decimalsOf(a0), source.prices(a1), OraclePositionMath.decimalsOf(a1)
        );
    }

    function _initAtFair(PoolKey memory k) internal {
        pm.initialize(k, _fairSqrt(k));
    }

    /// @dev Third-party liquidity worth about `usd` dollars a side, across +-30% of the price.
    function _seedLiquidity(PoolKey memory k, uint256 usd) internal {
        (int24 lo, int24 hi) = _range(k, 3000);
        address a0 = _asset(k.currency0);
        address a1 = _asset(k.currency1);
        uint256 x0 = usd * 10 ** OraclePositionMath.decimalsOf(a0) / source.prices(a0);
        uint256 x1 = usd * 10 ** OraclePositionMath.decimalsOf(a1) / source.prices(a1);
        helper.addAmounts(k, lo, hi, x0, x1);
    }

    /// @dev A range of +-`half` ticks around the pool's current tick, on the spacing.
    function _range(PoolKey memory k, int24 half) internal view returns (int24 lo, int24 hi) {
        (, int24 tick,,) = pm.getSlot0(k.toId());
        int24 s = k.tickSpacing;
        int24 c = tick / s;
        if (tick < 0 && tick % s != 0) c--;
        lo = (c * s) - (half / s) * s;
        hi = (c * s) + (half / s + 1) * s;
    }

    // ------------------------------------------------------------ actions

    /// @dev Amounts given per asset; ordered into currency0 and currency1 here.
    function _mint(PoolKey memory k, int24 lo, int24 hi, address assetA, uint256 amountA, uint256 amountB)
        internal
        view
        returns (bytes memory)
    {
        (uint256 a0, uint256 a1) = _asset(k.currency0) == assetA ? (amountA, amountB) : (amountB, amountA);
        return abi.encode(uint8(0), k, lo, hi, a0, a1, uint256(0), uint256(0));
    }

    function _act(address adapter_, bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(adapter_, action);
    }

    function _nav() internal view returns (uint256 n) {
        bool complete;
        (n, complete) = controller.nav(uint8(Side.Fair));
        require(complete, "book incomplete");
    }

    function _firstId() internal view returns (uint256) {
        return lp.positionList()[0].id;
    }

    function _liquidity(UniswapV4LiquidityAdapter.Position memory p) internal view returns (uint128 l) {
        (l,,) = pm.getPositionInfo(p.key.toId(), address(lp), p.tickLower, p.tickUpper, bytes32(p.id));
    }

    function _held(address token) internal view returns (uint256) {
        (Amount[] memory a,) = lp.positions(router);
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token == token) return a[i].amount;
        }
        return 0;
    }

    function _positionUsd() internal view returns (uint256 usd) {
        (Amount[] memory a,) = lp.positions(router);
        for (uint256 i; i < a.length; ++i) {
            (uint256 v,,) = router.value(a[i].token, a[i].amount, Side.Fair);
            usd += v;
        }
    }

    function _hookAt(address implementation, uint160 flags) internal returns (address h) {
        h = address((uint160(0x4444) << 144) | flags);
        vm.etch(h, implementation.code);
    }
}

contract UniswapV4LiquidityAdapterTest is V4World {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpV4("");
    }

    function test_MintIsAPositionAtFairValue() public {
        uint256 before = _nav();
        (int24 lo, int24 hi) = _range(key, 600);
        bytes memory r = _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        (uint256 id, uint128 liquidity,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        assertEq(id, 1);
        assertGt(liquidity, 0);
        assertEq(_liquidity(lp.positionList()[0]), liquidity, "the clone owns the position in the PoolManager");
        assertApproxEqRel(_nav(), before, 1e12, "minting at the fair price keeps NAV");
        assertApproxEqRel(_positionUsd(), 4_000e18, 0.05e18, "most of both went in; the rest went back to the vault");
        assertLe(_positionUsd(), 4_000e18);
        assertEq(usdg.balanceOf(address(lp)), 0);
        assertEq(tkn.balanceOf(address(lp)), 0);
    }

    function test_MovingThePoolDoesNotMoveNav() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        uint256 navBefore = _nav();
        uint256 tknBefore = _held(address(tkn));

        // Someone dumps TKN until its pool price is 30% below fair, right through our range.
        (uint160 fair,,,) = pm.getSlot0(key.toId());
        bool tknIs0 = Currency.unwrap(key.currency0) == address(tkn);
        uint160 limit = tknIs0 ? uint160(uint256(fair) * 836 / 1000) : uint160(uint256(fair) * 1196 / 1000);
        helper.swap(key, tknIs0, 1e30, limit);
        (uint160 spot,,,) = pm.getSlot0(key.toId());
        assertEq(spot, limit, "the pool moved");

        uint256 navAfter = _nav();
        assertGe(navAfter, navBefore, "only fees may change NAV");
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "NAV moved with the pool");

        // At the pool's price the position is now all TKN; at the fair price it is not.
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        (uint256 s0, uint256 s1) = OraclePositionMath.amountsForLiquidity(
            spot, TickMath.getSqrtPriceAtTick(p.tickLower), TickMath.getSqrtPriceAtTick(p.tickUpper), _liquidity(p)
        );
        uint256 tknAtSpot = tknIs0 ? s0 : s1;
        assertGt(tknAtSpot, tknBefore * 3 / 2, "spot valuation would have swung");
        assertApproxEqRel(_held(address(tkn)), tknBefore, 0.01e18, "fair valuation did not");
    }

    function test_FeesAreCountedAndCollected() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        uint256 navBefore = _nav();
        bool tknIs0 = Currency.unwrap(key.currency0) == address(tkn);
        // Trade back and forth: the price ends where it started, the fees stay.
        for (uint256 i; i < 3; ++i) {
            helper.swap(key, tknIs0, 20_000e18, tknIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            helper.swap(key, !tknIs0, 40_000e6, tknIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1);
        }
        uint256 navWithFees = _nav();
        assertGt(navWithFees, navBefore, "uncollected fees count");

        uint256 usdgBefore = usdg.balanceOf(address(vault));
        uint256 tknBefore = tkn.balanceOf(address(vault));
        bytes memory r = _act(address(lp), abi.encode(uint8(3), _firstId()));
        (uint256 f0, uint256 f1) = abi.decode(r, (uint256, uint256));
        assertGt(f0 + f1, 0);
        assertEq(usdg.balanceOf(address(vault)) + tkn.balanceOf(address(vault)), usdgBefore + tknBefore + f0 + f1);
        assertApproxEqRel(_nav(), navWithFees, 1e12, "collecting moves fees, not value");
    }

    function test_DecreaseAndCloseSendToVault() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        uint128 l = _liquidity(p);
        uint256 navBefore = _nav();
        _act(address(lp), abi.encode(uint8(2), p.id, l / 2, uint256(0), uint256(0)));
        assertEq(_liquidity(p), l - l / 2);
        _act(address(lp), abi.encode(uint8(2), p.id, l - l / 2, uint256(0), uint256(0)));
        assertEq(lp.positionList().length, 0, "an empty position is forgotten");
        assertApproxEqRel(_nav(), navBefore, 1e12);
        assertEq(usdg.balanceOf(address(lp)) + tkn.balanceOf(address(lp)), 0);
    }

    function test_DecreaseMinimumsHold() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        uint128 l = _liquidity(p);
        vm.prank(manager);
        vm.expectPartialRevert(UniswapV4LiquidityAdapter.BelowMinimum.selector);
        controller.act(address(lp), abi.encode(uint8(2), p.id, l, type(uint256).max, uint256(0)));
    }

    function test_RebalanceMovesTheRangeInOneAction() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        uint256 oldId = _firstId();
        uint256 navBefore = _nav();
        (int24 lo2, int24 hi2) = _range(key, 1200);
        bytes memory r = _act(
            address(lp), abi.encode(uint8(4), oldId, lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0))
        );
        (uint256 newId, uint128 l2) = abi.decode(r, (uint256, uint128));
        UniswapV4LiquidityAdapter.Position[] memory list = lp.positionList();
        assertEq(list.length, 1);
        assertEq(list[0].id, newId);
        assertTrue(newId != oldId);
        assertEq(list[0].tickLower, lo2);
        assertEq(_liquidity(list[0]), l2);
        (uint128 oldL,,) = pm.getPositionInfo(key.toId(), address(lp), lo, hi, bytes32(oldId));
        assertEq(oldL, 0, "old range emptied");
        assertApproxEqRel(_nav(), navBefore, 1e12, "rebalancing at the fair price keeps NAV");
        assertEq(usdg.balanceOf(address(lp)) + tkn.balanceOf(address(lp)), 0, "leftovers went to the vault");
    }

    function test_UnwindThroughController() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        uint128 l = _liquidity(p);
        uint256 navBefore = _nav();

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 0.5e18);
        // Half, less at most the exit margin (GrowMath.taken: a unit of each token, at most l / 1e6 + 1).
        assertGe(_liquidity(p), l - l / 2);
        assertLe(_liquidity(p), l - l / 2 + l / 1e6 + 1);
        assertApproxEqRel(_nav(), navBefore, 1e12);

        vm.prank(owner);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(lp.positionList().length, 0);
        (Amount[] memory left,) = lp.positions(router);
        assertEq(left.length, 0);
        assertApproxEqRel(_nav(), navBefore, 1e12, "unwinding returned what positions reported");
    }

    function test_SplitHandsOverItsSlice() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        uint256 positionUsd = _positionUsd();
        address holder = makeAddr("holder");
        vm.prank(address(controller));
        Amount[] memory sent = lp.split(0.25e18, holder);
        assertEq(sent.length, 2);
        uint256 got;
        for (uint256 i; i < sent.length; ++i) {
            assertEq(IERC20(sent[i].token).balanceOf(holder), sent[i].amount);
            (uint256 v,,) = router.value(sent[i].token, sent[i].amount, Side.Fair);
            got += v;
        }
        assertApproxEqRel(got, positionUsd / 4, 1e12, "a quarter of the position");
        assertApproxEqRel(_positionUsd(), positionUsd * 3 / 4, 1e12);
    }

    function test_OnlyThePoolManagerMayCallBack() public {
        vm.expectRevert(UniswapV4LiquidityAdapter.UnauthorizedCallback.selector);
        lp.unlockCallback("");
        // Even the PoolManager, when the unlock is not ours.
        vm.prank(address(pm));
        vm.expectRevert(UniswapV4LiquidityAdapter.UnauthorizedCallback.selector);
        lp.unlockCallback("");
    }

    function test_SwapOnlyHookPoolIsAccepted() public {
        address h = _hookAt(address(new AfterSwapHook()), Hooks.AFTER_SWAP_FLAG);
        PoolKey memory k = _key(address(tkn), address(usdg), h);
        _initAtFair(k);
        assertEq(lp.poolProblem(k), "");
        (int24 lo, int24 hi) = _range(k, 600);
        _act(address(lp), _mint(k, lo, hi, address(usdg), 1_000e6, 500e18));
        assertEq(lp.positionList().length, 1);
        vm.prank(manager);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(lp.positionList().length, 0);
    }

    function test_HookThatTouchesRemovalsIsRefused() public {
        address h = _hookAt(address(new RemoveHook()), Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        PoolKey memory k = _key(address(tkn), address(usdg), h);
        _initAtFair(k);
        assertEq(lp.poolProblem(k), "hook can act on liquidity removal");
        (int24 lo, int24 hi) = _range(k, 600);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4LiquidityAdapter.HookNotSupported.selector, h));
        controller.act(address(lp), _mint(k, lo, hi, address(usdg), 1_000e6, 500e18));
    }

    function test_HookThatRefusesUsFailsCleanly() public {
        address h = _hookAt(address(new RefuseAddHook()), Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        PoolKey memory k = _key(address(tkn), address(usdg), h);
        _initAtFair(k);
        (int24 lo, int24 hi) = _range(k, 600);
        vm.prank(manager);
        vm.expectPartialRevert(UniswapV4LiquidityAdapter.HookRefusedLiquidity.selector);
        controller.act(address(lp), _mint(k, lo, hi, address(usdg), 1_000e6, 500e18));
    }

    function test_UninitialisedPoolIsRefused() public {
        PoolKey memory k = PoolKey(key.currency0, key.currency1, 500, 10, IHooks(address(0)));
        vm.prank(manager);
        vm.expectPartialRevert(UniswapV4LiquidityAdapter.PoolNotInitialized.selector);
        controller.act(address(lp), _mint(k, -600, 600, address(usdg), 1_000e6, 500e18));
    }

    function test_NativeEtherPool() public {
        PoolKey memory k = _key(address(0), address(usdg), address(0));
        _initAtFair(k);
        _seedLiquidity(k, 1_000_000e18);
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(vault), 10 ether);
        vm.prank(address(controller));
        vault.track(address(weth));

        uint256 navBefore = _nav();
        (int24 lo, int24 hi) = _range(k, 600);
        _act(address(lp), _mint(k, lo, hi, address(weth), 1 ether, 3_000e6));
        assertGt(_held(address(weth)), 0, "native ether reported as WETH");
        assertEq(address(lp).balance, 0, "no loose ether");
        assertEq(weth.balanceOf(address(lp)), 0);
        assertApproxEqRel(_nav(), navBefore, 1e12);

        (int24 lo2, int24 hi2) = _range(k, 1200);
        _act(address(lp), abi.encode(uint8(4), _firstId(), lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0)));
        assertEq(address(lp).balance, 0);
        assertApproxEqRel(_nav(), navBefore, 1e12);

        address holder = makeAddr("holder");
        vm.prank(address(controller));
        lp.split(0.5e18, holder);
        assertGt(weth.balanceOf(holder), 0, "the holder gets WETH");

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(address(lp).balance, 0);
        assertEq(lp.positionList().length, 0);
    }

    function test_StrayEtherIsRefused() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(lp).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_UnavailablePriceMakesTheBookIncomplete() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        source.setDown(address(tkn), true);
        assertGt(_held(address(tkn)), 0, "the unpriced token is reported, not hidden");
        assertEq(_held(address(usdg)), 0);
        (, bool complete) = controller.nav(uint8(Side.Fair));
        assertFalse(complete);
    }

    function test_NoMarketTokenTakesTheWholePosition() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        _price(address(tkn), 0, PriceClass.None, 0);
        assertEq(_held(address(usdg)), 0, "valued as if arbitrage drained the USDG");
        assertGt(_held(address(tkn)), 1_000e18);
    }

    function test_DescribeIsJson() public view {
        string memory d = lp.describe();
        assertEq(vm.parseJsonString(d, ".actions[4].name"), "rebalance");
        assertEq(vm.parseJsonUint(d, ".actions[0].id"), 0);
    }

    function test_TooManyPositions() public {
        (int24 lo, int24 hi) = _range(key, 600);
        for (uint256 i; i < lp.MAX_POSITIONS(); ++i) {
            _act(address(lp), _mint(key, lo, hi, address(usdg), 10e6, 5e18));
        }
        vm.prank(manager);
        vm.expectRevert(UniswapV4LiquidityAdapter.TooManyPositions.selector);
        controller.act(address(lp), _mint(key, lo, hi, address(usdg), 10e6, 5e18));
    }
}

contract UniswapV4RestrictedTest is V4World {
    function setUp() public {
        // Built in two steps: the allowed pool's id is only known once the tokens exist.
        _setUpV4("");
    }

    function test_OnlyConfiguredPools() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PoolId.unwrap(key.toId());
        UniswapV4LiquidityAdapter only = UniswapV4LiquidityAdapter(payable(_enable(address(impl), abi.encode(ids))));
        assertTrue(only.restricted());
        PoolKey memory other = PoolKey(key.currency0, key.currency1, 500, 10, IHooks(address(0)));
        _initAtFair(other);
        (int24 lo, int24 hi) = _range(other, 600);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4LiquidityAdapter.PoolNotAllowed.selector, PoolId.unwrap(other.toId())));
        controller.act(address(only), _mint(other, lo, hi, address(usdg), 1_000e6, 500e18));
        (lo, hi) = _range(key, 600);
        _act(address(only), _mint(key, lo, hi, address(usdg), 1_000e6, 500e18));
    }
}

/// @notice The shared adapter rules, against a real PoolManager.
/// @notice `grow`: the same fraction more liquidity in every position, exactly what the PoolManager charges,
///         fees to the vault.
contract UniswapV4GrowTest is V4World {
    function setUp() public {
        _setUpV4("");
    }

    function _grow(uint256 f) internal returns (Amount[] memory needs, Amount[] memory used) {
        needs = lp.growInputs(f);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            if (needs[i].token == address(weth)) {
                vm.deal(address(this), needs[i].amount);
                vm.stopPrank();
                weth.deposit{value: needs[i].amount}();
                weth.transfer(address(vault), needs[i].amount);
                vm.startPrank(address(controller));
            } else {
                MockERC20(needs[i].token).mint(address(vault), needs[i].amount);
            }
            vault.approveFor(needs[i].token, address(lp), needs[i].amount);
        }
        used = lp.grow(f);
        vm.stopPrank();
        for (uint256 i; i < needs.length; ++i) {
            assertEq(IERC20(needs[i].token).allowance(address(vault), address(lp)), 0, "inputs not all pulled");
        }
        assertEq(address(lp).balance, 0, "no loose ether");
    }

    /// The add names its liquidity exactly, so the pool takes exactly what `growInputs` declared.
    function test_GrowTakesExactlyTheInputsAndCollectsFees() public {
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        uint128 l0 = _liquidity(p);
        // Swaps both ways pay fees to the range.
        helper.swap(key, true, 1_000 * 10 ** OraclePositionMath.decimalsOf(_asset(key.currency0)), TickMath.MIN_SQRT_PRICE + 1);
        helper.swap(key, false, 1_000 * 10 ** OraclePositionMath.decimalsOf(_asset(key.currency1)), TickMath.MAX_SQRT_PRICE - 1);
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        _grow(0);
        assertGt(usdg.balanceOf(address(vault)), usdgBefore, "fees not collected to the vault");
        assertEq(_liquidity(p), l0);

        uint256 u0 = _held(address(usdg));
        uint256 k0 = _held(address(tkn));
        (Amount[] memory needs, Amount[] memory used) = _grow(0.5e18);
        for (uint256 i; i < needs.length; ++i) assertEq(used[i].amount, needs[i].amount, "pool took other than declared");
        assertGe(uint256(_liquidity(p)) * 2, uint256(l0) * 3);
        assertGe(_held(address(usdg)) * 2, u0 * 3);
        assertGe(_held(address(tkn)) * 2, k0 * 3);
        assertEq(usdg.balanceOf(address(lp)), 0);
        assertEq(tkn.balanceOf(address(lp)), 0);
    }

    function test_GrowNativeEtherPool() public {
        PoolKey memory k = _key(address(0), address(usdg), address(0));
        _initAtFair(k);
        _seedLiquidity(k, 1_000_000e18);
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(vault), 10 ether);
        vm.prank(address(controller));
        vault.track(address(weth));
        (int24 lo, int24 hi) = _range(k, 600);
        _act(address(lp), _mint(k, lo, hi, address(weth), 1 ether, 3_000e6));
        uint256 w0 = _held(address(weth));
        _grow(2e18);
        assertGe(_held(address(weth)), w0 * 3, "native position did not triple");
        assertEq(weth.balanceOf(address(lp)), 0);
    }

    function test_GrowOnlyController() public {
        vm.expectRevert();
        lp.grow(0.1e18);
    }
}

contract UniswapV4AdapterSuite is V4World, AdapterSuite {
    /// @dev A range side worth only a few raw units at the fair price may read one short after rounding.
    function _growTolerance() internal pure override returns (uint256) {
        return 2;
    }

    using StateLibrary for IPoolManager;

    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpV4("");
        (int24 lo, int24 hi) = _range(key, 600);
        _act(address(lp), _mint(key, lo, hi, address(usdg), 2_000e6, 1_000e18));
        return IAdapter(address(lp));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        UniswapV4LiquidityAdapter.Position memory p = lp.positionList()[0];
        uint256 kind = seed % 5;
        uint256 amount = bound(seed >> 8, 1e6, 2_000e6);
        if (kind == 0) {
            (int24 lo, int24 hi) = _range(key, 1200);
            return _mint(key, lo, hi, address(usdg), amount, amount * 1e12 / 2);
        }
        if (kind == 1) {
            (uint256 a0, uint256 a1) = Currency.unwrap(key.currency0) == address(usdg)
                ? (amount, amount * 1e12 / 2)
                : (amount * 1e12 / 2, amount);
            return abi.encode(uint8(1), p.id, a0, a1, uint256(0), uint256(0));
        }
        if (kind == 2) return abi.encode(uint8(2), p.id, _liquidity(p) / 2, uint256(0), uint256(0));
        if (kind == 3) return abi.encode(uint8(3), p.id);
        (int24 lo2, int24 hi2) = _range(key, 1800);
        return abi.encode(uint8(4), p.id, lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0));
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdg);
        t[1] = address(tkn);
    }
}

/// @notice With the most positions a clone may hold, `positions` fits well inside the controller's gas cap,
///         read cold in its own transaction.
contract UniswapV4GasTest is V4World {
    function setUp() public {
        _setUpV4("");
        for (uint256 i; i < lp.MAX_POSITIONS(); ++i) {
            (int24 lo, int24 hi) = _range(key, int24(int256(300 + 60 * i)));
            _act(address(lp), _mint(key, lo, hi, address(usdg), 100e6, 50e18));
        }
    }

    function test_PositionsFitTheGasCap() public {
        uint256 cap = controller.POSITIONS_GAS();
        uint256 g = gasleft();
        (bool ok,) = address(lp).staticcall{gas: cap}(abi.encodeCall(lp.positions, (router)));
        uint256 used = g - gasleft();
        emit log_named_uint("positions() gas, 10 positions, cold", used);
        assertTrue(ok);
        assertLt(used, cap / 2);
    }
}
