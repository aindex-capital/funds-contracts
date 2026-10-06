// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ArcusRedeemAdapter} from "../../../src/adapters/arcus/ArcusRedeemAdapter.sol";
import {BaseAdapter} from "../../../src/adapters/BaseAdapter.sol";
import {Amount} from "../../../src/interfaces/IAdapter.sol";
import {IPriceRouter} from "../../../src/interfaces/IPriceRouter.sol";
import {IArcusPTokenFactory} from "../../../src/interfaces/external/arcus/IArcusPToken.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {MockPToken, MockPTokenFactory} from "./ArcusMocks.sol";

contract ArcusRedeemAdapterTest is Test {
    MockERC20 usdg;
    MockPToken p;
    MockPToken q;
    MockPTokenFactory factory;
    ArcusRedeemAdapter a;
    address vault = makeAddr("vault");
    address leaver = makeAddr("leaver");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        p = new MockPToken(usdg);
        q = new MockPToken(usdg);
        p.setPerShare(145_393_617); // 145.39 USDG a share, pHOOD3x on 2026-10-06
        q.setPerShare(94_339_000);
        factory = new MockPTokenFactory();
        factory.set(address(p), true);
        factory.set(address(q), true);
        ArcusRedeemAdapter impl = new ArcusRedeemAdapter(IArcusPTokenFactory(address(factory)));
        a = ArcusRedeemAdapter(Clones.clone(address(impl)));
        a.initialize(vault, address(this), "");
        p.mint(vault, 10e18);
        q.mint(vault, 10e18);
        vm.startPrank(vault);
        p.approve(address(a), type(uint256).max);
        q.approve(address(a), type(uint256).max);
        vm.stopPrank();
    }

    function _req(MockPToken t, uint256 shares) internal returns (uint256 id) {
        id = abi.decode(a.execute(abi.encode(uint8(0), address(t), shares)), (uint256));
    }

    function _claim() internal {
        a.execute(abi.encode(uint8(1), address(0), uint256(0)));
    }

    function test_RequestCountsAtValueThenClaimPaysTheVault() public {
        uint256 id = _req(p, 2e18);
        assertEq(p.balanceOf(vault), 8e18, "shares left the vault");
        assertEq(p.balanceOf(address(a)), 0, "nothing loose in the clone");
        (Amount[] memory pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos.length, 1);
        assertEq(pos[0].token, address(usdg));
        assertEq(pos[0].amount, 290_787_234, "pending counts at convertToAssets");
        p.fulfil(id);
        (pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos[0].amount, 290_787_234, "fulfilled: what the claim pays");
        _claim();
        assertEq(usdg.balanceOf(vault), 290_787_234);
        (pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos.length, 0, "nothing left");
        (address[] memory tokens,,,) = a.requests();
        assertEq(tokens.length, 0, "request forgotten");
    }

    function test_RejectedSharesComeBack() public {
        uint256 id = _req(p, 1e18);
        p.reject(id);
        (Amount[] memory pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos.length, 1);
        assertEq(pos[0].token, address(p), "counted in the pToken while it comes back");
        assertEq(pos[0].amount, 1e18);
        _claim();
        assertEq(p.balanceOf(vault), 10e18, "all shares back");
        assertEq(usdg.balanceOf(vault), 0);
    }

    function test_ExpiredRequestIsCancelledAndReturned() public {
        _req(p, 1e18);
        _claim(); // not expired: nothing happens, still pending
        (address[] memory tokens,,,) = a.requests();
        assertEq(tokens.length, 1);
        vm.warp(block.timestamp + 7 days + 1);
        _claim();
        assertEq(p.balanceOf(vault), 10e18, "cancelled after the TTL and returned");
        (tokens,,,) = a.requests();
        assertEq(tokens.length, 0);
    }

    function test_SplitRefusesWhilePendingThenHandsSlices() public {
        uint256 id1 = _req(p, 2e18);
        uint256 id2 = _req(q, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ArcusRedeemAdapter.RequestPending.selector, address(p), id1));
        a.split(0.25e18, leaver);
        p.fulfil(id1);
        q.reject(id2);
        Amount[] memory sent = a.split(0.25e18, leaver);
        assertEq(usdg.balanceOf(leaver), uint256(290_787_234) / 4, "a quarter of the claimable USDG");
        assertEq(q.balanceOf(leaver), 0.25e18, "a quarter of the returning shares");
        assertEq(q.balanceOf(vault), 9.75e18, "the rest of them back to the vault");
        assertEq(sent.length, 2);
        (Amount[] memory pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos.length, 1);
        assertEq(pos[0].amount, 290_787_234 - uint256(290_787_234) / 4, "three quarters still claimable for the Fund");
    }

    function test_UnwindClaimsWhatIsReadyAndKeepsPending() public {
        uint256 id1 = _req(p, 1e18);
        _req(q, 1e18);
        p.fulfil(id1);
        Amount[] memory got = a.unwind(0.5e18);
        assertEq(usdg.balanceOf(vault), 145_393_617, "everything claimable, paid to the Fund");
        assertEq(got[0].token, address(usdg));
        assertEq(got[0].amount, 145_393_617);
        (Amount[] memory pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos.length, 1, "the pending request stays counted");
        assertEq(pos[0].amount, 94_339_000);
    }

    function test_Gates() public {
        MockPToken fake = new MockPToken(usdg);
        fake.mint(vault, 1e18);
        vm.prank(vault);
        fake.approve(address(a), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ArcusRedeemAdapter.NotPToken.selector, address(fake)));
        a.execute(abi.encode(uint8(0), address(fake), uint256(1e18)));
        vm.expectRevert(ArcusRedeemAdapter.ZeroShares.selector);
        a.execute(abi.encode(uint8(0), address(p), uint256(0)));
        for (uint256 i; i < 6; ++i) _req(p, 0.1e18);
        vm.expectRevert(ArcusRedeemAdapter.TooManyRequests.selector);
        a.execute(abi.encode(uint8(0), address(p), uint256(0.1e18)));
        vm.prank(leaver);
        vm.expectRevert(BaseAdapter.NotController.selector);
        a.execute(abi.encode(uint8(1), address(0), uint256(0)));
        vm.expectRevert(ArcusRedeemAdapter.NoGrow.selector);
        a.grow(1);
        vm.expectRevert(ArcusRedeemAdapter.BadAction.selector);
        a.execute(abi.encode(uint8(9), address(0), uint256(0)));
    }

    function test_InputsAndOutputsAreDeclared() public {
        Amount[] memory ins = a.inputs(abi.encode(uint8(0), address(p), uint256(3e18)));
        assertEq(ins.length, 1);
        assertEq(ins[0].token, address(p));
        assertEq(ins[0].amount, 3e18);
        _req(p, 1e18);
        address[] memory outs = a.outputs(abi.encode(uint8(1), address(0), uint256(0)));
        assertEq(outs.length, 2);
        assertEq(outs[0], address(usdg));
        assertEq(outs[1], address(p));
    }

    function test_Grow0ClaimsAndDescribeIsJson() public {
        uint256 id = _req(p, 1e18);
        p.fulfil(id);
        a.grow(0);
        assertEq(usdg.balanceOf(vault), 145_393_617);
        string memory d = a.describe();
        assertTrue(vm.keyExistsJson(d, ".actions"));
        assertEq(vm.parseJsonString(d, ".actions[0].name"), "request");
    }
}
