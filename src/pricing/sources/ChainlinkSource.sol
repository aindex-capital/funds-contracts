// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceSource} from "../../interfaces/IPriceSource.sol";
import {ISessionSource} from "../../interfaces/ISessionSource.sol";
import {SourceAdmin} from "./SourceAdmin.sol";

/// @notice The part of a Chainlink aggregator proxy this source reads.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Robinhood stock tokens: Robinhood pauses the token's oracle during corporate actions.
interface IStockToken {
    function oraclePaused() external view returns (bool);
}

/**
 * @title  ChainlinkSource
 * @notice Prices tokens from Chainlink Data Feeds: USD per whole token, 18 decimals.
 *
 * @dev    ## What makes a reading usable
 *         - the answer is above zero;
 *         - the round is complete (`updatedAt` set, not in the future, `answeredInRound >= roundId`);
 *         - it is no older than the token's `maxAge`. Every feed on Robinhood Chain has a 24 hour heartbeat
 *           and a 0.5% deviation threshold, so 26 hours is the normal setting;
 *         - for a Robinhood stock token (`checkPause`), the token's own `oraclePaused()` is false. Robinhood
 *           sets it during corporate actions (splits, multiplier changes), when the feed may hold a price
 *           that no longer matches what one token is worth;
 *         - when a sequencer uptime feed is set, the sequencer is up and has been for `SEQUENCER_GRACE`.
 *           Chainlink publishes no sequencer uptime feed for Robinhood Chain (checked 2026-10-01), so this
 *           stays unset until one exists.
 *
 *         ## Stock feeds are closed at the weekend
 *         Stock and ETF feeds follow US equities 24/5 and do not heartbeat while the market is shut: NVDA's
 *         feed went from Friday 19:55 UTC to Monday 00:00 UTC (52 hours) without a round. For a feed marked
 *         `weekendClosed`, time between Saturday 00:00 and Monday 00:00 UTC does not count towards its age,
 *         so the price stays usable over a normal weekend and a feed that stops mid-week is still caught.
 *         A Monday holiday is not skipped: the feed then goes unavailable for the rest of that day.
 *         Widening bid and ask while the market is closed is the router's job, not this source's.
 *
 *         ## Stock feeds already include the dividend multiplier
 *         A stock feed answers USD per raw token unit: the share price times the token's `uiMultiplier`.
 *         So value = answer x `balanceOf` (raw), never x `balanceOfUI`, which would count the multiplier
 *         twice. Measured on chain 2026-10-01 (see the fork test): `balanceOfUI / balanceOf` equals
 *         `uiMultiplier` exactly, and the feeds sit on Robinhood's quote times the multiplier (SGOV, with a
 *         1.0072 multiplier, reads 0.2% from quote x multiplier and 0.5% from the bare share quote).
 *
 *         ## Exchange-rate feeds
 *         A feed quoted in another asset (syrupUSDG / USDG, wstETH / stETH) sets `quoteSource` and
 *         `quoteToken`; the answer is then multiplied by that token's USD price from the other source.
 *
 *         ## Holidays: `lastPrice`
 *         The weekend skip above does not cover a market holiday. For that the router (with the token marked
 *         as a US-session token) asks `lastPrice`: every check here except age, with the round's own
 *         `updatedAt`, and decides itself whether the reading was fresh enough when the market closed.
 *
 *         `price` and `lastPrice` never revert for a configured token: every outside call is caught and
 *         reported as `ok = false`.
 */
