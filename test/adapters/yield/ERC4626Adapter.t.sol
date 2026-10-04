// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../../utils/FundTestBase.sol";
import {AdapterSuite} from "../AdapterSuite.sol";
import {IAdapter, Amount} from "../../../src/interfaces/IAdapter.sol";
import {Side} from "../../../src/interfaces/IPriceRouter.sol";
import {ERC4626Adapter} from "../../../src/adapters/yield/ERC4626Adapter.sol";
import {MockVault4626} from "./MockVault4626.sol";

abstract contract YieldWorld is FundTestBase {
    MockVault4626 internal v1;
    MockVault4626 internal v2;
    ERC4626Adapter internal impl;
    ERC4626Adapter internal y;

    function _setUpYield() internal {
        _setUpCore();
        _createFund(_openDial(), 1000e6);
        v1 = new MockVault4626(usdg);
        v2 = new MockVault4626(usdg);
        impl = new ERC4626Adapter();
        registry.register(address(impl), "");
        address[] memory list = new address[](2);
        list[0] = address(v1);
        list[1] = address(v2);
        y = ERC4626Adapter(_enable(address(impl), abi.encode(list)));
    }

    function _deposit(address v, uint256 assets) internal pure returns (bytes memory) {
        return abi.encode(uint8(0), v, assets, uint256(1));
    }
}

/// @notice `grow`: every vault position gets the same fraction more shares, paid in its asset.
contract ERC4626GrowTest is YieldWorld {
    function setUp() public {
        _setUpYield();
        vm.startPrank(manager);
        controller.act(address(y), _deposit(address(v1), 300e6));
        controller.act(address(y), _deposit(address(v2), 200e6));
        vm.stopPrank();
        v1.earn(31e6); // share prices that are not round numbers
        v2.earn(7e6);
        v2.setExitFeeBps(50);
    }

    function _grow(uint256 f) internal returns (Amount[] memory needs, Amount[] memory used) {
        needs = y.growInputs(f);
        vm.startPrank(address(controller));
        for (uint256 i; i < needs.length; ++i) {
            usdg.mint(address(vault), needs[i].amount);
            vault.approveFor(needs[i].token, address(y), needs[i].amount);
        }
        used = y.grow(f);
        vm.stopPrank();
    }

    function test_GrowMintsTheFractionOfEveryVault() public {
        (Amount[] memory before,) = y.positions(router);
        uint256 s1 = v1.balanceOf(address(y));
        uint256 s2 = v2.balanceOf(address(y));
        (Amount[] memory needs, Amount[] memory used) = _grow(0.37e18);
        assertEq(needs.length, 1, "two vaults of one asset: one input");
        assertEq(used[0].amount, needs[0].amount, "the vaults took exactly what was declared");
        assertEq(usdg.allowance(address(vault), address(y)), 0);
        assertGe(v1.balanceOf(address(y)) * 100, s1 * 137);
        assertGe(v2.balanceOf(address(y)) * 100, s2 * 137);
        (Amount[] memory after_,) = y.positions(router);
        for (uint256 i; i < before.length; ++i) assertGe(after_[i].amount * 100, before[i].amount * 137);
        assertEq(usdg.balanceOf(address(y)), 0);
    }

    function test_GrowByMoreThanDouble() public {
        (Amount[] memory before,) = y.positions(router);
        _grow(3e18);
        (Amount[] memory after_,) = y.positions(router);
        for (uint256 i; i < before.length; ++i) assertGe(after_[i].amount, before[i].amount * 4);
    }

    function test_GrowOnlyController() public {
        vm.expectRevert();
        y.grow(0.1e18);
    }
}

