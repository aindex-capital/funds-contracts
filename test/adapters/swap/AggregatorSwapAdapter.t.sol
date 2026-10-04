// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../../utils/FundTestBase.sol";
import {AdapterSuite} from "../AdapterSuite.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {Dial} from "../../../src/interfaces/IFundController.sol";
import {PriceClass, Side} from "../../../src/interfaces/IPriceRouter.sol";
import {IPermit2} from "../../../src/interfaces/external/permit2/IPermit2.sol";
import {AggregatorSwapAdapter} from "../../../src/adapters/swap/AggregatorSwapAdapter.sol";
import {MockAggregator, MockPermit2, MockUniversalRouter} from "./SwapMocks.sol";

/// @dev Shared world: USDG ($1, 6 decimals), TKN ($2, 18 decimals), a direct router and a Permit2 router.
abstract contract SwapWorld is FundTestBase {
    MockERC20 internal tkn;
    MockAggregator internal agg;
    MockPermit2 internal permit2;
    MockUniversalRouter internal ur;
    AggregatorSwapAdapter internal impl;
    AggregatorSwapAdapter internal swap;

    function _setUpSwap() internal {
        _setUpCore();
        tkn = new MockERC20("Token", "TKN", 18);
        _price(address(tkn), 2e18, PriceClass.Feed, 0);
        _createFund(_openDial(), 1000e6);
        agg = new MockAggregator();
        permit2 = new MockPermit2();
        ur = new MockUniversalRouter(permit2);
        impl = new AggregatorSwapAdapter(IPermit2(address(permit2)));
        registry.register(address(impl), "");
        swap = AggregatorSwapAdapter(_enable(address(impl), _config()));
    }

    function _config() internal view returns (bytes memory) {
        AggregatorSwapAdapter.Target[] memory t = new AggregatorSwapAdapter.Target[](2);
        t[0] = AggregatorSwapAdapter.Target(address(agg), AggregatorSwapAdapter.Approval.Direct);
        t[1] = AggregatorSwapAdapter.Target(address(ur), AggregatorSwapAdapter.Approval.Permit2);
        return abi.encode(t);
    }

    /// 1 USDG (1e6) buys 0.5 TKN (5e17) at fair prices.
    function _fairOut(uint256 usdgIn) internal pure returns (uint256) {
        return usdgIn * 5e11;
    }

    function _direct(uint256 amountIn, uint256 amountOut, address recipient, uint256 minOut)
        internal
        view
        returns (bytes memory)
    {
        bytes memory data =
            abi.encodeCall(MockAggregator.swap, (address(usdg), amountIn, address(tkn), amountOut, recipient));
        return abi.encode(uint8(0), address(usdg), amountIn, address(tkn), minOut, address(agg), data);
    }

    function _viaUr(uint256 amountIn, uint256 amountOut, address recipient, uint256 minOut)
        internal
        view
        returns (bytes memory)
    {
        bytes memory data = abi.encodeCall(
            MockUniversalRouter.execute, (address(usdg), amountIn, address(tkn), amountOut, recipient)
        );
        return abi.encode(uint8(0), address(usdg), amountIn, address(tkn), minOut, address(ur), data);
    }
}

