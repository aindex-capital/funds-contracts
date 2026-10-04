// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {FablesLiquidityAdapter} from "../../../../../src/adapters/liquidity/FablesLiquidityAdapter.sol";
import {IFablesLedger} from "../../../../../src/interfaces/external/fables/IFablesLedger.sol";
import {IFablesPoolRegistry} from "../../../../../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../../../../../src/interfaces/external/fables/IFablesFeeDistributor.sol";
import {MockPriceSource} from "../../../../utils/Mocks.sol";

/// @dev Swaps exact input through a v4 pool for tests: the only way to make fees on a fork.
contract ForkSwapper is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256 out) {
        bytes memory r = pm.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender));
        out = abi.decode(r, (uint256));
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
        int128 dout = zeroForOne ? d.amount1() : d.amount0();
        int128 din = zeroForOne ? d.amount0() : d.amount1();
        pm.sync(cin);
        IERC20(Currency.unwrap(cin)).transferFrom(payer, address(pm), uint256(uint128(-din)));
        pm.settle();
        uint256 out = uint256(uint128(dout));
        pm.take(cout, payer, out);
        return abi.encode(out);
    }
}

/**
 * @notice The adapter against the live Fables contracts on Robinhood Chain (chain 4663), forked at the latest
 *         block. Skipped unless ROBINHOOD_RPC is set. Nothing is broadcast: every call runs on the local fork.
 *
 *         Pools (from Fables' registry): NVDA/USDG on the gen-1 calendar hook 0x6662 (10% claim fee) and
 *         CRCL/USDG on the gen-2 singleton calendar hook 0x5Eb8, so both ledger generations are exercised.
 */
