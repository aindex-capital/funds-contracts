// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FundTestBase} from "../utils/FundTestBase.sol";
import {AdapterSuite} from "../adapters/AdapterSuite.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {IAdapter, Amount} from "../../src/interfaces/IAdapter.sol";
import {IPriceRouter, PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {FundController} from "../../src/core/FundController.sol";

/// @dev A swap venue that trades USDG for TKN at a set rate by minting and burning; `lossBps` makes it a bad
///      venue so the loss budget can be exercised.
contract MockSwapAdapter is BaseAdapter {
    MockERC20 public usdg;
    MockERC20 public tkn;
    uint256 public tknPerUsdg; // TKN raw units per 1 USDG raw unit, scaled 1e18
    uint256 public lossBps;

    function setUp_(MockERC20 usdg_, MockERC20 tkn_, uint256 rate, uint256 lossBps_) external {
        usdg = usdg_;
        tkn = tkn_;
        tknPerUsdg = rate;
        lossBps = lossBps_;
    }

    function name() external pure returns (string memory) {
        return "Mock swap";
    }

    function describe() external pure returns (string memory) {
        return '{"actions":[{"id":0,"name":"buy","params":[{"name":"usdgIn","type":"uint256"}]}]}';
    }

    function inputs(bytes calldata action) public view returns (Amount[] memory) {
        (, uint256 amount) = abi.decode(action, (uint8, uint256));
        return _one(address(usdg), amount);
    }

    function outputs(bytes calldata) external view returns (address[] memory) {
        return _tokens2(address(usdg), address(tkn));
    }

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (, uint256 amount) = abi.decode(action, (uint8, uint256));
        _pull(address(usdg), amount);
        usdg.burn(address(this), amount);
        uint256 out = amount * tknPerUsdg / 1e18 * (10_000 - lossBps) / 10_000;
        tkn.mint(address(this), out);
        _pushAll(address(tkn));
        return abi.encode(out);
    }

    function positions(IPriceRouter) external pure returns (Amount[] memory, Amount[] memory) {
        return (new Amount[](0), new Amount[](0));
    }

    function unwind(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }

    function split(uint256, address) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function grow(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function growInputs(uint256) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }
}

contract ControllerTest is FundTestBase {
    MockERC20 tkn;
    MockSwapAdapter impl;
    address swap;

    function setUp() public {
        _setUpCore();
        tkn = new MockERC20("Token", "TKN", 18);
        _price(address(tkn), 2e18, PriceClass.Thin, 500); // $2, thin, 5% haircut
    }

    function _deploy(uint256 lossBps, Dial memory dial) internal {
        _createFund(dial, 1000e6);
        impl = new MockSwapAdapter();
        registry.register(address(impl), "");
        swap = _enable(address(impl), "");
        // 1 USDG (1e6 raw) buys 0.5 TKN (5e17 raw): rate = 5e17 / 1e6 * 1e18
        MockSwapAdapter(swap).setUp_(usdg, tkn, 5e29, lossBps);
    }

    function test_ActsAndTracksOutputs() public {
        _deploy(0, _openDial());
        vm.prank(manager);
        controller.act(swap, abi.encode(uint8(0), uint256(100e6)));
        assertEq(tkn.balanceOf(address(vault)), 50e18);
        assertEq(usdg.balanceOf(address(vault)), 900e6);
        (uint256 fair,) = controller.nav(uint8(Side.Fair));
        assertEq(fair, 1000e18);
    }

    function test_LossBudgetStopsBadVenue() public {
        Dial memory d = _openDial();
        d.dailyLossBps = 100; // 1% a day
        _deploy(3000, d); // venue keeps 30%
        vm.prank(manager);
        vm.expectRevert();
        controller.act(swap, abi.encode(uint8(0), uint256(100e6)));
    }

    function test_ThinCapRespected() public {
        Dial memory d = _openDial();
        d.maxThinBps = 1000; // at most 10% in thin tokens
        _deploy(0, d);
        vm.startPrank(manager);
        controller.act(swap, abi.encode(uint8(0), uint256(90e6)));
        vm.expectRevert();
        controller.act(swap, abi.encode(uint8(0), uint256(50e6)));
        vm.stopPrank();
    }

    function test_OnlyManager() public {
        _deploy(0, _openDial());
        vm.expectRevert(FundController.NotManager.selector);
        controller.act(swap, abi.encode(uint8(0), uint256(1e6)));
    }

    function test_RiskWaitsOnceOthersHoldShares() public {
        Dial memory tight = _openDial();
        tight.maxThinBps = 1000;
        _deploy(0, tight);
        // Someone else holds a share now.
        vm.prank(owner);
        vault.transfer(makeAddr("holder"), 1e18);
        Dial memory loose = _openDial();
        vm.prank(owner);
        controller.setDial(loose);
        assertEq(controller.dial().maxThinBps, 1000, "loosening applied at once");
        vm.warp(block.timestamp + 7 days);
        controller.applyPendingDial();
        assertEq(controller.dial().maxThinBps, 10_000);
    }
}

contract MockSwapAdapterSuite is AdapterSuite {
    MockERC20 tkn;

    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpCore();
        tkn = new MockERC20("Token", "TKN", 18);
        _price(address(tkn), 2e18, PriceClass.Feed, 0);
        _createFund(_openDial(), 1000e6);
        MockSwapAdapter impl = new MockSwapAdapter();
        registry.register(address(impl), "");
        address inst = _enable(address(impl), "");
        MockSwapAdapter(inst).setUp_(usdg, tkn, 5e29, 0);
        return IAdapter(inst);
    }

    function _action(uint256 seed) internal pure override returns (bytes memory) {
        return abi.encode(uint8(0), bound(seed, 1, 500e6));
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(usdg);
        t[1] = address(tkn);
    }
}
