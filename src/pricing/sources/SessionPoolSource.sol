// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IClosedMarketSource} from "../../interfaces/IClosedMarketSource.sol";
import {SourceAdmin} from "./SourceAdmin.sol";
import {PoolMath} from "./PoolMath.sol";

/// @notice The part of a Uniswap v3 pool this source reads.
interface IUniswapV3PoolSession {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/**
 * @title  SessionPoolSource
 * @notice What a Robinhood stock or ETF token trades at while its US session is closed: the 30-minute time-weighted
 *         price of each of its deep Uniswap v3 pools, in the pool's other token. The PriceRouter asks it only while
 *         the token's market is closed, converts each price to USD through its own price of that other token (on
 *         the same side, in the same call), holds each within the token's band around the feed's last price, and
 *         prices entrants at the highest and leavers at the lowest of them and the last price (the "worse-of"
 *         rule, `PriceRouter`).
 *
 * @dev    ## Why pools, and why several
 *         Robinhood's stock feeds stop from Friday 20:00 to Sunday 20:00 New York time; their last price is then up
 *         to two days old (14 weekends measured 2026-10-02: the gap to Monday's open was 0.57% at the median, 5.4%
 *         at the 99th percentile, 7.75% at most). The tokens keep trading in pools meanwhile. A pool may be paired
 *         with any token the router prices: pools against WETH, converted at the live ETH feed, tracked the USDG
 *         pools of the same stock within 0.6% over two weekends of samples (within 0.4% live, 2026-10-02), which
 *         is the ETH feed's own 0.5% deviation band. A token may name up to `MAX_POOLS` pools; the router takes
 *         the worst of every one that qualifies, so bending any one pool still only hurts the one who bends it.
 *
 *         A pool counts only:
 *         - time-weighted over `WINDOW` (30 minutes), never spot, so it cannot move within a block and holding it
 *           off market costs a trader the whole window;
 *         - when it qualifies, and on nothing a trade in the same block can change:
 *           - its in-range liquidity averaged over the window (the harmonic mean, from the pool's
 *             `secondsPerLiquidityCumulative`, as Uniswap's OracleLibrary computes it) is at least `minLiquidity`.
 *             Liquidity added or removed inside a transaction never counts (a pool writes at most one observation
 *             per second, with the liquidity from before that second's changes), and a pool pushed out of its
 *             liquid range for part of the window, or simply thin, falls short;
 *           - its stored history covers the window even if a trade in this block wrote a new observation over the
 *             oldest one. Otherwise a swap in the same transaction could push a pool whose history only just
 *             covers the window out of the set, and so choose which pools the router takes the worst of.
 *         Which pools count is therefore fixed for the block, like their prices. The band around the last feed
 *         price and the spread are the router's (`PriceRouter.Session`).
 *
 *         ## Configuration
 *         Every change waits `CONFIG_DELAY`, removal included: a pool that stops qualifying moves the router towards
 *         its fallback spread, which can be narrower on one side, so nothing here is instant. The emergency lever
 *         is the router's spreads, which can be raised at once. `closedRatios` never reverts.
 */
contract SessionPoolSource is IClosedMarketSource, SourceAdmin {
    struct Pool {
        IUniswapV3PoolSession pool;
        uint128 minLiquidity; // in-range liquidity over the window (harmonic mean), at least
        address quote; // the pool's other token (the router must price it)
        bool baseIsToken0;
        uint8 baseDecimals;
        uint8 quoteDecimals;
    }

    /// @notice A pool as proposed: the pool and the least in-range liquidity, averaged over the window, for it to
    ///         count.
    struct Spec {
        IUniswapV3PoolSession pool;
        uint128 minLiquidity;
    }

    /// @notice The time-weighted window: 30 minutes, the length the research measured.
    uint32 public constant WINDOW = 30 minutes;
    /// @notice Most pools one token may name.
    uint256 public constant MAX_POOLS = 3;

    mapping(address => Pool[]) private _pools;

    constructor(address owner_) SourceAdmin(owner_) {}

    function name() external pure returns (string memory) {
        return "Session pools (30-minute TWAPs while the market is closed)";
    }

    function poolsOf(address token) external view returns (Pool[] memory) {
        return _pools[token];
    }

    // ---- price ----

    /// @inheritdoc IClosedMarketSource
    function closedRatios(address token) external view returns (Ratio[] memory out) {
        Pool[] storage ps = _pools[token];
        uint256 n = ps.length;
        out = new Ratio[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            Pool memory c = ps[i];
            uint256 r = _ratio(c);
            if (r != 0) out[k++] = Ratio(c.quote, r);
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    /// @dev One pool's 30-minute price in its quote, or 0 when it does not qualify now.
    function _ratio(Pool memory c) private view returns (uint256) {
        if (!_historyHolds(c.pool)) return 0;
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        try c.pool.observe(ago) returns (int56[] memory cum, uint160[] memory spl) {
            if (cum.length != 2 || spl.length != 2) return 0;
            uint160 dspl;
            unchecked {
                dspl = spl[1] - spl[0]; // the cumulative wraps by design
            }
            if (dspl == 0 || (uint256(WINDOW) << 128) / dspl < c.minLiquidity) return 0;
            int56 delta = cum[1] - cum[0];
            int56 mean = delta / int56(uint56(WINDOW));
            if (delta < 0 && delta % int56(uint56(WINDOW)) != 0) mean--;
            return PoolMath.ratioAtTick(int24(mean), c.baseDecimals, c.baseIsToken0, c.quoteDecimals);
        } catch {
            return 0;
        }
    }

    /// @dev The pool's stored history covers the window, judged so that no trade in this block can change the answer.
    ///      A pool writes at most one observation per second, into the slot after its newest (over the oldest once
    ///      the ring is full, or into a new slot when the ring grows). The observation that must be `WINDOW` old is
    ///      the oldest one that survives that write: the one after the slot the write lands in, or slot 1 when the
    ///      ring is not full or that slot is the last (the ring may grow by one, which keeps slot 0). Whether a
    ///      write happens in this block, or the ring grows, therefore never changes the result.
    function _historyHolds(IUniswapV3PoolSession pool) private view returns (bool) {
        uint256 index;
        uint256 card;
        try pool.slot0() returns (uint160, int24, uint16 i, uint16 n, uint16, uint8, bool) {
            (index, card) = (i, n);
        } catch {
            return false;
        }
        if (card < 2) return false; // one observation: the next write replaces it
        (uint32 newest,) = _observation(pool, index);
        uint256 p = newest == block.timestamp ? index : (index + 1) % card; // the newest slot once this second's write is in
        uint256 target = p == card - 1 ? 1 : p + 1;
        if (target == p) return false;
        (uint32 ts, bool init) = _observation(pool, target);
        // Not initialized: the ring has not filled yet (slots after the newest are empty), and slot 0 is the oldest
        // and stays so; the one after it must then be old enough.
        if (!init && target != 1) (ts, init) = _observation(pool, 1);
        return init && uint256(ts) + WINDOW <= block.timestamp;
    }

    function _observation(IUniswapV3PoolSession pool, uint256 i) private view returns (uint32 ts, bool initialized) {
        try pool.observations(i) returns (uint32 t, int56, uint160, bool init) {
            return (t, init);
        } catch {
            return (0, false);
        }
    }

    // ---- configuration ----

    /// @notice Price `token` while its market is closed from `pools` (at most `MAX_POOLS`, each paired with a token
    ///         the router prices), each counting only while its in-range liquidity over the window is at least its
    ///         `minLiquidity`. An empty list removes the token. Every change waits `CONFIG_DELAY`.
    function propose(address token, Spec[] calldata pools) external onlyOwner {
        if (pools.length > MAX_POOLS) revert BadConfig();
        Pool[] memory list = new Pool[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            IUniswapV3PoolSession pool = pools[i].pool;
            if (pools[i].minLiquidity == 0) revert BadConfig();
            address t0 = pool.token0();
            address t1 = pool.token1();
            if (token != t0 && token != t1) revert BadConfig();
            bool base0 = token == t0;
            address quote = base0 ? t1 : t0;
            list[i] = Pool(
                pool,
                pools[i].minLiquidity,
                quote,
                base0,
                IERC20Metadata(token).decimals(),
                IERC20Metadata(quote).decimals()
            );
        }
        _propose(token, abi.encode(list));
    }

    /// @dev Nothing is instant (see the header): even a removal can narrow one side of the router's spread.
    function _lowersOnly(address, bytes memory) internal pure override returns (bool) {
        return false;
    }

    function _set(address token, bytes memory encoded) internal override {
        Pool[] memory list = abi.decode(encoded, (Pool[]));
        delete _pools[token];
        for (uint256 i; i < list.length; ++i) {
            _pools[token].push(list[i]);
        }
    }
}
