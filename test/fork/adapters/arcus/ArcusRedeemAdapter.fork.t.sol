// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ArcusRedeemAdapter} from "../../../../src/adapters/arcus/ArcusRedeemAdapter.sol";
import {Amount} from "../../../../src/interfaces/IAdapter.sol";
import {IPriceRouter} from "../../../../src/interfaces/IPriceRouter.sol";
import {IArcusPToken, IArcusPTokenFactory} from "../../../../src/interfaces/external/arcus/IArcusPToken.sol";

/**
 * @notice The redeem adapter against live Arcus pTokens on Robinhood Chain (4663). Skipped when ROBINHOOD_RPC is unset.
 *         The fulfil path replays Arcus' keeper's two real transactions for request 0x4f2 (2026-10-01, block 79287182
 *         and 79287209) with this adapter's own request id: the keeper links the request to bridge withdrawal 0x301f
 *         and the second call settles that withdrawal, which is what makes the shares claimable.
 */
contract ArcusRedeemAdapterForkTest is Test {
    address constant FACTORY = 0x9c3663FA9ab976E67B42939486EC4966Cb41a0BB;
    address constant PHOOD3X = 0xe24CABDf76DD1c2576049167eB1755C84b985C36;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant KEEPER = 0xB7410dc44e2715161E9914272e2D55D7c5061FAa;
    bytes constant KEEPER_SETTLE = hex"56478360000000000000000000000000000000000000000000000000000000000000301f000000000000000000000000e24cabdf76dd1c2576049167eb1755c84b985c3600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002517da000000000000000000000000000000000000000000000000000000000000010d00000000000000000000000000000000000000000000000000000000000009b9000000000000000000000000000000000000000000000000000000504315a27800000000000000000000000000000000000000000000000000010377d48fc2fa00000000000000000000000000000000000000000000000000010327917a2082000000000000000000000000000000000000000000000000000000006ac1455a000000000000000000000000000000000000000000000000000000006ac1456d00000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000c70352b9a07be0e6afdce63ac05c540e7d8fe45a00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004149ea0d026795d6f75b8827f68b51ac77f5aae662ad54b3da28ff37195f13984365ad308e506c1cf3abf669323a4a8b107e6f1bca9c23d89b15ca2272bec0bf251c00000000000000000000000000000000000000000000000000000000000000";

    ArcusRedeemAdapter a;
    address vault = makeAddr("fund vault");
    address leaver = makeAddr("leaver");

    function _setUp(uint256 block_) internal returns (bool) {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return false;
        if (block_ == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, block_);
        ArcusRedeemAdapter impl = new ArcusRedeemAdapter(IArcusPTokenFactory(FACTORY));
        a = ArcusRedeemAdapter(Clones.clone(address(impl)));
        a.initialize(vault, address(this), "");
        vm.prank(vault);
        IERC20(PHOOD3X).approve(address(a), type(uint256).max);
        return true;
    }

    function _request(uint256 shares) internal returns (uint256) {
        return abi.decode(a.execute(abi.encode(uint8(0), PHOOD3X, shares)), (uint256));
    }

    function _claim() internal {
        a.execute(abi.encode(uint8(1), address(0), uint256(0)));
    }

    function test_FulfilledRequestPaysArcusValueToTheVault() public {
        if (!_setUp(79287181)) return;
        uint256 shares = 2401420477814949199; // what request 0x4f2 redeemed
        deal(PHOOD3X, vault, shares, true);
        uint256 value = IArcusPToken(PHOOD3X).convertToAssets(shares);
        uint256 id = _request(shares);
        (Amount[] memory pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos[0].token, USDG);
        assertEq(pos[0].amount, value, "pending counts at Arcus' value");
        vm.roll(79287182);
        vm.prank(KEEPER);
        (bool ok1,) = PHOOD3X.call(abi.encodeWithSelector(0x4c22fd49, id, uint256(0x301f), uint256(0x148c0dbb)));
        assertTrue(ok1, "keeper links the request to its bridge withdrawal");
        vm.roll(79287209);
        vm.prank(KEEPER);
        (bool ok2,) = PHOOD3X.call(KEEPER_SETTLE);
        assertTrue(ok2, "keeper settles the withdrawal");
        assertEq(IArcusPToken(PHOOD3X).claimableRedeemRequest(id, address(a)), shares, "claimable");
        uint256 owed = IArcusPToken(PHOOD3X).maxWithdraw(address(a));
        (pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos[0].amount, owed, "fulfilled: counts what the claim pays");
        _claim();
        uint256 got = IERC20(USDG).balanceOf(vault);
        console.log("shares", shares);
        console.log("value posted at request (USDG raw)", value);
        console.log("paid to the vault (USDG raw)", got);
        assertEq(got, owed);
        assertApproxEqRel(got, value, 0.01e18, "within 1% of the posted value");
        assertEq(IERC20(USDG).balanceOf(address(a)), 0, "nothing loose");
        (pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos.length, 0);
    }

    function test_RejectedRequestReturnsTheShares() public {
        if (!_setUp(0)) return;
        deal(PHOOD3X, vault, 1e18, true);
        assertTrue(IArcusPTokenFactory(FACTORY).isPToken(PHOOD3X));
        uint256 id = _request(1e18);
        assertEq(IERC20(PHOOD3X).balanceOf(vault), 0);
        vm.expectRevert(abi.encodeWithSelector(ArcusRedeemAdapter.RequestPending.selector, PHOOD3X, id));
        a.split(0.5e18, leaver);
        vm.prank(KEEPER);
        IArcusPTokenReject(PHOOD3X).rejectRedeemRequest(id);
        (Amount[] memory pos,) = a.positions(IPriceRouter(address(0)));
        assertEq(pos[0].token, PHOOD3X, "counted in the pToken while it comes back");
        assertEq(pos[0].amount, 1e18);
        _claim();
        assertEq(IERC20(PHOOD3X).balanceOf(vault), 1e18, "back in the vault");
    }

    function test_ExpiredRequestIsCancelledAndReturned() public {
        if (!_setUp(0)) return;
        deal(PHOOD3X, vault, 1e18, true);
        _request(0.6e18);
        _claim();
        assertEq(IERC20(PHOOD3X).balanceOf(vault), 0.4e18, "not expired: still pending");
        vm.warp(block.timestamp + 7 days + 60);
        _claim();
        assertEq(IERC20(PHOOD3X).balanceOf(vault), 1e18, "cancelled after 7 days and returned");
    }

    function test_RefusesWhatIsNotAPToken() public {
        if (!_setUp(0)) return;
        deal(USDG, vault, 1e6, true);
        vm.expectRevert(abi.encodeWithSelector(ArcusRedeemAdapter.NotPToken.selector, USDG));
        a.execute(abi.encode(uint8(0), USDG, uint256(1e6)));
    }
}

interface IArcusPTokenReject {
    function rejectRedeemRequest(uint256 requestId) external;
}
