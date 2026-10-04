// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAdapter, IUnvalued, Amount} from "../interfaces/IAdapter.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController} from "../interfaces/IFundController.sol";
import {IPriceRouter, PriceClass, Side} from "../interfaces/IPriceRouter.sol";
import {ILookThrough, ILookThroughRegistry} from "../interfaces/ILookThrough.sol";
import {FundBook} from "./FundBook.sol";

/// @dev The PriceRouter's one-call view of a token for the hold check (`PriceRouter.holdInfo`).
interface IHoldInfo {
    function holdInfo(address token) external view returns (PriceClass class_, bool closed, address lookThrough);
}

/// @dev The controller's exit units (`FundController.pendingExits`, `unitsOf`).
interface IExitUnits {
    function pendingExits() external view returns (uint256);
}

/// @dev Implemented by the Teller, so a malformed `positions` reply can be caught.
interface IPositionsDecoderT {
    function decodePositions(bytes calldata data) external pure returns (Amount[] memory, Amount[] memory);
    function decodeAmounts(bytes calldata data) external pure returns (Amount[] memory);
}

/// @notice A Fund's listed adapters and what each reported, read once per settlement or exit and kept in memory:
///         the fees' bid NAV, the match's fair NAV, the hold check and the plan all come from this one reading.
struct Snap {
    address[] adapters; // the controller's list, enabled and disabled
    bool[] ok; // false: `positions` could not be read, or the adapter was left behind
    Amount[][] assets;
    Amount[][] debts;
    bool withVault; // `tracked` and `balances` were read with the adapters (`snapshotAll`)
    address[] tracked; // the vault's counted tokens
    uint256[] balances; // and its balance of each, at the same moment
}

/// @notice One adapter's positions as read before a deposit or an exit.
struct Pos {
    address adapter;
    bool measured; // false when `positions` could not be read (in-kind exits go ahead without measuring it)
    Amount[] assets;
    Amount[] debts;
}

/**
 * @title  TellerMath
 * @notice The teller's planning, measuring and pricing, as a linked library (it runs in the teller's context) so the
 *         teller stays small. A settlement prices shares at NAV (`navs`, `matchAt`, `mintFor`, `payFor`); an exit in
 *         kind plans a slice (`slicePlan`) and measures afterwards that the remaining holders kept theirs
 *         (`checkShrunk`).
 *
 * @dev    ## Tolerance
 *         Positions are measured with a slack of `TOLERANCE` raw units per row an adapter reported for a token
 *         before the move (at least one row, at most `MAX_SLACK_ROWS`), in the form
 *         `(after + 2 * rows) * 1e18 >= before * (1e18 - f)`; vault balances move by exact transfers and are
 *         measured exactly. Every row an adapter reports (a Morpho market, a liquidity position, a yield vault)
 *         is rounded the way the protocol pays it, owed down and owing up, so each row can land up to a unit off
 *         its exact share; liquidity adapters report one row per position for that reason. Adapters still keep
 *         each row's rounding to themselves where they can (docs/ADAPTERS.md, rule 10): an exit takes each row's
 *         slice less a raw unit's worth. The slack per row covers what they cannot: a liquidity range holding fewer
 *         than about a million raw units of a token (GrowMath), which may read a unit short. At the slack, holders
 *         who stay can lose at most two raw units of a token per row, so at most `2 * MAX_SLACK_ROWS` raw units of
 *         a token per adapter per exit, which for any token with six or more decimals is far below a cent.
 *
 *         ## One reading
 *         A settlement reads every adapter's `positions` once (`snapshotAll`) and prices that one reading on
 *         every side (FundBook.navs); the hold check uses it too. An exit in kind reads every adapter before it
 *         splits (`snapshot`) and once more after, to measure.
 *
 *         ## Debt keeps its ratio
 *         An exit must shrink every debt by the fraction, no less: the remaining holders never keep more than
 *         their share of the Fund's debt.
 */
