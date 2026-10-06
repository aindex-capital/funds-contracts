// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {VaultShareSource} from "../../src/pricing/sources/VaultShareSource.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {IPriceRouter, PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";

/// @dev A vault share whose price per share a manager posts, like an Arcus pToken (ERC-7540: no previews, no mint).
contract MockPostedShare is MockERC20 {
    address public asset;
    uint256 public assetsPerShare;
    bool public broken;

    constructor(address asset_) MockERC20("Arcus HOOD 3x long", "pHOOD3x", 18) {
        asset = asset_;
    }

    function post(uint256 perShare) external {
        assetsPerShare = perShare;
    }

    function breakIt() external {
        broken = true;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!broken, "broken");
        return shares * assetsPerShare / 1e18;
    }
}

contract VaultShareSourceTest is Test {
    PriceRouter internal router;
    MockPriceSource internal usd;
    VaultShareSource internal source;
    MockERC20 internal usdg;
    MockPostedShare internal share;

    function setUp() public {
        vm.warp(1_790_860_852);
        router = new PriceRouter(address(this));
        usd = new MockPriceSource();
        source = new VaultShareSource(IPriceRouter(address(router)));
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        share = new MockPostedShare(address(usdg));
        usd.set(address(usdg), 1e18);
        _apply(address(usdg), _cfg(usd, PriceClass.Feed, 0));
        share.post(147_190_000); // 147.19 USDG (6 decimals) per whole share, pHOOD3x on 2026-10-05
    }

    function _cfg(IPriceSource p, PriceClass c, uint16 h) internal pure returns (PriceRouter.Config memory) {
        return PriceRouter.Config({ primary: p, check: IPriceSource(address(0)), class_: c, haircutBps: h, maxDeviationBps: 0, decimals: 0, chained: 0 });
    }

    function _apply(address token, PriceRouter.Config memory c) internal {
        router.propose(token, c);
        if (router.pendingAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(token);
        }
    }

    function test_PricesAShareAtWhatItConvertsTo() public view {
        (uint256 p, uint64 at, bool ok) = source.price(address(share));
        assertTrue(ok);
        assertEq(p, 147.19e18, "147.19 USDG at $1");
        assertEq(at, block.timestamp);
    }

    function test_TheRouterAddsTheClassAndHaircut() public {
        _apply(address(share), _cfg(source, PriceClass.Thin, 100)); // a new token waits the delay
        (uint256 bid,, bool ok) = router.value(address(share), 1e18, Side.Bid);
        assertTrue(ok);
        assertEq(bid, 145.7181e18, "1% under fair at the bid");
        assertEq(uint8(router.classOf(address(share))), uint8(PriceClass.Thin));
    }

    function test_FollowsTheAssetsPrice() public {
        usd.set(address(usdg), 0.99e18);
        (uint256 p,, bool ok) = source.price(address(share));
        assertTrue(ok);
        assertEq(p, 145.7181e18);
    }

    function test_UnavailableRatherThanWrong() public {
        // The asset cannot be priced.
        usd.setDown(address(usdg), true);
        (, , bool ok) = source.price(address(share));
        assertFalse(ok, "asset down");
        usd.setDown(address(usdg), false);
        // Nothing posted yet.
        share.post(0);
        (, , ok) = source.price(address(share));
        assertFalse(ok, "converts to nothing");
        // The vault reverts.
        share.post(1e6);
        share.breakIt();
        (, , ok) = source.price(address(share));
        assertFalse(ok, "convertToAssets reverts");
        // Not a vault at all.
        (, , ok) = source.price(address(usdg));
        assertFalse(ok, "plain token");
        // Not even a token.
        (, , ok) = source.price(address(0xBEEF));
        assertFalse(ok, "no code");
    }

    function test_AShareCannotBackItself() public {
        SelfShare s = new SelfShare();
        (, , bool ok) = source.price(address(s));
        assertFalse(ok);
    }
}

contract SelfShare is MockERC20 {
    constructor() MockERC20("Self", "SELF", 18) {}

    function asset() external view returns (address) {
        return address(this);
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}
