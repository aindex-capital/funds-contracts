// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FundTestBase} from "../../../utils/FundTestBase.sol";
import {AdapterSuite} from "../../AdapterSuite.sol";
import {MockERC20} from "../../../utils/Mocks.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {FablesLiquidityAdapterV2} from "../../../../src/adapters/liquidity/FablesLiquidityAdapterV2.sol";
import {OraclePositionMath} from "../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {IFablesPoolRegistry} from "../../../../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../../../../src/interfaces/external/fables/IFablesFeeDistributor.sol";
import {IWETH9} from "../../../../src/interfaces/external/uniswap/IWETH9.sol";
import {
    MockPoolManager,
    MockFablesLedger,
    MockFablesRegistry,
    MockPotDistributor,
    MockWETH9
} from "./FablesMocks.sol";

/// @notice A Fund holding WETH and USDG, and a native ETH/USDG Fables pool on a mock ledger that takes ETH as
///         `msg.value`, refunds the unused budget with a bare call and pays out in ETH, as the live ETH hooks do.
///         The same ledger also lists an ERC20 pool (STK/USDG), so v2's ERC20 path is checked beside it.
abstract contract FablesNativeWorld is FundTestBase {
    using PoolIdLibrary for PoolKey;

    int24 internal constant TS = 10;
    uint24 internal constant DYNAMIC_FEE = 0x800000;

    MockWETH9 internal weth;
    MockERC20 internal tkn;
    MockPoolManager internal pm;
    MockFablesLedger internal ledger;
    MockFablesRegistry internal freg;
    MockPotDistributor internal pot;
    FablesLiquidityAdapterV2 internal impl;
    FablesLiquidityAdapterV2 internal fab;
    PoolKey internal key; // ETH/USDG
    bytes32 internal poolId;
    int24 internal mid;
    PoolKey internal key20; // STK/USDG
    bytes32 internal poolId20;
    int24 internal mid20;
    address internal treasury = makeAddr("fablesTreasury");

    function _buildWorld() internal {
        _setUpCore();
        weth = new MockWETH9();
        vm.deal(address(weth), 1e30); // so WETH dealt by tests can be unwrapped
        _price(address(weth), 2_500e18, PriceClass.Feed, 0);
        tkn = new MockERC20("Stock", "STK", 18);
        _price(address(tkn), 100e18, PriceClass.Feed, 0);
        _createFund(_openDial(), 100_000e6);

        pm = new MockPoolManager();
        ledger = new MockFablesLedger(pm);
        freg = new MockFablesRegistry();
        pot = new MockPotDistributor(address(usdg));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdg)), DYNAMIC_FEE, TS, IHooks(address(ledger)));
        poolId = freg.register(key);
        uint160 sqrtP = _oracleSqrt(address(weth), address(usdg));
        pm.initialize(key.toId(), sqrtP);
        mid = TickMath.getTickAtSqrtPrice(sqrtP) / TS * TS;

        (address c0, address c1) =
            address(tkn) < address(usdg) ? (address(tkn), address(usdg)) : (address(usdg), address(tkn));
        key20 = PoolKey(Currency.wrap(c0), Currency.wrap(c1), DYNAMIC_FEE, TS, IHooks(address(ledger)));
        poolId20 = freg.register(key20);
        uint160 sqrt20 = _oracleSqrt(c0, c1);
        pm.initialize(key20.toId(), sqrt20);
        mid20 = TickMath.getTickAtSqrtPrice(sqrt20) / TS * TS;

        ledger.setClaimFee(1000, treasury);
        vm.deal(address(ledger), 100_000 ether);
        usdg.mint(address(ledger), 1_000_000_000e6);
        tkn.mint(address(ledger), 1_000_000e18);

        impl = new FablesLiquidityAdapterV2(
            IFablesPoolRegistry(address(freg)),
            IPoolManager(address(pm)),
            IFablesFeeDistributor(address(pot)),
            IWETH9(address(weth))
        );
        registry.register(address(impl), "");
        fab = FablesLiquidityAdapterV2(payable(_enable(address(impl), _config(200))));

        // The Fund also holds 20 WETH ($50k) and 500 STK ($50k).
        weth.mint(address(vault), 20e18);
        tkn.mint(address(vault), 500e18);
        vm.startPrank(address(controller));
        vault.track(address(weth));
        vault.track(address(tkn));
        vm.stopPrank();
    }

    function _config(uint16 maxDev) internal view returns (bytes memory) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(ledger);
        bytes32[] memory witness = new bytes32[](1);
        witness[0] = poolId;
        return abi.encode(hooks, witness, maxDev);
    }

    function _oracleSqrt(address t0, address t1) internal view returns (uint160) {
        return OraclePositionMath.sqrtPriceFromPrices(
            router.quote(t0).fair, MockERC20(t0).decimals(), router.quote(t1).fair, MockERC20(t1).decimals()
        );
    }

    // ---- ETH/USDG actions (amount0 is ETH, paid in WETH)
    function _dep(int24 tl, int24 tu, uint256 eth, uint256 usd) internal view returns (bytes memory) {
        return abi.encode(uint8(0), poolId, tl, tu, uint128(eth), uint128(usd), uint128(0));
    }

    function _wd(int24 tl, int24 tu, uint128 liq, uint256 fraction) internal view returns (bytes memory) {
        return abi.encode(uint8(1), poolId, tl, tu, liq, fraction, uint128(0), uint128(0));
    }

    function _claim(int24 tl, int24 tu, uint16 maxFee) internal view returns (bytes memory) {
        return abi.encode(uint8(2), poolId, tl, tu, maxFee);
    }

    function _reb(int24 fl, int24 fu, uint256 fraction, int24 tl, int24 tu, uint256 extraEth)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(uint8(3), poolId, fl, fu, fraction, tl, tu, uint128(extraEth), uint128(0), uint128(0));
    }

    /// @dev Swappers paid `eth` ETH and `usd` USDG in fees to the ETH pool's in-range liquidity.
    function _accrue(uint256 eth, uint256 usd) internal {
        vm.deal(address(this), address(this).balance + eth);
        ledger.accrue{value: eth}(key, eth, usd);
    }

    // ---- STK/USDG
    function _dep20(int24 tl, int24 tu, uint256 stk, uint256 usd) internal view returns (bytes memory) {
        (uint128 a0, uint128 a1) =
            Currency.unwrap(key20.currency0) == address(tkn) ? (uint128(stk), uint128(usd)) : (uint128(usd), uint128(stk));
        return abi.encode(uint8(0), poolId20, tl, tu, a0, a1, uint128(0));
    }

    function _doAct(bytes memory action) internal returns (bytes memory) {
        vm.prank(manager);
        return controller.act(address(fab), action);
    }

    function _rid(int24 tl, int24 tu) internal view returns (uint256) {
        return fab.rangeIdOf(poolId, tl, tu);
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

    function _navFair() internal view returns (uint256 v) {
        (v,) = controller.nav(uint8(Side.Fair));
    }

    /// @dev The vault never holds ETH and the clone never ends a call holding anything loose.
    function _assertClean() internal view {
        assertEq(address(vault).balance, 0, "vault holds native ETH");
        assertEq(address(fab).balance, 0, "clone holds ETH");
        assertEq(weth.balanceOf(address(fab)), 0, "clone holds WETH");
        assertEq(usdg.balanceOf(address(fab)), 0, "clone holds USDG");
        assertEq(tkn.balanceOf(address(fab)), 0, "clone holds STK");
    }

    receive() external payable {}
}

