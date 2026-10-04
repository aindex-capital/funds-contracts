// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FundTestBase} from "../../../utils/FundTestBase.sol";
import {MockERC20} from "../../../utils/Mocks.sol";
import {AdapterSuite} from "../../AdapterSuite.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {INonfungiblePositionManager} from "../../../../src/interfaces/external/uniswap/IUniswapV3.sol";
import {UniswapV3LiquidityAdapter} from "../../../../src/adapters/liquidity/UniswapV3LiquidityAdapter.sol";
import {OraclePositionMath} from "../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {MockV3Factory, MockV3Pool, MockNPM, MockWETH} from "./UniswapMocks.sol";

/// @notice A Fund with 10,000 USDG and 5,000 TKN ($2 each), and a mocked v3 TKN/USDG pool at the fair price.
abstract contract V3World is FundTestBase {
    MockERC20 internal tkn;
    MockV3Factory internal v3factory;
    MockV3Pool internal pool;
    MockNPM internal npm;
    UniswapV3LiquidityAdapter internal impl;
    UniswapV3LiquidityAdapter internal lp;
    address internal t0;
    address internal t1;

    uint24 internal constant FEE = 3000;

    function _setUpV3(bool restrictToPool) internal {
        _setUpCore();
        tkn = new MockERC20("Token", "TKN", 18);
        _price(address(tkn), 2e18, PriceClass.Feed, 0);
        (t0, t1) = address(tkn) < address(usdg) ? (address(tkn), address(usdg)) : (address(usdg), address(tkn));

        v3factory = new MockV3Factory();
        pool = new MockV3Pool(t0, t1, FEE, 60, _fairSqrt());
        v3factory.setPool(t0, t1, FEE, address(pool));
        npm = new MockNPM(address(v3factory), address(new MockWETH()));

        _createFund(_openDial(), 10_000e6);
        tkn.mint(address(vault), 5_000e18);
        vm.prank(address(controller));
        vault.track(address(tkn));

        impl = new UniswapV3LiquidityAdapter(INonfungiblePositionManager(address(npm)));
        registry.register(address(impl), "");
        bytes memory config;
        if (restrictToPool) {
            address[] memory pools = new address[](1);
            pools[0] = address(pool);
            config = abi.encode(pools);
        }
        lp = UniswapV3LiquidityAdapter(_enable(address(impl), config));
    }

    function _fairSqrt() internal view returns (uint160) {
        return OraclePositionMath.sqrtPriceFromPrices(source.prices(t0), MockERC20(t0).decimals(), source.prices(t1), MockERC20(t1).decimals());
    }

    function _range(int24 half) internal view returns (int24 lo, int24 hi) {
        int24 tick = pool.tick();
        int24 c = tick / 60;
        if (tick < 0 && tick % 60 != 0) c--;
        lo = c * 60 - (half / 60) * 60;
        hi = c * 60 + (half / 60 + 1) * 60;
    }

    function _mint(int24 lo, int24 hi, uint256 usdgAmount, uint256 tknAmount) internal view returns (bytes memory) {
        (uint256 a0, uint256 a1) = t0 == address(usdg) ? (usdgAmount, tknAmount) : (tknAmount, usdgAmount);
        return abi.encode(uint8(0), t0, t1, FEE, lo, hi, a0, a1, uint256(0), uint256(0));
    }

    function _act(address a, bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(a, action);
    }

    function _nav() internal view returns (uint256 n) {
        bool complete;
        (n, complete) = controller.nav(uint8(Side.Fair));
        require(complete, "book incomplete");
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

    function _liquidity(uint256 id) internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = npm.positions(id);
    }

    /// @dev Fees as a swap would leave them: growth for every unit of in-range liquidity, tokens to the NPM.
    function _earn(uint256 fee0, uint256 fee1, uint128 inRangeLiquidity) internal {
        pool.growFees(fee0 * (1 << 128) / inRangeLiquidity, fee1 * (1 << 128) / inRangeLiquidity);
        MockERC20(t0).mint(address(npm), fee0);
        MockERC20(t1).mint(address(npm), fee1);
    }
}

