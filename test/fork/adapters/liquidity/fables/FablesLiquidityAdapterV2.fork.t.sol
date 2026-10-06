// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {AdapterRegistry} from "../../../../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../../../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../../../../src/core/FundFactory.sol";
import {FundVault} from "../../../../../src/core/FundVault.sol";
import {FundController} from "../../../../../src/core/FundController.sol";
import {SeedTeller} from "../../../../../src/core/SeedTeller.sol";
import {Dial} from "../../../../../src/interfaces/IFundController.sol";
import {PriceClass, Side} from "../../../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../../../src/interfaces/IPriceSource.sol";
import {IAdapter, Amount} from "../../../../../src/interfaces/IAdapter.sol";
import {GrowCheck} from "../../GrowCheck.sol";
import {FablesLiquidityAdapterV2} from "../../../../../src/adapters/liquidity/FablesLiquidityAdapterV2.sol";
import {IFablesLedger} from "../../../../../src/interfaces/external/fables/IFablesLedger.sol";
import {IFablesPoolRegistry} from "../../../../../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../../../../../src/interfaces/external/fables/IFablesFeeDistributor.sol";
import {IWETH9} from "../../../../../src/interfaces/external/uniswap/IWETH9.sol";
import {MockPriceSource} from "../../../../utils/Mocks.sol";
import {DeployFablesV2} from "../../../../../script/DeployFablesV2.s.sol";

/// @dev Exact-input swaps through a v4 pool, native ETH included: the only way to make fees on a fork.
contract NativeForkSwapper is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external payable returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only pm");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 paid = uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        pm.sync(cin);
        if (Currency.unwrap(cin) == address(0)) {
            pm.settle{value: paid}();
        } else {
            IERC20(Currency.unwrap(cin)).transferFrom(payer, address(pm), paid);
            pm.settle();
        }
        pm.take(cout, payer, out);
        return abi.encode(out);
    }
}

/**
 * @notice v2 against the live Fables contracts on Robinhood Chain (chain 4663), forked at the latest block. Skipped
 *         unless ROBINHOOD_RPC is set. Nothing is broadcast.
 *
 *         The Fund enables v2 with every active hook in Fables' registry (DeployFablesV2.fablesHooks, the config the
 *         deploy script records), ETH hooks included. Pools: ETH/USDG on the gen-1 ETH hook 0x06a8 (0% claim
 *         fee, the largest Fables pool), one pool on each gen-2 ETH hook (0x594e, 0xca89), and NVDA/USDG on the
 *         gen-1 hook 0x6662 as the ERC20 regression.
 */