contract FablesLiquidityAdapterV2Test is FablesNativeWorld {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _buildWorld();
    }

    // ---------------------------------------------------------------- what the vault sees

    function test_InputsAndOutputsNameWeth() public view {
        Amount[] memory ins = fab.inputs(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        assertEq(ins[0].token, address(weth), "ETH side pulled as WETH");
        assertEq(ins[0].amount, 1e18);
        assertEq(ins[1].token, address(usdg));
        address[] memory outs = fab.outputs(_wd(mid - 600, mid + 600, 1, 0));
        assertEq(outs[0], address(weth), "ETH side returned as WETH");
        assertEq(outs[1], address(usdg));
        for (uint256 i; i < outs.length; ++i) assertTrue(outs[i] != address(0), "address(0) is never an output");
        ins = fab.inputs(_reb(mid - 600, mid + 600, 1e18, mid - 1200, mid + 1200, 0.5e18));
        assertEq(ins[0].token, address(weth));
        assertEq(ins[0].amount, 0.5e18);
    }

    function test_DepositUnwrapsPaysEthAndWrapsTheRefund() public {
        uint256 navBefore = _navFair();
        uint256 wBefore = weth.balanceOf(address(vault));
        uint256 uBefore = usdg.balanceOf(address(vault));
        // Budget more ETH than the range takes: the ledger refunds the rest in ETH.
        uint128 liq = abi.decode(_doAct(_dep(mid - 600, mid + 600, 4e18, 2_500e6)), (uint128));
        uint256 rid = _rid(mid - 600, mid + 600);
        assertEq(ledger.balanceOf(address(fab), rid), liq, "clone holds the ledger shares");
        uint256 wSpent = wBefore - weth.balanceOf(address(vault));
        uint256 uSpent = uBefore - usdg.balanceOf(address(vault));
        assertGt(wSpent, 0, "some WETH used");
        assertLt(wSpent, 4e18, "the refund came back to the vault as WETH");
        assertEq(address(ledger).balance, 100_000 ether + wSpent, "the ledger got exactly the ETH the vault spent");
        assertLe(uSpent, 2_500e6);
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18, "NAV unchanged by a deposit at the oracle price");
        _assertClean();
    }

    function test_PositionsReportWethAtTheOraclePrice() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        (Amount[] memory held,) = fab.positions(router);
        assertEq(held[0].token, address(weth));
        assertEq(held[1].token, address(usdg));
        assertGt(_usd(held), 4_900e18, "range worth about what went in");
        uint256 before = _positionsUsd();
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 105 / 100));
        assertEq(_positionsUsd(), before, "moving the pool does not move the value");
    }

    function test_ClaimFeesArriveAsWeth() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(0.01e18, 25e6);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertApproxEqAbs(f0, 0.009e18, 2, "ETH fees net of the 10% claim fee");
        assertApproxEqAbs(f1, 22.5e6, 2);
        uint256 w = weth.balanceOf(address(vault));
        uint256 u = usdg.balanceOf(address(vault));
        _doAct(_claim(mid - 600, mid + 600, 1000));
        assertApproxEqAbs(weth.balanceOf(address(vault)) - w, f0, 2, "ETH fees reached the vault as WETH");
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - u, f1, 2);
        assertApproxEqAbs(treasury.balance, 0.001e18, 2, "Fables kept its claim fee in ETH");
        _assertClean();
    }

    function test_WithdrawReturnsWeth() public {
        uint128 liq = abi.decode(_doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6)), (uint128));
        _accrue(0.01e18, 25e6);
        uint256 navBefore = _navFair();
        uint256 w = weth.balanceOf(address(vault));
        _doAct(_wd(mid - 600, mid + 600, 0, 0.5e18));
        assertGt(weth.balanceOf(address(vault)), w, "principal and fees came back as WETH");
        _doAct(_wd(mid - 600, mid + 600, liq - liq / 2, 0));
        assertEq(fab.ranges().length, 0, "range closed");
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18);
        _assertClean();
    }

    function test_RebalanceWithExtraWeth() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        _accrue(0.01e18, 25e6);
        uint256 navBefore = _navFair();
        bytes memory res = _doAct(_reb(mid - 600, mid + 600, 1e18, mid - 1200, mid + 1200, 0.5e18));
        (, uint128 added) = abi.decode(res, (uint128, uint128));
        assertEq(ledger.balanceOf(address(fab), _rid(mid - 1200, mid + 1200)), added);
        assertEq(ledger.balanceOf(address(fab), _rid(mid - 600, mid + 600)), 0);
        assertEq(fab.ranges().length, 1);
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18, "a rebalance at the oracle price keeps NAV");
        _assertClean();
    }

    function test_UnwindWhileClaimsPausedThenAfter() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(0.01e18, 25e6);
        ledger.setPaused(7 days);
        uint256 navBefore = _navFair();
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);
        assertEq(ledger.balanceOf(address(fab), rid), 0, "principal out despite the pause");
        assertEq(fab.ranges().length, 1, "range kept while fees are owed");
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18);
        _assertClean();
        vm.warp(block.timestamp + 7 days + 1);
        _price(address(weth), 2_500e18, PriceClass.Feed, 0); // the warp made the mock feed stale
        _price(address(usdg), 1e18, PriceClass.Feed, 0);
        _price(address(tkn), 100e18, PriceClass.Feed, 0);
        vm.prank(owner);
        Amount[] memory got = controller.unwindAdapter(address(fab), 1e18);
        assertEq(fab.ranges().length, 0, "fees collected once the pause lapsed");
        for (uint256 i; i < got.length; ++i) assertTrue(got[i].token != address(0));
        _assertClean();
    }

    function test_SplitHandsTheLeaverWeth() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        uint256 shares = ledger.balanceOf(address(fab), rid);
        _accrue(0.01e18, 25e6);
        uint256 total = _positionsUsd();
        address leaver = makeAddr("leaver");
        uint256 vWeth = weth.balanceOf(address(vault));

        vm.prank(address(controller));
        Amount[] memory sent = fab.split(0.25e18, leaver);

        assertEq(leaver.balance, 0, "leaver gets no native ETH");
        assertGt(weth.balanceOf(leaver), 0, "leaver gets WETH");
        assertGt(usdg.balanceOf(leaver), 0);
        assertApproxEqRel(_usd(sent), total / 4, 0.0001e18, "a quarter of principal and fees");
        assertEq(_sentOf(sent, address(weth)), weth.balanceOf(leaver), "reported what was sent");
        assertGe(ledger.balanceOf(address(fab), rid), shares - shares / 4, "75% of the shares stay");
        assertApproxEqAbs(weth.balanceOf(address(vault)) - vWeth, 0.00675e18, 2, "the other 75% of ETH fees");
        _assertClean();
    }

    function test_GrowPaysInEth() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(0.01e18, 25e6);
        vm.prank(address(controller));
        fab.grow(0);
        uint256 s0 = ledger.balanceOf(address(fab), rid);
        Amount[] memory needs = fab.growInputs(0.5e18);
        assertEq(needs[0].token, address(weth), "grow asks for WETH");
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) vault.approveFor(needs[i].token, address(fab), needs[i].amount);
        fab.grow(0.5e18);
        vm.stopPrank();
        assertGe(ledger.balanceOf(address(fab), rid) * 2, s0 * 3, "shares grew by half");
        assertEq(weth.allowance(address(vault), address(fab)), 0, "pulled exactly growInputs");
        _assertClean();
    }

    // ---------------------------------------------------------------- ETH in and out of the clone

    function test_ReceiveRefusesStrangers() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(fab).call{value: 1 ether}("");
        assertFalse(ok, "a stranger cannot send ETH");
        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault));
        (ok,) = address(fab).call{value: 1 ether}("");
        assertFalse(ok, "nor the vault");
        vm.deal(address(vault), 0);
        // The allowed hook, the PoolManager and WETH may.
        vm.deal(address(pm), 1 ether);
        vm.prank(address(pm));
        (ok,) = address(fab).call{value: 1 wei}("");
        assertTrue(ok, "PoolManager");
        vm.prank(address(ledger));
        (ok,) = address(fab).call{value: 1 wei}("");
        assertTrue(ok, "allowed hook");
        vm.prank(address(weth));
        (ok,) = address(fab).call{value: 1 wei}("");
        assertTrue(ok, "WETH");
    }

    function test_ReceiveRefusesAHookThisFundDoesNotAllow() public {
        MockFablesLedger other = new MockFablesLedger(pm);
        vm.deal(address(other), 1 ether);
        vm.prank(address(other));
        (bool ok,) = address(fab).call{value: 1 wei}("");
        assertFalse(ok);
    }

    function test_ForcedEthIsCountedThenWrappedAndSwept() public {
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        uint256 navBefore = _navFair();
        vm.deal(address(fab), 0.5 ether); // as a selfdestruct would
        assertApproxEqRel(_navFair(), navBefore + 1_250e18, 0.0001e18, "loose ETH counted as WETH");
        uint256 w = weth.balanceOf(address(vault));
        _doAct(_claim(mid - 600, mid + 600, 1000));
        assertEq(weth.balanceOf(address(vault)) - w, 0.5e18, "wrapped and swept by the next action");
        _assertClean();
    }

    function test_EthPoolNeedsItsHookAllowed() public {
        MockFablesLedger other = new MockFablesLedger(pm);
        PoolKey memory k2 = PoolKey(key.currency0, key.currency1, DYNAMIC_FEE, TS, IHooks(address(other)));
        bytes32 id2 = freg.register(k2);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FablesLiquidityAdapterV2.HookNotAllowed.selector, address(other)));
        controller.act(address(fab), abi.encode(uint8(0), id2, mid - 600, mid + 600, uint128(1e18), uint128(2_500e6), uint128(0)));
    }

    function test_SpotGuardUsesTheWethPrice() public {
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 1020 / 1000)); // about 4% off, limit 2%
        vm.prank(manager);
        vm.expectPartialRevert(FablesLiquidityAdapterV2.PoolPriceOffOracle.selector);
        controller.act(address(fab), _dep(mid - 600, mid + 600, 1e18, 2_500e6));
        pm.setSpot(key.toId(), p);
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6)); // at the oracle it goes through
    }

    function test_ImplementationNeedsWeth() public {
        vm.expectRevert();
        new FablesLiquidityAdapterV2(
            IFablesPoolRegistry(address(freg)), IPoolManager(address(pm)), IFablesFeeDistributor(address(pot)), IWETH9(address(0))
        );
    }

    // ---------------------------------------------------------------- ERC20 pools as in v1

    function test_Erc20PoolBesideTheEthPool() public {
        uint256 navBefore = _navFair();
        _doAct(_dep(mid - 600, mid + 600, 1e18, 2_500e6));
        _doAct(_dep20(mid20 - 600, mid20 + 600, 50e18, 5_000e6));
        assertEq(fab.ranges().length, 2);
        (Amount[] memory held,) = fab.positions(router);
        assertEq(held.length, 5, "two rows per range and the pot row");
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18);
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);
        assertEq(fab.ranges().length, 0);
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18);
        _assertClean();
    }

    function test_DescribeIsValidJson() public view {
        string memory j = fab.describe();
        assertEq(vm.parseJsonString(j, ".adapter"), "Fables liquidity v2");
        assertEq(vm.parseJsonString(j, ".actions[4].name"), "claimPot");
        assertEq(fab.name(), "Fables liquidity v2");
    }

    function _sentOf(Amount[] memory a, address token) internal pure returns (uint256) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token == token) return a[i].amount;
        }
        return 0;
    }
}

