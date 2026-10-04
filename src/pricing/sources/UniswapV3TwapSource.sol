// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceSource, IRatioSource, IRecentRatio} from "../../interfaces/IPriceSource.sol";
import {SourceAdmin} from "./SourceAdmin.sol";
import {PoolMath} from "./PoolMath.sol";

/// @notice Robinhood stock tokens: Robinhood pauses the token's oracle during corporate actions.
interface IPausableStockToken {
    function oraclePaused() external view returns (bool);
}

/// @notice The part of a Uniswap v3 pool this source reads.
interface IUniswapV3PoolOracle {
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
 * @title  UniswapV3TwapSource
 * @notice Prices a token from a Uniswap v3 pool's time-weighted average tick over a fixed window, in the pool's
 *         other token (`IRatioSource`): the PriceRouter converts that to USD through its own price of the other
 *         token, on the same side and in the same call, so the pool may be paired with anything the router
 *         prices (USDG, WETH, cbBTC, another stock token). For tokens with no feed but a deep, long-running v3
 *         pool: the Pool class (a chained price takes the worse of its own class and its quote's).
 *
 * @dev    ## Rules
 *         - The window is at least 30 minutes; a shorter one is refused at configuration. Morpho's long-tail
 *           markets on this chain use 60 seconds, which one well-funded trader can hold off-market.
 *         - The pool's oldest stored observation must be at least `window` old, so the average really
 *           spans the window. Otherwise the price is unavailable (ok = false), never a shorter average.
 *           Anyone can lengthen a pool's history with `increaseObservationCardinalityNext`.
 *         - The mean tick is rounded towards negative infinity, as Uniswap's OracleLibrary does.
 *         - `recentRatio` is the same pool over its last `RECENT_WINDOW` (one minute). The router prices the bid
 *           from the lower of it and the window's average and the ask from the higher, so a deposit or an exit
 *           cannot use the average's lag against the holders. It cannot move within a block either: a pool
 *           writes at most one observation per second, with the price from before that second's trades, so the
 *           cumulatives up to now are fixed for the whole block; moving it means holding the pool off market for
 *           seconds against every arbitrageur, and doing so only worsens the price for whoever does it.
 *         - For a Robinhood stock token without a feed (`checkPause`), the token's `oraclePaused()` must be
 *           false. During a corporate action (a split, a multiplier change) the pool's history mixes prices
 *           of tokens worth different amounts, so the average means nothing until it is over.
 *
 *         ## Market holidays
 *         This source does not implement `ISessionSource`. It has no age rule of its own (the average always
 *         ends now, and pools trade while the stock market is closed), so a "last price ignoring age" would
 *         be the same answer as `price`. The router's closed-market spread still applies to the token.
 *
 *         ## What this cannot see
 *         An idle pool answers `observe` happily by carrying one old observation forward, and a thin pool's
 *         average is cheap to move for a whole window. Whether a pool is deep and traded enough to trust is
 *         decided when a token is classed (depth, age, impact), not here. Use this source as the router's
 *         `check` next to a feed where both exist.
 *
 *         Configuration: changing a token's pool or window waits `CONFIG_DELAY`; removing it is instant. `ratio`
 *         never reverts for a configured token. `price` answers nothing (ok = false): a USD price needs the
 *         router's conversion, so the router reads `ratio` (its configuration marks this source as chained).
 */
contract UniswapV3TwapSource is IPriceSource, IRatioSource, IRecentRatio, SourceAdmin {
    struct Twap {
        IUniswapV3PoolOracle pool; // zero: token not priced here
        uint32 window; // seconds
        address quote; // the pool's other token, which the router prices
        bool baseIsToken0; // filled when proposed
        uint8 baseDecimals; // filled when proposed
        uint8 quoteDecimals; // filled when proposed
        bool checkPause; // a Robinhood stock token: also require !token.oraclePaused()
    }

    uint32 public constant MIN_WINDOW = 30 minutes;
    /// @notice The recent price's window (`recentRatio`).
    uint32 public constant RECENT_WINDOW = 1 minutes;
    /// @dev A v3 pool keeps at most 65,535 observations; a week is already more than most pools hold.
    uint32 public constant MAX_WINDOW = 7 days;

    mapping(address => Twap) private _twaps;

    constructor(address owner_) SourceAdmin(owner_) {}

    function name() external pure returns (string memory) {
        return "Uniswap v3 TWAP";
    }

    function twapOf(address token) external view returns (Twap memory) {
        return _twaps[token];
    }

    // ---- price ----

    /// @notice Not a USD price: see `ratio`.
    function price(address) external pure returns (uint256, uint64, bool) {
        return (0, 0, false);
    }

    /// @inheritdoc IRatioSource
    function ratio(address token) external view returns (address quote, uint256 ratioWad, uint64 updatedAt, bool ok) {
        Twap memory t = _twaps[token];
        if (address(t.pool) == address(0)) return (address(0), 0, 0, false);
        quote = t.quote;
        if (t.checkPause && _paused(token)) return (quote, 0, 0, false);
        if (historySeconds(t.pool) < t.window) return (quote, 0, 0, false);
        int24 tick;
        (tick, ok) = _meanTick(t.pool, t.window);
        if (!ok) return (quote, 0, 0, false);
        ratioWad = PoolMath.ratioAtTick(tick, t.baseDecimals, t.baseIsToken0, t.quoteDecimals);
        ok = ratioWad != 0;
        updatedAt = uint64(block.timestamp);
    }

    /// @inheritdoc IRecentRatio
    function ratioAndRecent(address token)
        external
        view
        returns (address quote, uint256 ratioWad, uint256 recentWad, uint64 updatedAt, bool ok)
    {
        Twap memory t = _twaps[token];
        if (address(t.pool) == address(0)) return (address(0), 0, 0, 0, false);
        quote = t.quote;
        if (t.checkPause && _paused(token)) return (quote, 0, 0, 0, false);
        if (historySeconds(t.pool) < t.window) return (quote, 0, 0, 0, false);
        uint32[] memory ago = new uint32[](3);
        ago[0] = t.window;
        ago[1] = RECENT_WINDOW;
        try t.pool.observe(ago) returns (int56[] memory c, uint160[] memory) {
            if (c.length != 3) return (quote, 0, 0, 0, false);
            ratioWad = PoolMath.ratioAtTick(_mean(c[2] - c[0], t.window), t.baseDecimals, t.baseIsToken0, t.quoteDecimals);
            recentWad =
                PoolMath.ratioAtTick(_mean(c[2] - c[1], RECENT_WINDOW), t.baseDecimals, t.baseIsToken0, t.quoteDecimals);
        } catch {
            return (quote, 0, 0, 0, false);
        }
        ok = ratioWad != 0 && recentWad != 0;
        updatedAt = uint64(block.timestamp);
    }

    /// @inheritdoc IRecentRatio
    function recentRatio(address token) external view returns (uint256 ratioWad, bool ok) {
        Twap memory t = _twaps[token];
        if (address(t.pool) == address(0)) return (0, false);
        if (t.checkPause && _paused(token)) return (0, false);
        int24 tick;
        (tick, ok) = _meanTick(t.pool, RECENT_WINDOW);
        if (!ok) return (0, false);
        ratioWad = PoolMath.ratioAtTick(tick, t.baseDecimals, t.baseIsToken0, t.quoteDecimals);
        ok = ratioWad != 0;
    }

    /// @notice How far back the pool's stored observations reach, in seconds (0 if unreadable).
    function historySeconds(IUniswapV3PoolOracle pool) public view returns (uint256) {
        uint16 index;
        uint16 cardinality;
        try pool.slot0() returns (uint160, int24, uint16 i, uint16 c, uint16, uint8, bool) {
            (index, cardinality) = (i, c);
        } catch {
            return 0;
        }
        if (cardinality == 0) return 0;
        // The slot after the newest is the oldest once the ring has filled; before that it is slot 0.
        (uint32 oldest, bool initialized) = _observation(pool, (uint256(index) + 1) % cardinality);
        if (!initialized) (oldest, initialized) = _observation(pool, 0);
        if (!initialized || oldest > block.timestamp) return 0;
        return block.timestamp - oldest;
    }

    function _paused(address token) private view returns (bool) {
        try IPausableStockToken(token).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return true; // configured as a stock token but cannot say: treat as paused
        }
    }

    function _observation(IUniswapV3PoolOracle pool, uint256 i) private view returns (uint32 ts, bool initialized) {
        try pool.observations(i) returns (uint32 t, int56, uint160, bool init) {
            return (t, init);
        } catch {
            return (0, false);
        }
    }

    function _meanTick(IUniswapV3PoolOracle pool, uint32 window) private view returns (int24 tick, bool ok) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        try pool.observe(ago) returns (int56[] memory cumulatives, uint160[] memory) {
            if (cumulatives.length != 2) return (0, false);
            return (_mean(cumulatives[1] - cumulatives[0], window), true);
        } catch {
            return (0, false);
        }
    }