contract UniswapV3LiquidityAdapterTest is V3World {
    function setUp() public {
        _setUpV3(false);
    }

    function test_MintHoldsTheNftAtFairValue() public {
        uint256 before = _nav();
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (uint256 id, uint128 l,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        assertEq(npm.ownerOf(id), address(lp), "the clone owns the NFT");
        assertEq(lp.positionIds()[0], id);
        assertEq(_liquidity(id), l);
        assertApproxEqRel(_nav(), before, 1e12);
        assertApproxEqRel(_positionUsd(), 4_000e18, 0.05e18, "most of both went in; the rest went back to the vault");
        assertLe(_positionUsd(), 4_000e18);
        assertEq(usdg.balanceOf(address(lp)) + tkn.balanceOf(address(lp)), 0);
        assertEq(usdg.allowance(address(lp), address(npm)) + tkn.allowance(address(lp), address(npm)), 0);
    }

    function test_MovingThePoolDoesNotMoveNav() public {
        (int24 lo, int24 hi) = _range(600);
        _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        uint256 navBefore = _nav();
        uint256 tknBefore = _held(address(tkn));
        // TKN 30% cheap in the pool.
        bool tknIs0 = t0 == address(tkn);
        uint160 fair = pool.sqrtPriceX96();
        pool.setPrice(tknIs0 ? uint160(uint256(fair) * 836 / 1000) : uint160(uint256(fair) * 1196 / 1000));
        assertEq(_nav(), navBefore, "NAV moved with the pool");
        assertEq(_held(address(tkn)), tknBefore);
    }

    function test_FeesCountBeforeAndAfterCollect() public {
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (uint256 id, uint128 l,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        uint256 navBefore = _nav();
        // Fees as if 4x our liquidity was in range: we earn a quarter.
        (uint256 fee0, uint256 fee1) = t0 == address(usdg) ? (uint256(40e6), uint256(20e18)) : (uint256(20e18), uint256(40e6));
        _earn(fee0, fee1, l * 4);
        assertApproxEqRel(_nav(), navBefore + 20e18, 1e9, "uncollected fees count: a quarter of $80");

        uint256 vaultUsdg = usdg.balanceOf(address(vault));
        _act(address(lp), abi.encode(uint8(3), id));
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - vaultUsdg, 10e6, 1);
        assertApproxEqRel(_nav(), navBefore + 20e18, 1e9, "collected fees count the same");
    }

    function test_DecreaseCollectsAndBurnsWhenEmpty() public {
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (uint256 id, uint128 l,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        uint256 navBefore = _nav();
        _act(address(lp), abi.encode(uint8(2), id, l / 2, uint256(0), uint256(0)));
        assertEq(_liquidity(id), l - l / 2);
        _act(address(lp), abi.encode(uint8(2), id, l - l / 2, uint256(0), uint256(0)));
        assertEq(lp.positionIds().length, 0, "burned and forgotten");
        vm.expectRevert();
        npm.ownerOf(id);
        assertApproxEqRel(_nav(), navBefore, 1e12);
    }

    function test_IncreaseAddsFromTheVault() public {
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (uint256 id, uint128 l,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        (uint256 a0, uint256 a1) = t0 == address(usdg) ? (uint256(1_000e6), uint256(500e18)) : (uint256(500e18), uint256(1_000e6));
        _act(address(lp), abi.encode(uint8(1), id, a0, a1, uint256(0), uint256(0)));
        assertApproxEqRel(_liquidity(id), l * 3 / 2, 1e15);
        assertApproxEqRel(_positionUsd(), 6_000e18, 0.05e18);
        assertLe(_positionUsd(), 6_000e18);
    }

    function test_RebalanceMintsANewRange() public {
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (uint256 oldId,,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        uint256 navBefore = _nav();
        (int24 lo2, int24 hi2) = _range(1200);
        r = _act(address(lp), abi.encode(uint8(4), oldId, lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0)));
        (uint256 newId, uint128 l2) = abi.decode(r, (uint256, uint128));
        assertTrue(newId != oldId);
        assertEq(lp.positionIds().length, 1);
        assertEq(lp.positionIds()[0], newId);
        assertEq(_liquidity(newId), l2);
        vm.expectRevert();
        npm.ownerOf(oldId);
        assertApproxEqRel(_nav(), navBefore, 1e12);
        assertEq(usdg.balanceOf(address(lp)) + tkn.balanceOf(address(lp)), 0);
    }

    function test_PartialUnwindTakesItsShareOfFees() public {
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (uint256 id, uint128 l,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
        (uint256 fee0, uint256 fee1) = t0 == address(usdg) ? (uint256(10e6), uint256(5e18)) : (uint256(5e18), uint256(10e6));
        _earn(fee0, fee1, l);
        uint256 navBefore = _nav();
        uint256 positionBefore = _positionUsd();

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 0.5e18);
        // Half, less at most the exit margin (GrowMath.taken: a unit of each token, at most l / 1e6 + 1).
        assertGe(_liquidity(id), l - l / 2);
        assertLe(_liquidity(id), l - l / 2 + l / 1e6 + 1);
        assertApproxEqRel(_positionUsd(), positionBefore / 2, 1e12, "half the liquidity and half the fees remain");
        assertApproxEqRel(_nav(), navBefore, 1e12);

        vm.prank(manager);
        controller.unwindAdapter(address(lp), 1e18);
        assertEq(lp.positionIds().length, 0);
        assertApproxEqRel(_nav(), navBefore, 1e12);
    }

    function test_SplitSendsTokensForAnUnsplittableNft() public {
        (int24 lo, int24 hi) = _range(600);
        _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        uint256 positionUsd = _positionUsd();
        address holder = makeAddr("holder");
        vm.prank(address(controller));
        Amount[] memory sent = lp.split(0.25e18, holder);
        uint256 got;
        for (uint256 i; i < sent.length; ++i) {
            assertEq(IERC20(sent[i].token).balanceOf(holder), sent[i].amount);
            (uint256 v,,) = router.value(sent[i].token, sent[i].amount, Side.Fair);
            got += v;
        }
        assertApproxEqRel(got, positionUsd / 4, 1e12);
        assertApproxEqRel(_positionUsd(), positionUsd * 3 / 4, 1e12);
    }

    function test_PoolChecks() public {
        (int24 lo, int24 hi) = _range(600);
        vm.startPrank(manager);
        vm.expectRevert(UniswapV3LiquidityAdapter.UnsortedTokens.selector);
        controller.act(address(lp), abi.encode(uint8(0), t1, t0, FEE, lo, hi, uint256(1), uint256(1), uint256(0), uint256(0)));
        vm.expectRevert(UniswapV3LiquidityAdapter.PoolNotFound.selector);
        controller.act(address(lp), abi.encode(uint8(0), t0, t1, uint24(500), lo, hi, uint256(1), uint256(1), uint256(0), uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(UniswapV3LiquidityAdapter.UnknownPosition.selector, 42));
        controller.act(address(lp), abi.encode(uint8(3), uint256(42)));
        vm.stopPrank();
    }

    function test_UnavailablePriceMakesTheBookIncomplete() public {
        (int24 lo, int24 hi) = _range(600);
        _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        source.setDown(address(tkn), true);
        assertGt(_held(address(tkn)), 0);
        assertEq(_held(address(usdg)), 0);
        (, bool complete) = controller.nav(uint8(Side.Fair));
        assertFalse(complete);
    }

    function test_DescribeIsJson() public view {
        string memory d = lp.describe();
        assertEq(vm.parseJsonString(d, ".actions[4].name"), "rebalance");
        assertEq(vm.parseJsonString(d, ".actions[0].name"), "mint");
    }
}

contract UniswapV3RestrictedTest is V3World {
    function setUp() public {
        _setUpV3(true);
    }

    function test_OnlyConfiguredPools() public {
        assertTrue(lp.restricted());
        MockV3Pool other = new MockV3Pool(t0, t1, 500, 10, _fairSqrt());
        v3factory.setPool(t0, t1, 500, address(other));
        (int24 lo, int24 hi) = _range(600);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3LiquidityAdapter.PoolNotAllowed.selector, address(other)));
        controller.act(address(lp), abi.encode(uint8(0), t0, t1, uint24(500), lo, hi, uint256(1e6), uint256(1e18), uint256(0), uint256(0)));
        _act(address(lp), _mint(lo, hi, 1_000e6, 500e18));
    }
}

/// @notice The shared adapter rules, against the mocked v3 position manager.
/// @notice `grow`: deposits add the same fraction of liquidity to every position, fees go to the vault first.
contract UniswapV3GrowTest is V3World {
    uint256 internal id;
    uint128 internal l0;

    function setUp() public {
        _setUpV3(false);
        (int24 lo, int24 hi) = _range(600);
        bytes memory r = _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        (id, l0,,) = abi.decode(r, (uint256, uint128, uint256, uint256));
    }

    function _grow(uint256 f) internal returns (Amount[] memory used) {
        Amount[] memory needs = lp.growInputs(f);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            MockERC20(needs[i].token).mint(address(vault), needs[i].amount);
            vault.approveFor(needs[i].token, address(lp), needs[i].amount);
        }
        used = lp.grow(f);
        vm.stopPrank();
        for (uint256 i; i < needs.length; ++i) {
            assertEq(IERC20(needs[i].token).allowance(address(vault), address(lp)), 0, "inputs not all pulled");
            assertLe(used[i].amount, needs[i].amount);
        }
        assertEq(usdg.balanceOf(address(lp)), 0);
        assertEq(tkn.balanceOf(address(lp)), 0);
    }

    /// `grow(0)` collects fees to the vault and nothing else, so the teller's snapshot is principal only.
    function test_GrowZeroCollectsFeesOnly() public {
        (uint256 fee0, uint256 fee1) = t0 == address(usdg) ? (uint256(40e6), uint256(20e18)) : (uint256(20e18), uint256(40e6));
        _earn(fee0, fee1, l0 * 4);
        uint256 usdgBefore = usdg.balanceOf(address(vault));
        uint256 navBefore = _nav();
        assertEq(lp.growInputs(0).length, 0);
        _grow(0);
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - usdgBefore, 10e6, 1, "fees not in the vault");
        assertEq(_liquidity(id), l0, "grow(0) changed liquidity");
        assertApproxEqAbs(_nav(), navBefore, 1e12, "collecting moved NAV");
    }

    /// Liquidity grows by the fraction even when the pool sits away from the fair price: the cost is paid at
    /// the pool's price, the position is measured at fair prices, and both scale with liquidity.
    function test_GrowInAMovedPoolStillGrowsByTheFraction() public {
        uint160 fair = _fairSqrt();
        pool.setPrice(uint160(uint256(fair) * 103 / 100));
        uint256 u0 = _held(address(usdg));
        uint256 k0 = _held(address(tkn));
        _grow(0.3e18);
        assertGe(_liquidity(id) * 10, uint256(l0) * 13);
        assertGe(_held(address(usdg)) * 10, u0 * 13);
        assertGe(_held(address(tkn)) * 10, k0 * 13);
    }

    /// A batch may more than double a small Fund.
    function test_GrowByMoreThanDouble() public {
        _grow(9e18);
        assertGe(_liquidity(id), uint256(l0) * 10);
    }

    /// Out of range: only one token is needed.
    function test_GrowOutOfRangeNeedsOneToken() public {
        bool tknIs0 = t0 == address(tkn);
        pool.setPrice(tknIs0 ? TickMath.getSqrtPriceAtTick(887000) : TickMath.getSqrtPriceAtTick(-887000));
        Amount[] memory needs = lp.growInputs(0.5e18);
        assertEq(needs.length, 1);
        assertEq(needs[0].token, address(usdg));
        _grow(0.5e18);
        assertGe(_liquidity(id) * 2, uint256(l0) * 3);
    }

    function test_GrowOnlyController() public {
        vm.expectRevert();
        lp.grow(0.1e18);
    }
}