contract AggregatorSwapAdapterTest is SwapWorld {
    function setUp() public {
        _setUpSwap();
    }

    function _actAs(bytes memory action) internal {
        vm.prank(manager);
        controller.act(address(swap), action);
    }

    function test_DirectSwap() public {
        _actAs(_direct(100e6, _fairOut(100e6), address(swap), 49e18));
        assertEq(tkn.balanceOf(address(vault)), 50e18);
        assertEq(usdg.balanceOf(address(vault)), 900e6);
        assertEq(tkn.balanceOf(address(swap)), 0);
        assertEq(usdg.balanceOf(address(swap)), 0);
        assertEq(usdg.allowance(address(swap), address(agg)), 0, "router approval left");
        assertEq(usdg.allowance(address(vault), address(swap)), 0, "vault approval left");
        assertTrue(vault.isTracked(address(tkn)));
    }

    function test_Permit2Swap() public {
        _actAs(_viaUr(100e6, _fairOut(100e6), address(swap), 49e18));
        assertEq(tkn.balanceOf(address(vault)), 50e18);
        assertEq(usdg.allowance(address(swap), address(permit2)), 0, "permit2 approval left");
        (uint160 amt,,) = permit2.allowance(address(swap), address(usdg), address(ur));
        assertEq(amt, 0, "permit2 allowance left");
    }

    function test_OutputSentElsewhereReverts() public {
        address thief = makeAddr("thief");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AggregatorSwapAdapter.TooLittle.selector, 0, 49e18));
        controller.act(address(swap), _direct(100e6, _fairOut(100e6), thief, 49e18));
        // Same through the Permit2 router.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AggregatorSwapAdapter.TooLittle.selector, 0, 49e18));
        controller.act(address(swap), _viaUr(100e6, _fairOut(100e6), thief, 49e18));
    }

    function test_BelowMinOutReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AggregatorSwapAdapter.TooLittle.selector, 40e18, 49e18));
        controller.act(address(swap), _direct(100e6, 40e18, address(swap), 49e18));
    }

    function test_ZeroMinOutReverts() public {
        vm.prank(manager);
        vm.expectRevert(AggregatorSwapAdapter.ZeroMinOut.selector);
        controller.act(address(swap), _direct(100e6, _fairOut(100e6), address(swap), 0));
    }

    function test_UnspentInputReturnsToVault() public {
        // The route spends only 60 of the 100 USDG it was allowed.
        bytes memory data =
            abi.encodeCall(MockAggregator.swap, (address(usdg), 60e6, address(tkn), _fairOut(60e6), address(swap)));
        _actAs(abi.encode(uint8(0), address(usdg), uint256(100e6), address(tkn), uint256(1), address(agg), data));
        assertEq(usdg.balanceOf(address(vault)), 940e6);
        assertEq(tkn.balanceOf(address(vault)), 30e18);
        assertEq(usdg.balanceOf(address(swap)), 0);
    }

    function test_RouteCannotTakeMoreThanAmountIn() public {
        bytes memory data =
            abi.encodeCall(MockAggregator.swap, (address(usdg), 200e6, address(tkn), _fairOut(200e6), address(swap)));
        vm.prank(manager);
        vm.expectRevert();
        controller.act(
            address(swap),
            abi.encode(uint8(0), address(usdg), uint256(100e6), address(tkn), uint256(1), address(agg), data)
        );
    }

    function test_NativePayoutReverts() public {
        vm.deal(address(agg), 1 ether);
        bytes memory data = abi.encodeCall(MockAggregator.swapToNative, (address(usdg), 100e6));
        vm.prank(manager);
        vm.expectRevert("native payout refused");
        controller.act(
            address(swap),
            abi.encode(uint8(0), address(usdg), uint256(100e6), address(tkn), uint256(1), address(agg), data)
        );
    }

    function test_NativeTokensRefused() public {
        address eee = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        bytes memory data = "";
        vm.startPrank(manager);
        vm.expectRevert(AggregatorSwapAdapter.BadTokens.selector);
        controller.act(
            address(swap), abi.encode(uint8(0), address(usdg), uint256(1e6), eee, uint256(1), address(agg), data)
        );
        vm.expectRevert(AggregatorSwapAdapter.BadTokens.selector);
        controller.act(
            address(swap), abi.encode(uint8(0), address(usdg), uint256(1e6), address(0), uint256(1), address(agg), data)
        );
        vm.stopPrank();
    }

    function test_SameTokenRefused() public {
        vm.prank(manager);
        vm.expectRevert(AggregatorSwapAdapter.BadTokens.selector);
        controller.act(
            address(swap),
            abi.encode(uint8(0), address(usdg), uint256(1e6), address(usdg), uint256(1), address(agg), bytes(""))
        );
    }

    function test_UnknownTargetRefused() public {
        MockAggregator other = new MockAggregator();
        bytes memory data =
            abi.encodeCall(MockAggregator.swap, (address(usdg), 1e6, address(tkn), _fairOut(1e6), address(swap)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AggregatorSwapAdapter.TargetNotAllowed.selector, address(other)));
        controller.act(
            address(swap),
            abi.encode(uint8(0), address(usdg), uint256(1e6), address(tkn), uint256(1), address(other), data)
        );
    }

    function test_BadVenueHitsLossBudget() public {
        // A route inside minOut but at 30% below fair still has to fit the Fund's daily loss budget.
        vm.prank(owner);
        controller.setDial(_tightLoss());
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(swap), _direct(100e6, 35e18, address(swap), 1));
    }

    function _tightLoss() internal pure returns (Dial memory d) {
        d = _openDial();
        d.dailyLossBps = 100;
    }

    function test_ConfigRules() public {
        AggregatorSwapAdapter.Target[] memory t = new AggregatorSwapAdapter.Target[](1);
        // An address with no code.
        t[0] = AggregatorSwapAdapter.Target(makeAddr("eoa"), AggregatorSwapAdapter.Approval.Direct);
        vm.prank(owner);
        vm.expectRevert(AggregatorSwapAdapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(t));
        // Permit2 itself.
        t[0] = AggregatorSwapAdapter.Target(address(permit2), AggregatorSwapAdapter.Approval.Direct);
        vm.prank(owner);
        vm.expectRevert(AggregatorSwapAdapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(t));
        // A duplicate.
        AggregatorSwapAdapter.Target[] memory d = new AggregatorSwapAdapter.Target[](2);
        d[0] = AggregatorSwapAdapter.Target(address(agg), AggregatorSwapAdapter.Approval.Direct);
        d[1] = d[0];
        vm.prank(owner);
        vm.expectRevert(AggregatorSwapAdapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(d));
        // Empty.
        vm.prank(owner);
        vm.expectRevert(AggregatorSwapAdapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(new AggregatorSwapAdapter.Target[](0)));
    }

    function test_ImplementationLocked() public {
        vm.expectRevert(bytes4(keccak256("AlreadyInitialized()")));
        impl.initialize(address(1), address(2), _config());
    }

    function test_DescribeListsTargets() public view {
        string memory j = swap.describe();
        assertTrue(bytes(j).length > 200);
        assertTrue(_contains(j, '"approval":"permit2"'));
        assertTrue(_contains(j, '"name":"swap"'));
    }

    function test_InputsAndOutputs() public view {
        bytes memory a = _direct(7e6, 1, address(swap), 1);
        assertEq(swap.inputs(a)[0].token, address(usdg));
        assertEq(swap.inputs(a)[0].amount, 7e6);
        address[] memory o = swap.outputs(a);
        assertEq(o[0], address(tkn));
        assertEq(o[1], address(usdg));
    }

    function _contains(string memory h, string memory n) internal pure returns (bool) {
        bytes memory hb = bytes(h);
        bytes memory nb = bytes(n);
        for (uint256 i; i + nb.length <= hb.length; ++i) {
            bool ok = true;
            for (uint256 j; j < nb.length; ++j) {
                if (hb[i + j] != nb[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}

contract AggregatorSwapAdapterSuite is AdapterSuite, SwapWorld {
    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpSwap();
        return IAdapter(address(swap));
    }

    /// Fuzzed amounts, alternating between the direct router and the Permit2 router.
    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint256 amount = bound(seed, 1, 500e6);
        uint256 out = _fairOut(amount);
        return seed % 2 == 0 ? _direct(amount, out, address(swap), out) : _viaUr(amount, out, address(swap), out);
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdg);
        t[1] = address(tkn);
    }
}
