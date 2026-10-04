// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceRecorder} from "../../src/pricing/sources/PriceRecorder.sol";
import {SourceAdmin} from "../../src/pricing/sources/SourceAdmin.sol";
import {PoolMath} from "../../src/pricing/sources/PoolMath.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {MockPoolManager, MockArbSys} from "./PricingMocks.sol";

/// @notice Exposes the recorder's internals for direct tests of the median.
contract RecorderHarness is PriceRecorder {
    constructor(address owner_, IPoolManager pm) PriceRecorder(owner_, pm) {}

    function store(address token, uint32 slot, int24 tick) external {
        _store(token, slot, tick);
    }
}

contract PriceRecorderTest is Test {
    RecorderHarness internal rec;
    MockPoolManager internal pm;
    MockPriceSource internal quotes;
    MockERC20 internal meme;
    MockERC20 internal weth;
    PoolKey internal key;
    bytes32 internal poolId;

    uint256 internal constant SLOT = 10 minutes;
    // A Pons pool: native ETH is currency0, the token currency1, fee 0, tick spacing 200.
    address internal constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    function setUp() public {
        vm.warp(1_790_860_800); // a slot boundary (divisible by 600)
        vm.roll(1_000);
        pm = new MockPoolManager();
        rec = new RecorderHarness(address(this), IPoolManager(address(pm)));
        rec.setRecorder(address(this), true); // these tests record as AINDEX's keeper
        quotes = new MockPriceSource();
        meme = new MockERC20("Nova AI", "NOVAAI", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        quotes.set(address(weth), 2_700e18);

        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(meme)), 0, 200, IHooks(PONS_HOOK));
        poolId = PoolId.unwrap(key.toId());
        pm.setSlot0(poolId, 1, 88548);

        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        rec.propose(address(meme), key, address(weth));
        vm.warp(now_);
        rec.applyPending(address(meme));
    }

    function _setTick(int24 t) internal {
        pm.setSlot0(poolId, 1, t);
    }

    /// @dev Move forward and roll enough blocks to allow a confirmation.
    function _wait(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 5);
    }

    function _slot() internal view returns (uint32) {
        return uint32(block.timestamp / SLOT);
    }

    /// @dev Record one final reading at `t` in the current slot, then move to the next slot's start.
    function _finalAt(int24 t) internal {
        _setTick(t);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Marked));
        _wait(61);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final));
        vm.warp((block.timestamp / SLOT + 1) * SLOT);
        vm.roll(block.number + 5);
    }

    // ---- slot rules ----

    function test_firstMarksSecondConfirms() public {
        uint32 slot = _slot();
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Marked));
        (bool found,) = rec.readingAt(address(meme), slot);
        assertFalse(found, "a mark alone is not a reading");

        _wait(60);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final));
        int24 tick;
        (found, tick) = rec.readingAt(address(meme), slot);
        assertTrue(found);
        assertEq(tick, 88548);
    }

    function test_confirmationNeedsTimeAndBlocks() public {
        rec.record(address(meme));

        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 59);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Waiting), "59 seconds is too soon");

        vm.warp(block.timestamp + 600 - 59 - 1); // still in the slot, but one block only
        vm.roll(block.number - 99);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Waiting), "one block is too soon");

        vm.roll(block.number + 1);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final), "two blocks and a minute");
    }

    function test_countsL2BlocksFromArbSys() public {
        // Robinhood Chain's block.number is Ethereum's; the L2 block comes from ArbSys.
        vm.etch(address(100), address(new MockArbSys()).code);
        MockArbSys arb = MockArbSys(address(100));
        arb.set(500);
        rec.record(address(meme));
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 100); // block.number moves, the L2 block does not
        arb.set(501);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Waiting));
        arb.set(502);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final));
    }

    function test_placeholderArbSysDoesNotBurnGas() public {
        vm.etch(address(100), hex"fe"); // what a local fork of the chain serves for the precompile
        uint256 g = gasleft();
        rec.record(address(meme));
        assertLt(g - gasleft(), 200_000);
    }

    function test_onlyOneFinalReadingPerSlot() public {
        rec.record(address(meme));
        _wait(60);
        rec.record(address(meme));
        _setTick(90000);
        _wait(60);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.AlreadyFinal));
        (, int24 tick) = rec.readingAt(address(meme), _slot());
        assertEq(tick, 88548, "first final reading kept");
    }

    function test_disagreementReplacesTheMark() public {
        rec.record(address(meme));
        _setTick(88548 + 100); // just over 1%
        _wait(60);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Replaced));
        (uint32 s, int24 t,,) = rec.markOf(address(meme));
        assertEq(s, _slot());
        assertEq(t, 88648);

        _wait(60);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final));
        (, int24 tick) = rec.readingAt(address(meme), _slot());
        assertEq(tick, 88648);
    }

    function test_withinOnePercentConfirms() public {
        rec.record(address(meme));
        _setTick(88548 - 99);
        _wait(60);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final));
        (, int24 tick) = rec.readingAt(address(meme), _slot());
        assertEq(tick, 88548, "the mark is what is kept");
    }

    function test_markDoesNotCarryIntoNextSlot() public {
        vm.warp(block.timestamp + SLOT - 30); // mark 30 seconds before the slot ends
        uint32 first = _slot();
        rec.record(address(meme));
        _wait(60); // now in the next slot
        assertEq(
            uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Marked), "fresh mark, not a confirmation"
        );
        (bool found,) = rec.readingAt(address(meme), first);
        assertFalse(found);
    }

    function test_uninitialisedPoolRecordsNothing() public {
        pm.setSlot0(poolId, 0, 0);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.NoPool));
        (uint32 s,,,) = rec.markOf(address(meme));
        assertEq(s, 0);
    }

    function test_unconfiguredTokenReverts() public {
        vm.expectRevert(PriceRecorder.NotConfigured.selector);
        rec.record(address(weth));
        (,,, bool ok) = rec.ratio(address(weth));
        assertFalse(ok);
    }

    // ---- price ----

    function test_needsOneHundredReadings() public {
        for (uint256 i; i < 99; ++i) {
            _finalAt(88548);
        }
        (,,, bool ok) = rec.ratio(address(meme));
        assertFalse(ok, "99 readings");
        _finalAt(88548);
        address quote;
        uint256 r;
        uint64 at;
        (quote, r, at, ok) = rec.ratio(address(meme));
        assertTrue(ok, "100 readings");
        assertEq(quote, address(weth), "native ETH is priced as WETH by the router");
        // ETH is currency0, the token currency1: one token is 1 / 1.0001^88548 ETH.
        assertEq(r, PoolMath.ratioAtTick(88548, 18, false, 18));
        assertApproxEqRel(r * 2_700, 0.3854e18, 0.001e18);
        assertEq(at, (block.timestamp / SLOT - 1) * SLOT, "newest reading's slot");
        assertEq(rec.name(), "v4 price recorder");
        (,, bool okUsd) = rec.price(address(meme));
        assertFalse(okUsd, "no USD price of its own");
    }

    function test_medianIgnoresAMinorityOfManipulatedSlots() public {
        for (uint256 i; i < 72; ++i) {
            _finalAt(88548);
        }
        // pumped in 71 of 143 slots
        for (uint256 i; i < 71; ++i) {
            _finalAt(70000);
        }
        (int24 tick, uint256 count,) = rec.medianTick(address(meme));
        assertEq(count, 143);
        assertEq(tick, 88548);
    }

    function test_evenCountTakesMeanOfMiddleTwo() public {
        for (uint256 i; i < 50; ++i) {
            _finalAt(-101);
        }
        for (uint256 i; i < 50; ++i) {
            _finalAt(-200);
        }
        (int24 tick, uint256 count,) = rec.medianTick(address(meme));
        assertEq(count, 100);
        assertEq(tick, -151, "(-101 + -200) / 2 rounded down");
    }

    function test_readingsOlderThanADayDropOut() public {
        for (uint256 i; i < 100; ++i) {
            _finalAt(88548);
        }
        (,,, bool ok) = rec.ratio(address(meme));
        assertTrue(ok);
        vm.warp(block.timestamp + 88 * SLOT); // the oldest 45 are now more than 144 slots old
        (, uint256 count,) = rec.medianTick(address(meme));
        assertEq(count, 100 - 45);
        (,,, ok) = rec.ratio(address(meme));
        assertFalse(ok);
    }

    function test_ringOverwritesOldSlots() public {
        for (uint256 i; i < 150; ++i) {
            _finalAt(int24(int256(i)));
        }
        (int24 tick, uint256 count,) = rec.medianTick(address(meme));
        assertEq(count, 143, "the current slot has no reading yet");
        // Ticks 7..149 remain; their median is 78.
        assertEq(tick, 78);
    }

    function test_quoteMustBeThePoolsOtherToken() public {
        PoolKey memory k2 =
            PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(meme)), 3000, 60, IHooks(address(0)));
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        rec.propose(address(meme), k2, address(0xBEEF));
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        rec.propose(address(meme), key, address(meme));
    }

    /// @notice A `record` can finalise the current slot inside any transaction (say between the two NAV readings of a
    ///         manager's action), so the current slot never counts: the median, the count and the recent price are
    ///         the same before and after it.
    function test_currentSlotNeverMovesThePrice() public {
        uint32 cur = _slot();
        for (uint32 i = 1; i <= 120; ++i) {
            rec.store(address(meme), cur - i, 88548);
        }
        (int24 before, uint256 nBefore, uint32 newestBefore) = rec.medianTick(address(meme));
        (uint256 recentBefore, bool ok) = rec.recentRatio(address(meme));
        assertTrue(ok);
        rec.store(address(meme), cur, 600_000); // this slot's reading lands
        (int24 afterTick, uint256 nAfter, uint32 newestAfter) = rec.medianTick(address(meme));
        (uint256 recentAfter,) = rec.recentRatio(address(meme));
        assertEq(afterTick, before);
        assertEq(nAfter, nBefore);
        assertEq(newestAfter, newestBefore);
        assertEq(recentAfter, recentBefore);
    }

    /// @notice The recent price is the newest complete slot's reading, so a sharp move shows within a slot or
    ///         two while the 24-hour median trails it for hours.
    function test_recentIsTheNewestCompleteSlot() public {
        uint32 cur = _slot();
        for (uint32 i = 3; i <= 120; ++i) {
            rec.store(address(meme), cur - i, 88548);
        }
        rec.store(address(meme), cur - 2, 89548); // the pool rose about 10%
        (int24 med,,) = rec.medianTick(address(meme));
        assertEq(med, 88548, "the median has not moved");
        (uint256 recent, bool ok) = rec.recentRatio(address(meme));
        assertTrue(ok);
        assertEq(recent, PoolMath.ratioAtTick(89548, 18, false, 18));
        // Nothing within the window: not ok.
        vm.warp(block.timestamp + 2 days);
        (, ok) = rec.recentRatio(address(meme));
        assertFalse(ok);
    }

    function testFuzz_medianMatchesSort(int24[144] memory raw, uint8 n) public {
        uint256 count = bound(n, 1, 143); // the current slot never counts
        uint32 cur = uint32(block.timestamp / SLOT);
        int24[] memory ticks = new int24[](count);
        for (uint256 i; i < count; ++i) {
            ticks[i] = int24(bound(raw[i], -600_000, 600_000));
            rec.store(address(meme), cur - 1 - uint32(i), ticks[i]);
        }
        // insertion sort, the obvious way
        for (uint256 i = 1; i < count; ++i) {
            int24 v = ticks[i];
            uint256 j = i;
            while (j > 0 && ticks[j - 1] > v) {
                ticks[j] = ticks[j - 1];
                --j;
            }
            ticks[j] = v;
        }
        int256 expected;
        if (count % 2 == 1) {
            expected = ticks[count / 2];
        } else {
            int256 sum = int256(ticks[count / 2 - 1]) + int256(ticks[count / 2]);
            expected = sum >= 0 ? sum / 2 : (sum - 1) / 2;
        }
        (int24 tick, uint256 got,) = rec.medianTick(address(meme));
        assertEq(got, count);
        assertEq(int256(tick), expected);
    }

    // ---- configuration ----

    function test_tokenMustBeInThePool() public {
        vm.expectRevert(SourceAdmin.BadConfig.selector);
        rec.propose(address(weth), key, address(weth));
    }

    function test_changingPoolWaitsAndClearsHistory() public {
        for (uint256 i; i < 3; ++i) {
            _finalAt(88548);
        }
        PoolKey memory other =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(meme)), 3000, 60, IHooks(address(0)));
        rec.propose(address(meme), other, address(weth));
        (, uint256 count,) = rec.medianTick(address(meme));
        assertEq(count, 3, "pending change does not touch readings");
        vm.warp(block.timestamp + 1 days);
        rec.applyPending(address(meme));
        (, count,) = rec.medianTick(address(meme));
        assertEq(count, 0, "new pool, new history");
    }

    function test_removalIsInstant() public {
        PoolKey memory none;
        rec.propose(address(meme), none, address(0));
        vm.expectRevert(PriceRecorder.NotConfigured.selector);
        rec.record(address(meme));
    }
}
