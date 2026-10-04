// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAdapter, Amount} from "../interfaces/IAdapter.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IPriceRouter, PriceClass, Side} from "../interfaces/IPriceRouter.sol";
import {ILookThrough, ILookThroughRegistry} from "../interfaces/ILookThrough.sol";

/// @dev The PriceRouter's three-sided value (`PriceRouter.values`).
interface IPriceValues {
    function values(address token, uint256 amount) external view returns (uint256[3] memory, PriceClass, bool, uint8);
}

/// @dev Implemented by the FundController, so the book can decode an adapter's reply under try/catch.
interface IPositionsDecoder {
    function decodePositions(bytes calldata data) external pure returns (Amount[] memory, Amount[] memory);
}

/**
 * @title  FundBook
 * @notice Reads a Fund's book: everything it holds (vault balances of tracked tokens, every listed adapter's
 *         positions) and everything it owes, priced by the router. A linked library so the controller stays
 *         under the contract size limit; it runs in the controller's context.
 *
 * @dev    The book never reverts on bad data. An adapter whose `positions` reverts, runs out of its gas
 *         allowance (`POSITIONS_GAS`) or returns malformed data, and a holding or debt the router cannot
 *         price, make the book incomplete and are listed, so the owner can see and remove what is wrong.
 *         A debt in a token with no market (class None, worth zero) is unpriceable, not free.
 *
 *         Exposure per class is at fair prices. A holding whose token has a look-through (an index share) is
 *         split across the classes of what it holds, in proportion to their fair values, while its NAV stays
 *         its own price. If the look-through fails, the whole holding counts as thin.
 */
