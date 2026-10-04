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
import {FablesLiquidityAdapter} from "../../../../src/adapters/liquidity/FablesLiquidityAdapter.sol";
import {OraclePositionMath} from "../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {IFablesPoolRegistry} from "../../../../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../../../../src/interfaces/external/fables/IFablesFeeDistributor.sol";
import {MockPoolManager, MockFablesLedger, MockFablesRegistry, MockPotDistributor} from "./FablesMocks.sol";

/// @notice A Fund, a stock token at $100 against USDG, and a Fables pool on a mock ledger sitting at the oracle.
abstract contract FablesWorld is FundTestBase {
    using PoolIdLibrary for PoolKey;

    int24 internal constant TS = 60;
    uint24 internal constant DYNAMIC_FEE = 0x800000;

    MockERC20 internal tkn;
    MockPoolManager internal pm;
    MockFablesLedger internal ledger;
    MockFablesRegistry internal freg;
    MockPotDistributor internal pot;
    FablesLiquidityAdapter internal impl;
    FablesLiquidityAdapter internal fab;
    PoolKey internal key;
    bytes32 internal poolId;
    int24 internal mid; // spot tick rounded to the spacing
    address internal treasury = makeAddr("fablesTreasury");

    function _buildWorld() internal {
        _setUpCore();
        tkn = new MockERC20("Stock", "STK", 18);
        _price(address(tkn), 100e18, PriceClass.Feed, 0);
        _createFund(_openDial(), 100_000e6);

        pm = new MockPoolManager();
        ledger = new MockFablesLedger(pm);
        freg = new MockFablesRegistry();
        pot = new MockPotDistributor(address(usdg));
        (address c0, address c1) =
            address(tkn) < address(usdg) ? (address(tkn), address(usdg)) : (address(usdg), address(tkn));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), DYNAMIC_FEE, TS, IHooks(address(ledger)));
        poolId = freg.register(key);
        uint160 sqrtP = _oracleSqrt();
        pm.initialize(key.toId(), sqrtP);
        mid = TickMath.getTickAtSqrtPrice(sqrtP) / TS * TS;
        ledger.setClaimFee(1000, treasury); // Fables' usual 10%
        // The rest of the pool: reserves so withdrawals at a moved price can be paid.
        tkn.mint(address(ledger), 1_000_000e18);
        usdg.mint(address(ledger), 100_000_000e6);

        impl = new FablesLiquidityAdapter(
            IFablesPoolRegistry(address(freg)), IPoolManager(address(pm)), IFablesFeeDistributor(address(pot))
        );
        registry.register(address(impl), "");
        fab = FablesLiquidityAdapter(_enable(address(impl), _config(200)));

        // The Fund also holds 500 STK ($50k) so it can provide both sides.
        tkn.mint(address(vault), 500e18);
        vm.prank(address(controller));
        vault.track(address(tkn));
    }

    function _config(uint16 maxDev) internal view returns (bytes memory) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(ledger);
        bytes32[] memory witness = new bytes32[](1);
        witness[0] = poolId;
        return abi.encode(hooks, witness, maxDev);
    }

    function _oracleSqrt() internal view returns (uint160) {
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        return OraclePositionMath.sqrtPriceFromPrices(
            router.quote(t0).fair, MockERC20(t0).decimals(), router.quote(t1).fair, MockERC20(t1).decimals()
        );
    }

    /// @dev Amounts in the pool's order for `stk` stock tokens and `usd` USDG.
    function _amounts(uint256 stk, uint256 usd) internal view returns (uint128 a0, uint128 a1) {
        (a0, a1) = Currency.unwrap(key.currency0) == address(tkn) ? (uint128(stk), uint128(usd)) : (uint128(usd), uint128(stk));
    }

    /// @dev Swappers paid `stk` stock tokens and `usd` USDG in fees to the pool's in-range liquidity.
    function _accrue(uint256 stk, uint256 usd) internal {
        (uint128 a0, uint128 a1) = _amounts(stk, usd);
        ledger.accrue(key, a0, a1);
    }

    function _dep(int24 tl, int24 tu, uint256 stk, uint256 usd) internal view returns (bytes memory) {
        (uint128 a0, uint128 a1) = _amounts(stk, usd);
        return abi.encode(uint8(0), poolId, tl, tu, a0, a1, uint128(0));
    }

    function _wd(int24 tl, int24 tu, uint128 liq, uint256 fraction) internal view returns (bytes memory) {
        return abi.encode(uint8(1), poolId, tl, tu, liq, fraction, uint128(0), uint128(0));
    }

    function _claim(int24 tl, int24 tu, uint16 maxFee) internal view returns (bytes memory) {
        return abi.encode(uint8(2), poolId, tl, tu, maxFee);
    }

    function _reb(int24 fl, int24 fu, uint256 fraction, int24 tl, int24 tu) internal view returns (bytes memory) {
        return abi.encode(uint8(3), poolId, fl, fu, fraction, tl, tu, uint128(0), uint128(0), uint128(0));
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
}