contract UniswapV3AdapterSuite is V3World, AdapterSuite {
    /// @dev A range side worth only a few raw units at the fair price may read one short after rounding.
    function _growTolerance() internal pure override returns (uint256) {
        return 2;
    }

    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpV3(false);
        (int24 lo, int24 hi) = _range(600);
        _act(address(lp), _mint(lo, hi, 2_000e6, 1_000e18));
        return IAdapter(address(lp));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint256 id = lp.positionIds()[0];
        uint256 kind = seed % 5;
        uint256 amount = bound(seed >> 8, 1e6, 2_000e6);
        if (kind == 0) {
            (int24 lo, int24 hi) = _range(1200);
            return _mint(lo, hi, amount, amount * 1e12 / 2);
        }
        if (kind == 1) {
            (uint256 a0, uint256 a1) = t0 == address(usdg) ? (amount, amount * 1e12 / 2) : (amount * 1e12 / 2, amount);
            return abi.encode(uint8(1), id, a0, a1, uint256(0), uint256(0));
        }
        if (kind == 2) return abi.encode(uint8(2), id, _liquidity(id) / 2, uint256(0), uint256(0));
        if (kind == 3) return abi.encode(uint8(3), id);
        (int24 lo2, int24 hi2) = _range(1800);
        return abi.encode(uint8(4), id, lo2, hi2, uint256(0), uint256(0), uint256(0), uint256(0));
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdg);
        t[1] = address(tkn);
    }
}

/// @notice With the most positions a clone may hold, `positions` fits well inside the controller's gas cap.
contract UniswapV3GasTest is V3World {
    function setUp() public {
        _setUpV3(false);
        for (uint256 i; i < lp.MAX_POSITIONS(); ++i) {
            (int24 lo, int24 hi) = _range(int24(int256(300 + 60 * i)));
            _act(address(lp), _mint(lo, hi, 100e6, 50e18));
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
