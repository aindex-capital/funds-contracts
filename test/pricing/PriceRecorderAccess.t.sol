// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceRecorder} from "../../src/pricing/sources/PriceRecorder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {MockPoolManager} from "./PricingMocks.sol";

/// @notice An outsider who records a moved price at the start of each slot used to replace the keeper's mark
///         every time, so no slot ever got its reading and the token went unpriced. The first half of every slot
///         now belongs to the listed recorders.
contract PriceRecorderAccessTest is Test {
    PriceRecorder internal rec;
    MockPoolManager internal pm;
    MockERC20 internal meme;
    bytes32 internal poolId;
    address internal keeperBot = makeAddr("keeperBot");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant SLOT = 10 minutes;

    function setUp() public {
        vm.warp(1_790_860_800); // a slot boundary
        vm.roll(1_000);
        pm = new MockPoolManager();
        rec = new PriceRecorder(address(this), IPoolManager(address(pm)));
        MockPriceSource quotes = new MockPriceSource();
        meme = new MockERC20("Meme", "MEME", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        quotes.set(address(weth), 2_700e18);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(meme)), 0, 200, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        pm.setSlot0(poolId, 1, 88548);
        uint256 now_ = block.timestamp;
        vm.warp(now_ - 1 days);
        rec.propose(address(meme), key, address(weth));
        vm.warp(now_);
        rec.applyPending(address(meme));
        (bool ok,) = address(rec).call(abi.encodeWithSignature("setRecorder(address,bool)", keeperBot, true));
        ok;
    }

    function test_OutsiderCannotRecordEarlyInASlot() public {
        pm.setSlot0(poolId, 1, 90000); // the outsider moved the pool for one transaction
        vm.prank(outsider);
        vm.expectRevert(bytes4(keccak256("RecordersOnly()")));
        rec.record(address(meme));
    }

    function test_RecorderGetsItsReadingDespiteAnOutsider() public {
        pm.setSlot0(poolId, 1, 90000);
        vm.prank(outsider);
        try rec.record(address(meme)) {} catch {}
        pm.setSlot0(poolId, 1, 88548);
        vm.prank(keeperBot);
        rec.record(address(meme));
        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 5);
        vm.prank(keeperBot);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Final));
        (bool found, int24 tick) = rec.readingAt(address(meme), uint32(block.timestamp / SLOT));
        assertTrue(found);
        assertEq(tick, 88548);
    }

    function test_AnyoneRecordsInTheSecondHalf() public {
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(outsider);
        assertEq(uint8(rec.record(address(meme))), uint8(PriceRecorder.Recorded.Marked));
    }
}
