// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPriceSource, IRatioSource, IRecentRatio} from "../../interfaces/IPriceSource.sol";
import {SourceAdmin} from "./SourceAdmin.sol";
import {PoolMath} from "./PoolMath.sol";

/// @notice Arbitrum's system contract: the L2 block number (`block.number` on Robinhood Chain is Ethereum's).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/**
 * @title  PriceRecorder
 * @notice Builds a price history for tokens that trade only in Uniswap v4 pools, which keep none (hookless
 *         pools and the Pons hook have no oracle), and prices them at the median of the last 24 hours. The
 *         Thin class: a recorded price, with a size haircut set in the router.
 *
 * @dev    ## Recording (AINDEX's recorders every slot; anyone in a slot's second half)
 *         Time is cut into 10-minute slots. In the first `OPEN_AFTER` (5 minutes) of a slot only the recorders
 *         the owner lists may call `record`; after that anyone may. A recorder marks at the start of the slot and
 *         confirms a minute later, before anyone else can call, so an outsider who records a moved price first
 *         can no longer replace the mark and keep a slot from ever getting its reading (which, slot after slot,
 *         would leave the token unpriced). If the recorders stop, anyone can still record every slot.
 *         A slot gets at most one final reading:
 *         1. The first call in a slot marks the pool's current tick (read from the PoolManager's slot0).
 *         2. A later call in the same slot, at least `CONFIRM_SECONDS` and `CONFIRM_BLOCKS` L2 blocks after
 *            the mark, reads the tick again. If it is within 1% (`MAX_CONFIRM_TICKS`) of the mark, the mark
 *            becomes the slot's final reading. If not, the new tick replaces the mark and needs its own
 *            confirmation.
 *         So a manipulated price only counts if it is held in the open, where anyone can trade against it,
 *         rather than inside one transaction.
 *
 *         The design note asks for 2 blocks. Robinhood Chain makes a block about every 0.1 seconds, and its
 *         `block.number` is Ethereum's block number, not its own (measured 2026-10-01). Two L2 blocks would
 *         be 0.2 seconds, so the confirmation also has to be at least `CONFIRM_SECONDS` later. L2 blocks are
 *         read from ArbSys, falling back to `block.number` where ArbSys does not exist (tests).
 *
 *         ## Price
 *         The median tick of the final readings from the last 143 complete slots (24 hours less the current
 *         slot), in the pool's other side (`IRatioSource`; WETH for a pool paired with native ETH), which the
 *         PriceRouter converts to USD through its own price of it, on the same side and in the same call. Fewer
 *         than `MIN_READINGS` (100) readings: unavailable. Ticks are stored instead of prices: ordering is the
 *         same, a tick fits in 24 bits, and 1% is 100 ticks. `price` answers nothing: the router reads `ratio`.
 *
 *         The current slot never counts, nor the slot its reading would overwrite in the ring: a `record` can
 *         finalise the current slot inside any transaction, and a Fund compares NAV before and after an action in
 *         one transaction, so a reading that could land between the two must not move the price.
 *
 *         `recentRatio` is the newest of those readings: at most two slots old while recorders run. The router
 *         prices the bid from the lower of it and the median and the ask from the higher, so a deposit or an exit
 *         cannot use the median's lag (hours, after a sharp move) against the holders.
 *
 *         ## Cost to corrupt (design note section 4.2)
 *         Moving the median needs a manipulated reading in at least 73 of 144 slots, each held for a minute
 *         against every arbitrageur and paid for in pool and hook fees both ways. That is bounded, not free:
 *         the router's haircut and the Fund's Thin cap are what keep it unprofitable.
 *
 *         Readings live in a ring of 144 entries indexed by slot, four to a storage word, so a price read
 *         costs 36 storage reads. Changing a token's pool waits `CONFIG_DELAY` and clears its readings;
 *         removing it is instant. `price` never reverts for a configured token.
 */
