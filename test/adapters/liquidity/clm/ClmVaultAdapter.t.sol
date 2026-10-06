// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../../../utils/FundTestBase.sol";
import {AdapterSuite} from "../../AdapterSuite.sol";
import {MockERC20} from "../../../utils/Mocks.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {IPriceRouter, PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {IUniswapV3Factory} from "../../../../src/interfaces/external/uniswap/IUniswapV3.sol";
import {ClmVaultAdapter} from "../../../../src/adapters/liquidity/clm/ClmVaultAdapter.sol";
import {OraclePositionMath} from "../../../../src/adapters/liquidity/OraclePositionMath.sol";
import {MockV3Factory, MockClmPool, MockClmStrategy, MockClmVault} from "./ClmMocks.sol";

abstract contract ClmWorld is FundTestBase {
    address internal beefyFactory = makeAddr("beefyStrategyFactory");
    address internal beefyStratOwner = makeAddr("beefyStrategyOwner");
    address internal beefyVaultOwner = makeAddr("beefyVaultOwner");
    address internal arrowFactory = makeAddr("arrowStrategyFactory");
    address internal arrowOwner = makeAddr("arrowOwner");
    address internal lp = makeAddr("otherLp");

    MockERC20 internal stock;
    MockV3Factory internal v3;
    ClmVaultAdapter internal impl;
    ClmVaultAdapter internal c;
    MockClmVault internal beefy;
    MockClmVault internal arrow;
    address internal t0;
    address internal t1;

    function _setUpClm() internal {
        _setUpCore();
        _createFund(_openDial(), 10_000e6);
        stock = new MockERC20("Stock", "STK", 18);
        _price(address(stock), 200e18, PriceClass.Feed, 50);
        stock.mint(address(vault), 50e18);
        (t0, t1) = address(usdg) < address(stock) ? (address(usdg), address(stock)) : (address(stock), address(usdg));
        v3 = new MockV3Factory();
        impl = new ClmVaultAdapter(
            IUniswapV3Factory(address(v3)),
            ClmVaultAdapter.Family(beefyFactory, beefyStratOwner, beefyVaultOwner),
            ClmVaultAdapter.Family(arrowFactory, arrowOwner, arrowOwner)
        );
        registry.register(address(impl), "");
        beefy = _vault(beefyFactory, beefyStratOwner, beefyVaultOwner, 3000);
        arrow = _vault(arrowFactory, arrowOwner, arrowOwner, 500);
        arrow.setFees(20, 0);
        address[] memory list = new address[](2);
        list[0] = address(beefy);
        list[1] = address(arrow);
        c = ClmVaultAdapter(_enable(address(impl), abi.encode(list)));
    }

    /// @dev A vault with another LP's 10,000 USDG and 50 STK already in it, on a canonical pool.
    function _vault(address fac, address so, address vo, uint24 fee) internal returns (MockClmVault v) {
        MockClmPool pool = new MockClmPool(t0, t1);
        pool.setFee(fee);
        v3.setPool(t0, t1, pool.fee(), address(pool));
        MockClmStrategy s = new MockClmStrategy(fac, so, address(pool), t0, t1);
        v = new MockClmVault(s, vo);
        s.setVault(address(v));
        usdg.mint(lp, 10_000e6);
        stock.mint(lp, 50e18);
        vm.startPrank(lp);
        usdg.approve(address(v), type(uint256).max);
        stock.approve(address(v), type(uint256).max);
        (uint256 a0, uint256 a1) = t0 == address(usdg) ? (uint256(10_000e6), uint256(50e18)) : (uint256(50e18), uint256(10_000e6));
        v.deposit(a0, a1, 1);
        vm.stopPrank();
    }

    /// @dev Deposit `usd` worth of USDG and the matching stock (at $200) into `v`, with a little extra stock to return.
    function _depositAction(address v, uint256 usdgAmount) internal view returns (bytes memory) {
        uint256 stk = usdgAmount * 1e12 / 200 + 1e15;
        (uint256 a0, uint256 a1) = t0 == address(usdg) ? (usdgAmount, stk) : (stk, usdgAmount);
        return abi.encode(uint8(0), v, a0, a1, uint256(1));
    }

    function _withdrawAction(address v, uint256 shares) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), v, shares, uint256(0), uint256(0));
    }

    function _act(address a, bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(a, action);
    }
}

