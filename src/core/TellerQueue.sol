// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITeller} from "../interfaces/ITeller.sol";

/**
 * @title  TellerQueue
 * @notice The teller's loops over a batch's requests, as a linked library (it runs on the teller's storage) so the
 *         teller stays small. A batch holds at most `Teller.MAX_REQUESTS` requests, which bounds every loop here.
 */
library TellerQueue {
    error BadRequest(uint256 id);
    error MinNotMet(uint256 id);
    error NeedlessSkip(uint256 id);

    event Moved(address indexed vault, uint256 indexed id, uint64 toBatch);
    event Skipped(address indexed vault, uint256 indexed id);
    event DepositSplit(address indexed vault, uint256 indexed id, uint256 indexed part, uint256 amount);

    uint256 internal constant WAD = 1e18;

    /// @notice What a round gave, for the limits: the deposits it took (`base`, as requested: every deposit still
    ///         waiting when `allIn`, else those marked with `round`) and the shares they got (`refunded` when a Fund
    ///         winding down paid them back); in the first round the leavers' shares, the USDG they got and the
    ///         shares the Fund's cash could not cover (handed back).
    struct Result {
        uint16 round;
        bool allIn;
        uint256 base;
        uint256 shares;
        bool refunded;
        bool first;
        uint256 redIncluded;
        uint256 usdgOut;
        uint256 back;
        bool depFast; // the round's price beats the batch's tightest deposit limit: no deposit needs reading
        bool redFast; // the same for the leavers' tightest limit
        bool depWait; // the round took no deposit (they all wait): a listed deposit would have waited too
        bool noCash; // the leavers could not be priced (every share comes back): a listed leaver would have too
    }

    /// @notice Take the requests a keeper lists out of this round before anything is computed. In a later round
    ///         only waiting deposits can be listed (the leavers were paid at the first). Returns what they held.
    function mark(
        mapping(uint256 => ITeller.Request) storage reqs,
        address vault,
        uint64 id,
        uint256[] calldata skip,
        bool depositsOnly
    ) public returns (uint256 deposits, uint256 redeems) {
        for (uint256 i; i < skip.length; ++i) {
            ITeller.Request storage r = reqs[skip[i]];
            if (
                r.vault != vault || r.batch != id || r.status != ITeller.Status.Pending || r.round != 0
                    || (depositsOnly && r.kind != ITeller.Kind.Deposit)
            ) revert BadRequest(skip[i]);
            r.status = ITeller.Status.Skipped;
            if (r.kind == ITeller.Kind.Deposit) deposits += r.amount;
            else redeems += r.amount;
        }
    }

    /// @notice Under a cap, the waiting deposits in the order they came while they add up to at most `budget` USDG:
    ///         each is marked with `round`; the rest keep waiting. The first one larger than the room left, when that
    ///         room is at least `minPart` (the pool-price flow cap; a closed market's cap passes no part), goes in in
    ///         part: the part becomes request `partId` (same owner, batch and
    ///         clock, its limit scaled to the part and rounded up, marked with `round`), and the rest of the request
    ///         keeps waiting with its id and the rest of its limit, so a deposit larger than a whole cap still goes in
    ///         over the next windows. Returns the USDG taken and the request split (0 when none).
    function select(
        mapping(uint256 => ITeller.Request) storage reqs,
        uint256[] storage ids,
        mapping(uint256 => uint256) storage pos,
        uint64 id,
        uint16 round,
        uint256 budget,
        uint256 minPart,
        uint256 partId
    ) public returns (uint256 kept, uint256 split) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            ITeller.Request storage r = reqs[ids[i]];
            if (r.status != ITeller.Status.Pending || r.batch != id || r.kind != ITeller.Kind.Deposit || r.round != 0) {
                continue;
            }
            uint256 amt = r.amount;
            if (kept + amt <= budget) {
                kept += amt;
                r.round = round;
            } else if (split == 0 && budget - kept >= minPart) {
                split = ids[i];
                _split(reqs[partId], r, budget - kept, round);
                ids.push(partId);
                pos[partId] = ids.length;
                emit DepositSplit(r.vault, split, partId, budget - kept);
                kept = budget;
            }
        }
    }

    /// @dev Request `r` goes in by `part` as request `p`: the part's limit is `r`'s scaled to it, rounded up (a price at
    ///      least as tight), and `r` keeps the rest of its amount and limit.
    function _split(ITeller.Request storage p, ITeller.Request storage r, uint256 part, uint16 round) private {
        uint256 pm = Math.mulDiv(r.min, part, r.amount, Math.Rounding.Ceil);
        p.vault = r.vault;
        p.batch = r.batch;
        p.kind = ITeller.Kind.Deposit;
        p.status = ITeller.Status.Pending;
        p.round = round;
        p.owner = r.owner;
        p.madeAt = r.madeAt;
        p.amount = uint128(part);
        p.min = uint128(pm);
        r.amount -= uint128(part);
        r.min = r.min > pm ? r.min - uint128(pm) : 1;
    }

    /// @notice Every request the round took meets its own limit; every one the keeper listed would have failed it
    ///         (had it been included, it would have shared the result on the same terms), so a keeper cannot hold
    ///         anyone back at will. A side whose round price beats the batch's tightest limit on it (`depFast`,
    ///         `redFast`) needs no reading.
    /// @dev    With nobody left on a listed request's side there is no result to judge it by, and judging it by an
    ///         empty result would let a keeper move a whole side to the next batch, every batch. So such a request
    ///         may be moved only when its limit is tighter than the Fund's fair NAV (`perShare`, raw USDG per 1e18
    ///         shares, 0 when unknown): no fair settlement could meet it.
    function checkLimits(
        mapping(uint256 => ITeller.Request) storage reqs,
        uint256[] storage ids,
        uint64 id,
        Result memory res,
        uint256[] calldata skip,
        uint256 perShare
    ) public view {
        bool depFast = res.depFast;
        bool leavers = res.first && !res.redFast;
        if (!depFast || leavers) {
            for (uint256 i; i < ids.length; ++i) {
                ITeller.Request storage r = reqs[ids[i]];
                if (r.status != ITeller.Status.Pending || r.batch != id) continue;
                if (r.kind == ITeller.Kind.Deposit) {
                    if (depFast || !(r.round == res.round || (r.round == 0 && res.allIn))) continue;
                } else if (!leavers) {
                    continue;
                }
                if (!_meets(r, res)) revert MinNotMet(ids[i]);
            }
        }
        for (uint256 i; i < skip.length; ++i) {
            ITeller.Request storage r = reqs[skip[i]];
            bool dep = r.kind == ITeller.Kind.Deposit;
            uint256 peers = dep ? res.base : res.redIncluded;
            bool fails = peers != 0 ? !_meets(r, res) : _beyondFair(r.amount, r.min, dep, perShare);
            if (dep ? (res.refunded || res.depWait) : res.noCash) fails = false; // nothing would have been judged
            if (r.min == 0 || !fails) revert NeedlessSkip(skip[i]);
        }
    }

    /**
     * @dev Whether a request's share of the round meets its limit.
     *      A deposit's `min` is the least shares for its whole amount; every deposit in a round shares the round's
     *      shares pro rata by amount. One paid back (a Fund winding down) has nothing to judge.
     *      A cash exit's `min` is the least USDG for its whole amount, as a price: what it gets in USDG must be at
     *      least `min` times the part of its shares the Fund paid in cash, over all its shares. Shares handed back
     *      for an exit in kind (the Fund's USDG was short) are not sold, so they do not count against it.
     */
    function _meets(ITeller.Request storage r, Result memory res) private view returns (bool) {
        uint256 amt = r.amount;
        if (r.kind == ITeller.Kind.Deposit) {
            if (res.refunded) return true;
            if (res.base == 0) return false;
            return Math.mulDiv(res.shares, amt, res.base) >= r.min;
        }
        if (res.redIncluded == 0) return false;
        uint256 got = Math.mulDiv(res.usdgOut, amt, res.redIncluded);
        uint256 back = Math.mulDiv(res.back, amt, res.redIncluded, Math.Rounding.Ceil);
        uint256 sold = amt > back ? amt - back : 0;
        return got >= Math.mulDiv(r.min, sold, amt, Math.Rounding.Ceil);
    }

    /// @dev A limit no fair trade can meet: more shares than the deposit buys at fair NAV, or more USDG than the
    ///      shares are worth at fair NAV. Unknown NAV: nothing can be shown, so the move is refused (with a price
    ///      missing nobody is judged anyway: deposits wait and leavers get their shares back).
    function _beyondFair(uint256 amount, uint256 min, bool dep, uint256 perShare) private pure returns (bool) {
        if (perShare == 0) return false;
        return dep ? min > Math.mulDiv(amount, WAD, perShare) : min > Math.mulDiv(amount, perShare, WAD);
    }

    /// @notice A limit as a price, rounded up: shares per raw USDG for a deposit, raw USDG per share for a cash exit
    ///         (1e18). The batch keeps the tightest of each.
    function tight(uint256 min, uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(min, WAD, amount, Math.Rounding.Ceil);
    }

    /// @notice Take request `id` out of its batch's list (swap and pop), so its place is free again.
    function unlist(
        mapping(uint64 => uint256[]) storage ids,
        mapping(uint256 => uint256) storage pos,
        uint64 batch,
        uint256 id
    ) public {
        uint256[] storage list = ids[batch];
        uint256 at = pos[id];
        if (at == 0) return;
        uint256 last = list[list.length - 1];
        list[at - 1] = last;
        pos[last] = at;
        list.pop();
        delete pos[id];
    }

    /// @notice Move the requests a keeper listed into batch `next`, once each. One that does not fit (`max`), or
    ///         that was moved before, stays skipped and is paid back in full by `claim`: a limit that fails twice
    ///         does not keep a place in the queue.
    function move(
        mapping(uint256 => ITeller.Request) storage reqs,
        mapping(uint64 => ITeller.Batch) storage batches,
        mapping(uint64 => uint256[]) storage ids,
        mapping(uint256 => uint256) storage pos,
        mapping(uint256 => bool) storage moved,
        address vault,
        uint64 next,
        uint256 max,
        uint256[] calldata skip
    ) public {
        ITeller.Batch storage nb = batches[next];
        for (uint256 i; i < skip.length; ++i) {
            ITeller.Request storage r = reqs[skip[i]];
            bool dep = r.kind == ITeller.Kind.Deposit;
            if (dep) batches[r.batch].deposits -= r.amount;
            else batches[r.batch].redeems -= r.amount;
            if (nb.count >= max || moved[skip[i]] || r.amount == 0) {
                emit Skipped(vault, skip[i]);
                continue;
            }
            moved[skip[i]] = true;
            ++nb.count;
            r.batch = next;
            r.status = ITeller.Status.Pending;
            ids[next].push(skip[i]);
            pos[skip[i]] = ids[next].length;
            uint256 t = tight(r.min, r.amount);
            if (dep) {
                nb.deposits += r.amount;
                if (t > nb.depTight) nb.depTight = t;
            } else {
                nb.redeems += r.amount;
                if (t > nb.redTight) nb.redTight = t;
                if (nb.redLow == 0 || r.amount < nb.redLow) nb.redLow = r.amount;
            }
            emit Moved(vault, skip[i], next);
        }
    }
}
