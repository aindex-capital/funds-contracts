// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockERC20} from "../utils/Mocks.sol";

/// @notice A Chainlink aggregator whose round tests set by hand.
contract MockAggregator {
    uint8 public decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    bool public reverts;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        roundId++;
        answeredInRound = roundId;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
    }

    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function setStartedAt(uint256 s) external {
        startedAt = s;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "feed down");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice A Robinhood stock token: an ERC-20 with `oraclePaused()`.
contract MockStockToken is MockERC20 {
    bool public oraclePaused;

    constructor() MockERC20("NVIDIA", "NVDA", 18) {}

    function setPaused(bool p) external {
        oraclePaused = p;
    }
}

/// @notice A Uniswap v3 pool with a constant tick since `start` (optionally another tick for the last stretch), and a
///         hand-set observation ring. A full ring's other slots are spaced evenly from the oldest to a second ago.
contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public tick;
    uint256 public start;
    uint16 public index;
    uint16 public cardinality;
    bool public observeReverts;
    bool public ringFull;
    uint256 public oldestIndex;
    uint32 public oldestTime;
    mapping(uint256 => uint32) public obsTime;
    mapping(uint256 => bool) public obsInit;
    /// @dev When set, observe returns cumulatives on the line through these (at 30 minutes ago and now).
    int56[2] public forced;
    bool public useForced;
    /// @dev From `switchAt` on, the pool sits at `lateTick` (a move the 30-minute average has not caught up with).
    int24 public lateTick;
    uint256 public switchAt;
    /// @notice Liquidity at the current tick: what a trade in this block could change.
    uint128 public liquidity = 1e18;
    /// @notice Liquidity over the pool's history (what `secondsPerLiquidityCumulative` accrues).
    uint128 public pastLiquidity = 1e18;

    constructor(address t0, address t1) {
        (token0, token1) = (t0, t1);
    }

    function setTick(int24 t, uint256 start_) external {
        tick = t;
        start = start_;
        switchAt = 0;
    }

    /// @dev The pool has sat at `t` for the last `secs` seconds.
    function setLateTick(int24 t, uint256 secs) external {
        lateTick = t;
        switchAt = block.timestamp - secs;
    }

    /// @dev One observation `age` seconds old in slot 0, ring of `card` with only slot 0 written.
    function setHistory(uint16 index_, uint16 card, uint256 oldestIndex_, uint32 oldestTime_, bool ringFull_) external {
        index = index_;
        cardinality = card;
        obsTime[oldestIndex_] = oldestTime_;
        obsInit[oldestIndex_] = true;
        (oldestIndex, oldestTime, ringFull) = (oldestIndex_, oldestTime_, ringFull_);
        if (!ringFull_) obsInit[(uint256(index_) + 1) % card] = false;
    }

    /// @dev Set one slot of the ring by hand.
    function setObservation(uint256 i, uint32 t, bool init) external {
        obsTime[i] = t;
        obsInit[i] = init;
    }

    /// @dev Liquidity now and over the whole history.
    function setLiquidity(uint128 l) external {
        liquidity = l;
        pastLiquidity = l;
    }

    /// @dev Liquidity now only (added or removed in this block): the history keeps what it had.
    function setSpotLiquidity(uint128 l) external {
        liquidity = l;
    }

    function setObserveReverts(bool r) external {
        observeReverts = r;
    }

    function forceCumulatives(int56 a, int56 b) external {
        forced = [a, b];
        useForced = true;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1, tick, index, cardinality, cardinality, 0, true);
    }

    function observations(uint256 i) external view returns (uint32, int56, uint160, bool) {
        if (obsInit[i] || !ringFull || cardinality < 2 || i >= cardinality) return (obsTime[i], 0, 0, obsInit[i]);
        uint256 d = (i + cardinality - oldestIndex) % cardinality;
        uint256 span = block.timestamp - 1 - oldestTime;
        return (uint32(oldestTime + d * span / (cardinality - 1)), 0, 0, true);
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory cums, uint160[] memory spl) {
        require(!observeReverts, "OLD");
        cums = new int56[](ago.length);
        spl = new uint160[](ago.length);
        for (uint256 i; i < ago.length; ++i) {
            uint256 t = block.timestamp - ago[i];
            if (useForced) {
                cums[i] = forced[1] - (forced[1] - forced[0]) * int56(uint56(ago[i])) / 1800;
            } else if (switchAt != 0 && t > switchAt) {
                cums[i] = int56(tick) * int56(int256(switchAt - start)) + int56(lateTick) * int56(int256(t - switchAt));
            } else {
                cums[i] = int56(tick) * int56(int256(t - start));
            }
            spl[i] = uint160(((t - start) << 128) / (pastLiquidity == 0 ? 1 : pastLiquidity));
        }
    }
}

/// @notice The one PoolManager function the recorder reads through StateLibrary: `extsload`.
contract MockPoolManager {
    mapping(bytes32 => bytes32) public words;

    function setSlot0(bytes32 poolId, uint160 sqrtPriceX96, int24 tick) external {
        bytes32 slot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        words[slot] = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }
}

/// @notice Arbitrum's ArbSys, with an L2 block number tests set by hand.
contract MockArbSys {
    uint256 public arbBlockNumber;

    function set(uint256 n) external {
        arbBlockNumber = n;
    }
}