contract ClmVaultAdapterSuite is AdapterSuite, ClmWorld {
    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpClm();
        return IAdapter(address(c));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        return _depositAction(seed % 2 == 0 ? address(beefy) : address(arrow), bound(seed, 1e6, 2_000e6));
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdg);
        t[1] = address(stock);
    }

    function _growTolerance() internal pure override returns (uint256) {
        return 2;
    }

    /// Split hands over vault shares, which the router does not price: value them through the adapter's own reading.
    function _valueSent(Amount[] memory sent) internal view override returns (uint256 usd) {
        for (uint256 i; i < sent.length; ++i) {
            if (sent[i].amount == 0) continue;
            address token = sent[i].token;
            if (token == address(beefy) || token == address(arrow)) {
                (uint256 a0, uint256 a1) = c.valueOf(IPriceRouter(address(router)), token, sent[i].amount);
                (uint256 v0,,) = router.value(t0, a0, Side.Fair);
                (uint256 v1,,) = router.value(t1, a1, Side.Fair);
                usd += v0 + v1;
            } else {
                (uint256 x,,) = router.value(token, sent[i].amount, Side.Fair);
                usd += x;
            }
        }
    }
}

contract ClmVaultAdapterTest is ClmWorld {
    function setUp() public {
        _setUpClm();
    }

    function _held() internal view returns (Amount[] memory a) {
        (a,) = c.positions(IPriceRouter(address(router)));
    }

    function _usd(Amount[] memory list) internal view returns (uint256 usd) {
        for (uint256 i; i < list.length; ++i) {
            (uint256 v,,) = router.value(list[i].token, list[i].amount, Side.Fair);
            usd += v;
        }
    }

    // ------------------------------------------------ origin checks

    function _enableOne(address v) internal returns (address) {
        address[] memory list = new address[](1);
        list[0] = v;
        return _enable(address(impl), abi.encode(list));
    }

    function test_RejectsAStrangersStrategyFromTheSameFactory() public {
        MockClmVault fake = _vault(beefyFactory, makeAddr("stranger"), beefyVaultOwner, 3000);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, address(fake)));
        _enableOne(address(fake));
    }

    function test_RejectsAVaultFromAnotherFactory() public {
        MockClmVault fake = _vault(makeAddr("otherFactory"), beefyStratOwner, beefyVaultOwner, 3000);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, address(fake)));
        _enableOne(address(fake));
    }

    function test_RejectsAVaultWithAStrangeOwner() public {
        MockClmVault fake = _vault(beefyFactory, beefyStratOwner, makeAddr("stranger"), 3000);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, address(fake)));
        _enableOne(address(fake));
    }

    function test_RejectsAPoolTheFactoryDoesNotKnow() public {
        MockClmPool rogue = new MockClmPool(t0, t1);
        rogue.setFee(10_000); // 1%: no canonical pool registered for it
        MockClmStrategy s = new MockClmStrategy(beefyFactory, beefyStratOwner, address(rogue), t0, t1);
        MockClmVault fake = new MockClmVault(s, beefyVaultOwner);
        s.setVault(address(fake));
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, address(fake)));
        _enableOne(address(fake));
    }

    function test_RejectsAStrategyThatNamesAnotherVault() public {
        MockClmVault fake = _vault(beefyFactory, beefyStratOwner, beefyVaultOwner, 3000);
        MockClmStrategy(address(fake.strategy())).setVault(address(beefy));
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, address(fake)));
        _enableOne(address(fake));
    }

    function test_RejectsDuplicatesAndEmpty() public {
        address[] memory list = new address[](2);
        list[0] = address(beefy);
        list[1] = address(beefy);
        vm.expectRevert(ClmVaultAdapter.BadConfig.selector);
        _enable(address(impl), abi.encode(list));
        vm.expectRevert(ClmVaultAdapter.BadConfig.selector);
        _enable(address(impl), abi.encode(new address[](0)));
    }

    // ------------------------------------------------ actions

    function test_DepositKeepsSharesAndReturnsWhatTheVaultDidNotTake() public {
        uint256 stkBefore = stock.balanceOf(address(vault));
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        assertGt(beefy.balanceOf(address(c)), 0, "clone holds the shares");
        // The vault takes 1,000 USDG and 5 STK (its 200:1 ratio); the extra 0.001 STK came back.
        assertEq(stkBefore - stock.balanceOf(address(vault)), 5e18);
        assertEq(stock.balanceOf(address(c)), 0);
        assertEq(usdg.allowance(address(c), address(beefy)), 0);
        Amount[] memory h = _held();
        assertApproxEqAbs(_usd(h), 2_000e18, 1e15, "counted at fair: 1,000 USDG and 5 STK");
    }

    function test_ArrowfarmKeepsItsDepositFee() public {
        _act(address(c), _depositAction(address(arrow), 1_000e6));
        // The 0.2% fee stays in the vault, so the Fund keeps its own pro-rata slice of it (about a sixth here).
        uint256 v = _usd(_held());
        assertLt(v, 2_000e18 * 9_999 / 10_000, "the fee costs something");
        assertGt(v, 2_000e18 * 9_980 / 10_000, "never more than the fee");
    }

    function test_WithdrawPaysTheFund() public {
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        uint256 u = usdg.balanceOf(address(vault));
        _act(address(c), _withdrawAction(address(beefy), type(uint256).max));
        assertEq(beefy.balanceOf(address(c)), 0);
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - u, 1_000e6, 2);
        assertEq(_usd(_held()), 0);
    }

    function test_NotCalmRefusesBothWays() public {
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        beefy.setCalm(false);
        bytes memory dep = _depositAction(address(beefy), 1_000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotCalm.selector, address(beefy)));
        controller.act(address(c), dep);
        bytes memory wd = _withdrawAction(address(beefy), type(uint256).max);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotCalm.selector, address(beefy)));
        controller.act(address(c), wd);
    }

    function test_NoNewMoneyAfterControlMoves() public {
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        beefy.setOwner(makeAddr("newOwner"));
        bytes memory dep = _depositAction(address(beefy), 500e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, address(beefy)));
        controller.act(address(c), dep);
        // Leaving still works.
        _act(address(c), _withdrawAction(address(beefy), type(uint256).max));
        assertEq(beefy.balanceOf(address(c)), 0);
    }

    function test_MinSharesHolds() public {
        bytes memory dep = abi.encode(uint8(0), address(beefy), uint256(1_000e6), uint256(1_000e6), type(uint256).max);
        (uint256 a0, uint256 a1) = t0 == address(usdg) ? (uint256(1_000e6), uint256(5e18)) : (uint256(5e18), uint256(1_000e6));
        dep = abi.encode(uint8(0), address(beefy), a0, a1, type(uint256).max);
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(c), dep);
    }

    // ------------------------------------------------ value

    /// The live ranges are valued at fair prices from their liquidity; owed fees count, locked profit does not, and
    /// Arrowfarm's withdraw fee comes off.
    function test_ValueFromRangesAtFairPrice() public {
        _act(address(c), _depositAction(address(arrow), 1_000e6));
        MockClmStrategy s = MockClmStrategy(address(arrow.strategy()));
        MockClmPool pool = MockClmPool(s.pool());
        (bytes32 kMain, bytes32 kAlt) = s.getKeys();
        Amount[] memory before = _held();
        uint256 supply = arrow.totalSupply();
        uint256 mine = arrow.balanceOf(address(c));

        pool.set(kMain, 1e15, 3e6, 0);
        pool.set(kAlt, 2e14, 0, 0);
        s.setLocked(1e6, 0);
        (uint256 m0, uint256 m1) = OraclePositionMath.fairAmounts(IPriceRouter(address(router)), t0, t1, s.lo(), s.hi(), 1e15);
        (uint256 x0, uint256 x1) = OraclePositionMath.fairAmounts(IPriceRouter(address(router)), t0, t1, s.altLo(), s.altHi(), 2e14);
        Amount[] memory h = _held();
        uint256 idx0 = 2; // the Arrowfarm vault's rows
        uint256 add0 = m0 + x0 + 3e6 - 1e6; // the ranges, plus owed fees, less locked profit (both set on token0)
        // A floor of the sum is at most one unit above the sum of floors.
        assertApproxEqAbs(h[idx0].amount, before[idx0].amount + add0 * mine / supply, 1, "token0: ranges, owed, less locked");
        assertApproxEqAbs(h[idx0 + 1].amount, before[idx0 + 1].amount + (m1 + x1) * mine / supply, 1, "token1: ranges");

        arrow.setFees(20, 50);
        Amount[] memory fee = _held();
        assertApproxEqAbs(fee[idx0].amount, h[idx0].amount * 9950 / 10_000, 2, "withdraw fee comes off");
    }

    // ------------------------------------------------ exits

    function test_UnwindSkipsAVaultThatIsNotCalm() public {
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        _act(address(c), _depositAction(address(arrow), 1_000e6));
        arrow.setCalm(false);
        uint256 arrowShares = arrow.balanceOf(address(c));
        vm.expectEmit(true, false, false, true, address(c));
        emit ClmVaultAdapter.UnwindSkipped(address(arrow), arrowShares);
        vm.prank(address(controller));
        c.unwind(1e18);
        assertEq(beefy.balanceOf(address(c)), 0, "the calm one paid out");
        assertEq(arrow.balanceOf(address(c)), arrowShares, "the other stays counted");
    }

    function test_SplitHandsOverSharesOrTokens() public {
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        address leaver = makeAddr("leaver");
        uint256 held = beefy.balanceOf(address(c));
        vm.prank(address(controller));
        c.split(0.25e18, leaver);
        assertEq(beefy.balanceOf(leaver), held / 4);
        // A vault that refuses transfers pays the slice in its tokens.
        beefy.setBlockTransfers(true);
        address leaver2 = makeAddr("leaver2");
        vm.prank(address(controller));
        Amount[] memory sent = c.split(1e18, leaver2);
        assertGt(usdg.balanceOf(leaver2), 0);
        assertEq(sent[0].token, t0);
        assertEq(beefy.balanceOf(address(c)), 0);
    }

    function test_GrowAddsTheFractionAndReturnsTheRest() public {
        _act(address(c), _depositAction(address(beefy), 1_000e6));
        _act(address(c), _depositAction(address(arrow), 1_000e6));
        uint256 s1 = beefy.balanceOf(address(c));
        uint256 s2 = arrow.balanceOf(address(c));
        Amount[] memory needs = c.growInputs(0.5e18);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            MockERC20(needs[i].token).mint(address(vault), needs[i].amount);
            vault.approveFor(needs[i].token, address(c), needs[i].amount);
        }
        Amount[] memory used = c.grow(0.5e18);
        vm.stopPrank();
        assertGe(beefy.balanceOf(address(c)) * 2, s1 * 3);
        assertGe(arrow.balanceOf(address(c)) * 2, s2 * 3);
        for (uint256 i; i < used.length; ++i) assertLe(used[i].amount, needs[i].amount);
        assertEq(usdg.balanceOf(address(c)), 0);
        assertEq(stock.balanceOf(address(c)), 0);
    }

    function test_DescribeNamesTheVaults() public view {
        string memory d = c.describe();
        assertGt(bytes(d).length, 500);
    }
}
