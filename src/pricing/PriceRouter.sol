// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceRouter, PriceClass, Side} from "../interfaces/IPriceRouter.sol";
import {IPriceSource, IRatioSource, IRecentRatio} from "../interfaces/IPriceSource.sol";
import {ISessionSource} from "../interfaces/ISessionSource.sol";
import {IClosedMarketSource} from "../interfaces/IClosedMarketSource.sol";
import {ILookThrough, ILookThroughRegistry} from "../interfaces/ILookThrough.sol";

/**
 * @title  PriceRouter
 * @notice One place every Fund reads prices from. Each token has a class (how well it can be priced), a
 *         primary source, an optional second source that must agree with it, and a haircut that sets the bid
 *         and ask around the fair price. A token with no configuration is class None: worth zero in NAV.
 *
 * @dev    Classes are measurements AINDEX publishes, not limits: each Fund's owner decides how much of each
 *         class its Fund may hold. Because every Fund's NAV depends on this contract, configuration changes
 *         that could raise a token's value wait `CONFIG_DELAY`; changes that can only lower it (downgrading a
 *         class, raising a haircut) apply at once, and cancel any raise still pending for that token, so an
 *         emergency downgrade is never undone by an older announcement landing later.
 *
 *         Downgrading to None makes a token worth zero as an asset, which would make a debt in it look free.
 *         Funds therefore treat a debt in a None token as unpriceable (their book is incomplete), so an
 *         instant downgrade can never raise a borrower's NAV.
 *
 *         Reads never revert: a source that reverts, or a value too large to compute, reads as unavailable.
 *         The router trusts each source's own `ok` for staleness; sources must also be unmovable within a
 *         block (oracle feeds, time-weighted or recorded prices), because Funds compare NAV before and after
 *         an action in the same transaction.
 *
 *         ## Pool prices lag: the worse of the average and the recent price
 *         A price from a pool (a 30-minute TWAP, a 24-hour recorded median) trails the market. Minting and
 *         redeeming at it alone would let anyone who sees the market move first enter cheap or leave rich against
 *         the holders. So when the primary source also gives a recent price that still cannot move within a block
 *         (`IRecentRatio`: the pool's last minute, the newest recorded reading), the bid is taken from the lower of
 *         the two and the ask from the higher, each with the token's haircut; fair stays the average. Bending the
 *         recent price only worsens the price of whoever bends it, as with the weekend rule below. Funds also cap
 *         what one day moves in and out of a Fund that holds such tokens (`Teller.poolFlowBps`).
 *
 *         ## Markets that close (US stocks and ETFs)
 *         A token marked `usSession` follows Robinhood's 24/5 stock market, which trades from Sunday 20:00 to
 *         Friday 20:00 New York time and stops on US market holidays. New York's clock moves for daylight
 *         saving, so in UTC the market shuts at Saturday 00:00 (summer) or 01:00 (winter) and opens again at
 *         Monday 00:00 (summer) or 01:00 (winter). The router takes the safe side of both all year: closed from
 *         Saturday 00:00 to Monday 01:00 UTC, and for every holiday in its calendar from that day's 00:00 to
 *         01:00 UTC the day after. It may call the market closed for an hour while it trades, never open while
 *         it does not.
 *
 *         A reopened market is not yet a new price: the feed's last round is still Friday's until its first round
 *         of the new session. So a token counts as open only once its primary source has a reading from at or
 *         after the reopening (20:00 New York time: 00:00 UTC while New York keeps summer time, 01:00 UTC
 *         otherwise, by the US rule since 2007); until then it is still in the closure that just ended, with its
 *         worse-of prices and its caps (`marketClosed`, `lastClosedSince`). Feeds give that round within a
 *         minute of the reopening (measured 2026-09-28: SPY, AAPL and SGOV at 00:00:40 to 00:00:48 UTC). A feed with
 *         no reading `REOPEN_GRACE` after the reopening is unavailable. The same holds after a holiday. While
 *         closed:
 *         - if the token has a closed-market source (`Session.closedSource`, a deep USDG pool's 30-minute
 *           time-weighted price held within a band of the last feed price, `SessionPoolSource`) and it qualifies,
 *           the "worse-of" rule applies: `lo = min(pool, last)`, `hi = max(pool, last)`, where `last` is the feed's
 *           last price; ask = `hi * (1 + s)`, bid = `lo * (1 - s)`, fair = `(lo + hi) / 2`, with `s` the token's
 *           `closedSpreadBps` (AINDEX proposes 50 for ETFs, 100 for megacaps, 300 for volatile names). Entrants pay
 *           the ask and leavers get the bid, so moving the pool can only make entrants pay more or leavers get
 *           less: nobody gains by bending it. Measured over 14 weekends of feeds and two of pools, `s` = 0.5% left
 *           the worst holder edge at 0.02%;
 *         - otherwise (no source, or the pool does not qualify) bid and ask widen around `last` by the token's
 *           `closedHaircutBps` on top of its haircut (the fallback: AINDEX proposes 450 for single stocks and 100
 *           for ETFs, so 5% and 1.5% in all with the 50 bps haircut);
 *         - if a source calls its price stale, the router asks it (when it implements `ISessionSource`) for its
 *           last reading and accepts it when that reading is no older than `PRE_CLOSE_AGE` at the moment the
 *           closure began. So Funds holding stocks keep working through a Monday holiday instead of freezing.
 *         Holidays are added `CONFIG_DELAY` ahead (an added day makes stale prices usable) and removed at
 *         once. Session settings wait the delay unless they only widen the closed spreads (raising `s` or the
 *         fallback is the emergency lever, at once); a new or removed closed-market source, a narrower spread or
 *         dropping the session altogether waits.
 *
 *         ## Look-through
 *         A wrapper token (an AINDEX index share) may name an `ILookThrough` that says what it holds. Funds
 *         value the wrapper at its own price but judge class caps on its contents. Setting, changing or
 *         clearing one can loosen a cap either way, so every change waits `CONFIG_DELAY`.
 */