contract FablesLiquidityAdapterV2ForkTest is Test, GrowCheck {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant FABLES_REGISTRY = 0x159A113E012593D9B3cC63ad45E30F0467e13Ef3;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POT = 0xC9EcC11728a4955B31f77c077B97FEC521D78760;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant ETH_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    address constant ETH_HOOK_B = 0x594e8e6281eDf2d363a0293a50004Cf868E7a080;
    address constant ETH_HOOK_C = 0xcA89f079AF00f752bfD3C345358Dc38d4d73e080;
    bytes32 constant ETH_POOL = 0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551;
    bytes32 constant POOL_B = 0xb59001413cb070e28433826f927b7265a0813213ba21f454d86896cee3cce674;
    bytes32 constant POOL_C = 0x31f8624041c93e2abd0fb23540d259b069fa76c053eb7e3f5abc754d7194726b;
    bytes32 constant NVDA_POOL = 0x7990aad9e8fb048f49a155a7df5603db0366f0657035b78eb4196395cccb3dcd;
    address constant FABLES_ADMIN = 0x359856655934338d798F9ccE1f181486301D36a5;

    address guardian = makeAddr("guardian");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");

    AdapterRegistry registry;
    PriceRouter router;
    MockPriceSource source;
    FundVault vault;
    FundController controller;
    FablesLiquidityAdapterV2 fab;
    NativeForkSwapper swapper;
    IPoolManager pm = IPoolManager(POOL_MANAGER);
    uint256 hookCount;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        FundFactory factory = new FundFactory(registry, router, guardian, USDG);
        SeedTeller teller = new SeedTeller();
        // Prices from the pools at the fork block, so the test is about the adapter, not the oracle.
        _price(USDG, 1e18);
        uint256 ethUsd = _ethUsd();
        _price(WETH, ethUsd);
        _price(NVDA, _nvdaUsd());
        _priceVsEth(POOL_B, ethUsd);
        _priceVsEth(POOL_C, ethUsd);

        Dial memory d = Dial(10_000, 10_000, 10_000, 10_000, 10_000, false, 10_000, true);
        (vault, controller) = factory.create("Fables v2 Fork Fund", "FV2", owner, address(teller), d);
        deal(USDG, owner, 40_000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), 40_000e6);
        teller.seed(vault, USDG, 40_000e6, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 300 days));
        vm.stopPrank();

        FablesLiquidityAdapterV2 impl = new FablesLiquidityAdapterV2(
            IFablesPoolRegistry(FABLES_REGISTRY), pm, IFablesFeeDistributor(POT), IWETH9(WETH)
        );
        registry.register(address(impl), "");
        bytes memory config = new DeployFablesV2().defaultConfig();
        vm.prank(owner);
        fab = FablesLiquidityAdapterV2(payable(controller.addAdapter(address(impl), config)));
        hookCount = fab.hooks().length;
        assertTrue(fab.allowedHook(ETH_HOOK) && fab.allowedHook(ETH_HOOK_B) && fab.allowedHook(ETH_HOOK_C), "ETH hooks");

        // 8 WETH (real wrapped ETH, so the clone can unwrap it) and NVDA bought through its pool.
        vm.deal(address(this), 8 ether);
        IWETH9(WETH).deposit{value: 8 ether}();
        IERC20(WETH).transfer(address(vault), 8 ether);
        swapper = new NativeForkSwapper(pm);
        _buyNvda(8_000e6);
        vm.startPrank(address(controller));
        vault.track(WETH);
        vault.track(NVDA);
        vm.stopPrank();
    }

    int24 lo;
    int24 hi;
    int24 lo2;
    int24 hi2;

    function test_fork_EthUsdgLifecycle() public {
        PoolKey memory key = _key(ETH_POOL);
        assertEq(Currency.unwrap(key.currency0), address(0), "a native ETH pool");
        (lo, hi) = _around(key, 400);
        (lo2, hi2) = _around(key, 1000);
        emit log_named_uint("hooks enabled from the registry", hookCount);
        uint256 rid = _stepDeposit();
        _stepFeesAndClaim(key, rid);
        uint256 rid2 = _stepRebalance(rid);
        _churn(key, 3_000e6);
        bool paused = _stepSplit(rid2);
        _stepUnwind(rid2, paused);
    }

    function _stepDeposit() internal returns (uint256 rid) {
        uint256 nav0 = _nav();
        uint256 w0 = IERC20(WETH).balanceOf(address(vault));
        uint256 u0 = IERC20(USDG).balanceOf(address(vault));
        // 3 WETH and 10k USDG of budget; the range takes what fits at the pool price and the rest comes back.
        uint128 liq = abi.decode(_act(abi.encode(uint8(0), ETH_POOL, lo, hi, uint128(3e18), uint128(10_000e6), uint128(0))), (uint128));
        rid = fab.rangeIdOf(ETH_POOL, lo, hi);
        assertEq(IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid), liq, "clone holds the Fables shares");
        emit log_named_decimal_uint("WETH spent", w0 - IERC20(WETH).balanceOf(address(vault)), 18);
        emit log_named_decimal_uint("USDG spent", u0 - IERC20(USDG).balanceOf(address(vault)), 6);
        assertApproxEqRel(_nav(), nav0, 0.002e18, "deposit valued at the oracle price");
        (Amount[] memory held,) = fab.positions(router);
        assertEq(held[0].token, WETH, "ETH side reported as WETH");
        emit log_named_decimal_uint("range value (USD)", _usd(held), 18);
        _assertClean();
    }

    function _stepFeesAndClaim(PoolKey memory key, uint256 rid) internal {
        _churn(key, 20_000e6);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertGt(f0, 0, "ETH fees visible in view");
        assertGt(f1, 0, "USDG fees visible in view");
        emit log_named_uint("pending fee0 (wei)", f0);
        emit log_named_uint("pending fee1 (USDG raw)", f1);
        uint256 w = IERC20(WETH).balanceOf(address(vault));
        uint256 u = IERC20(USDG).balanceOf(address(vault));
        _act(abi.encode(uint8(2), ETH_POOL, lo, hi, uint16(1000)));
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(vault)) - w, f0, 2, "ETH fees reached the vault as WETH");
        assertApproxEqAbs(IERC20(USDG).balanceOf(address(vault)) - u, f1, 2, "USDG fees as predicted");
        _assertClean();
    }

    function _stepRebalance(uint256 rid) internal returns (uint256 rid2) {
        uint256 nav0 = _nav();
        _act(abi.encode(uint8(3), ETH_POOL, lo, hi, uint256(1e18), lo2, hi2, uint128(0.5e18), uint128(0), uint128(0)));
        assertEq(IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid), 0, "old range emptied");
        rid2 = fab.rangeIdOf(ETH_POOL, lo2, hi2);
        assertGt(IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid2), 0, "new range funded");
        assertApproxEqRel(_nav(), nav0, 0.003e18, "rebalance keeps NAV");
        _assertClean();
    }

    function _stepSplit(uint256 rid2) internal returns (bool paused) {
        paused = _pauseLedger(ETH_HOOK);
        address leaver = makeAddr("leaver");
        uint256 shares = IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid2);
        uint256 before = _positionsUsd();
        vm.prank(address(controller));
        Amount[] memory sent = fab.split(0.25e18, leaver);
        uint256 left = IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid2);
        assertGe(left, shares - shares / 4, "75% stays");
        assertLe(left, shares - shares / 4 + shares / 1e6 + 1, "and the margin");
        assertEq(leaver.balance, 0, "the leaver gets no native ETH");
        assertGt(IERC20(WETH).balanceOf(leaver), 0, "the leaver gets WETH");
        assertGt(IERC20(USDG).balanceOf(leaver), 0);
        emit log_named_decimal_uint("leaver's slice (USD)", _usd(sent), 18);
        emit log_named_decimal_uint("a quarter of the position (USD)", before / 4, 18);
        if (!paused) assertApproxEqRel(_usd(sent), before / 4, 0.003e18, "a quarter of principal and fees");
        _assertClean();
    }

    function _stepUnwind(uint256 rid2, bool paused) internal {
        uint256 nav0 = _nav();
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);
        assertEq(IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid2), 0, "all principal out");
        if (paused) {
            _unpauseLedger(ETH_HOOK);
            vm.prank(owner);
            controller.unwindAdapter(address(fab), 1e18);
        }
        assertEq(fab.ranges().length, 0, "nothing left in Fables");
        assertApproxEqRel(_nav(), nav0, 0.003e18, "unwind returns what positions reported");
        _assertClean();
        emit log_named_decimal_uint("NAV at the end", _nav(), 18);
    }

    /// Deposits into the existing mix on the ETH pool: `grow(0)` claims fees as WETH, then 10% and 100% more shares,
    /// paid in ETH unwrapped from WETH the vault holds.
    function test_fork_EthUsdgGrow() public {
        PoolKey memory key = _key(ETH_POOL);
        (lo, hi) = _around(key, 600);
        _act(abi.encode(uint8(0), ETH_POOL, lo, hi, uint128(2e18), uint128(6_000e6), uint128(0)));
        _churn(key, 10_000e6);
        uint256 rid = fab.rangeIdOf(ETH_POOL, lo, hi);
        uint256 s0 = IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid);
        (Amount[] memory needs,) =
            _growChecked(IAdapter(address(fab)), address(vault), address(controller), router, 0.1e18, 2);
        assertEq(needs[0].token, WETH, "grow asks the vault for WETH");
        _growChecked(IAdapter(address(fab)), address(vault), address(controller), router, 1e18, 2);
        assertGe(IFablesLedger(ETH_HOOK).balanceOf(address(fab), rid) * 10, s0 * 22, "shares grew 2.2x");
        _assertClean();
    }

    /// The gen-2 ETH hooks (0x594e and 0xca89): an ETH-only range above the price on one pool each, valued, then
    /// unwound back to WETH.
    function test_fork_Gen2EthHooksOneSided() public {
        _oneSided(POOL_B, ETH_HOOK_B);
        _oneSided(POOL_C, ETH_HOOK_C);
    }

    function _oneSided(bytes32 poolId, address hook) internal {
        PoolKey memory key = _key(poolId);
        assertEq(address(key.hooks), hook);
        (, int24 tick,,) = pm.getSlot0(key.toId());
        int24 s = key.tickSpacing;
        int24 l = (tick / s + 2) * s;
        int24 u = l + 20 * s;
        uint256 nav0 = _nav();
        uint256 w0 = IERC20(WETH).balanceOf(address(vault));
        _act(abi.encode(uint8(0), poolId, l, u, uint128(0.5e18), uint128(0), uint128(0)));
        uint256 rid = fab.rangeIdOf(poolId, l, u);
        assertGt(IFablesLedger(hook).balanceOf(address(fab), rid), 0, "shares on the gen-2 ETH hook");
        assertApproxEqRel(_nav(), nav0, 0.001e18, "valued at the oracle price");
        _assertClean();
        _act(abi.encode(uint8(1), poolId, l, u, uint128(0), uint256(1e18), uint128(0), uint128(0)));
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(vault)), w0, 2, "the WETH came back, less v4 rounding");
        assertEq(fab.ranges().length, 0);
        _assertClean();
    }

    /// v2 on an ERC20 pool behaves as v1: NVDA/USDG deposit, fees, withdraw, unwind.
    function test_fork_Erc20RegressionNvda() public {
        PoolKey memory key = _key(NVDA_POOL);
        (lo, hi) = _around(key, 400);
        uint256 nav0 = _nav();
        uint128 stk = uint128(IERC20(NVDA).balanceOf(address(vault)) / 2);
        (uint128 a0, uint128 a1) = Currency.unwrap(key.currency0) == USDG ? (uint128(4_000e6), stk) : (stk, uint128(4_000e6));
        _act(abi.encode(uint8(0), NVDA_POOL, lo, hi, a0, a1, uint128(0)));
        assertApproxEqRel(_nav(), nav0, 0.002e18, "NVDA range valued at the oracle price");
        _churnErc20(key, 3_000e6);
        uint256 rid = fab.rangeIdOf(NVDA_POOL, lo, hi);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertGt(f0 + f1, 0, "fees visible in view");
        _act(abi.encode(uint8(1), NVDA_POOL, lo, hi, uint128(0), uint256(0.5e18), uint128(0), uint128(0)));
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);
        assertEq(fab.ranges().length, 0, "unwound");
        _assertClean();
    }

    // ---------------------------------------------------------------- helpers

    function _assertClean() internal view {
        assertEq(address(vault).balance, 0, "vault holds native ETH");
        assertEq(address(fab).balance, 0, "clone holds ETH");
        assertEq(IERC20(WETH).balanceOf(address(fab)), 0, "clone holds WETH");
        assertEq(IERC20(USDG).balanceOf(address(fab)), 0, "clone holds USDG");
        assertEq(IERC20(NVDA).balanceOf(address(fab)), 0, "clone holds NVDA");
    }

    function _fundForGrow(address token, address vault_, uint256 amount) internal override {
        if (token == WETH) {
            vm.deal(address(this), amount);
            IWETH9(WETH).deposit{value: amount}();
            IERC20(WETH).transfer(vault_, amount);
        } else {
            deal(token, vault_, IERC20(token).balanceOf(vault_) + amount);
        }
    }

    function _act(bytes memory action) internal returns (bytes memory) {
        vm.prank(manager);
        return controller.act(address(fab), action);
    }

    function _nav() internal view returns (uint256 v) {
        (v,) = controller.nav(uint8(Side.Fair));
    }

    function _usd(Amount[] memory a) internal view returns (uint256 usd) {
        for (uint256 i; i < a.length; ++i) {
            (uint256 v,,) = router.value(a[i].token, a[i].amount, Side.Fair);
            usd += v;
        }
    }

    function _positionsUsd() internal view returns (uint256) {
        (Amount[] memory held,) = fab.positions(router);
        return _usd(held);
    }

    function _key(bytes32 poolId) internal view returns (PoolKey memory) {
        return IFablesPoolRegistry(FABLES_REGISTRY).poolById(PoolId.wrap(poolId)).key;
    }

    function _price(address token, uint256 usdWad) internal {
        source.set(token, usdWad);
        router.propose(
            token,
            PriceRouter.Config({
                primary: IPriceSource(address(source)),
                check: IPriceSource(address(0)),
                class_: PriceClass.Feed,
                haircutBps: 0,
                maxDeviationBps: 0,
                decimals: 0,
                chained: 0
            })
        );
        if (router.pendingAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(token);
        }
    }

    /// @dev USD per ETH from the ETH/USDG pool: ratio = USDG raw per wei = sqrtP^2 / 2^192, so USD wad = ratio * 1e30.
    function _ethUsd() internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(_key(ETH_POOL).toId());
        return FullMath.mulDiv(FullMath.mulDiv(1e30, sqrtP, 1 << 96), sqrtP, 1 << 96);
    }

    function _nvdaUsd() internal view returns (uint256) {
        PoolKey memory key = _key(NVDA_POOL);
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        if (Currency.unwrap(key.currency0) == USDG) {
            return FullMath.mulDiv(FullMath.mulDiv(1e30, 1 << 96, sqrtP), 1 << 96, sqrtP);
        }
        return FullMath.mulDiv(FullMath.mulDiv(1e30, sqrtP, 1 << 96), sqrtP, 1 << 96);
    }

    /// @dev Prices currency1 of an ETH pool from the pool: token1 raw per wei = sqrtP^2 / 2^192.
    function _priceVsEth(bytes32 poolId, uint256 ethUsd) internal {
        PoolKey memory key = _key(poolId);
        address t1 = Currency.unwrap(key.currency1);
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        uint256 scaled = FullMath.mulDiv(ethUsd, 10 ** IERC20Metadata(t1).decimals(), 1e18);
        _price(t1, FullMath.mulDiv(FullMath.mulDiv(scaled, 1 << 96, sqrtP), 1 << 96, sqrtP));
    }

    function _around(PoolKey memory key, int24 width) internal view returns (int24 low, int24 high) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        int24 s = key.tickSpacing;
        int24 m = tick / s * s;
        int24 w = width / s * s;
        return (m - w, m + w);
    }

    function _buyNvda(uint256 usd) internal {
        PoolKey memory key = _key(NVDA_POOL);
        deal(USDG, address(this), usd);
        IERC20(USDG).approve(address(swapper), usd);
        uint256 out = swapper.swapExactIn(key, Currency.unwrap(key.currency0) == USDG, usd);
        IERC20(NVDA).transfer(address(vault), out);
    }

    /// @dev Round trips `usd` of USDG through the ETH/USDG pool, paying fees both ways.
    function _churn(PoolKey memory key, uint256 usd) internal {
        address trader = makeAddr("trader");
        deal(USDG, trader, usd);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapper), type(uint256).max);
        uint256 before = trader.balance;
        swapper.swapExactIn(key, false, usd); // USDG in, ETH out to the trader
        uint256 got = trader.balance - before;
        swapper.swapExactIn{value: got}(key, true, got); // ETH in, settled from what the trader sends
        vm.stopPrank();
    }

    function _churnErc20(PoolKey memory key, uint256 usd) internal {
        address trader = makeAddr("trader20");
        deal(USDG, trader, usd);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapper), type(uint256).max);
        IERC20(NVDA).approve(address(swapper), type(uint256).max);
        bool usdgIs0 = Currency.unwrap(key.currency0) == USDG;
        uint256 got = swapper.swapExactIn(key, usdgIs0, usd);
        swapper.swapExactIn(key, !usdgIs0, got);
        vm.stopPrank();
    }

    function _pauseLedger(address hook) internal returns (bool) {
        vm.prank(FABLES_ADMIN);
        (bool ok,) = hook.call(abi.encodeWithSignature("setPaused(uint256)", uint256(7 days)));
        if (!ok) {
            emit log("could not pause the Fables ledger on the fork; paused leg skipped");
            return false;
        }
        assertTrue(IFablesLedger(hook).paused());
        emit log("ETH hook paused on the fork with Fables' admin key: split ran with claims frozen");
        return true;
    }

    function _unpauseLedger(address hook) internal {
        vm.prank(FABLES_ADMIN);
        (bool ok,) = hook.call(abi.encodeWithSignature("setPaused(uint256)", uint256(0)));
        assertTrue(ok, "unpause");
    }

    receive() external payable {}
}