contract ChainlinkSource is IPriceSource, ISessionSource, SourceAdmin {
    struct Feed {
        IChainlinkFeed feed; // zero: token not priced here
        uint32 maxAge; // seconds a reading stays usable (weekend hours excluded when weekendClosed)
        bool checkPause; // a Robinhood stock token: also require !token.oraclePaused()
        bool weekendClosed; // a 24/5 feed: Saturday and Sunday (UTC) do not count towards its age
        IPriceSource quoteSource; // optional: the feed is quoted in quoteToken, priced by this source
        address quoteToken;
        uint8 decimals; // the feed's decimals, read when proposed
    }

    uint256 public constant SEQUENCER_GRACE = 1 hours;
    /// @dev Longest age a configuration may allow. Longer would hide a dead feed for days.
    uint32 public constant MAX_AGE_LIMIT = 3 days;

    /// @dev 1970-01-03, the first Saturday 00:00 UTC after the epoch.
    uint256 private constant FIRST_SATURDAY = 2 days;
    uint256 private constant WEEK = 7 days;
    uint256 private constant WEEKEND = 2 days;

    mapping(address => Feed) private _feeds;
    /// @notice L2 sequencer uptime feed; unset on Robinhood Chain until Chainlink publishes one.
    IChainlinkFeed public sequencer;

    event SequencerSet(address feed);

    constructor(address owner_) SourceAdmin(owner_) {}

    function name() external pure returns (string memory) {
        return "Chainlink";
    }

    function feedOf(address token) external view returns (Feed memory) {
        return _feeds[token];
    }

    // ---- price ----

    function price(address token) external view returns (uint256 usd, uint64 updatedAt, bool ok) {
        return _price(token, true);
    }

    /// @notice The latest reading with every check except its age; `updatedAt` is the round's. For the router
    ///         while the token's market is closed (ISessionSource).
    function lastPrice(address token) external view returns (uint256 usd, uint64 updatedAt, bool ok) {
        return _price(token, false);
    }

    function _price(address token, bool checkAge) private view returns (uint256 usd, uint64 updatedAt, bool ok) {
        Feed memory f = _feeds[token];
        if (address(f.feed) == address(0)) return (0, 0, false);
        if (!_sequencerUp()) return (0, 0, false);
        if (f.checkPause && _paused(token)) return (0, 0, false);

        uint256 at;
        (usd, at, ok) = _read(f, checkAge);
        if (!ok) return (0, 0, false);
        updatedAt = uint64(at);

        if (address(f.quoteSource) != address(0)) {
            try f.quoteSource.price(f.quoteToken) returns (uint256 q, uint64 qAt, bool qOk) {
                if (!qOk || q == 0) return (0, 0, false);
                usd = usd * q / 1e18;
                if (qAt < updatedAt) updatedAt = qAt;
            } catch {
                return (0, 0, false);
            }
        }
        if (usd == 0) return (0, 0, false);
    }

    /// @notice Seconds of a reading's age that count against `maxAge`: the plain age, less any weekend
    ///         time when the feed is marked closed at weekends.
    function countedAge(address token, uint256 updatedAt) public view returns (uint256) {
        return _age(_feeds[token].weekendClosed, updatedAt);
    }

    function _age(bool weekendClosed, uint256 at) private view returns (uint256 age) {
        if (at >= block.timestamp) return 0;
        age = block.timestamp - at;
        if (weekendClosed) age -= _weekendSeconds(block.timestamp) - _weekendSeconds(at);
    }

    function _read(Feed memory f, bool checkAge) private view returns (uint256 usd, uint256 updatedAt, bool ok) {
        try f.feed.latestRoundData() returns (uint80 roundId, int256 answer, uint256, uint256 at, uint80 answeredIn) {
            if (answer <= 0) return (0, 0, false);
            if (at == 0 || at > block.timestamp || answeredIn < roundId) return (0, 0, false);
            if (checkAge && _age(f.weekendClosed, at) > f.maxAge) return (0, 0, false);
            return (uint256(answer) * 1e18 / 10 ** f.decimals, at, true);
        } catch {
            return (0, 0, false);
        }
    }

    function _paused(address token) private view returns (bool) {
        try IStockToken(token).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return true; // configured as a stock token but cannot say: treat as paused
        }
    }

    /// @dev Chainlink's uptime feed answers 0 when the sequencer is up, 1 when down; `startedAt` is when that
    ///      status began. After a restart, wait the grace period so feeds can catch up first.
    function _sequencerUp() private view returns (bool) {
        IChainlinkFeed s = sequencer;
        if (address(s) == address(0)) return true;
        try s.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (answer != 0 || startedAt == 0) return false;
            return block.timestamp >= startedAt + SEQUENCER_GRACE;
        } catch {
            return false;
        }
    }

    /// @dev Weekend seconds (Saturday 00:00 to Monday 00:00 UTC) between the first Saturday and `t`.
    function _weekendSeconds(uint256 t) private pure returns (uint256) {
        if (t <= FIRST_SATURDAY) return 0;
        uint256 since = t - FIRST_SATURDAY;
        uint256 inWeek = since % WEEK;
        return (since / WEEK) * WEEKEND + (inWeek < WEEKEND ? inWeek : WEEKEND);
    }

    // ---- configuration ----

    /// @notice Set, change or remove (`feed` = 0) a token's feed. Removing it or tightening its limits
    ///         applies at once; anything else waits `CONFIG_DELAY`.
    function propose(address token, Feed calldata f) external onlyOwner {
        Feed memory next = f;
        if (address(f.feed) != address(0)) {
            if (f.maxAge == 0 || f.maxAge > MAX_AGE_LIMIT) revert BadConfig();
            if ((address(f.quoteSource) == address(0)) != (f.quoteToken == address(0))) revert BadConfig();
            if (address(f.quoteSource) == address(this) && f.quoteToken == token) revert BadConfig();
            next.decimals = f.feed.decimals();
            if (next.decimals > 36) revert BadConfig();
        } else {
            next = Feed(IChainlinkFeed(address(0)), 0, false, false, IPriceSource(address(0)), address(0), 0);
        }
        _propose(token, abi.encode(next));
    }

    /// @notice Set or clear the sequencer uptime feed. Instant: it can only make prices unavailable.
    function setSequencer(address feed) external onlyOwner {
        sequencer = IChainlinkFeed(feed);
        emit SequencerSet(feed);
    }

    function _lowersOnly(address token, bytes memory encoded) internal view override returns (bool) {
        Feed memory next = abi.decode(encoded, (Feed));
        if (address(next.feed) == address(0)) return true;
        Feed memory cur = _feeds[token];
        return address(cur.feed) != address(0) && next.feed == cur.feed && next.quoteSource == cur.quoteSource
            && next.quoteToken == cur.quoteToken && next.maxAge <= cur.maxAge && (next.checkPause || !cur.checkPause)
            && (!next.weekendClosed || cur.weekendClosed);
    }

    function _set(address token, bytes memory encoded) internal override {
        _feeds[token] = abi.decode(encoded, (Feed));
    }
}