library TellerMath {
    error Unmeasurable(address adapter);
    error ShortGas();
    error DebtChanged(address adapter, address token, uint256 before, uint256 afterAmount);
    error ShortVault(address token, uint256 balance, uint256 required);
    error NotShrunk(address adapter, address token, uint256 before, uint256 afterAmount);
    /// @notice A slice paid out by someone other than its leaver did not pay at least its share of a position.
    error NotPaid(address adapter, address token, uint256 before, uint256 afterAmount);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant POSITIONS_GAS = 2_000_000;
    uint256 internal constant LOOK_THROUGH_GAS = 1_000_000;
    /// @dev Most gas a call to a function the adapter does not have costs (a clone's delegatecall and the revert);
    ///      a failed `unvalued` that cost more ran out of gas or reverted on its own, which is not "no such function".
    uint256 internal constant NO_FUNCTION_GAS = 20_000;
    /// @dev `ITeller.Hold` values.
    uint8 internal constant HOLD_CLOSED = 1;
    uint8 internal constant HOLD_NO_MARKET = 2;
    uint256 public constant TOLERANCE = 2;
    /// @notice Most rows of one token in one adapter that each get `TOLERANCE`: the largest per-adapter cap of
    ///         the AINDEX adapters (13 Morpho markets; 10 Uniswap v3 or v4 positions, 6 Fables ranges and the pot,
    ///         8 ERC-4626 vaults). An adapter reporting more rows gets no more slack.
    uint256 public constant MAX_SLACK_ROWS = 13;

    /// @notice What an exit in kind takes from each adapter: its slice in the adapter's units (set aside in the
    ///         controller, `reserveFor`) and the debt repayment that slice needs (`unwindInputs`), held in escrow
    ///         until the slice is paid out.
    struct ExitPlan {
        address[] adapters;
        uint256[] fraction; // of each adapter's positions now
        Amount[][] needs;
    }

    // ---------------------------------------------------------------- readings

    /// @notice Every adapter's positions now, one `positions` call each (adapters in `leave` are not read), scaled
    ///         to the Fund's part where a leaver's slice waits to be paid out (`FundController.unitsOf`).
    function snapshot(IFundController c, address[] memory leave) public view returns (Snap memory s) {
        s.adapters = c.adapters();
        IPriceRouter router = c.router();
        uint256 n = s.adapters.length;
        s.ok = new bool[](n);
        s.assets = new Amount[][](n);
        s.debts = new Amount[][](n);
        bool pending = _pending(c);
        for (uint256 i; i < n; ++i) {
            if (_in(leave, s.adapters[i])) continue;
            (s.ok[i], s.assets[i], s.debts[i]) = positionsOf(s.adapters[i], router);
            if (pending && s.ok[i]) {
                (uint256 fund, uint256 total) = c.unitsOf(s.adapters[i]);
                FundBook.scale(s.assets[i], s.debts[i], fund, total);
            }
        }
    }

    /// @notice `snapshot` and the vault's counted balances at the same moment, so a settlement's NAV and hold check
    ///         read each balance once.
    function snapshotAll(IFundController c, address vault) public view returns (Snap memory s) {
        s = snapshot(c, new address[](0));
        s.withVault = true;
        s.tracked = IFundVault(vault).trackedTokens();
        s.balances = new uint256[](s.tracked.length);
        for (uint256 i; i < s.tracked.length; ++i) {
            s.balances[i] = IERC20(s.tracked[i]).balanceOf(vault);
        }
    }

    // ---------------------------------------------------------------- exits in kind

    /// @notice Per adapter not left behind, the fraction of its positions an exit of `f` (of the Fund) takes, and
    ///         the debt repayment that needs now (`unwindInputs`), plus `marginBps` of it for interest that may
    ///         accrue before the slice is paid out. With `skipEmpty` (an exit in parts), an adapter that holds and
    ///         owes nothing (`holdsNothing`) is not in the plan: its slice is worth nothing, so the leaver is given
    ///         none and needs no step for it. An exit in one transaction splits every adapter instead, which costs
    ///         less than reading each one first.
    function exitPlan(IFundController c, uint256 f, address[] memory leave, uint256 marginBps, bool skipEmpty)
        public
        view
        returns (ExitPlan memory p)
    {
        address[] memory ads = c.adapters();
        IPriceRouter router = skipEmpty ? c.router() : IPriceRouter(address(0));
        p.adapters = new address[](ads.length);
        p.fraction = new uint256[](ads.length);
        p.needs = new Amount[][](ads.length);
        uint256 n;
        for (uint256 i; i < ads.length; ++i) {
            if (_in(leave, ads[i])) continue;
            (uint256 fund, uint256 total) = c.unitsOf(ads[i]);
            uint256 x = Math.mulDiv(f, fund, total);
            if (x == 0 || (skipEmpty && holdsNothing(ads[i], router))) continue;
            p.adapters[n] = ads[i];
            p.fraction[n] = x;
            Amount[] memory need = _unwindInputs(ads[i], x);
            for (uint256 j; j < need.length; ++j) {
                if (need[j].amount != 0) need[j].amount += Math.mulDiv(need[j].amount, marginBps, 10_000) + 2;
            }
            p.needs[n] = need;
            ++n;
        }
        _cutA(p.adapters, n);
        _cutU(p.fraction, n);
        assembly ("memory-safe") {
            mstore(mload(add(p, 0x40)), n)
        }
    }

    /**
     * @notice Whether `adapter` says it holds and owes nothing: its `positions` read, and every row of it is zero.
     *         A row of zero may stand for a claim valued at zero (`IUnvalued`), so where there is one the adapter
     *         must also answer `unvalued` with nothing, or not have that function at all (a revert without data that
     *         cost next to no gas; `IUnvalued`: an adapter without it holds none). Anything else, a `positions` or
     *         `unvalued` that fails, runs out of gas or cannot be decoded, is not nothing: that adapter's slice is set
     *         aside as before.
     */
    function holdsNothing(address adapter, IPriceRouter router) public view returns (bool) {
        (bool ok, Amount[] memory a, Amount[] memory d) = positionsOf(adapter, router);
        if (!ok || !_empty(a, d)) return false;
        if (a.length == 0) return true;
        uint256 g = gasleft();
        // Too little gas to tell a missing function from one that ran out: fail, so a gas estimate goes higher and
        // the answer never depends on the gas the caller sent.
        if (g < POSITIONS_GAS + POSITIONS_GAS / 32) revert ShortGas();
        (bool s, bytes memory ret) = adapter.staticcall{gas: POSITIONS_GAS}(abi.encodeCall(IUnvalued.unvalued, ()));
        if (!s) return ret.length == 0 && g - gasleft() < NO_FUNCTION_GAS;
        try IPositionsDecoderT(address(this)).decodeAmounts(ret) returns (Amount[] memory u) {
            for (uint256 j; j < u.length; ++j) {
                if (u[j].amount != 0) return false;
            }
            return true;
        } catch {
            return false;
        }
    }

    /// @dev An adapter's `unwindInputs`, or none when it cannot say (a broken adapter must not block leaving).
    function _unwindInputs(address adapter, uint256 x) private view returns (Amount[] memory need) {
        try IAdapter(adapter).unwindInputs(x) returns (Amount[] memory a) {
            return a;
        } catch {}
    }

    /// @notice After a slice `f` of `pre` was split off: the adapter still holds at least `(1 - f)` of every
    ///         position and owes no more than `(1 - f)` of every debt, within the slack per row. With `full` (a slice
    ///         paid out by someone other than its leaver), it also holds no more than `(1 - f)` of every position,
    ///         within the slack and a ten-thousandth of the slice: a third party can finalise a slice only when it
    ///         paid in full, never one a moment of illiquidity (a flash borrow) cut short. Reads it again (what the
    ///         split did). Returns whether it now owes anything, for the controller's `everOwed` mark.
    function checkSplit(Pos memory pre, IPriceRouter router, uint256 f, bool full) public view returns (bool owes) {
        (bool ok, Amount[] memory a, Amount[] memory d) = positionsOf(pre.adapter, router);
        if (!ok) revert Unmeasurable(pre.adapter);
        for (uint256 j; j < pre.assets.length; ++j) {
            address t = pre.assets[j].token;
            if (_seen(pre.assets, j)) continue;
            (uint256 b, uint256 slack) = _sumRows(pre.assets, t);
            uint256 x = _sum(a, t);
            if ((x + slack) * WAD < b * (WAD - f)) revert NotShrunk(pre.adapter, t, b, x);
            if (full && x * WAD > b * (WAD - f) + (slack * WAD + b * f / 10_000)) revert NotPaid(pre.adapter, t, b, x);
        }
        for (uint256 j; j < d.length; ++j) {
            address t = d[j].token;
            if (_seen(d, j)) continue;
            (uint256 b, uint256 slack) = _sumRows(pre.debts, t);
            uint256 x = _sum(d, t);
            if (x * WAD > b * (WAD - f) + slack * WAD) revert DebtChanged(pre.adapter, t, b, x);
        }
        return _owes(d);
    }

    /**
     * @notice What an exit in kind of `shares` now would ask the leaver to bring, per token: the debt repayment of
     *         its slices (with `marginBps` for interest when the slices are paid out later) beyond its own slice of
     *         the vault's counted balance of that token.
     */
    function inKindNeeds(address vault, uint256 shares, uint256 marginBps) public view returns (Amount[] memory out) {
        IFundController c = IFundController(IFundVault(vault).controller());
        uint256 supply = IERC20(vault).totalSupply();
        if (supply == 0 || shares == 0 || shares > supply) return out;
        ExitPlan memory p = exitPlan(c, shares * WAD / supply, new address[](0), marginBps, false);
        uint256 rows;
        for (uint256 k; k < p.needs.length; ++k) {
            rows += p.needs[k].length;
        }
        out = new Amount[](rows);
        uint256 m;
        for (uint256 k; k < p.needs.length; ++k) {
            for (uint256 j; j < p.needs[k].length; ++j) {
                address t = p.needs[k][j].token;
                uint256 at;
                while (at < m && out[at].token != t) ++at;
                if (at == m) out[m++].token = t;
                out[at].amount += p.needs[k][j].amount;
            }
        }
        for (uint256 i; i < m; ++i) {
            address t = out[i].token;
            uint256 slice = IFundVault(vault).isTracked(t) ? Math.mulDiv(IERC20(t).balanceOf(vault), shares, supply) : 0;
            out[i].amount = out[i].amount > slice ? out[i].amount - slice : 0;
        }
        assembly ("memory-safe") {
            mstore(out, m)
        }
    }

    // ---------------------------------------------------------------- when new money waits

    /**
     * @notice How a settlement now would treat new money (`ITeller.Hold`), and the token why. Every token the Fund
     *         holds is looked at: vault balances, every adapter's positions and debts, and what a wrapper (an index
     *         share) holds, through the router's look-through.
     *         - `HOLD_NO_MARKET`: a token with no market (class None) above `dustWad` whole tokens, or a claim an
     *           adapter reports as valued at zero (`IUnvalued`) above it. NAV counts it as nothing, yet an exit in
     *           kind hands its slice over, so a share minted now would take a slice it did not pay for. Nobody is
     *           minted (nor fee shares) until a pocket sets it aside for the holders of the moment
     *           (`TellerOps.pocket`, anyone), which a keeper runs before it settles. Inside a wrapper it cannot be
     *           pocketed: then new money waits until the manager sells the wrapper.
     *         - `HOLD_CLOSED`: a token in a closed market (`marketClosed`). Deposits still settle, at the router's
     *           worse-of prices, within the closure's net inflow cap.
     *         A no-market holding is reported first. A failing adapter or look-through is not judged here: the
     *         Fund's NAV is then incomplete, which makes new money wait too.
     */
    function depositHold(IFundController c, address vault, uint256 dustWad)
        public
        view
        returns (uint8 why, address token)
    {
        Snap memory s = snapshotAll(c, vault);
        (, FundBook.Rows memory rows) = FundBook.navs(s.tracked, s.balances, s.ok, s.assets, s.debts, c.router());
        (why, token,) = holdFrom(c.router(), rows, s, dustWad);
    }

    /// @notice `depositHold` from a settlement's one reading: the rows `FundBook.navs` priced (each token once, with
    ///         its class and whether its market is closed or it has a look-through, as the router said) and the
    ///         adapters read in `s`.
    function holdFrom(IPriceRouter router, FundBook.Rows memory rows, Snap memory s, uint256 dustWad)
        public
        view
        returns (uint8 why, address token, bool closed)
    {
        address none;
        address shut;
        for (uint256 k; k < rows.n; ++k) {
            if (rows.amounts[k] == 0) continue;
            address t = rows.tokens[k];
            if (rows.classes[k] == PriceClass.None) {
                if (none == address(0) && _aboveDust(t, rows.amounts[k], dustWad)) none = t;
                continue;
            }
            if (shut == address(0) && rows.flags[k] & 1 != 0) shut = t;
            if (rows.flags[k] & 2 != 0 && (none == address(0) || shut == address(0))) {
                (address n2, address c2) = _inside(router, t, rows.amounts[k], dustWad);
                if (none == address(0)) none = n2;
                if (shut == address(0)) shut = c2;
            }
        }
        // Claims valued at zero (`IUnvalued`): an adapter that has any reports a zero row for each in `positions`
        // (docs/ADAPTERS.md), so only those adapters are asked.
        for (uint256 i; none == address(0) && i < s.adapters.length; ++i) {
            if (!s.ok[i] || !_hasZeroRow(s.assets[i])) continue;
            Amount[] memory u = unvaluedOf(s.adapters[i]);
            for (uint256 j; j < u.length; ++j) {
                if (u[j].amount != 0 && _aboveDust(u[j].token, u[j].amount, dustWad)) {
                    none = u[j].token;
                    break;
                }
            }
        }
        closed = shut != address(0);
        if (none != address(0)) return (HOLD_NO_MARKET, none, closed);
        if (closed) return (HOLD_CLOSED, shut, true);
    }

    function _hasZeroRow(Amount[] memory a) private pure returns (bool) {
        for (uint256 j; j < a.length; ++j) {
            if (a[j].amount == 0) return true;
        }
        return false;
    }

    /// @dev What a wrapper holds (the router's look-through): the first no-market token above dust, and the first
    ///      token in a closed market, if any.
    function _inside(IPriceRouter router, address t, uint256 amount, uint256 dustWad)
        private
        view
        returns (address none, address shut)
    {
        ILookThrough lt;
        try ILookThroughRegistry(address(router)).lookThrough(t) returns (ILookThrough x) {
            lt = x;
        } catch {}
        if (address(lt) == address(0)) return (none, shut);
        try lt.underlying{gas: LOOK_THROUGH_GAS}(t, amount) returns (Amount[] memory parts) {
            for (uint256 i; i < parts.length; ++i) {
                if (parts[i].amount == 0 || parts[i].token == t) continue;
                (PriceClass cl, bool closed,) = IHoldInfo(address(router)).holdInfo(parts[i].token);
                if (cl == PriceClass.None) {
                    if (none == address(0) && _aboveDust(parts[i].token, parts[i].amount, dustWad)) {
                        none = parts[i].token;
                    }
                } else if (shut == address(0) && closed) {
                    shut = parts[i].token;
                }
            }
        } catch {}
    }

    /// @dev More than `dustWad` whole tokens (1e18 = one). A token whose decimals cannot be read is never dust.
    function _aboveDust(address t, uint256 amount, uint256 dustWad) private view returns (bool) {
        try IERC20Metadata(t).decimals() returns (uint8 d) {
            return d > 36 || amount > Math.mulDiv(dustWad, 10 ** d, WAD);
        } catch {
            return true;
        }
    }

    /// @notice An adapter's zero-valued claims (`IUnvalued`), under a gas cap; none when it does not say.
    function unvaluedOf(address adapter) public view returns (Amount[] memory u) {
        (bool ok, bytes memory ret) = adapter.staticcall{gas: POSITIONS_GAS}(abi.encodeCall(IUnvalued.unvalued, ()));
        if (!ok || ret.length == 0) return u;
        try IPositionsDecoderT(address(this)).decodeAmounts(ret) returns (Amount[] memory x) {
            return x;
        } catch {}
    }

    // ---------------------------------------------------------------- prices

    /**
     * @notice Match `deposits` (USDG) with `redeems` (shares) at the Fund's fair NAV per share (`nav`, read in the
     *         settlement). Returns the shares that change hands, the USDG paid for them and the price. All zero
     *         without a USDG price. The side that is smaller is matched in full; rounding favours the leavers by a
     *         raw unit at most when they are matched in full, and the entrants when they are. Neutral for the
     *         Fund, and at least as good for each side as its own net price (fair lies between bid and ask).
     */
    function matchAt(uint256 usdgUsd, uint256 unit, uint256 supply, uint256 deposits, uint256 redeems, uint256 nav)
        public
        pure
        returns (uint256 shares, uint256 paid, uint256 price)
    {
        if (nav == 0 || supply == 0 || usdgUsd == 0) return (0, 0, 0);
        price = Math.mulDiv(nav, WAD, supply);
        uint256 depositsUsd = Math.mulDiv(deposits, usdgUsd, unit);
        uint256 redeemsUsd = Math.mulDiv(redeems, price, WAD);
        if (redeemsUsd <= depositsUsd) {
            shares = redeems;
            paid = Math.mulDiv(redeemsUsd, unit, usdgUsd, Math.Rounding.Ceil);
            if (paid > deposits) paid = deposits;
        } else {
            paid = deposits;
            shares = Math.mulDiv(depositsUsd, WAD, price);
        }
    }

    /// @notice Shares `usdg` (raw) buys at the ask NAV (`navAsk` over `supply`), rounded down: the entrant pays the
    ///         ask, so the holders it joins never pay for its entry. `usdgUsd` is one whole USDG at bid.
    function mintFor(uint256 usdg, uint256 usdgUsd, uint256 unit, uint256 navAsk, uint256 supply)
        public
        pure
        returns (uint256)
    {
        return Math.mulDiv(Math.mulDiv(usdg, usdgUsd, unit), supply, navAsk);
    }

    /// @notice USDG (raw) `shares` are worth at the bid NAV (`navBid` over `supply`), rounded down. `usdgUsd` is one
    ///         whole USDG at ask.
    function payFor(uint256 shares, uint256 usdgUsd, uint256 unit, uint256 navBid, uint256 supply)
        public
        pure
        returns (uint256)
    {
        return Math.mulDiv(Math.mulDiv(shares, navBid, supply), unit, usdgUsd);
    }

    /// @notice The Fund's fair NAV per share in raw USDG per 1e18 shares; 0 when NAV or USDG cannot be priced.
    function usdgPerShare(IFundController c, address vault, address usdg, uint256 unit) public view returns (uint256) {
        (uint256 nav, bool ok) = navOf(c, Side.Fair);
        uint256 supply = IERC20(vault).totalSupply();
        (uint256 usd,, bool okU) = valueOf(c.router(), usdg, unit, Side.Fair);
        if (!ok || !okU || supply == 0 || usd == 0) return 0;
        return Math.mulDiv(Math.mulDiv(nav, unit, usd), WAD, supply);
    }

    /// @notice The controller's NAV, never reverting.
    function navOf(IFundController c, Side side) public view returns (uint256 usd, bool ok) {
        try c.nav(uint8(side)) returns (uint256 u, bool complete) {
            return (u, complete);
        } catch {
            return (0, false);
        }
    }

    /// @notice The router's value, never reverting.
    function valueOf(IPriceRouter router, address token, uint256 amount, Side side)
        public
        view
        returns (uint256, PriceClass, bool)
    {
        try router.value(token, amount, side) returns (uint256 usd, PriceClass cl, bool ok) {
            return (usd, cl, ok);
        } catch {
            return (0, PriceClass.None, false);
        }
    }

    // ---------------------------------------------------------------- reading positions

    /// @notice An adapter's positions under a gas cap, as a static call; ok = false instead of a revert.
    function positionsOf(address adapter, IPriceRouter router)
        public
        view
        returns (bool ok, Amount[] memory held, Amount[] memory owed)
    {
        bytes memory ret;
        (ok, ret) = adapter.staticcall{gas: POSITIONS_GAS}(abi.encodeCall(IAdapter.positions, (router)));
        if (!ok) return (false, held, owed);
        try IPositionsDecoderT(address(this)).decodePositions(ret) returns (Amount[] memory h, Amount[] memory o) {
            return (true, h, o);
        } catch {
            return (false, held, owed);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _pending(IFundController c) private view returns (bool) {
        try IExitUnits(address(c)).pendingExits() returns (uint256 n) {
            return n != 0;
        } catch {
            return false;
        }
    }

    function _empty(Amount[] memory a, Amount[] memory d) private pure returns (bool) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].amount != 0) return false;
        }
        for (uint256 i; i < d.length; ++i) {
            if (d[i].amount != 0) return false;
        }
        return true;
    }

    function _owes(Amount[] memory d) private pure returns (bool) {
        for (uint256 i; i < d.length; ++i) {
            if (d[i].amount != 0) return true;
        }
        return false;
    }

    function _sum(Amount[] memory a, address t) private pure returns (uint256 s) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token == t) s += a[i].amount;
        }
    }

    /// @dev What `rows` hold of `t` in all, and the slack: `TOLERANCE` for every row of it (at least one, at most
    ///      `MAX_SLACK_ROWS`).
    function _sumRows(Amount[] memory rows, address t) private pure returns (uint256 sum, uint256 slack) {
        uint256 n;
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].token == t) {
                sum += rows[i].amount;
                ++n;
            }
        }
        if (n == 0) n = 1;
        else if (n > MAX_SLACK_ROWS) n = MAX_SLACK_ROWS;
        slack = n * TOLERANCE;
    }

    /// @dev True when the token at `j` already appeared earlier (so each token is checked once, summed).
    function _seen(Amount[] memory a, uint256 j) private pure returns (bool) {
        for (uint256 i; i < j; ++i) {
            if (a[i].token == a[j].token) return true;
        }
        return false;
    }

    function _in(address[] memory list, address t) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == t) return true;
        }
        return false;
    }

    function _index(address[] memory list, uint256 n, address t) private pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (list[i] == t) return i;
        }
        return n;
    }

    function _put(address[] memory list, uint256 n, address t) private pure returns (uint256) {
        if (_index(list, n, t) != n) return n;
        list[n] = t;
        return n + 1;
    }

    function _cut(Pos[] memory a, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(a, n)
        }
    }

    function _cutA(address[] memory a, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(a, n)
        }
    }

    function _cutU(uint256[] memory a, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(a, n)
        }
    }
}