contract PriceRecorder is IPriceSource, IRatioSource, IRecentRatio, SourceAdmin {
    using StateLibrary for IPoolManager;

    error NotConfigured();
    error RecordersOnly();

    enum Recorded {
        Marked, // first reading of the slot, waiting for confirmation
        Waiting, // too soon after the mark to confirm; nothing changed
        Replaced, // disagreed with the mark by more than 1%: this reading is the new mark
        Final, // confirmed the mark: the slot has its reading
        AlreadyFinal, // the slot already has its reading; nothing changed
        NoPool // the pool has no price (not initialised); nothing changed
    }

    struct Config {
        PoolId poolId; // zero: token not priced here
        bool baseIsToken0;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        address quote; // the pool's other side as the router prices it (WETH for a native ETH pool)
    }

    struct Mark {
        uint32 slot;
        int24 tick;
        uint64 l2Block;
        uint64 time;
    }

    uint256 public constant SLOT = 10 minutes;
    uint256 public constant SLOTS = 144; // 24 hours
    uint256 public constant MIN_READINGS = 100;
    uint256 public constant CONFIRM_SECONDS = 60;
    uint256 public constant CONFIRM_BLOCKS = 2;
    /// @dev 1.0001^99 = 1.0099: within 1%.
    int24 public constant MAX_CONFIRM_TICKS = 99;
    /// @notice How far into a slot only listed recorders may call `record`.
    uint256 public constant OPEN_AFTER = 5 minutes;

    uint256 private constant WORDS = SLOTS / 4;
    address private constant ARBSYS = address(100);

    IPoolManager public immutable poolManager;

    mapping(address => Config) private _configs;
    mapping(address => Mark) public markOf;
    /// @notice Callers that may record at any time in a slot.
    mapping(address => bool) public isRecorder;
    /// @dev token => word => four packed readings of 64 bits: slot (32 bits, low) then tick (24 bits).
    mapping(address => uint256[WORDS]) private _ring;

    event Reading(address indexed token, uint32 indexed slot, int24 tick, Recorded result);
    event RecorderSet(address indexed recorder, bool allowed);

    constructor(address owner_, IPoolManager poolManager_) SourceAdmin(owner_) {
        poolManager = poolManager_;
    }

    function name() external pure returns (string memory) {
        return "v4 price recorder";
    }

    function configOf(address token) external view returns (Config memory) {
        return _configs[token];
    }

    // ---- recording ----

    /// @notice Record the pool's current price for this slot. See the contract notes for the rule.
    function record(address token) external returns (Recorded result) {
        if (!isRecorder[msg.sender] && block.timestamp % SLOT < OPEN_AFTER) revert RecordersOnly();
        Config memory c = _configs[token];
        if (PoolId.unwrap(c.poolId) == bytes32(0)) revert NotConfigured();
        uint32 slot = uint32(block.timestamp / SLOT);
        (uint32 have,) = _entry(token, slot % SLOTS);
        if (have == slot) return _emit(token, slot, 0, Recorded.AlreadyFinal);

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(c.poolId);
        if (sqrtPriceX96 == 0) return _emit(token, slot, 0, Recorded.NoPool);

        Mark memory m = markOf[token];
        uint64 l2 = uint64(_l2Block());
        if (m.slot == slot) {
            if (block.timestamp < m.time + CONFIRM_SECONDS || l2 < m.l2Block + CONFIRM_BLOCKS) {
                return _emit(token, slot, tick, Recorded.Waiting);
            }
            int24 diff = tick > m.tick ? tick - m.tick : m.tick - tick;
            if (diff <= MAX_CONFIRM_TICKS) {
                _store(token, slot, m.tick);
                delete markOf[token];
                return _emit(token, slot, m.tick, Recorded.Final);
            }
            markOf[token] = Mark(slot, tick, l2, uint64(block.timestamp));
            return _emit(token, slot, tick, Recorded.Replaced);
        }
        markOf[token] = Mark(slot, tick, l2, uint64(block.timestamp));
        return _emit(token, slot, tick, Recorded.Marked);
    }

    function _emit(address token, uint32 slot, int24 tick, Recorded r) private returns (Recorded) {
        emit Reading(token, slot, tick, r);
        return r;
    }

    function _l2Block() private view returns (uint256) {
        if (ARBSYS.code.length == 0) return block.number;
        // Gas-capped: where ArbSys is only a placeholder (a local fork serves its 0xfe code), a failed call
        // must not burn the caller's gas.
        (bool ok, bytes memory ret) = ARBSYS.staticcall{gas: 30_000}(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (!ok || ret.length < 32) return block.number;
        return abi.decode(ret, (uint256));
    }

    // ---- price ----

    /// @notice Not a USD price: see `ratio`.
    function price(address) external pure returns (uint256, uint64, bool) {
        return (0, 0, false);
    }

    /// @inheritdoc IRatioSource
    function ratio(address token) external view returns (address quote, uint256 ratioWad, uint64 updatedAt, bool ok) {
        Config memory c = _configs[token];
        if (PoolId.unwrap(c.poolId) == bytes32(0)) return (address(0), 0, 0, false);
        quote = c.quote;
        (int24 tick, uint256 count, uint32 newest) = medianTick(token);
        if (count < MIN_READINGS) return (quote, 0, 0, false);
        ratioWad = PoolMath.ratioAtTick(tick, c.baseDecimals, c.baseIsToken0, c.quoteDecimals);
        ok = ratioWad != 0;
        updatedAt = uint64(uint256(newest) * SLOT);
    }

    /// @notice Median tick of the final readings in the `SLOTS - 1` complete slots before the current one, how many
    ///         there are, and the newest one's slot. With an even count, the mean of the middle two, rounded down.
    ///         The current slot is left out (a `record` in this transaction could still finalise it), and so is the
    ///         slot a `record` now would overwrite in the ring.
    function medianTick(address token) public view returns (int24 tick, uint256 count, uint32 newest) {
        (tick, count, newest,) = _median(token);
    }

    /// @dev `medianTick`, and the newest reading's tick.
    function _median(address token)
        private
        view
        returns (int24 tick, uint256 count, uint32 newest, int24 newestTick)
    {
        uint256 cur = block.timestamp / SLOT;
        int24[] memory ticks = new int24[](SLOTS);
        for (uint256 w; w < WORDS; ++w) {
            uint256 word = _ring[token][w];
            if (word == 0) continue;
            for (uint256 j; j < 4; ++j) {
                uint64 e = uint64(word >> (64 * j));
                uint32 s = uint32(e);
                if (s == 0 || s >= cur || s + SLOTS <= cur) continue;
                int24 t = int24(uint24(e >> 32));
                ticks[count++] = t;
                if (s > newest) (newest, newestTick) = (s, t);
            }
        }
        if (count == 0) return (0, 0, 0, 0);
        uint256 k = (count - 1) / 2;
        int24 lo = _select(ticks, 0, count - 1, k);
        if (count % 2 == 1) return (lo, count, newest, newestTick);
        // Even count: the next value up is the smallest of everything right of k after selection.
        int24 hi = ticks[k + 1];
        for (uint256 i = k + 2; i < count; ++i) {
            if (ticks[i] < hi) hi = ticks[i];
        }
        int256 sum = int256(lo) + int256(hi);
        tick = int24(sum >= 0 || sum % 2 == 0 ? sum / 2 : sum / 2 - 1);
    }

    /// @inheritdoc IRecentRatio
    function ratioAndRecent(address token)
        external
        view
        returns (address quote, uint256 ratioWad, uint256 recentWad, uint64 updatedAt, bool ok)
    {
        Config memory c = _configs[token];
        if (PoolId.unwrap(c.poolId) == bytes32(0)) return (address(0), 0, 0, 0, false);
        quote = c.quote;
        (int24 tick, uint256 count, uint32 newest, int24 newestTick) = _median(token);
        if (count < MIN_READINGS) return (quote, 0, 0, 0, false);
        ratioWad = PoolMath.ratioAtTick(tick, c.baseDecimals, c.baseIsToken0, c.quoteDecimals);
        recentWad = PoolMath.ratioAtTick(newestTick, c.baseDecimals, c.baseIsToken0, c.quoteDecimals);
        ok = ratioWad != 0 && recentWad != 0;
        updatedAt = uint64(uint256(newest) * SLOT);
    }

    /// @inheritdoc IRecentRatio
    /// @dev The newest final reading of a complete slot within the median's window (the current slot left out, as
    ///      for the median). Not ok when there is none.
    function recentRatio(address token) external view returns (uint256 ratioWad, bool ok) {
        Config memory c = _configs[token];
        if (PoolId.unwrap(c.poolId) == bytes32(0)) return (0, false);
        uint256 cur = block.timestamp / SLOT;
        for (uint256 back = 1; back < SLOTS && back < cur; ++back) {
            uint256 slot = cur - back;
            (uint32 s, int24 tick) = _entry(token, slot % SLOTS);
            if (s != slot) continue;
            ratioWad = PoolMath.ratioAtTick(tick, c.baseDecimals, c.baseIsToken0, c.quoteDecimals);
            return (ratioWad, ratioWad != 0);
        }
    }

    /// @notice The final reading stored for `slot`, if it is still in the ring.
    function readingAt(address token, uint32 slot) external view returns (bool found, int24 tick) {
        (uint32 s, int24 t) = _entry(token, slot % SLOTS);
        return (s == slot && s != 0, t);
    }

    /// @dev Quickselect (Hoare): after it returns, a[k] is the k-th smallest of a[lo..hi], everything left of
    ///      k is no larger and everything right of k is no smaller.
    function _select(int24[] memory a, uint256 lo, uint256 hi, uint256 k) internal pure returns (int24) {
        while (lo < hi) {
            int24 pivot = a[(lo + hi) / 2];
            uint256 i = lo;
            uint256 j = hi;
            while (i <= j) {
                while (a[i] < pivot) ++i;
                while (a[j] > pivot) --j;
                if (i <= j) {
                    (a[i], a[j]) = (a[j], a[i]);
                    ++i;
                    if (j == 0) break;
                    --j;
                }
            }
            if (k <= j) hi = j;
            else if (k >= i) lo = i;
            else return a[k];
        }
        return a[k];
    }

    function _entry(address token, uint256 index) private view returns (uint32 slot, int24 tick) {
        uint64 e = uint64(_ring[token][index / 4] >> (64 * (index % 4)));
        return (uint32(e), int24(uint24(e >> 32)));
    }

    function _store(address token, uint32 slot, int24 tick) internal {
        uint256 index = slot % SLOTS;
        uint256 shift = 64 * (index % 4);
        uint256 e = uint256(slot) | (uint256(uint24(tick)) << 32);
        uint256 word = _ring[token][index / 4];
        word = (word & ~(uint256(type(uint64).max) << shift)) | (e << shift);
        _ring[token][index / 4] = word;
    }

    // ---- configuration ----

    /// @notice Owner: allow or stop a recorder (AINDEX's keeper) recording at any time in a slot.
    function setRecorder(address recorder, bool allowed) external onlyOwner {
        isRecorder[recorder] = allowed;
        emit RecorderSet(recorder, allowed);
    }

    /// @notice Record `token` from the v4 pool `key`; the router prices its other side as `quote` (the other
    ///         currency itself, or WETH for native ETH). Pass a key with zero currencies and a zero quote to remove
    ///         the token, which applies at once.
    function propose(address token, PoolKey calldata key, address quote) external onlyOwner {
        Config memory c;
        if (quote != address(0)) {
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            if (token == address(0) || (token != c0 && token != c1) || quote == token) revert BadConfig();
            address other = token == c0 ? c1 : c0;
            if (other != address(0) && other != quote) revert BadConfig();
            c.poolId = key.toId();
            c.baseIsToken0 = token == c0;
            c.baseDecimals = IERC20Metadata(token).decimals();
            c.quoteDecimals = other == address(0) ? 18 : IERC20Metadata(other).decimals();
            c.quote = quote;
        }
        _propose(token, abi.encode(c));
    }

    /// @dev Only removal is instant: a new pool or quote can move the price either way.
    function _lowersOnly(address, bytes memory encoded) internal pure override returns (bool) {
        return PoolId.unwrap(abi.decode(encoded, (Config)).poolId) == bytes32(0);
    }

    /// @dev A different pool (or removal) clears the history: readings from another pool are not this price.
    function _set(address token, bytes memory encoded) internal override {
        Config memory next = abi.decode(encoded, (Config));
        if (PoolId.unwrap(next.poolId) != PoolId.unwrap(_configs[token].poolId)) {
            delete _ring[token];
            delete markOf[token];
        }
        _configs[token] = next;
    }
}