contract FablesLiquidityAdapterForkTest is Test, GrowCheck {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant FABLES_REGISTRY = 0x159A113E012593D9B3cC63ad45E30F0467e13Ef3;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POT = 0xC9EcC11728a4955B31f77c077B97FEC521D78760;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant CRCL = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5;
    address constant NVDA_HOOK = 0x66622f77B797D506e5376F7798b67ab288966080;
    address constant GEN2_HOOK = 0x5Eb87F69bE00Df39981622Fd60A8De4b7837e080;
    bytes32 constant NVDA_POOL = 0x7990aad9e8fb048f49a155a7df5603db0366f0657035b78eb4196395cccb3dcd;
    bytes32 constant CRCL_POOL = 0xdb9c34002d173981250969293af6f43f42a26f2110f19893bbe2ad373375e9e6;
    /// @dev Fables' ADMIN (AccessManager role 0, no execution delay), used only to pause the ledger on the fork.
    address constant FABLES_ADMIN = 0x359856655934338d798F9ccE1f181486301D36a5;

    address guardian = makeAddr("guardian");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");

    AdapterRegistry registry;
    PriceRouter router;
    MockPriceSource source;
    FundVault vault;
    FundController controller;
    FablesLiquidityAdapter fab;
    ForkSwapper swapper;
    IPoolManager pm = IPoolManager(POOL_MANAGER);

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
        _price(USDG, 1e18);
        // Stock prices are taken from the pools themselves at the fork block: the test is about the adapter,
        // and an oracle that agrees with the pool keeps the deposit guard quiet.
        _price(NVDA, _usdFromPool(_key(NVDA_POOL), NVDA));
        _price(CRCL, _usdFromPool(_key(CRCL_POOL), CRCL));

        Dial memory d = Dial(10_000, 10_000, 10_000, 10_000, 10_000, false, 10_000, true);
        (vault, controller) = factory.create("Fables Fork Fund", "FFF", owner, address(teller), d);
        deal(USDG, owner, 40_000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), 40_000e6);
        teller.seed(vault, USDG, 40_000e6, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 300 days));
        vm.stopPrank();

        FablesLiquidityAdapter impl = new FablesLiquidityAdapter(
            IFablesPoolRegistry(FABLES_REGISTRY), pm, IFablesFeeDistributor(POT)
        );
        registry.register(address(impl), "");
        address[] memory hooks = new address[](2);
        hooks[0] = NVDA_HOOK;
        hooks[1] = GEN2_HOOK;
        bytes32[] memory witness = new bytes32[](2);
        witness[0] = NVDA_POOL;
        witness[1] = CRCL_POOL;
        vm.prank(owner);
        fab = FablesLiquidityAdapter(controller.addAdapter(address(impl), abi.encode(hooks, witness, uint16(100))));

        // Buy stock for the vault through the pools (dealing tokenized stocks is unreliable).
        swapper = new ForkSwapper(pm);
        _buyForVault(_key(NVDA_POOL), NVDA, 8_000e6);
        _buyForVault(_key(CRCL_POOL), CRCL, 4_000e6);
    }

    // Range ticks for the NVDA lifecycle, kept in storage to stay clear of the stack limit.
    int24 nvdaLo;
    int24 nvdaHi;
    int24 nvdaLo2;
    int24 nvdaHi2;

    function test_fork_NvdaUsdgLifecycle() public {
        PoolKey memory key = _key(NVDA_POOL);
        (nvdaLo, nvdaHi) = _around(key, 400);
        (nvdaLo2, nvdaHi2) = _around(key, 1000);
        uint256 rid = _stepDeposit(key);
        _stepFeesAndClaim(key, rid);
        uint256 rid2 = _stepRebalance(rid);
        _churn(key, NVDA, 2_000e6);
        bool paused = _stepPausedSplit(rid2);
        _stepUnwind(rid2, paused);
    }

    function _stepDeposit(PoolKey memory key) internal returns (uint256 rid) {
        uint256 nav0 = _nav();
        (uint128 a0, uint128 a1) = _sides(key, NVDA, 5_000e6);
        uint128 liq = abi.decode(_act(abi.encode(uint8(0), NVDA_POOL, nvdaLo, nvdaHi, a0, a1, uint128(0))), (uint128));
        rid = fab.rangeIdOf(NVDA_POOL, nvdaLo, nvdaHi);
        assertEq(IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid), liq, "clone holds the Fables shares");
        assertApproxEqRel(_nav(), nav0, 0.002e18, "deposit valued at the oracle price");
        emit log_named_uint("NVDA/USDG liquidity", liq);
        emit log_named_decimal_uint("NAV after deposit", _nav(), 18);
    }

    function _stepFeesAndClaim(PoolKey memory key, uint256 rid) internal {
        _churn(key, NVDA, 3_000e6);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertGt(f0 + f1, 0, "fees visible in view before any sync");
        emit log_named_uint("pending fee0 (USDG raw)", f0);
        emit log_named_uint("pending fee1 (NVDA raw)", f1);
        uint256 vU = IERC20(USDG).balanceOf(address(vault));
        uint256 vN = IERC20(NVDA).balanceOf(address(vault));
        _act(abi.encode(uint8(2), NVDA_POOL, nvdaLo, nvdaHi, uint16(1000)));
        assertApproxEqAbs(IERC20(USDG).balanceOf(address(vault)) - vU, f0, 2, "USDG fees as predicted");
        assertApproxEqAbs(IERC20(NVDA).balanceOf(address(vault)) - vN, f1, 2, "NVDA fees as predicted");
    }

    function _stepRebalance(uint256 rid) internal returns (uint256 rid2) {
        uint256 nav0 = _nav();
        _act(_rebalance(NVDA_POOL, nvdaLo, nvdaHi, nvdaLo2, nvdaHi2));
        assertEq(IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid), 0, "old range emptied");
        rid2 = fab.rangeIdOf(NVDA_POOL, nvdaLo2, nvdaHi2);
        assertGt(IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid2), 0, "new range funded");
        assertEq(IERC20(USDG).balanceOf(address(fab)) + IERC20(NVDA).balanceOf(address(fab)), 0, "nothing loose");
        assertApproxEqRel(_nav(), nav0, 0.003e18, "rebalance keeps NAV");
    }

    function _stepPausedSplit(uint256 rid2) internal returns (bool paused) {
        paused = _pauseLedger(NVDA_HOOK);
        address leaver = makeAddr("leaver");
        uint256 shares = IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid2);
        vm.prank(address(controller));
        fab.split(0.25e18, leaver);
        // 75% stays, plus at most the exit margin (GrowMath.taken: a unit of each token, at most shares / 1e6 + 1).
        uint256 left = IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid2);
        assertGe(left, shares - shares / 4, "75% stays");
        assertLe(left, shares - shares / 4 + shares / 1e6 + 1, "and the margin");
        assertGt(IERC20(USDG).balanceOf(leaver) + IERC20(NVDA).balanceOf(leaver), 0, "leaver paid in kind");
        if (paused) {
            emit log("Fables ledger paused on the fork with its admin key: split ran with claims frozen");
            (uint256 f0, uint256 f1) = fab.pendingFees(rid2);
            assertGt(f0 + f1, 0, "paused fees stay owed to the Fund");
        }
    }

    function _stepUnwind(uint256 rid2, bool paused) internal {
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);
        assertEq(IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid2), 0, "all principal out, pause or not");
        if (paused) {
            assertEq(fab.ranges().length, 1, "range kept while its fees are owed");
            _unpauseLedger(NVDA_HOOK);
            vm.prank(owner);
            controller.unwindAdapter(address(fab), 1e18);
        }
        assertEq(fab.ranges().length, 0, "fees collected once claims reopened");
        (Amount[] memory left,) = fab.positions(router);
        for (uint256 i; i < left.length; ++i) assertEq(left[i].amount, 0, "nothing left in Fables");
        emit log_named_decimal_uint("NAV at the end", _nav(), 18);
    }

    function _rebalance(bytes32 pool, int24 fl, int24 fu, int24 tl, int24 tu) internal pure returns (bytes memory) {
        return abi.encode(uint8(3), pool, fl, fu, uint256(1e18), tl, tu, uint128(0), uint128(0), uint128(0));
    }

    function test_fork_Gen2HookDepositValueExit() public {
        PoolKey memory key = _key(CRCL_POOL);
        assertEq(address(key.hooks), GEN2_HOOK);
        (int24 lo, int24 hi) = _around(key, 1200);
        uint256 nav0 = _nav();
        (uint128 a0, uint128 a1) = _sides(key, CRCL, 1_500e6);
        _act(abi.encode(uint8(0), CRCL_POOL, lo, hi, a0, a1, uint128(0)));
        assertApproxEqRel(_nav(), nav0, 0.003e18, "gen-2 position valued at the oracle price");
        _churn(key, CRCL, 1_000e6);
        uint256 rid = fab.rangeIdOf(CRCL_POOL, lo, hi);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertGt(f0 + f1, 0, "gen-2 fees visible in view");
        _act(abi.encode(uint8(1), CRCL_POOL, lo, hi, uint128(0), uint256(1e18), uint128(0), uint128(0)));
        assertEq(fab.ranges().length, 0, "withdraw also claimed: range closed");
        assertEq(IERC20(USDG).balanceOf(address(fab)) + IERC20(CRCL).balanceOf(address(fab)), 0);
    }

    /// Deposits into the existing mix on live Fables ledgers (gen 1 NVDA hook and gen 2 CRCL hook), after swaps
    /// have earned fees: `grow(0)` claims them to the vault, then each range gets 10% and then 100% more shares,
    /// paid at the pool's price, and grows by at least that at the oracle price.
    function test_fork_GrowByFraction() public {
        PoolKey memory nk = _key(NVDA_POOL);
        (int24 lo, int24 hi) = _around(nk, 400);
        (uint128 a0, uint128 a1) = _sides(nk, NVDA, 3_000e6);
        _act(abi.encode(uint8(0), NVDA_POOL, lo, hi, a0, a1, uint128(0)));
        PoolKey memory ck = _key(CRCL_POOL);
        (int24 clo, int24 chi) = _around(ck, 1200);
        (a0, a1) = _sides(ck, CRCL, 1_000e6);
        _act(abi.encode(uint8(0), CRCL_POOL, clo, chi, a0, a1, uint128(0)));
        _churn(nk, NVDA, 500e6);
        _churn(ck, CRCL, 300e6);
        uint256 rid = fab.rangeIdOf(NVDA_POOL, lo, hi);
        uint256 s0 = IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid);
        uint256 vU = IERC20(USDG).balanceOf(address(vault));
        _growChecked(IAdapter(address(fab)), address(vault), address(controller), router, 0.1e18, 2);
        assertGt(IERC20(USDG).balanceOf(address(vault)), vU, "fees did not reach the vault");
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        emit log_named_uint("NVDA range fees left after grow (raw0)", f0);
        emit log_named_uint("NVDA range fees left after grow (raw1)", f1);
        _growChecked(IAdapter(address(fab)), address(vault), address(controller), router, 1e18, 2);
        assertGe(IFablesLedger(NVDA_HOOK).balanceOf(address(fab), rid) * 10, s0 * 22, "shares did not grow 2.2x");
    }

    /// @dev The vault already holds the stock bought in setUp; tokenized stocks cannot be dealt reliably.
    function _fundForGrow(address token, address vault_, uint256 amount) internal override {
        if (token == USDG) {
            deal(USDG, vault_, IERC20(USDG).balanceOf(vault_) + amount);
        } else {
            assertGe(IERC20(token).balanceOf(vault_), amount, "vault short of stock for the test");
        }
    }

    // ---------------------------------------------------------------- helpers

    function _act(bytes memory action) internal returns (bytes memory) {
        vm.prank(manager);
        return controller.act(address(fab), action);
    }

    function _nav() internal view returns (uint256 v) {
        (v,) = controller.nav(uint8(Side.Fair));
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

    /// @dev USD per whole `stock` (1e18) implied by the pool's price, with USDG at $1 (6 decimals, stock 18).
    function _usdFromPool(PoolKey memory key, address stock) internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        // ratio = token1 raw per token0 raw = sqrtP^2 / 2^192
        if (Currency.unwrap(key.currency0) == USDG) {
            // stock raw per USDG raw; USD per stock = 1e12 / ratio
            return FullMath.mulDiv(FullMath.mulDiv(1e30, 1 << 96, sqrtP), 1 << 96, sqrtP);
        }
        // USDG raw per stock raw; USD per stock = ratio * 1e12
        stock;
        return FullMath.mulDiv(FullMath.mulDiv(1e30, sqrtP, 1 << 96), sqrtP, 1 << 96);
    }

    function _around(PoolKey memory key, int24 width) internal view returns (int24 low, int24 high) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        int24 s = key.tickSpacing;
        int24 m = tick / s * s;
        int24 w = width / s * s;
        return (m - w, m + w);
    }

    /// @dev `usd` USDG and the vault's matching amount of stock, as (amount0, amount1).
    function _sides(PoolKey memory key, address stock, uint256 usd) internal view returns (uint128, uint128) {
        uint256 stk = IERC20(stock).balanceOf(address(vault)) / 2;
        return Currency.unwrap(key.currency0) == USDG ? (uint128(usd), uint128(stk)) : (uint128(stk), uint128(usd));
    }

    function _buyForVault(PoolKey memory key, address stock, uint256 usd) internal {
        deal(USDG, address(this), usd);
        IERC20(USDG).approve(address(swapper), usd);
        uint256 out = swapper.swapExactIn(key, Currency.unwrap(key.currency0) == USDG, usd);
        IERC20(stock).transfer(address(vault), out);
        vm.prank(address(controller));
        vault.track(stock);
    }

    /// @dev Round trips `usd` of USDG through the pool, paying fees both ways.
    function _churn(PoolKey memory key, address stock, uint256 usd) internal {
        address trader = makeAddr("trader");
        deal(USDG, trader, usd);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapper), type(uint256).max);
        IERC20(stock).approve(address(swapper), type(uint256).max);
        bool usdgIs0 = Currency.unwrap(key.currency0) == USDG;
        uint256 got = swapper.swapExactIn(key, usdgIs0, usd);
        swapper.swapExactIn(key, !usdgIs0, got);
        vm.stopPrank();
    }

    /// @dev Pauses the ledger with Fables' real admin key on the fork. Returns false (and the test continues
    ///      without the paused leg) if the role mapping on chain refuses it.
    function _pauseLedger(address hook) internal returns (bool) {
        vm.prank(FABLES_ADMIN);
        (bool ok,) = hook.call(abi.encodeWithSignature("setPaused(uint256)", uint256(7 days)));
        if (!ok) {
            emit log("could not pause the Fables ledger on the fork; paused leg skipped");
            return false;
        }
        assertTrue(IFablesLedger(hook).paused());
        return true;
    }

    function _unpauseLedger(address hook) internal {
        vm.prank(FABLES_ADMIN);
        (bool ok,) = hook.call(abi.encodeWithSignature("setPaused(uint256)", uint256(0)));
        assertTrue(ok, "unpause");
    }
}