    /// @dev The mean tick of a cumulative `delta` over `window`, rounded towards negative infinity.
    function _mean(int56 delta, uint32 window) private pure returns (int24) {
        int56 mean = delta / int56(uint56(window));
        if (delta < 0 && delta % int56(uint56(window)) != 0) mean--;
        return int24(mean);
    }

    // ---- configuration ----

    /// @notice Price `token` from `pool` over `window` seconds, in the pool's other token (which the router must
    ///         price). `checkPause` for Robinhood stock tokens. Pass a zero pool to remove the token, which applies
    ///         at once.
    function propose(address token, IUniswapV3PoolOracle pool, uint32 window, bool checkPause) external onlyOwner {
        Twap memory t;
        if (address(pool) != address(0)) {
            if (window < MIN_WINDOW || window > MAX_WINDOW) revert BadConfig();
            address t0 = pool.token0();
            address t1 = pool.token1();
            if (token != t0 && token != t1) revert BadConfig();
            t.pool = pool;
            t.window = window;
            t.baseIsToken0 = token == t0;
            t.quote = t.baseIsToken0 ? t1 : t0;
            t.baseDecimals = IERC20Metadata(token).decimals();
            t.quoteDecimals = IERC20Metadata(t.quote).decimals();
            t.checkPause = checkPause;
        }
        _propose(token, abi.encode(t));
    }

    /// @dev Instant: removal, or turning the pause check on with nothing else changed. A new window or pool
    ///      can move the price either way, and dropping the pause check loosens it, so those wait.
    function _lowersOnly(address token, bytes memory encoded) internal view override returns (bool) {
        Twap memory next = abi.decode(encoded, (Twap));
        if (address(next.pool) == address(0)) return true;
        Twap memory cur = _twaps[token];
        return address(cur.pool) != address(0) && next.pool == cur.pool && next.window == cur.window
            && (next.checkPause || !cur.checkPause);
    }

    function _set(address token, bytes memory encoded) internal override {
        _twaps[token] = abi.decode(encoded, (Twap));
    }
}