contract FablesLiquidityAdapterTest is FablesWorld {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _buildWorld();
    }

    // ---------------------------------------------------------------- deposit and valuation

    function test_DepositHoldsSharesAndValuesAtOracle() public {
        uint256 navBefore = _navFair();
        bytes memory res = _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint128 liq = abi.decode(res, (uint128));
        uint256 rid = _rid(mid - 600, mid + 600);
        assertEq(ledger.balanceOf(address(fab), rid), liq, "clone holds the ledger shares");
        assertGt(_positionsUsd(), 9_900e18, "position worth roughly what went in");
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18, "NAV unchanged by a deposit at the oracle price");
        assertEq(tkn.balanceOf(address(fab)), 0);
        assertEq(usdg.balanceOf(address(fab)), 0);
    }

    function test_PositionsIgnoreThePoolPrice() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint256 before = _positionsUsd();
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 110 / 100)); // pool pushed ~21% in price
        assertEq(_positionsUsd(), before, "moving the pool must not move the Fund's value");
        pm.setSpot(key.toId(), uint160(uint256(p) * 90 / 100));
        assertEq(_positionsUsd(), before);
    }

    function test_FeesCountedNetOfClaimFeeThenClaimed() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        uint256 before = _positionsUsd();
        _accrue(1e18, 100e6); // swappers paid 1 STK and 100 USDG
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        (uint256 e0, uint256 e1) = _feeAmounts(0.9e18, 90e6); // 10% claim fee kept by Fables
        assertApproxEqAbs(f0, e0, 2, "fee0 net of claim fee");
        assertApproxEqAbs(f1, e1, 2, "fee1 net of claim fee");
        assertApproxEqRel(_positionsUsd(), before + 180e18, 0.0001e18, "fees are part of the position");

        uint256 vUsdg = usdg.balanceOf(address(vault));
        uint256 vTkn = tkn.balanceOf(address(vault));
        _doAct(_claim(mid - 600, mid + 600, 1000));
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - vUsdg, 90e6, 2, "USDG fees reached the vault");
        assertApproxEqAbs(tkn.balanceOf(address(vault)) - vTkn, 0.9e18, 2, "stock fees reached the vault");
        (f0, f1) = fab.pendingFees(rid);
        assertEq(f0 + f1, 0);
        assertApproxEqAbs(usdg.balanceOf(treasury), 10e6, 2, "Fables treasury kept 10%");
    }

    function test_FeesStopWhilePriceOutOfRange() public {
        _doAct(_dep(mid + 600, mid + 1200, 10e18, 1_000e6)); // above the price: one-sided
        uint256 rid = _rid(mid + 600, mid + 1200);
        _doAct(_dep(mid - 600, mid + 600, 10e18, 1_000e6)); // gives the pool active liquidity
        _accrue(1e18, 100e6);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertEq(f0 + f1, 0, "out of range earns nothing");
    }

    function test_ClaimFeeBoundIsTheManagersChoice() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        _accrue(1e18, 100e6);
        vm.prank(manager);
        vm.expectRevert(MockFablesLedger.ClaimFeeAboveMax.selector);
        controller.act(address(fab), _claim(mid - 600, mid + 600, 500));
    }

    // ---------------------------------------------------------------- guards

    function test_DepositRefusedWhilePoolIsOffOracle() public {
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 1020 / 1000)); // about 4% in price, limit is 2%
        vm.prank(manager);
        vm.expectPartialRevert(FablesLiquidityAdapter.PoolPriceOffOracle.selector);
        controller.act(address(fab), _dep(mid - 600, mid + 600, 100e18, 10_000e6));
    }

    /// The guard is the owner's choice: 0 turns it off (the default for new Funds). A deposit into a moved pool
    /// then goes through, and the oracle valuation shows what it cost in the same action.
    function test_SpotGuardOffLetsDepositThroughAndCountsTheCost() public {
        FablesLiquidityAdapter open_ = FablesLiquidityAdapter(_enable(address(impl), _config(0)));
        assertEq(open_.maxSpotDeviationBps(), 0);
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 1020 / 1000)); // about 4% off the oracle
        uint256 navBefore = _navFair();
        vm.prank(manager);
        controller.act(address(open_), _dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint256 navAfter = _navFair();
        assertLe(navAfter, navBefore, "a deposit into a moved pool cannot show a gain");
        emit log_named_decimal_uint("cost of depositing 4% off the oracle (USD)", navBefore - navAfter, 18);
    }

    function test_SpotGuardAboveFullRangeRefused() public {
        vm.prank(owner);
        vm.expectRevert(FablesLiquidityAdapter.BadDeviation.selector);
        controller.addAdapter(address(impl), _config(10_001));
    }

    function test_DepositRefusedForRetiredPool() public {
        freg.setActive(poolId, false);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FablesLiquidityAdapter.PoolNotActive.selector, poolId));
        controller.act(address(fab), _dep(mid - 600, mid + 600, 100e18, 10_000e6));
    }

    function test_DepositRefusedOnHookNotAllowed() public {
        MockFablesLedger other = new MockFablesLedger(pm);
        PoolKey memory k2 = PoolKey(key.currency0, key.currency1, DYNAMIC_FEE, TS, IHooks(address(other)));
        bytes32 id2 = freg.register(k2);
        pm.initialize(k2.toId(), _oracleSqrt());
        (uint128 a0, uint128 a1) = _amounts(10e18, 1_000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FablesLiquidityAdapter.HookNotAllowed.selector, address(other)));
        controller.act(address(fab), abi.encode(uint8(0), id2, mid - 600, mid + 600, a0, a1, uint128(0)));
    }

    function test_NativePoolRefused() public {
        PoolKey memory k2 = PoolKey(Currency.wrap(address(0)), key.currency1, DYNAMIC_FEE, TS, IHooks(address(ledger)));
        bytes32 id2 = freg.register(k2);
        vm.prank(manager);
        vm.expectRevert(FablesLiquidityAdapter.NativeNotSupported.selector);
        controller.act(address(fab), abi.encode(uint8(0), id2, mid - 600, mid + 600, uint128(1e18), uint128(1e6), uint128(0)));
    }

    function test_ConfigNeedsARegistryWitnessForEachHook() public {
        MockFablesLedger stranger = new MockFablesLedger(pm);
        address[] memory hooks = new address[](1);
        hooks[0] = address(stranger);
        bytes32[] memory witness = new bytes32[](1);
        witness[0] = poolId; // listed, but under a different hook
        FablesLiquidityAdapter impl2 = new FablesLiquidityAdapter(
            IFablesPoolRegistry(address(freg)), IPoolManager(address(pm)), IFablesFeeDistributor(address(pot))
        );
        registry.register(address(impl2), "");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FablesLiquidityAdapter.HookNotFables.selector, address(stranger)));
        controller.addAdapter(address(impl2), abi.encode(hooks, witness, uint16(200)));
    }

    function test_RangeCountIsBounded() public {
        for (uint256 i; i < fab.MAX_RANGES(); ++i) {
            int24 w = int24(int256(60 * (i + 1)));
            _doAct(_dep(mid - w, mid + w, 1e18, 100e6));
        }
        vm.prank(manager);
        vm.expectRevert(FablesLiquidityAdapter.TooManyRanges.selector);
        controller.act(address(fab), _dep(mid - 6000, mid + 6000, 1e18, 100e6));
    }

    function test_MissingPriceMarksBookIncompleteWithoutReverting() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        source.setDown(address(tkn), true);
        fab.positions(router); // must not revert
        (, bool complete) = controller.nav(uint8(Side.Fair));
        assertFalse(complete, "an unpriced position must not be counted as if priced");
    }

    // ---------------------------------------------------------------- withdraw and rebalance

    function test_WithdrawByFractionThenByLiquidity() public {
        uint128 liq = abi.decode(_doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6)), (uint128));
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(1e18, 100e6);
        uint256 navBefore = _navFair();
        _doAct(_wd(mid - 600, mid + 600, 0, 0.5e18));
        assertEq(ledger.balanceOf(address(fab), rid), liq - liq / 2);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertEq(f0 + f1, 0, "withdraw also claimed the fees");
        _doAct(_wd(mid - 600, mid + 600, uint128(ledger.balanceOf(address(fab), rid)), 0));
        assertEq(fab.ranges().length, 0, "empty range forgotten");
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18);
        assertEq(tkn.balanceOf(address(fab)) + usdg.balanceOf(address(fab)), 0);
    }

    function test_RebalanceMovesToNewRange() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        _accrue(1e18, 100e6);
        uint256 navBefore = _navFair();
        bytes memory res = _doAct(_reb(mid - 600, mid + 600, 1e18, mid - 1200, mid + 1200));
        (, uint128 added) = abi.decode(res, (uint128, uint128));
        FablesLiquidityAdapter.Range[] memory rs = fab.ranges();
        assertEq(rs.length, 1);
        assertEq(rs[0].tickLower, mid - 1200);
        assertEq(ledger.balanceOf(address(fab), _rid(mid - 1200, mid + 1200)), added);
        assertEq(ledger.balanceOf(address(fab), _rid(mid - 600, mid + 600)), 0);
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18, "a rebalance at the oracle price keeps NAV");
        assertEq(tkn.balanceOf(address(fab)) + usdg.balanceOf(address(fab)), 0);
    }

    function test_RebalanceRefusedWhilePoolIsOffOracle() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 1020 / 1000));
        vm.prank(manager);
        vm.expectPartialRevert(FablesLiquidityAdapter.PoolPriceOffOracle.selector);
        controller.act(address(fab), _reb(mid - 600, mid + 600, 1e18, mid - 1200, mid + 1200));
    }

    // ---------------------------------------------------------------- exits

    function test_UnwindReturnsPrincipalWhileClaimsArePaused() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(1e18, 100e6);
        ledger.setPaused(7 days);
        uint256 navBefore = _navFair();

        vm.expectEmit(true, false, false, false, address(fab));
        emit FablesLiquidityAdapter.FeesClaimSkipped(rid);
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);

        assertEq(ledger.balanceOf(address(fab), rid), 0, "principal out despite the pause");
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertGt(f0 + f1, 0, "fees still owed and still counted");
        assertEq(fab.ranges().length, 1, "range kept while fees are owed");
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18, "nothing lost, fees still in the book");

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(owner);
        controller.unwindAdapter(address(fab), 1e18);
        assertEq(fab.ranges().length, 0, "fees collected once the pause lapsed");
        (Amount[] memory left,) = fab.positions(router);
        for (uint256 i; i < left.length; ++i) assertEq(left[i].amount, 0);
        assertApproxEqRel(_navFair(), navBefore, 0.0001e18);
    }

    function test_ClaimFeesActionRevertsWhilePaused() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        _accrue(1e18, 100e6);
        ledger.setPaused(1 days);
        vm.prank(manager);
        vm.expectRevert(MockFablesLedger.LedgerPaused.selector);
        controller.act(address(fab), _claim(mid - 600, mid + 600, 1000));
    }

    function test_SplitHandsTheLeaverItsSlice() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        uint256 shares = ledger.balanceOf(address(fab), rid);
        _accrue(1e18, 100e6);
        uint256 total = _positionsUsd();
        address leaver = makeAddr("leaver");
        uint256 vUsdg = usdg.balanceOf(address(vault));

        vm.prank(address(controller));
        Amount[] memory sent = fab.split(0.25e18, leaver);

        // 75% stay, plus at most the exit margin (GrowMath.taken: a unit of each token, at most shares / 1e6 + 1).
        assertGe(ledger.balanceOf(address(fab), rid), shares - shares / 4, "75% of the shares stay");
        assertLe(ledger.balanceOf(address(fab), rid), shares - shares / 4 + shares / 1e6 + 1, "and the margin");
        assertApproxEqRel(_usd(sent), total / 4, 0.0001e18, "leaver got a quarter of principal and fees");
        assertApproxEqAbs(tkn.balanceOf(leaver), _sentOf(sent, address(tkn)), 0);
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - vUsdg, 67.5e6, 2, "the other 75% of USDG fees to the vault");
        assertEq(tkn.balanceOf(address(fab)) + usdg.balanceOf(address(fab)), 0);
    }

    function test_SplitWhilePausedStillMovesPrincipal() public {
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(1e18, 100e6);
        ledger.setPaused(7 days);
        address leaver = makeAddr("leaver");
        vm.prank(address(controller));
        fab.split(1e18, leaver);
        assertEq(ledger.balanceOf(address(fab), rid), 0);
        assertGt(tkn.balanceOf(leaver), 0);
        assertGt(usdg.balanceOf(leaver), 0);
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertGt(f0 + f1, 0, "unclaimable fees stay with the Fund");
    }

    // ---------------------------------------------------------------- USDG pot

    function test_ClaimPotSendsUsdgToVault() public {
        usdg.mint(address(pot), 1_000e6);
        pot.setRoot(pot.leaf(address(fab), 50e6)); // one-leaf tree: the proof is empty
        uint256 before = usdg.balanceOf(address(vault));
        _doAct(abi.encode(uint8(4), uint256(50e6), new bytes32[](0)));
        assertEq(usdg.balanceOf(address(vault)) - before, 50e6);
        assertEq(usdg.balanceOf(address(fab)), 0);
    }

    function test_PotClaimedByAStrangerIsCountedThenSwept() public {
        usdg.mint(address(pot), 1_000e6);
        pot.setRoot(pot.leaf(address(fab), 50e6));
        uint256 navBefore = _navFair();
        // Anyone may claim for the clone; the USDG lands in the clone.
        pot.claim(address(fab), 50e6, new bytes32[](0));
        assertEq(usdg.balanceOf(address(fab)), 50e6);
        assertEq(_navFair(), navBefore + 50e18, "loose pot USDG is counted");
        uint256 before = usdg.balanceOf(address(vault));
        _doAct(abi.encode(uint8(4), uint256(50e6), new bytes32[](0)));
        assertEq(usdg.balanceOf(address(vault)) - before, 50e6, "swept even though the claim itself failed");
    }

    function test_ClaimPotWithNothingReverts() public {
        pot.setRoot(pot.leaf(address(fab), 50e6));
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(fab), abi.encode(uint8(4), uint256(49e6), new bytes32[](0)));
    }

    // ---------------------------------------------------------------- describe

    function test_DescribeIsValidJson() public view {
        string memory j = fab.describe();
        assertEq(vm.parseJsonUint(j, ".actions[3].id"), 3);
        assertEq(vm.parseJsonString(j, ".actions[4].name"), "claimPot");
        assertEq(vm.parseJsonString(j, ".adapter"), "Fables liquidity v1");
    }

    // ---------------------------------------------------------------- helpers

    function _feeAmounts(uint256 stk, uint256 usd) internal view returns (uint256 f0, uint256 f1) {
        (uint128 a0, uint128 a1) = _amounts(stk, usd);
        return (a0, a1);
    }

    function _sentOf(Amount[] memory a, address token) internal pure returns (uint256) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token == token) return a[i].amount;
        }
        return 0;
    }
}

