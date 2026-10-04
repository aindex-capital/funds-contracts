// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {IPriceRouter, PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";

contract RevertingSource is IPriceSource {
    function price(address) external pure returns (uint256, uint64, bool) {
        revert("down");
    }

    function name() external pure returns (string memory) {
        return "reverting";
    }
}

contract PriceRouterTest is Test {
    PriceRouter router;
    MockPriceSource a;
    MockPriceSource b;
    MockERC20 tkn; // 18 decimals
    MockERC20 usd6; // 6 decimals

    function setUp() public {
        router = new PriceRouter(address(this));
        a = new MockPriceSource();
        b = new MockPriceSource();
        tkn = new MockERC20("T", "T", 18);
        usd6 = new MockERC20("U", "U", 6);
        a.set(address(tkn), 2e18);
        b.set(address(tkn), 2e18);
        a.set(address(usd6), 1e18);
    }

    function _cfg(IPriceSource p, IPriceSource c, PriceClass k, uint16 h, uint16 dev)
        internal
        pure
        returns (PriceRouter.Config memory)
    {
        return PriceRouter.Config({
            primary: p, check: c, class_: k, haircutBps: h, maxDeviationBps: dev, decimals: 0, chained: 0
        });
    }

    function _live(address t, PriceRouter.Config memory c) internal {
        router.propose(t, c);
        if (router.pendingAt(t) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(t);
        }
    }

    function test_UnconfiguredIsNoneWorthZero() public view {
        IPriceRouter.Quote memory q = router.quote(address(tkn));
        assertEq(uint8(q.class_), uint8(PriceClass.None));
        assertTrue(q.available);
        (uint256 usd, PriceClass c, bool ok) = router.value(address(tkn), 1e18, Side.Fair);
        assertEq(usd, 0);
        assertEq(uint8(c), uint8(PriceClass.None));
        assertTrue(ok);
    }

    function test_FirstConfigWaitsTheDelay() public {
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        assertEq(uint8(router.classOf(address(tkn))), uint8(PriceClass.None));
        vm.expectRevert(PriceRouter.NotReady.selector);
        router.applyPending(address(tkn));
        vm.warp(block.timestamp + 1 days);
        vm.prank(makeAddr("anyone"));
        router.applyPending(address(tkn));
        assertEq(uint8(router.classOf(address(tkn))), uint8(PriceClass.Feed));
    }

    function test_LowersOnlyApplyAtOnce() public {
        _live(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 100, 0));
        // Bigger haircut.
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 200, 0));
        assertEq(router.pendingAt(address(tkn)), 0);
        assertEq(router.config(address(tkn)).haircutBps, 200);
        // Worse class.
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Thin, 200, 0));
        assertEq(uint8(router.classOf(address(tkn))), uint8(PriceClass.Thin));
        // None.
        router.propose(address(tkn), _cfg(IPriceSource(address(0)), IPriceSource(address(0)), PriceClass.None, 0, 0));
        assertEq(uint8(router.classOf(address(tkn))), uint8(PriceClass.None));
    }

    function test_RaisesWait() public {
        _live(address(tkn), _cfg(a, b, PriceClass.Thin, 200, 100));
        PriceRouter.Config[5] memory raises = [
            _cfg(a, b, PriceClass.Thin, 100, 100), // smaller haircut
            _cfg(a, b, PriceClass.Feed, 200, 100), // better class
            _cfg(b, b, PriceClass.Thin, 200, 100), // new primary
            _cfg(a, IPriceSource(address(0)), PriceClass.Thin, 200, 0), // check removed
            _cfg(a, b, PriceClass.Thin, 200, 500) // looser deviation
        ];
        for (uint256 i; i < raises.length; ++i) {
            router.propose(address(tkn), raises[i]);
            assertGt(router.pendingAt(address(tkn)), 0, "raise applied at once");
            assertEq(router.config(address(tkn)).haircutBps, 200);
            router.cancelPending(address(tkn));
        }
        // Tighter deviation is a lowering.
        router.propose(address(tkn), _cfg(a, b, PriceClass.Thin, 200, 50));
        assertEq(router.pendingAt(address(tkn)), 0);
    }

    function test_InstantLoweringCancelsPendingRaise() public {
        _live(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Thin, 500, 0));
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Thin, 100, 0));
        assertGt(router.pendingAt(address(tkn)), 0);
        // Emergency: haircut to 50%.
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Thin, 5000, 0));
        assertEq(router.pendingAt(address(tkn)), 0, "old raise would undo the emergency");
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PriceRouter.NotReady.selector);
        router.applyPending(address(tkn));
        assertEq(router.config(address(tkn)).haircutBps, 5000);
    }

    function test_DeviationCheck() public {
        _live(address(tkn), _cfg(a, b, PriceClass.Feed, 0, 100)); // 1%
        assertTrue(router.quote(address(tkn)).available);
        b.set(address(tkn), 2.01e18); // 0.5% apart
        assertTrue(router.quote(address(tkn)).available);
        b.set(address(tkn), 2.1e18); // 5% apart
        assertFalse(router.quote(address(tkn)).available);
        (uint256 usd,, bool ok) = router.value(address(tkn), 1e18, Side.Fair);
        assertEq(usd, 0);
        assertFalse(ok);
        b.setDown(address(tkn), true);
        b.set(address(tkn), 2e18);
        assertFalse(router.quote(address(tkn)).available, "check source down");
    }

    function test_SourceDownOrRevertingIsUnavailableNotRevert() public {
        _live(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        a.setDown(address(tkn), true);
        assertFalse(router.quote(address(tkn)).available);
        RevertingSource r = new RevertingSource();
        _live(address(usd6), _cfg(r, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        assertFalse(router.quote(address(usd6)).available);
        (,, bool ok) = router.value(address(usd6), 1, Side.Bid);
        assertFalse(ok);
    }

    function test_SidesAndDecimals() public {
        _live(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Pool, 500, 0));
        _live(address(usd6), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        (uint256 fair,,) = router.value(address(tkn), 3e18, Side.Fair);
        (uint256 bid,,) = router.value(address(tkn), 3e18, Side.Bid);
        (uint256 ask,,) = router.value(address(tkn), 3e18, Side.Ask);
        assertEq(fair, 6e18);
        assertEq(bid, 5.7e18);
        assertEq(ask, 6.3e18);
        (uint256 u,,) = router.value(address(usd6), 250e6, Side.Fair);
        assertEq(u, 250e18);
    }

    function test_AbsurdAmountIsUnavailableNotRevert() public {
        _live(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        (uint256 usd,, bool ok) = router.value(address(tkn), type(uint256).max, Side.Fair);
        assertEq(usd, 0);
        assertFalse(ok);
        // Large but representable still works.
        (usd,, ok) = router.value(address(tkn), 1e50, Side.Fair);
        assertTrue(ok);
        assertEq(usd, 2e50);
    }

    function test_BadConfigs() public {
        vm.expectRevert(PriceRouter.BadConfig.selector);
        router.propose(address(tkn), _cfg(IPriceSource(address(0)), IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        vm.expectRevert(PriceRouter.BadConfig.selector);
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 10_000, 0));
        vm.expectRevert(PriceRouter.BadConfig.selector);
        router.propose(address(tkn), _cfg(a, b, PriceClass.Feed, 0, 0));
        vm.expectRevert(PriceRouter.BadConfig.selector);
        router.propose(address(0), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
    }

    function test_OnlyOwnerAndTwoStepOwnership() public {
        address x = makeAddr("x");
        vm.startPrank(x);
        vm.expectRevert(PriceRouter.NotOwner.selector);
        router.propose(address(tkn), _cfg(a, IPriceSource(address(0)), PriceClass.Feed, 0, 0));
        vm.expectRevert(PriceRouter.NotOwner.selector);
        router.cancelPending(address(tkn));
        vm.stopPrank();
        router.transferOwnership(x);
        assertEq(router.owner(), address(this));
        vm.prank(x);
        router.acceptOwnership();
        assertEq(router.owner(), x);
    }
}