contract PriceRouter is IPriceRouter, ILookThroughRegistry {
    error NotOwner();
    error NotReady();
    error BadConfig();

    struct Config {
        IPriceSource primary;
        IPriceSource check; // optional; when set, the two must agree within maxDeviationBps
        PriceClass class_;
        uint16 haircutBps; // bid = fair * (1 - h), ask = fair * (1 + h)
        uint16 maxDeviationBps;
        uint8 decimals;
        uint8 chained; // bit 1: `primary` is an `IRatioSource`; bit 2: `check` is (priced in another token)
    }

    /// @notice How a token's market keeps hours. Default: always open.
    struct Session {
        bool usSession; // closed at weekends and on calendar holidays
        uint16 closedHaircutBps; // fallback: added to the haircut while closed when no closed-market price qualifies
        uint16 closedSpreadBps; // `s` of the worse-of rule while closed and the closed-market source qualifies
        uint16 closedClampBps; // each closed-market price is held within this of the last feed price
        IClosedMarketSource closedSource; // zero: always the fallback while closed
    }

    /// @dev Where a US-session token stands on the closure calendar, and what its sources' readings showed: the
    ///      current closure's start (calendar), or while open the last reopening and the closure it ended; `stale`
    ///      when a source's reading is from before that reopening (still the closure), `dead` when it still is
    ///      `REOPEN_GRACE` after it.
    struct Clock {
        uint256 closedAt;
        uint256 opened;
        uint256 since;
        bool stale;
        bool dead;
    }

    uint64 public constant CONFIG_DELAY = 1 days;
    /// @notice While a market is closed, a last reading is usable if it was at most this old when the closure
    ///         began. Matches a 24 hour heartbeat with slack, like the sources' own `maxAge`.
    uint64 public constant PRE_CLOSE_AGE = 26 hours;
    /// @notice Longest closure the router looks back over (a long weekend plus a few holidays).
    uint256 public constant MAX_CLOSED_DAYS = 6;
    /// @dev 1970-01-03, the first Saturday 00:00 UTC after the epoch.
    uint256 private constant FIRST_SATURDAY_DAY = 2;
    /// @notice The market reopens at 20:00 New York time: 00:00 UTC in summer, 01:00 UTC in winter. The first
    ///         hour of a UTC day after a closed day therefore counts as closed all year.
    uint256 public constant REOPEN_LAG = 1 hours;
    /// @notice A US-session token whose primary source has no reading this long after the market reopened is
    ///         unavailable: its feed has stopped, and the closure's last price must not carry on into the week.
    uint256 public constant REOPEN_GRACE = 26 hours;
    /// @notice Longest chain of prices in other tokens: a token priced in a quote priced in another quote, and so
    ///         on, ends in a USD price within this many steps.
    uint256 public constant MAX_HOPS = 3;
    /// @dev Seed of the transient quote cache's slots (`warm`).
    bytes32 private constant CACHE_SEED = keccak256("aindex.priceRouter.quoteCache");
    /// @dev Transient slot of the closure calendar worked out once per transaction by `warm` (`_clock`).
    bytes32 private constant CLOCK_SLOT = keccak256("aindex.priceRouter.clock");

    address public owner;
    address public pendingOwner;
    mapping(address => Config) private _config;
    mapping(address => Config) public pendingConfig;
    mapping(address => uint64) public pendingAt;

    mapping(address => Session) private _session;
    mapping(address => Session) public pendingSession;
    mapping(address => uint64) public pendingSessionAt;
    /// @notice UTC day number (timestamp / 1 days) => when it starts counting as a holiday (0: not one).
    mapping(uint256 => uint64) public holidayFrom;

    mapping(address => ILookThrough) public lookThrough;
    mapping(address => ILookThrough) public pendingLookThrough;
    mapping(address => uint64) public pendingLookThroughAt;

    event ConfigProposed(address indexed token, uint64 effectiveAt);
    event PendingCancelled(address indexed token);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SessionProposed(
        address indexed token,
        bool usSession,
        uint16 closedHaircutBps,
        uint16 closedSpreadBps,
        address closedSource,
        uint64 effectiveAt
    );
    event SessionApplied(
        address indexed token, bool usSession, uint16 closedHaircutBps, uint16 closedSpreadBps, address closedSource
    );
    event HolidayAdded(uint256 indexed day, uint64 effectiveAt);
    event HolidayRemoved(uint256 indexed day);
    event LookThroughProposed(address indexed token, address lookThrough, uint64 effectiveAt);
    event LookThroughApplied(address indexed token, address lookThrough);
    event ConfigApplied(address indexed token, PriceClass class_, address primary, address check, uint16 haircutBps);

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---- reads ----

    function classOf(address token) external view returns (PriceClass) {
        return _config[token].class_;
    }

    function config(address token) external view returns (Config memory) {
        return _config[token];
    }

    function quote(address token) public view returns (Quote memory q) {
        (bool hit, Quote memory cached,) = _cached(token);
        if (hit) return cached;
        (q,) = _quote(token);
    }

    /**
     * @notice Price `tokens` once for the rest of this transaction: later `quote` and `value` calls in the same
     *         transaction read the result from transient storage instead of asking the sources again. Anyone may
     *         call it; it stores only what the sources say now, and transient storage is gone when the
     *         transaction ends.
     * @dev    Sound because every source must be unmovable within a block (see the header) and the clock, which
     *         decides the session, does not move within a transaction. A source that could still move inside
     *         one (a price recorded mid-transaction) reads the same until `release` instead, so a
     *         before-and-after comparison can only become more consistent. A settlement reads each token a dozen
     *         times or more (every adapter values its positions before and after), so the teller warms its
     *         tokens first and releases them when it is done, so nothing after its call reads its cache.
     */
    function warm(address[] calldata tokens) external {
        _warmClock();
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            (bool hit,, uint256 s) = _cached(t);
            if (hit) continue;
            (Quote memory q, bool closed) = _quote(t);
            uint256 meta = uint256(_flags(t, closed)) << 25 | 1 << 24 | uint256(_config[t].decimals) << 9
                | (q.available ? 1 << 8 : 0) | uint256(q.class_);
            uint256 fair = q.fair;
            uint256 bid = q.bid;
            uint256 ask = q.ask;
            assembly ("memory-safe") {
                tstore(s, meta)
                tstore(add(s, 1), fair)
                tstore(add(s, 2), bid)
                tstore(add(s, 3), ask)
            }
        }
    }

    /// @notice Forget every quote `warm` cached in this transaction. Anyone; it only makes later reads ask the
    ///         sources again.
    function release() external {
        bytes32 e = CACHE_SEED;
        assembly ("memory-safe") {
            tstore(e, add(tload(e), 1))
        }
    }

    /// @dev Transient slots of `token`'s cached quote in the current generation (`release` starts a new one):
    ///      meta (present, decimals, available, class), fair, bid, ask.
    function _cached(address token) private view returns (bool hit, Quote memory q, uint256 s) {
        bytes32 e = CACHE_SEED;
        uint256 gen;
        assembly ("memory-safe") {
            gen := tload(e)
        }
        s = uint256(keccak256(abi.encode(e, gen, token)));
        uint256 meta;
        assembly ("memory-safe") {
            meta := tload(s)
        }
        if (meta == 0) return (false, q, s);
        uint256 fair;
        uint256 bid;
        uint256 ask;
        assembly ("memory-safe") {
            fair := tload(add(s, 1))
            bid := tload(add(s, 2))
            ask := tload(add(s, 3))
        }
        q = Quote(fair, bid, ask, PriceClass(uint8(meta)), (meta >> 8) & 1 == 1);
        hit = true;
    }

    /// @dev `token`'s quote, and whether its market counts as closed now (`_closure`).
    function _quote(address token) private view returns (Quote memory q, bool closed) {
        return _quoteHop(token, new address[](MAX_HOPS + 1), 0);
    }

    /// @dev A quote from the transient cache when `warm` put it there, else priced now (a chained price reads its
    ///      quote token the same way, so a settlement prices every token once).
    function _quoteOf(address token, address[] memory path, uint256 depth) private view returns (Quote memory q) {
        (bool hit, Quote memory cached,) = _cached(token);
        if (hit) return cached;
        (q,) = _quoteHop(token, path, depth);
    }

    /// @dev `token`'s quote, `depth` steps down a chain (`path` lists the tokens above it, so a chain that comes
    ///      back to one of them is refused).
    function _quoteHop(address token, address[] memory path, uint256 depth)
        private
        view
        returns (Quote memory q, bool closed)
    {
        Config memory c = _config[token];
        q.class_ = c.class_;
        if (c.class_ == PriceClass.None || address(c.primary) == address(0)) {
            // No market: worth zero, and that is a known value rather than a missing one.
            q.class_ = PriceClass.None;
            q.available = true;
            return (q, false);
        }
        path[depth] = token;
        Session memory sess = _session[token];
        Clock memory k = _clock(sess);
        // `p`: fair, bid and ask before the token's own haircut (a chained price takes its quote's sides).
        (uint256[3] memory p, bool ok) = _sources(c, token, k, path, depth, q);
        // Reopened, but the reading is from before: still the closure that reopening ended (`Clock`).
        uint256 closedAt = k.closedAt != 0 ? k.closedAt : k.stale ? k.since : 0;
        closed = closedAt != 0 || k.dead;
        if (!ok) return (q, closed); // unavailable
        if (q.class_ == PriceClass.None) return (_none(q), closed); // a chain through a token with no market
        if (closedAt != 0 && address(sess.closedSource) != address(0) && _worseOf(q, sess, token, p, path, depth)) {
            q.available = true;
            return (q, closed);
        }
        uint256 h = c.haircutBps;
        if (closedAt != 0) h += sess.closedHaircutBps;
        if (h > 9_999) h = 9_999;
        q.fair = p[0];
        q.bid = p[1] * (10_000 - h) / 10_000;
        q.ask = p[2] * (10_000 + h) / 10_000;
        q.available = true;
    }

    /// @dev The primary's price and, with a check source, that the two agree; the class capped at every quote's.
    function _sources(
        Config memory c,
        address token,
        Clock memory k,
        address[] memory path,
        uint256 depth,
        Quote memory q
    ) private view returns (uint256[3] memory p, bool ok) {
        PriceClass cap;
        (p, cap, ok) = _side(c.primary, c.chained & 1 != 0, true, token, k, path, depth);
        if (ok && cap == PriceClass.None) {
            q.class_ = PriceClass.None;
            return (p, true);
        }
        if (!ok || p[0] == 0) return (p, false);
        if (uint8(cap) < uint8(q.class_)) q.class_ = cap;
        if (address(c.check) == address(0)) return (p, true);
        (uint256[3] memory p2, PriceClass cap2, bool ok2) =
            _side(c.check, c.chained & 2 != 0, false, token, k, path, depth);
        if (ok2 && cap2 == PriceClass.None) {
            q.class_ = PriceClass.None;
            return (p, true);
        }
        if (!ok2 || p2[0] == 0) return (p, false);
        uint256 diff = p[0] > p2[0] ? p[0] - p2[0] : p2[0] - p[0];
        if (diff * 10_000 > uint256(c.maxDeviationBps) * p[0]) return (p, false); // sources disagree
        if (uint8(cap2) < uint8(q.class_)) q.class_ = cap2;
        return (p, true);
    }

    function _none(Quote memory q) private pure returns (Quote memory) {
        q.class_ = PriceClass.None;
        q.available = true;
        return q;
    }

    /// @dev One source's price of `token`: a USD source gives the same price on every side; a ratio source's price
    ///      is converted through the router's quote of its quote token, side by side, and caps the class at that
    ///      quote's. For the primary (`recent`), a ratio source that also gives a recent price (`IRecentRatio`) sets
    ///      the bid from the lower of the two and the ask from the higher (fair stays the average). A chain longer
    ///      than `MAX_HOPS`, or one that loops, is unavailable.
    function _side(
        IPriceSource s,
        bool chained,
        bool recent,
        address token,
        Clock memory k,
        address[] memory path,
        uint256 depth
    ) private view returns (uint256[3] memory p, PriceClass cap, bool ok) {
        cap = PriceClass.Feed;
        if (!chained) {
            (uint256 usd, bool ok_) = _read(s, token, k);
            return ([usd, usd, usd], cap, ok_);
        }
        (address qt, uint256[3] memory r, uint256 at, bool okR) = _readRatio(s, token, recent);
        if (!okR || r[0] == 0 || !_stamp(k, at)) return (p, cap, false);
        Quote memory qq;
        (qq, ok) = _hop(qt, path, depth);
        if (!ok) return (p, cap, false);
        cap = qq.class_;
        p[0] = Math.mulDiv(r[0], qq.fair, 1e18);
        p[1] = Math.mulDiv(r[1], qq.bid, 1e18);
        p[2] = Math.mulDiv(r[2], qq.ask, 1e18);
    }

    /// @dev The quote token's quote, one step further down the chain; not ok past `MAX_HOPS`, on a loop, or when it
    ///      is unavailable.
    function _hop(address qt, address[] memory path, uint256 depth) private view returns (Quote memory qq, bool ok) {
        if (qt == address(0) || depth + 1 > MAX_HOPS) return (qq, false);
        for (uint256 i; i <= depth; ++i) {
            if (path[i] == qt) return (qq, false);
        }
        qq = _quoteOf(qt, path, depth + 1);
        ok = qq.available && (qq.class_ == PriceClass.None || qq.fair != 0);
    }

    /// @dev A ratio source's answer as fair, low and high, never reverting. With `recent`, a source that also gives a
    ///      recent price (`IRecentRatio`) widens low and high to it; one that does not (the call reverts) leaves them
    ///      at the average, and one that gives none now (`ok` false) makes the answer unavailable.
    function _readRatio(IPriceSource s, address token, bool recent)
        private
        view
        returns (address qt, uint256[3] memory r, uint256 at, bool ok)
    {
        if (recent) {
            try IRecentRatio(address(s)).ratioAndRecent(token) returns (
                address q_, uint256 r_, uint256 x, uint64 at_, bool ok_
            ) {
                if (!ok_ || r_ == 0 || x == 0) return (q_, r, at_, false);
                return (q_, [r_, r_ < x ? r_ : x, r_ > x ? r_ : x], at_, true);
            } catch {} // no recent price: the average alone
        }
        try IRatioSource(address(s)).ratio(token) returns (address q_, uint256 r_, uint64 at_, bool ok_) {
            (qt, r, at, ok) = (q_, [r_, r_, r_], at_, ok_);
        } catch {
            return (address(0), r, 0, false);
        }
    }

    /// @dev The worse-of rule while the market is closed: every qualifying closed-market price converted through the
    ///      router's quote of its quote token (lower prices at the quote's bid, higher at its ask) and held within
    ///      `closedClampBps` of the last price; then the lowest of them and the last bid sets the bid, the highest
    ///      and the last ask the ask, each with the spread `s`. False when none qualifies (the fallback applies).
    function _worseOf(
        Quote memory q,
        Session memory sess,
        address token,
        uint256[3] memory last,
        address[] memory path,
        uint256 depth
    ) private view returns (bool) {
        IClosedMarketSource.Ratio[] memory rs;
        try sess.closedSource.closedRatios(token) returns (IClosedMarketSource.Ratio[] memory x) {
            rs = x;
        } catch {
            return false;
        }
        uint256 lo = last[1];
        uint256 hi = last[2];
        uint256 band = last[0] * sess.closedClampBps / 10_000;
        uint256 floor = last[0] > band ? last[0] - band : 0;
        uint256 ceil = last[0] + band;
        bool any;
        for (uint256 i; i < rs.length; ++i) {
            (Quote memory qq, bool ok) = _hop(rs[i].quote, path, depth);
            if (!ok || qq.class_ == PriceClass.None) continue;
            uint256 b = _clamp(Math.mulDiv(rs[i].ratioWad, qq.bid, 1e18), floor, ceil);
            uint256 a = _clamp(Math.mulDiv(rs[i].ratioWad, qq.ask, 1e18), floor, ceil);
            if (b < lo) lo = b;
            if (a > hi) hi = a;
            any = true;
        }
        if (!any) return false;
        uint256 s = sess.closedSpreadBps;
        if (s > 9_999) s = 9_999;
        q.fair = (lo + hi) / 2;
        q.bid = lo * (10_000 - s) / 10_000;
        q.ask = hi * (10_000 + s) / 10_000;
        return true;
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) private pure returns (uint256) {
        return x < lo ? lo : x > hi ? hi : x;
    }

    /// @notice True while `token`'s market is closed (a weekend or a calendar holiday, for US-session tokens), and
    ///         after the reopening until its primary source has a reading from the new session.
    function marketClosed(address token) external view returns (bool) {
        return _closedNow(token);
    }

    /// @dev `values`' flags: 1 the token's market is closed now, 2 it has a look-through.
    function _flags(address token, bool closed) private view returns (uint8 f) {
        if (closed) f = 1;
        if (address(lookThrough[token]) != address(0)) f |= 2;
    }

    /// @notice What a Fund's hold check needs of a token, in one call: its class, whether its market is closed
    ///         now (`marketClosed`), and its look-through (zero if none).
    function holdInfo(address token) external view returns (PriceClass class_, bool closed, address lookThrough_) {
        Config storage c = _config[token];
        class_ = address(c.primary) == address(0) ? PriceClass.None : c.class_;
        closed = _closedNow(token);
        lookThrough_ = address(lookThrough[token]);
    }

    /// @dev `marketClosed`: the closure calendar, and after a reopening, within `REOPEN_GRACE`, whether the primary
    ///      source's reading is from before it (from the transient cache when a settlement warmed the token). After
    ///      the grace a source still without a new reading is unavailable anyway.
    function _closedNow(address token) private view returns (bool) {
        Session memory sess = _session[token];
        if (!sess.usSession) return false;
        Clock memory k = _clock(sess);
        if (k.closedAt != 0) return true;
        if (k.opened == 0 || block.timestamp >= k.opened + REOPEN_GRACE) return false;
        (bool hit,, uint256 slot) = _cached(token);
        if (hit) {
            uint256 meta;
            assembly ("memory-safe") {
                meta := tload(slot)
            }
            return (meta >> 25) & 1 == 1;
        }
        uint256 at = _readingAt(_config[token], token);
        return at != 0 && at < k.opened;
    }

    /// @dev `token`'s place on the closure calendar now (`Clock`, before any source is read): the same for every
    ///      US-session token, so `warm` works it out once per transaction and later reads take it from there.
    function _clock(Session memory sess) private view returns (Clock memory k) {
        if (!sess.usSession) return k;
        bytes32 slot = CLOCK_SLOT;
        uint256 w;
        assembly ("memory-safe") {
            w := tload(slot)
        }
        if (w != 0 && w >> 192 == block.timestamp) {
            (k.closedAt, k.opened, k.since) = (uint64(w >> 128), uint64(w >> 64), uint64(w));
            return k;
        }
        k.closedAt = _closedSince(block.timestamp);
        if (k.closedAt == 0) (k.opened, k.since) = _lastReopening(block.timestamp);
    }

    function _warmClock() private {
        Clock memory k = _clock(Session(true, 0, 0, 0, IClosedMarketSource(address(0))));
        uint256 w = block.timestamp << 192 | k.closedAt << 128 | k.opened << 64 | k.since;
        bytes32 slot = CLOCK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, w)
        }
    }

    /// @dev A source's reading made at `at`, against the clock: after a reopening, a reading from before it marks the
    ///      token as still in the closure (`stale`), or unavailable once `REOPEN_GRACE` has passed (`dead`).
    function _stamp(Clock memory k, uint256 at) private view returns (bool ok) {
        if (k.closedAt != 0 || k.opened == 0 || at >= k.opened) return true;
        if (block.timestamp >= k.opened + REOPEN_GRACE) {
            k.dead = true;
            return false;
        }
        k.stale = true;
        return true;
    }

    function sessionOf(address token) external view returns (Session memory) {
        return _session[token];
    }

    /// @notice When the current US closure began (a UTC day boundary), or 0 while the US market is open. The same
    ///         calendar every US-session token follows; Funds count a closure's net inflow from it.
    function closedSince() external view returns (uint256) {
        return _closedSince(block.timestamp);
    }

    /// @notice `closedSince`, or while the market is open the start of the closure that ended last (0 if none in the
    ///         last week). A token whose feed has no reading yet from the new session is still in that closure
    ///         (`marketClosed`), so Funds keep counting its caps there.
    function lastClosedSince() external view returns (uint256 since) {
        since = _closedSince(block.timestamp);
        if (since == 0) (, since) = _lastReopening(block.timestamp);
    }

    /// @dev When the primary source's latest reading of `token` was made, whatever its age (0 if none).
    function _readingAt(Config memory c, address token) private view returns (uint256) {
        IPriceSource s = c.primary;
        if (address(s) == address(0)) return 0;
        if (c.chained & 1 != 0) {
            try IRatioSource(address(s)).ratio(token) returns (address, uint256, uint64 at, bool ok) {
                return ok ? at : 0;
            } catch {
                return 0;
            }
        }
        try s.price(token) returns (uint256, uint64 at, bool ok) {
            if (ok) return at;
        } catch {}
        try ISessionSource(address(s)).lastPrice(token) returns (uint256, uint64 at, bool ok) {
            if (ok) return at;
        } catch {}
        return 0;
    }

    /// @dev While the market is open at `t`: when it last reopened, and when the closure that reopening ended began
    ///      (0, 0 if none in the last week). It reopens at 20:00 New York time on its last closed UTC day: 00:00 UTC
    ///      the next day while New York keeps summer time, 01:00 UTC otherwise.
    function _lastReopening(uint256 t) private view returns (uint256 opened, uint256 since) {
        uint256 day = t / 1 days;
        for (uint256 i = 1; i <= 7 && i <= day; ++i) {
            uint256 e = day - i;
            if (!_closedDay(e)) continue;
            opened = (e + 1) * 1 days + (_summerTime(e) ? 0 : REOPEN_LAG);
            for (uint256 j; j < MAX_CLOSED_DAYS && e > 0 && _closedDay(e - 1); ++j) --e;
            return (opened, e * 1 days);
        }
    }

    /// @dev Whether New York keeps summer time on the evening of UTC day `day`: from the second Sunday of March to
    ///      the first Sunday of November (the US rule since 2007; the change is at 02:00, so both Sundays' evenings
    ///      fall on the new side).
    function _summerTime(uint256 day) private pure returns (bool) {
        uint256 y = _yearOf(day);
        return day >= _sundayFrom(_dayOf(y, 3, 8)) && day < _sundayFrom(_dayOf(y, 11, 1));
    }

    /// @dev The first Sunday on or after UTC day `d` (day 0, 1970-01-01, was a Thursday).
    function _sundayFrom(uint256 d) private pure returns (uint256) {
        return d + (7 - (d + 4) % 7) % 7;
    }

    /// @dev The UTC day number of `y`-`m`-`d`, for a month from March on (H. Hinnant's civil calendar algorithm).
    function _dayOf(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m - 3) + 2) / 5 + d - 1;
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    }

    /// @dev The year of UTC day number `z` (the same algorithm, the other way).
    function _yearOf(uint256 z) private pure returns (uint256) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        return yoe + era * 400 + ((5 * doy + 2) / 153 >= 10 ? 1 : 0);
    }

    function isHoliday(uint256 day) public view returns (bool) {
        uint64 from = holidayFrom[day];
        return from != 0 && block.timestamp >= from;
    }

    /// @dev When the current US closure began (a day boundary), or 0 when the market is open now. A closure runs
    ///      over its closed UTC days and `REOPEN_LAG` into the next one (winter's later reopening).
    function _closedSince(uint256 t) private view returns (uint256) {
        uint256 day = t / 1 days;
        if (!_closedDay(day)) {
            if (t % 1 days >= REOPEN_LAG || day == 0 || !_closedDay(day - 1)) return 0;
            --day;
        }
        for (uint256 i; i < MAX_CLOSED_DAYS && day > 0 && _closedDay(day - 1); ++i) --day;
        return day * 1 days;
    }

    function _closedDay(uint256 day) private view returns (bool) {
        // Days since the first Saturday: 0 is Saturday, 1 is Sunday.
        bool weekend = day >= FIRST_SATURDAY_DAY && (day - FIRST_SATURDAY_DAY) % 7 < 2;
        return weekend || isHoliday(day);
    }

    /// @notice `amount` of `token` at fair, bid and ask (`v[0]`, `v[1]`, `v[2]`), in one call: what a Fund's NAV on
    ///         every side needs per row. Same rules as `value`. `flags`: 1 its market is closed now, 2 it has a
    ///         look-through (what a Fund's hold check needs, so it asks nothing else).
    function values(address token, uint256 amount)
        external
        view
        returns (uint256[3] memory v, PriceClass class_, bool ok, uint8 flags)
    {
        (bool hit, Quote memory q, uint256 s) = _cached(token);
        uint256 dec;
        if (hit) {
            uint256 meta;
            assembly ("memory-safe") {
                meta := tload(s)
            }
            dec = (meta >> 9) & 0xff;
            flags = uint8(meta >> 25) & 3;
        } else {
            bool closed;
            (q, closed) = _quote(token);
            dec = _config[token].decimals;
            flags = _flags(token, closed);
        }
        class_ = q.class_;
        ok = q.available;
        if (!ok || amount == 0 || class_ == PriceClass.None) return (v, class_, ok, flags);
        uint256 unit = 10 ** dec;
        (uint256 hi,) = _mul512(amount, q.fair > q.ask ? q.fair : q.ask);
        if (hi >= unit) return (v, class_, false, flags);
        v[0] = Math.mulDiv(amount, q.fair, unit);
        v[1] = Math.mulDiv(amount, q.bid, unit);
        v[2] = Math.mulDiv(amount, q.ask, unit);
    }

    function value(address token, uint256 amount, Side side) external view returns (uint256 usd, PriceClass class_, bool ok) {
        (bool hit, Quote memory q, uint256 s) = _cached(token);
        uint256 dec;
        if (hit) {
            assembly ("memory-safe") {
                dec := and(shr(9, tload(s)), 0xff)
            }
        } else {
            (q,) = _quote(token);
            dec = _config[token].decimals;
        }
        class_ = q.class_;
        ok = q.available;
        if (!ok || amount == 0 || class_ == PriceClass.None) return (0, class_, ok);
        uint256 p = side == Side.Bid ? q.bid : side == Side.Ask ? q.ask : q.fair;
        uint256 unit = 10 ** dec;
        // A result beyond 2^256 is a broken amount, not a holding: unavailable rather than a revert.
        (uint256 hi,) = _mul512(amount, p);
        if (hi >= unit) return (0, class_, false);
        usd = Math.mulDiv(amount, p, unit);
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @dev A source that reverts or returns malformed data reads as unavailable. While the token's market
    ///      is closed (the calendar's closure, or after the reopening until the source has a reading from then,
    ///      within `REOPEN_GRACE`), a reading the source calls stale is still usable if it was fresh enough when the
    ///      closure began. Every reading is stamped against the clock (`_stamp`).
    function _read(IPriceSource s, address token, Clock memory k) private view returns (uint256, bool) {
        try s.price(token) returns (uint256 usd, uint64 at, bool ok_) {
            if (ok_ && usd != 0) return (usd, _stamp(k, at));
        } catch {}
        uint256 closure = k.closedAt;
        if (closure == 0 && k.opened != 0 && block.timestamp < k.opened + REOPEN_GRACE) closure = k.since;
        if (closure == 0) return (0, false);
        try ISessionSource(address(s)).lastPrice(token) returns (uint256 usd, uint64 at, bool ok_) {
            if (ok_ && usd != 0 && at <= block.timestamp && uint256(at) + PRE_CLOSE_AGE >= closure) {
                return (usd, _stamp(k, at));
            }
        } catch {}
        return (0, false);
    }

    // ---- configuration ----

    /// @notice Propose a token's pricing. Applies at once when it can only lower values, else after the delay.
    function propose(address token, Config calldata c) external onlyOwner {
        Config memory next = c;
        if (token == address(0)) revert BadConfig();
        if (c.class_ != PriceClass.None) {
            if (address(c.primary) == address(0) || c.haircutBps >= 10_000) revert BadConfig();
            if (address(c.check) != address(0) && c.maxDeviationBps == 0) revert BadConfig();
        }
        next.decimals = IERC20Metadata(token).decimals();
        if (_lowersOnly(_config[token], next)) {
            _apply(token, next);
            if (pendingAt[token] != 0) {
                delete pendingAt[token];
                delete pendingConfig[token];
                emit PendingCancelled(token);
            }
            return;
        }
        pendingConfig[token] = next;
        uint64 at = uint64(block.timestamp) + CONFIG_DELAY;
        pendingAt[token] = at;
        emit ConfigProposed(token, at);
    }

    /// @notice Anyone may apply a pending configuration once its delay has passed.
    function applyPending(address token) external {
        uint64 at = pendingAt[token];
        if (at == 0 || block.timestamp < at) revert NotReady();
        delete pendingAt[token];
        _apply(token, pendingConfig[token]);
        delete pendingConfig[token];
    }

    function cancelPending(address token) external onlyOwner {
        delete pendingAt[token];
        delete pendingConfig[token];
        emit PendingCancelled(token);
    }

    // ---- sessions and holidays ----

    /// @notice Set a token's session. Applies at once only when it can only widen what a closed market costs:
    ///         the session stays on, the same closed-market source, and neither spread narrower. Anything else
    ///         (a new or removed source, a narrower spread, dropping the session) waits CONFIG_DELAY.
    function proposeSession(address token, Session calldata next) external onlyOwner {
        if (next.closedHaircutBps >= 10_000 || next.closedSpreadBps >= 10_000 || next.closedClampBps >= 10_000) {
            revert BadConfig();
        }
        if (address(next.closedSource) != address(0) && !next.usSession) revert BadConfig();
        Session memory cur = _session[token];
        bool same = !next.usSession && !cur.usSession;
        bool wider = next.usSession && cur.usSession && next.closedHaircutBps >= cur.closedHaircutBps
            && next.closedSpreadBps >= cur.closedSpreadBps && next.closedSource == cur.closedSource
            && next.closedClampBps == cur.closedClampBps;
        if (same || wider) {
            _session[token] = next;
            delete pendingSession[token];
            pendingSessionAt[token] = 0;
            emit SessionApplied(
                token, next.usSession, next.closedHaircutBps, next.closedSpreadBps, address(next.closedSource)
            );
            return;
        }
        uint64 at = uint64(block.timestamp) + CONFIG_DELAY;
        pendingSession[token] = next;
        pendingSessionAt[token] = at;
        emit SessionProposed(
            token, next.usSession, next.closedHaircutBps, next.closedSpreadBps, address(next.closedSource), at
        );
    }

    function applySession(address token) external {
        uint64 at = pendingSessionAt[token];
        if (at == 0 || block.timestamp < at) revert NotReady();
        Session memory next = pendingSession[token];
        _session[token] = next;
        delete pendingSession[token];
        pendingSessionAt[token] = 0;
        emit SessionApplied(
            token, next.usSession, next.closedHaircutBps, next.closedSpreadBps, address(next.closedSource)
        );
    }

    /// @notice Add US market holidays (UTC day numbers). Each counts from CONFIG_DELAY after it is added, so
    ///         a holiday must be announced at least a day ahead to matter; the calendar is published yearly.
    function addHolidays(uint256[] calldata days_) external onlyOwner {
        uint64 at = uint64(block.timestamp) + CONFIG_DELAY;
        for (uint256 i; i < days_.length; ++i) {
            if (holidayFrom[days_[i]] != 0) continue;
            holidayFrom[days_[i]] = at;
            emit HolidayAdded(days_[i], at);
        }
    }

    /// @notice Remove holidays at once: it can only make prices unavailable sooner and spreads normal.
    function removeHolidays(uint256[] calldata days_) external onlyOwner {
        bytes32 slot = CLOCK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
        for (uint256 i; i < days_.length; ++i) {
            delete holidayFrom[days_[i]];
            emit HolidayRemoved(days_[i]);
        }
    }

    // ---- look-through ----

    /// @notice Name (or clear, with 0) the look-through for a wrapper token. Always waits CONFIG_DELAY.
    function proposeLookThrough(address token, ILookThrough lt) external onlyOwner {
        uint64 at = uint64(block.timestamp) + CONFIG_DELAY;
        pendingLookThrough[token] = lt;
        pendingLookThroughAt[token] = at;
        emit LookThroughProposed(token, address(lt), at);
    }

    function applyLookThrough(address token) external {
        uint64 at = pendingLookThroughAt[token];
        if (at == 0 || block.timestamp < at) revert NotReady();
        ILookThrough lt = pendingLookThrough[token];
        lookThrough[token] = lt;
        delete pendingLookThrough[token];
        pendingLookThroughAt[token] = 0;
        emit LookThroughApplied(token, address(lt));
    }

    function cancelLookThrough(address token) external onlyOwner {
        delete pendingLookThrough[token];
        pendingLookThroughAt[token] = 0;
    }

    function _apply(address token, Config memory c) private {
        _config[token] = c;
        emit ConfigApplied(token, c.class_, address(c.primary), address(c.check), c.haircutBps);
    }

    /// @dev Same sources, a class no better, a haircut no smaller, a deviation no looser and a unit no
    ///      smaller (more decimals means less value per raw unit): asset values can only go down. A first
    ///      configuration starts from None, so anything but None waits. None itself is always instant.
    function _lowersOnly(Config memory cur, Config memory next) private pure returns (bool) {
        if (next.class_ == PriceClass.None) return true;
        return next.primary == cur.primary && next.check == cur.check && next.chained == cur.chained
            && uint8(next.class_) <= uint8(cur.class_)
            && next.haircutBps >= cur.haircutBps && next.decimals >= cur.decimals
            && (address(next.check) == address(0) || next.maxDeviationBps <= cur.maxDeviationBps);
    }

    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