/// @notice `grow`: the same fraction more shares in every range, fees claimed to the vault first.
contract FablesGrowTest is FablesWorld {
    function setUp() public {
        _buildWorld();
        _doAct(_dep(mid - 600, mid + 600, 100e18, 10_000e6));
    }

    function _approveGrow(uint256 f) internal returns (Amount[] memory needs) {
        needs = fab.growInputs(f);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            MockERC20(needs[i].token).mint(address(vault), needs[i].amount);
            vault.approveFor(needs[i].token, address(fab), needs[i].amount);
        }
        vm.stopPrank();
    }

    function test_GrowClaimsFeesThenGrowsShares() public {
        uint256 rid = _rid(mid - 600, mid + 600);
        _accrue(1e18, 100e6);
        uint256 vUsdg = usdg.balanceOf(address(vault));
        vm.prank(address(controller));
        fab.grow(0);
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - vUsdg, 90e6, 2, "fees claimed to the vault");
        (uint256 f0, uint256 f1) = fab.pendingFees(rid);
        assertEq(f0 + f1, 0, "position is principal only");

        uint256 s0 = ledger.balanceOf(address(fab), rid);
        Amount[] memory needs = _approveGrow(0.25e18);
        vm.prank(address(controller));
        Amount[] memory used = fab.grow(0.25e18);
        assertGe(ledger.balanceOf(address(fab), rid) * 4, s0 * 5, "shares grew by less than a quarter");
        for (uint256 i; i < needs.length; ++i) {
            assertEq(IERC20(needs[i].token).allowance(address(vault), address(fab)), 0);
            assertLe(used[i].amount, needs[i].amount);
        }
        assertEq(tkn.balanceOf(address(fab)), 0);
        assertEq(usdg.balanceOf(address(fab)), 0);
    }

    /// The owner's spot guard applies to deposits into the existing mix too.
    function test_GrowRefusedWhilePoolIsOffOracle() public {
        (uint160 p,) = pm.spot(key.toId());
        pm.setSpot(key.toId(), uint160(uint256(p) * 1020 / 1000));
        _approveGrow(0.1e18);
        vm.prank(address(controller));
        vm.expectRevert();
        fab.grow(0.1e18);
    }

    /// Fables can pause deposits; then the grow, and the batch, waits.
    function test_GrowRevertsWhileFablesIsPaused() public {
        ledger.setPaused(7 days);
        _approveGrow(0.1e18);
        vm.prank(address(controller));
        vm.expectRevert();
        fab.grow(0.1e18);
    }

    function test_GrowOnlyController() public {
        vm.expectRevert();
        fab.grow(0.1e18);
    }
}