/// @notice The shared adapter suite against the native ETH/USDG pool: every rule holds with WETH in the vault.
contract FablesV2NativeSuiteTest is AdapterSuite, FablesNativeWorld {
    function _growTolerance() internal pure override returns (uint256) {
        return 2;
    }

    function _setUpAdapter() internal override returns (IAdapter) {
        _buildWorld();
        vm.prank(manager);
        controller.act(address(fab), _dep(mid - 600, mid + 600, 4e18, 10_000e6));
        _accrue(0.04e18, 100e6);
        return IAdapter(address(fab));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint256 kind = seed % 5;
        uint256 size = bound(seed >> 8, 1, 100);
        if (kind == 0) return _dep(mid - 1200, mid + 1200, size * 0.04e18, size * 100e6);
        if (kind == 1) return _dep(mid + 120, mid + 1800, size * 0.04e18, size * 100e6); // one-sided, above
        if (kind == 2) return _wd(mid - 600, mid + 600, 0, bound(seed >> 16, 1e12, 1e18));
        if (kind == 3) return _claim(mid - 600, mid + 600, 1000);
        return _reb(mid - 600, mid + 600, bound(seed >> 16, 1e15, 1e18), mid - 1800, mid + 600, 0);
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(weth);
        t[1] = address(usdg);
    }
}

