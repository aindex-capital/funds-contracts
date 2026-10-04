// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SessionPoolSource, IUniswapV3PoolSession} from "../../src/pricing/sources/SessionPoolSource.sol";
import {SourceAdmin} from "../../src/pricing/sources/SourceAdmin.sol";
import {PoolMath} from "../../src/pricing/sources/PoolMath.sol";
import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockV3Pool} from "./PricingMocks.sol";

/// @notice The weekend pools: up to three per token, any pair, each counting only while deep enough and with history
///         for the whole window; every change waits a day.
contract SessionPoolSourceTest is Test {
    SessionPoolSource internal src;
    MockERC20 internal stock; // 18 decimals
    MockERC20 internal usdg; // 6 decimals
    MockERC20 internal weth;
    MockV3Pool internal pUsdg;
    MockV3Pool internal pWeth;

    function setUp() public {
        vm.warp(1_790_860_852);
        src = new SessionPoolSource(address(this));
        stock = new MockERC20("Stock", "STK", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        pUsdg = new MockV3Pool(address(usdg), address(stock)); // stock is token1 here
        pUsdg.setTick(276324 - 46054, block.timestamp - 10 days); // about $100 per stock
        pUsdg.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
        pWeth = new MockV3Pool(address(stock), address(weth));
        pWeth.setTick(-29957, block.timestamp - 10 days); // about 0.05 WETH per stock
        pWeth.setHistory(5, 100, 6, uint32(block.timestamp - 2 hours), true);
    }

    function _specs(uint128 minL) internal view returns (SessionPoolSource.Spec[] memory s) {
        s = new SessionPoolSource.Spec[](2);
        s[0] = SessionPoolSource.Spec(IUniswapV3PoolSession(address(pUsdg)), minL);
        s[1] = SessionPoolSource.Spec(IUniswapV3PoolSession(address(pWeth)), minL);
    }

    function _configure(SessionPoolSource.Spec[] memory s) internal {
        src.propose(address(stock), s);
        vm.warp(block.timestamp + 1 days);
        src.applyPending(address(stock));
    }

    function test_EveryQualifyingPoolInItsOwnQuote() public {
        _configure(_specs(1e17));
        IClosedMarketSource.Ratio[] memory r = src.closedRatios(address(stock));
        assertEq(r.length, 2);
        assertEq(r[0].quote, address(usdg));
        assertEq(r[0].ratioWad, PoolMath.ratioAtTick(276324 - 46054, 18, false, 6));
        assertApproxEqRel(r[0].ratioWad, 100e18, 0.001e18);
        assertEq(r[1].quote, address(weth));
        assertApproxEqRel(r[1].ratioWad, 0.05e18, 0.001e18);
        SessionPoolSource.Pool[] memory ps = src.poolsOf(address(stock));
        assertFalse(ps[0].baseIsToken0);
        assertTrue(ps[1].baseIsToken0);
        assertEq(ps[0].quoteDecimals, 6);
    }

    function test_ShallowPoolDropsOut() public {
        _configure(_specs(1e17));
        pWeth.setLiquidity(1e17 - 1);
        IClosedMarketSource.Ratio[] memory r = src.closedRatios(address(stock));
        assertEq(r.length, 1);
        assertEq(r[0].quote, address(usdg));
        pUsdg.setLiquidity(0);
        assertEq(src.closedRatios(address(stock)).length, 0, "none qualifies: the router falls back");
    }

    /// @notice Qualification is on the window's liquidity, never on the liquidity now. Liquidity added or removed
    ///         inside a transaction (a flash add or remove) neither lets a thin pool in nor pushes a deep one out.
    function test_FlashLiquidityChangesNothing() public {
        _configure(_specs(1e17));
        pWeth.setSpotLiquidity(0); // a deep pool emptied in this block
        assertEq(src.closedRatios(address(stock)).length, 2, "still counts: its window was deep");
        pWeth.setLiquidity(1e17 - 1); // thin over the window
        pWeth.setSpotLiquidity(1e30); // and flooded in this block
        IClosedMarketSource.Ratio[] memory r = src.closedRatios(address(stock));
        assertEq(r.length, 1, "still out: its window was thin");
        assertEq(r[0].quote, address(usdg));
    }

    /// @notice The bar is the window's liquidity (its harmonic mean, so minutes out of range weigh heavily).
    function test_WindowLiquidityIsTheHarmonicMean() public {
        _configure(_specs(5e17));
        assertEq(src.closedRatios(address(stock)).length, 2);
        pWeth.setLiquidity(4.9e17);
        assertEq(src.closedRatios(address(stock)).length, 1, "just under over the whole window");
    }

    /// @notice Which pools count cannot change within a block. A swap here writes at most one observation, over
    ///         the oldest once the ring is full; a pool whose history only just covers the window would then drop out
    ///         in the same transaction. So the observation that must be old enough is the oldest that survives that
    ///         write, and the answer is the same before and after it.
    function test_HistoryJudgedAsAfterThisBlocksWrite() public {
        _configure(_specs(1e17));
        uint32 t = uint32(block.timestamp);
        // A full ring of 100; the newest is slot 5 from a minute ago, the oldest slot 6 is 40 minutes old, slot 7
        // only 20 minutes: one more write would overwrite slot 6 and leave 20 minutes of history.
        pWeth.setHistory(5, 100, 6, t - 40 minutes, true);
        pWeth.setObservation(5, t - 1 minutes, true);
        pWeth.setObservation(7, t - 20 minutes, true);
        assertEq(src.closedRatios(address(stock)).length, 1, "out before the write");
        // The write lands: slot 6 is now the newest (this second), slot 7 the oldest.
        pWeth.setHistory(6, 100, 7, t - 20 minutes, true);
        pWeth.setObservation(6, t, true);
        assertEq(src.closedRatios(address(stock)).length, 1, "and after it");

        // With slot 7 old enough the pool counts, before the write and after it.
        pWeth.setHistory(5, 100, 6, t - 40 minutes, true);
        pWeth.setObservation(5, t - 1 minutes, true);
        pWeth.setObservation(6, t - 40 minutes, true);
        pWeth.setObservation(7, t - 31 minutes, true);
        assertEq(src.closedRatios(address(stock)).length, 2, "in before the write");
        pWeth.setHistory(6, 100, 7, t - 31 minutes, true);
        pWeth.setObservation(6, t, true);
        assertEq(src.closedRatios(address(stock)).length, 2, "and after it");
    }

    /// @notice The last slot of the ring: a write there may land in a new slot if the ring grows (keeping slot 0),
    ///         or over slot 0; either way slot 1 is what must be old enough, so growing the ring in the same
    ///         transaction cannot let a pool in either.
    function test_HistoryAtTheEndOfTheRing() public {
        _configure(_specs(1e17));
        uint32 t = uint32(block.timestamp);
        pWeth.setHistory(98, 100, 0, t - 40 minutes, true); // newest slot 98: the write would land in slot 99
        pWeth.setObservation(98, t - 1 minutes, true);
        pWeth.setObservation(99, t - 50 minutes, true);
        pWeth.setObservation(1, t - 20 minutes, true);
        assertEq(src.closedRatios(address(stock)).length, 1, "slot 1 too young");
        pWeth.setObservation(1, t - 31 minutes, true);
        assertEq(src.closedRatios(address(stock)).length, 2, "slot 1 old enough");
    }

    function test_OneObservationNeverCounts() public {
        _configure(_specs(1e17));
        pWeth.setHistory(0, 1, 0, uint32(block.timestamp - 2 hours), true);
        assertEq(src.closedRatios(address(stock)).length, 1, "the next write replaces it");
    }

    function test_ShortHistoryDropsOut() public {
        _configure(_specs(1e17));
        pUsdg.setObserveReverts(true); // `observe` refuses a window older than its history
        IClosedMarketSource.Ratio[] memory r = src.closedRatios(address(stock));
        assertEq(r.length, 1);
        assertEq(r[0].quote, address(weth));
    }

    function test_TimeWeightedNotSpot() public {
        _configure(_specs(1e17));
        pWeth.forceCumulatives(0, 1800 * -30_000); // the 30-minute mean, whatever the current tick says
        assertEq(src.closedRatios(address(stock))[1].ratioWad, PoolMath.ratioAtTick(-30_000, 18, true, 18));
    }

    function test_ConfigurationRules() public {
        SessionPoolSource.Spec[] memory s = _specs(1e17);
        s[1].minLiquidity = 0;
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(stock), s);

        MockV3Pool wrong = new MockV3Pool(address(usdg), address(weth));
        s = new SessionPoolSource.Spec[](1);
        s[0] = SessionPoolSource.Spec(IUniswapV3PoolSession(address(wrong)), 1);
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(stock), s);

        s = new SessionPoolSource.Spec[](4);
        for (uint256 i; i < 4; ++i) {
            s[i] = SessionPoolSource.Spec(IUniswapV3PoolSession(address(pUsdg)), 1);
        }
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        src.propose(address(stock), s);

        vm.prank(makeAddr("x"));
        vm.expectRevert(SourceAdmin.NotOwner.selector);
        src.propose(address(stock), _specs(1));
    }

    /// @notice Nothing is instant, a removal included: a pool that stops counting can narrow one side of the
    ///         router's spread. The emergency lever is the router's spreads.
    function test_EveryChangeWaits() public {
        _configure(_specs(1e17));
        src.propose(address(stock), new SessionPoolSource.Spec[](0));
        assertGt(src.pendingAt(address(stock)), 0);
        assertEq(src.closedRatios(address(stock)).length, 2, "still in force");
        vm.warp(block.timestamp + 1 days);
        src.applyPending(address(stock));
        assertEq(src.closedRatios(address(stock)).length, 0);
        assertEq(src.closedRatios(address(weth)).length, 0, "an unknown token has none");
    }
}