/// @notice The shared adapter suite against the mock Fables world. A base range with fees is opened in setUp so
///         withdraw, claim and rebalance are valid actions from the first fuzz run.
contract FablesAdapterSuiteTest is AdapterSuite, FablesWorld {
    /// @dev A range side worth only a few raw units at the fair price may read one short after rounding.
    function _growTolerance() internal pure override returns (uint256) {
        return 2;
    }

    function _setUpAdapter() internal override returns (IAdapter) {
        _buildWorld();
        vm.prank(manager);
        controller.act(address(fab), _dep(mid - 600, mid + 600, 100e18, 10_000e6));
        _accrue(1e18, 100e6);
        return IAdapter(address(fab));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint256 kind = seed % 5;
        uint256 size = bound(seed >> 8, 1, 100);
        if (kind == 0) return _dep(mid - 1200, mid + 1200, size * 1e18, size * 100e6);
        if (kind == 1) return _dep(mid + 120, mid + 1800, size * 1e18, size * 100e6); // one-sided, above
        if (kind == 2) return _wd(mid - 600, mid + 600, 0, bound(seed >> 16, 1e12, 1e18));
        if (kind == 3) return _claim(mid - 600, mid + 600, 1000);
        return _reb(mid - 600, mid + 600, bound(seed >> 16, 1e15, 1e18), mid - 1800, mid + 600);
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(tkn);
        t[1] = address(usdg);
    }
}