/// @notice The shared adapter suite against v2 on an ERC20 pool (STK/USDG): v1's behaviour, unchanged.
contract FablesV2Erc20SuiteTest is AdapterSuite, FablesNativeWorld {
    function _growTolerance() internal pure override returns (uint256) {
        return 2;
    }

    function _setUpAdapter() internal override returns (IAdapter) {
        _buildWorld();
        vm.prank(manager);
        controller.act(address(fab), _dep20(mid20 - 600, mid20 + 600, 100e18, 10_000e6));
        (uint256 a0, uint256 a1) = Currency.unwrap(key20.currency0) == address(tkn) ? (uint256(1e18), uint256(100e6)) : (uint256(100e6), uint256(1e18));
        ledger.accrue(key20, a0, a1);
        return IAdapter(address(fab));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint256 kind = seed % 5;
        uint256 size = bound(seed >> 8, 1, 100);
        if (kind == 0) return _dep20(mid20 - 1200, mid20 + 1200, size * 1e18, size * 100e6);
        if (kind == 1) return _dep20(mid20 + 120, mid20 + 1800, size * 1e18, size * 100e6);
        if (kind == 2) {
            return abi.encode(uint8(1), poolId20, mid20 - 600, mid20 + 600, uint128(0), bound(seed >> 16, 1e12, 1e18), uint128(0), uint128(0));
        }
        if (kind == 3) return abi.encode(uint8(2), poolId20, mid20 - 600, mid20 + 600, uint16(1000));
        return abi.encode(
            uint8(3), poolId20, mid20 - 600, mid20 + 600, bound(seed >> 16, 1e15, 1e18), mid20 - 1800, mid20 + 600,
            uint128(0), uint128(0), uint128(0)
        );
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](3);
        t[0] = address(tkn);
        t[1] = address(usdg);
        t[2] = address(weth);
    }
}