contract ERC4626AdapterTest is YieldWorld {
    function setUp() public {
        _setUpYield();
    }

    function _actAs(bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(address(y), action);
    }

    function _held(uint256 i) internal view returns (uint256) {
        (Amount[] memory a,) = y.positions(router);
        return a[i].amount;
    }

    function _nav() internal view returns (uint256 n) {
        (n,) = controller.nav(uint8(Side.Fair));
    }

    function test_DepositIsAPosition() public {
        _actAs(_deposit(address(v1), 400e6));
        assertEq(usdg.balanceOf(address(vault)), 600e6);
        assertEq(v1.balanceOf(address(y)), 400e18, "clone holds the shares");
        assertEq(_held(0), 400e6);
        assertEq(_nav(), 1000e18, "NAV counts the position at its underlying");
        assertEq(usdg.allowance(address(y), address(v1)), 0);
    }

    function test_YieldRaisesNav() public {
        _actAs(_deposit(address(v1), 400e6));
        v1.earn(40e6);
        assertApproxEqAbs(_held(0), 440e6, 1);
        assertApproxEqAbs(_nav(), 1040e18, 1e12);
    }

    function test_ExitFeeIsCounted() public {
        _actAs(_deposit(address(v1), 400e6));
        v1.setExitFeeBps(100);
        assertEq(_held(0), 396e6, "positions report what redeeming returns");
    }

    function test_WithdrawAndRedeem() public {
        _actAs(_deposit(address(v1), 400e6));
        bytes memory r = _actAs(abi.encode(uint8(1), address(v1), uint256(100e6), uint256(100e18)));
        assertEq(abi.decode(r, (uint256)), 100e18);
        assertEq(usdg.balanceOf(address(vault)), 700e6);
        r = _actAs(abi.encode(uint8(2), address(v1), type(uint256).max, uint256(300e6)));
        assertEq(abi.decode(r, (uint256)), 300e6);
        assertEq(usdg.balanceOf(address(vault)), 1000e6);
        assertEq(v1.balanceOf(address(y)), 0);
    }

    function test_Bounds() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.TooFewShares.selector, 100e18, 101e18));
        controller.act(address(y), abi.encode(uint8(0), address(v1), uint256(100e6), uint256(101e18)));
        controller.act(address(y), _deposit(address(v1), 100e6));
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.TooManyShares.selector, 50e18, 49e18));
        controller.act(address(y), abi.encode(uint8(1), address(v1), uint256(50e6), uint256(49e18)));
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.TooLittle.selector, 50e6, 51e6));
        controller.act(address(y), abi.encode(uint8(2), address(v1), uint256(50e18), uint256(51e6)));
        vm.stopPrank();
    }

    function test_UnknownVaultRefused() public {
        MockVault4626 other = new MockVault4626(usdg);
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(y), _deposit(address(other), 1e6));
    }

    function test_UnwindHalf() public {
        _actAs(_deposit(address(v1), 400e6));
        _actAs(_deposit(address(v2), 200e6));
        vm.prank(address(controller));
        Amount[] memory got = y.unwind(0.5e18);
        // Each vault keeps one raw unit more than the fraction: the slice rounds against the leaver, so what
        // stays reads at least half of what it read (see `_slice`).
        assertEq(got[0].amount, 200e6 - 1);
        assertEq(got[1].amount, 100e6 - 1);
        assertEq(usdg.balanceOf(address(vault)), 700e6 - 2);
        assertEq(_held(0), 200e6 + 1);
        assertEq(_held(1), 100e6 + 1);
    }

    function test_UnwindSkipsIlliquidVault() public {
        _actAs(_deposit(address(v1), 400e6));
        _actAs(_deposit(address(v2), 200e6));
        v1.setBlockRedeem(true);
        vm.prank(address(controller));
        Amount[] memory got = y.unwind(1e18);
        assertEq(got[0].amount, 0, "illiquid vault skipped");
        assertEq(got[1].amount, 200e6, "the other still unwinds");
        assertEq(_held(0), 400e6, "skipped shares stay counted");
    }

    function test_SplitInKind() public {
        _actAs(_deposit(address(v1), 400e6));
        address leaver = makeAddr("leaver");
        vm.prank(address(controller));
        Amount[] memory sent = y.split(0.25e18, leaver);
        uint256 unit = v1.previewWithdraw(1); // the shares one raw unit is worth stay behind
        assertEq(sent[0].token, address(v1));
        assertEq(sent[0].amount, 100e18 - unit);
        assertEq(v1.balanceOf(leaver), 100e18 - unit);
        assertEq(v1.balanceOf(address(y)), 300e18 + unit);
    }

    function test_SplitFallsBackToAssetsWhenGated() public {
        _actAs(_deposit(address(v1), 400e6));
        v1.setBlockTransfers(true);
        address leaver = makeAddr("leaver");
        vm.prank(address(controller));
        Amount[] memory sent = y.split(0.25e18, leaver);
        assertEq(sent[0].token, address(usdg));
        assertEq(sent[0].amount, 100e6 - 1);
        assertEq(usdg.balanceOf(leaver), 100e6 - 1);
    }

    function test_SplitRevertsWhenNeitherWorks() public {
        _actAs(_deposit(address(v1), 400e6));
        v1.setBlockTransfers(true);
        v1.setBlockRedeem(true);
        vm.prank(address(controller));
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.SplitFailed.selector, address(v1)));
        y.split(0.25e18, makeAddr("leaver"));
    }

    function test_BadFraction() public {
        vm.startPrank(address(controller));
        vm.expectRevert(ERC4626Adapter.BadFraction.selector);
        y.unwind(1e18 + 1);
        vm.expectRevert(ERC4626Adapter.BadFraction.selector);
        y.split(0, address(1));
        vm.stopPrank();
    }

    function test_ConfigRules() public {
        address[] memory list = new address[](2);
        list[0] = address(v1);
        list[1] = address(v1);
        vm.prank(owner);
        vm.expectRevert(ERC4626Adapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(list));
        vm.prank(owner);
        vm.expectRevert(ERC4626Adapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(new address[](0)));
    }

    function test_Describe() public {
        _actAs(_deposit(address(v1), 1e6));
        string memory j = y.describe();
        assertGt(bytes(j).length, 300);
    }
}

contract ERC4626AdapterSuite is AdapterSuite, YieldWorld {
    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpYield();
        return IAdapter(address(y));
    }

    function _action(uint256 seed) internal view override returns (bytes memory) {
        return _deposit(seed % 2 == 0 ? address(v1) : address(v2), bound(seed, 1, 900e6));
    }

    /// Split hands over vault shares, which the router does not price: value them as their pro-rata claim on
    /// the vault's assets, priced by the router. Pro rata at full precision rather than previewRedeem per slice,
    /// so a one-raw-unit deposit split in two is not read as a loss of rounding dust.
    function _valueSent(Amount[] memory sent) internal view override returns (uint256 usd) {
        for (uint256 i; i < sent.length; ++i) {
            address token = sent[i].token;
            if (sent[i].amount == 0) continue;
            if (token == address(v1) || token == address(v2)) {
                MockVault4626 v = MockVault4626(token);
                (uint256 all,,) = router.value(address(usdg), v.totalAssets(), Side.Fair);
                usd += sent[i].amount * all / v.totalSupply();
            } else {
                (uint256 x,,) = router.value(token, sent[i].amount, Side.Fair);
                usd += x;
            }
        }
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(usdg);
    }
}