library FundBook {
    uint256 internal constant POSITIONS_GAS = 2_000_000;
    /// @dev A single holding or debt worth more than $1e30 is a broken report, not a position.
    uint256 internal constant MAX_ROW_USD = 1e48;
    /// @dev Gas for a look-through call; a basket of a few dozen tokens needs far less.
    uint256 internal constant LOOK_THROUGH_GAS = 1_000_000;

    struct Book {
        uint256 assets; // on the book's side
        uint256 debts; // on the mirror side (ask for a bid book, bid for an ask book, fair for fair)
        uint256 fairAssets;
        uint256 fairDebts;
        bool complete;
        uint256[4] byClass; // fair-price exposure per PriceClass, looking through wrappers
        address[] tokens; // asset rows, one per token; first `rows` used
        uint256[] amounts;
        uint256[] fair;
        PriceClass[] classes;
        uint256 rows;
        address[] debtTokens; // debt rows, one per token; first `debtRows` used
        uint256[] debtAmounts;
        uint256 debtRows;
        address[] unpriced; // first `nUnpriced` used
        uint256 nUnpriced;
        address[] failed; // first `nFailed` used
        uint256 nFailed;
    }

    /// @notice Everything the Fund holds and owes on `side`. Positions of disabled adapters still count.
    ///         Amounts are summed per token first, so each token is priced once however many places hold it.
    ///         `sc[i]` is the Fund's part of adapter `i`'s positions (`FundController.unitsOf`: a leaver's slice
    ///         waiting to be paid out is not the Fund's); empty when every adapter is wholly the Fund's.
    function read(IFundVault vault, address[] memory list, IPriceRouter router, Side side, uint256[2][] memory sc)
        public
        view
        returns (Book memory b)
    {
        (Amount[][] memory held, Amount[][] memory owed) = _readAdapters(b, list, router);
        if (sc.length != 0) {
            for (uint256 i; i < list.length; ++i) {
                scale(held[i], owed[i], sc[i][0], sc[i][1]);
            }
        }
        _gatherAll(b, vault, held, owed);
        b.unpriced = new address[](b.rows + b.debtRows);
        _priceAssets(b, router, side);
        _priceDebts(b, router, side);
    }

    /// @notice Every token a Fund holds or owes, once each, with its total and what the router said of it (class,
    ///         and `flags`: 1 its market is closed now, 2 it has a look-through): the hold check reads these instead
    ///         of asking the router again.
    struct Rows {
        address[] tokens;
        uint256[] amounts;
        PriceClass[] classes;
        uint8[] flags;
        uint256 n;
    }

    /// @notice A Fund's NAV on every side from one reading, with each side's completeness.
    struct Navs {
        uint256 bid; // assets at bid, debts at ask: what a leaver's share is worth
        uint256 fair;
        uint256 ask; // assets at ask, debts at bid: what an entrant pays for a share
        bool bidOk;
        bool fairOk;
        bool askOk;
        uint256 pooled; // fair value of every holding and debt priced from a pool (classes Pool and Thin)
    }

    /**
     * @notice The Fund's NAV at bid, fair and ask from positions already read (`ok[i]` false: adapter `i` could not
     *         be read), each exactly what `read` on that side would net to, with its completeness. The teller reads
     *         every adapter once per settlement and values that one reading here.
     * @dev    One pass prices each row on every side (the router quotes all three at once, and a settlement warms
     *         its quotes, so the extra sides are transient reads). A row the router cannot price makes every side
     *         incomplete; a debt in a token with no market is unpriceable, not free.
     */
    function navs(
        address[] memory tracked,
        uint256[] memory balances,
        bool[] memory ok,
        Amount[][] memory held,
        Amount[][] memory owed,
        IPriceRouter router
    ) public view returns (Navs memory n, Rows memory rows) {
        Book memory b;
        _gatherRows(b, tracked, balances, held, owed);
        bool complete = true;
        for (uint256 i; i < ok.length; ++i) {
            if (!ok[i]) complete = false;
        }
        rows.tokens = new address[](b.rows + b.debtRows);
        rows.amounts = new uint256[](b.rows + b.debtRows);
        rows.classes = new PriceClass[](b.rows + b.debtRows);
        rows.flags = new uint8[](b.rows + b.debtRows);
        uint256[6] memory sum; // assets at bid, fair, ask; debts at ask, fair, bid
        for (uint256 r; r < b.rows; ++r) {
            (uint256[3] memory v, bool ok_) = _row(router, rows, b.tokens[r], b.amounts[r]);
            if (!ok_) complete = false;
            sum[0] += v[1];
            sum[1] += v[0];
            sum[2] += v[2];
            if (_pooled(rows.classes[rows.n - 1])) n.pooled += v[0];
        }
        for (uint256 r; r < b.debtRows; ++r) {
            (uint256[3] memory v, bool ok_) = _row(router, rows, b.debtTokens[r], b.debtAmounts[r]);
            PriceClass c = rows.classes[rows.n - 1];
            if (!ok_ || c == PriceClass.None) complete = false;
            sum[3] += v[2];
            sum[4] += v[0];
            sum[5] += v[1];
            if (_pooled(c)) n.pooled += v[0];
        }
        n.bid = sum[0] > sum[3] ? sum[0] - sum[3] : 0;
        n.fair = sum[1] > sum[4] ? sum[1] - sum[4] : 0;
        n.ask = sum[2] > sum[5] ? sum[2] - sum[5] : 0;
        (n.bidOk, n.fairOk, n.askOk) = (complete, complete, complete);
    }

    function _pooled(PriceClass c) private pure returns (bool) {
        return c == PriceClass.Pool || c == PriceClass.Thin;
    }

    /// @dev Value one row on every side and note it in `rows` (a debt row of a token also held adds a second entry).
    function _row(IPriceRouter router, Rows memory rows, address token, uint256 amount)
        private
        view
        returns (uint256[3] memory v, bool ok)
    {
        PriceClass c;
        uint8 f;
        (v, c, ok, f) = valuesOf(router, token, amount);
        uint256 i = rows.n++;
        rows.tokens[i] = token;
        rows.amounts[i] = amount;
        rows.classes[i] = c;
        rows.flags[i] = f;
    }

    /// @notice Scale an adapter's rows to the Fund's part, `fund` of `total`: what it holds rounded down, what it
    ///         owes rounded up, so a leaver's slice waiting to be paid out never flatters the Fund.
    function scale(Amount[] memory held, Amount[] memory owed, uint256 fund, uint256 total) internal pure {
        if (fund == total) return;
        for (uint256 j; j < held.length; ++j) {
            held[j].amount = Math.mulDiv(held[j].amount, fund, total);
        }
        for (uint256 j; j < owed.length; ++j) {
            owed[j].amount = Math.mulDiv(owed[j].amount, fund, total, Math.Rounding.Ceil);
        }
    }

    /// @dev Every listed adapter's positions; failures recorded.
    function _readAdapters(Book memory b, address[] memory list, IPriceRouter router)
        private
        view
        returns (Amount[][] memory held, Amount[][] memory owed)
    {
        held = new Amount[][](list.length);
        owed = new Amount[][](list.length);
        b.failed = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            bool ok;
            (ok, held[i], owed[i]) = positionsOf(list[i], router);
            if (!ok) b.failed[b.nFailed++] = list[i];
        }
        b.complete = b.nFailed == 0;
    }

    /// @dev The asset and debt rows: tracked vault balances first, then every adapter's holdings and debts.
    function _gatherAll(Book memory b, IFundVault vault, Amount[][] memory held, Amount[][] memory owed)
        private
        view
    {
        address[] memory tracked = vault.trackedTokens();
        uint256[] memory balances = new uint256[](tracked.length);
        for (uint256 i; i < tracked.length; ++i) {
            balances[i] = IERC20(tracked[i]).balanceOf(address(vault));
        }
        _gatherRows(b, tracked, balances, held, owed);
    }

    /// @dev `_gatherAll` from vault balances already read (`tracked[i]` holds `balances[i]`).
    function _gatherRows(
        Book memory b,
        address[] memory tracked,
        uint256[] memory balances,
        Amount[][] memory held,
        Amount[][] memory owed
    ) private pure {
        uint256 rows = tracked.length;
        uint256 debtRows;
        for (uint256 i; i < held.length; ++i) {
            rows += held[i].length;
            debtRows += owed[i].length;
        }
        b.tokens = new address[](rows);
        b.amounts = new uint256[](rows);
        b.debtTokens = new address[](debtRows);
        b.debtAmounts = new uint256[](debtRows);
        for (uint256 i; i < tracked.length; ++i) {
            _gather(b, false, tracked[i], balances[i]);
        }
        for (uint256 i; i < held.length; ++i) {
            for (uint256 j; j < held[i].length; ++j) {
                _gather(b, false, held[i][j].token, held[i][j].amount);
            }
            for (uint256 j; j < owed[i].length; ++j) {
                _gather(b, true, owed[i][j].token, owed[i][j].amount);
            }
        }
    }

    /// @notice An adapter's positions under a gas cap, as a static call. ok = false instead of a revert.
    function positionsOf(address adapter, IPriceRouter router)
        public
        view
        returns (bool ok, Amount[] memory held, Amount[] memory owed)
    {
        bytes memory ret;
        (ok, ret) = adapter.staticcall{gas: POSITIONS_GAS}(abi.encodeCall(IAdapter.positions, (router)));
        if (!ok) return (false, held, owed);
        try IPositionsDecoder(address(this)).decodePositions(ret) returns (Amount[] memory h, Amount[] memory o) {
            return (true, h, o);
        } catch {
            return (false, held, owed);
        }
    }

    /// @notice `amount` of `token` at fair, bid and ask in one router call (`PriceRouter.values`), never reverting: a
    ///         revert or an absurd value reads as unpriced.
    function valuesOf(IPriceRouter router, address token, uint256 amount)
        public
        view
        returns (uint256[3] memory v, PriceClass c, bool ok, uint8 flags)
    {
        try IPriceValues(address(router)).values(token, amount) returns (
            uint256[3] memory x, PriceClass cl, bool ok_, uint8 f
        ) {
            if (x[0] > MAX_ROW_USD || x[1] > MAX_ROW_USD || x[2] > MAX_ROW_USD) return (v, cl, false, f);
            return (x, cl, ok_, f);
        } catch {
            return (v, PriceClass.None, false, 0);
        }
    }

    /// @notice The router's value, except that it never reverts: a revert or an absurd value reads as unpriced.
    function valueOf(IPriceRouter router, address token, uint256 amount, Side side)
        public
        view
        returns (uint256, PriceClass, bool)
    {
        try router.value(token, amount, side) returns (uint256 usd, PriceClass c, bool ok) {
            if (usd > MAX_ROW_USD) return (0, c, false);
            return (usd, c, ok);
        } catch {
            return (0, PriceClass.None, false);
        }
    }

    function _priceAssets(Book memory b, IPriceRouter router, Side side) private view {
        b.fair = new uint256[](b.rows);
        b.classes = new PriceClass[](b.rows);
        for (uint256 r; r < b.rows; ++r) {
            (uint256 usd, uint256 fairUsd, PriceClass c, bool ok) = _value2(router, b.tokens[r], b.amounts[r], side);
            b.classes[r] = c;
            if (!ok) {
                b.complete = false;
                b.unpriced[b.nUnpriced++] = b.tokens[r];
                continue;
            }
            b.assets += usd;
            b.fairAssets += fairUsd;
            b.fair[r] = fairUsd;
            if (fairUsd != 0) _classify(b, router, b.tokens[r], b.amounts[r], fairUsd, c);
        }
    }

    /// @dev Debts on the mirror side: what repaying costs on a bid book, the low end on an ask book.
    function _priceDebts(Book memory b, IPriceRouter router, Side side) private view {
        Side debtSide = side == Side.Bid ? Side.Ask : side == Side.Ask ? Side.Bid : Side.Fair;
        for (uint256 r; r < b.debtRows; ++r) {
            (uint256 usd, uint256 fairUsd, PriceClass c, bool ok) =
                _value2(router, b.debtTokens[r], b.debtAmounts[r], debtSide);
            if (!ok || c == PriceClass.None) {
                b.complete = false;
                b.unpriced[b.nUnpriced++] = b.debtTokens[r];
                continue;
            }
            b.debts += usd;
            b.fairDebts += fairUsd;
        }
    }

    /// @dev Add a holding's fair value to the class buckets, looking through a wrapper when it has one.
    function _classify(Book memory b, IPriceRouter router, address token, uint256 amount, uint256 fairUsd, PriceClass c)
        private
        view
    {
        ILookThrough lt;
        try ILookThroughRegistry(address(router)).lookThrough(token) returns (ILookThrough x) {
            lt = x;
        } catch {}
        if (address(lt) == address(0)) {
            b.byClass[uint8(c)] += fairUsd;
            return;
        }
        Amount[] memory parts;
        try lt.underlying{gas: LOOK_THROUGH_GAS}(token, amount) returns (Amount[] memory p) {
            parts = p;
        } catch {
            b.byClass[uint8(PriceClass.Thin)] += fairUsd; // cannot see inside: assume the worst priced class
            return;
        }
        uint256[4] memory split;
        uint256 total;
        for (uint256 i; i < parts.length; ++i) {
            if (parts[i].amount == 0 || parts[i].token == token) continue;
            (uint256 v, PriceClass pc, bool ok) = valueOf(router, parts[i].token, parts[i].amount, Side.Fair);
            if (!ok) {
                b.byClass[uint8(PriceClass.Thin)] += fairUsd;
                return;
            }
            split[uint8(pc)] += v;
            total += v;
        }
        if (total == 0) {
            b.byClass[uint8(c)] += fairUsd;
            return;
        }
        // Spread the holding's own value across the classes of what it holds; rounding goes to thin.
        uint256 given;
        for (uint256 k = 3; k > 1; --k) {
            uint256 share = fairUsd * split[k] / total;
            b.byClass[k] += share;
            given += share;
        }
        b.byClass[uint8(PriceClass.Thin)] += fairUsd - given;
    }

    function _value2(IPriceRouter router, address token, uint256 amount, Side side)
        private
        view
        returns (uint256 usd, uint256 fairUsd, PriceClass c, bool ok)
    {
        (usd, c, ok) = valueOf(router, token, amount, side);
        if (!ok) return (0, 0, c, false);
        if (side == Side.Fair) return (usd, usd, c, true);
        (fairUsd,, ok) = valueOf(router, token, amount, Side.Fair);
        if (!ok) return (0, 0, c, false);
    }

    /// @dev Add `amount` of `token` to the asset or debt rows, merging with an existing row. Zero is skipped.
    function _gather(Book memory b, bool debt, address token, uint256 amount) private pure {
        if (amount == 0) return;
        address[] memory tokens = debt ? b.debtTokens : b.tokens;
        uint256[] memory amounts = debt ? b.debtAmounts : b.amounts;
        uint256 rows = debt ? b.debtRows : b.rows;
        for (uint256 k; k < rows; ++k) {
            if (tokens[k] == token) {
                // A sum that overflows is a broken report; saturate and let pricing reject it.
                unchecked {
                    uint256 s = amounts[k] + amount;
                    amounts[k] = s < amount ? type(uint256).max : s;
                }
                return;
            }
        }
        tokens[rows] = token;
        amounts[rows] = amount;
        if (debt) b.debtRows = rows + 1;
        else b.rows = rows + 1;
    }
}
