// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Amount} from "../interfaces/IAdapter.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController} from "../interfaces/IFundController.sol";
import {IPriceRouter, PriceClass, Side} from "../interfaces/IPriceRouter.sol";
import {IPockets} from "../interfaces/IPockets.sol";
import {TellerMath, Snap, Pos} from "./TellerMath.sol";
import {FundFees} from "./Fees.sol";

/**
 * @title  TellerOps
 * @notice What the teller does with a Fund's tokens: take a leaver's slice out in kind, collect fees before it,
 *         accrue the Fund's fees as shares, write dust off, and set a holding NAV values at zero aside for the
 *         holders of the moment (a pocket). A linked library: it runs in the teller's context (the teller is the
 *         caller of every vault, controller and router call), so the teller stays small. The teller keeps all
 *         bookkeeping (requests, batches, what it owes); this library only moves and measures.
 *
 * @dev    ## Fee collection first
 *         Before an exit in kind reads the Fund, `grow(0)` is called on each of its enabled adapters (`collect`):
 *         liquidity adapters collect their trading fees into the vault (Fables also sweeps its pot's USDG) and
 *         change nothing else. Fees then count as holdings in the reading, so a leaver takes its slice of the
 *         fees, not all of them.
 */
library TellerOps {
    using SafeERC20 for IERC20;

    error NotDust(address token);
    error NotPocketable(address token);
    error NotHeld(address adapter);
    error PocketLoss(uint256 navBefore, uint256 navAfter);
    error VaultShort(address token);
    /// @notice A token pulled from the caller arrived short (a fee on transfer): escrow must be exactly what it says.
    error ShortArrival(address token);

    /// @notice `exitClaim` flags: the fees were collected in this same call; only whether the split works (the
    ///         caller rolls it back); the slice must pay in full (a third party pays it out).
    uint8 internal constant FRESH = 1;
    uint8 internal constant PROBE = 2;
    uint8 internal constant FULL = 4;

    event SlicePaid(address indexed vault, address indexed to, address indexed token, uint256 amount);
    event SliceFunded(address indexed vault, address indexed from, address indexed token, uint256 amount);
    event Left(address indexed vault, address indexed what);
    event FeesAccrued(address indexed vault, uint256 sharesMinted, uint256 lockedShares, uint256 burnedLocked);
    event RedeemedInKind(
        address indexed vault, address indexed from, address indexed to, uint256 shares, uint256 fractionWad
    );
    event Pocketed(address indexed vault, uint256 indexed id, address indexed token, uint256 amount);

    uint256 internal constant WAD = 1e18;
    /// @notice Most a pocket's unwinds may lower the Fund's fair NAV, in basis points (rounding, a position read
    ///         at the oracle against what it pays out). An unwind at a moved pool price returns more than the
    ///         position's oracle value, never less, so an honest unwind stays far inside it.
    uint256 public constant POCKET_LOSS_BPS = 10;
    /// @notice How long after it opened a pocket may still be added to (`pocket` with `into`).
    uint256 public constant POCKET_CONTINUE = 1 days;

    /// @notice What every operation needs to know about the Fund and the teller.
    struct Ctx {
        address vault;
        IFundController c;
        address usdg;
    }

    // ---------------------------------------------------------------- exits in kind

    /// @notice An exit in kind: `shares` (of `supply`) leave to `to`; `leave` lists adapters and tokens left behind;
    ///         `marginBps` is held on top of each slice's debt repayment for interest until it is paid out;
    ///         `skipEmpty` (an exit in parts) sets no slice aside of an adapter that holds and owes nothing.
    struct ExitArgs {
        uint256 shares;
        uint256 supply;
        address to;
        address[] leave;
        uint256 marginBps;
        bool skipEmpty;
    }

    /// @notice What an exit in kind set aside: per adapter, the leaver's slice in the adapter's units and the debt
    ///         repayment held in escrow for it.
    struct ExitStart {
        address[] adapters;
        uint256[] units;
        Amount[][] escrow;
    }

    /**
     * @notice The first part of an exit in kind (all of it when the slices are claimed in the same call):
     *         1. every enabled adapter's fees are collected into the vault, so the leaver's slice of the vault
     *            includes its share of them;
     *         2. the leaver's slice of every adapter not left behind (in parts, nor holding and owing nothing) is set
     *            aside in the controller (`reserveFor`):
     *            from now on the Fund's book no longer counts it, and nothing but its split may change that adapter
     *            until it is paid out (`exitClaim`);
     *         3. the shares are burned;
     *         4. the leaver gets its slice of every counted vault token now, less what the slices' debt repayment
     *            needs, which the teller holds in escrow until each slice is paid out (the leaver brings what its
     *            own slice of a token does not cover). The vault keeps exactly the other holders' part.
     */
    function exitStart(Ctx memory x, ExitArgs memory a, mapping(address => uint256) storage owed)
        public
        returns (ExitStart memory e)
    {
        uint256 f = a.shares * WAD / a.supply;
        collect(x.c, a.leave);
        TellerMath.ExitPlan memory p = TellerMath.exitPlan(x.c, f, a.leave, a.marginBps, a.skipEmpty);
        e.adapters = p.adapters;
        e.units = new uint256[](p.adapters.length);
        e.escrow = p.needs;
        for (uint256 k; k < p.adapters.length; ++k) {
            e.units[k] = x.c.reserveFor(p.adapters[k], f);
            if (e.units[k] == 0) e.escrow[k] = new Amount[](0);
        }
        IFundVault(x.vault).burn(msg.sender, a.shares);
        _paySlice(x, a, e.escrow, owed);
        for (uint256 i; i < a.leave.length; ++i) {
            emit Left(x.vault, a.leave[i]);
        }
        emit RedeemedInKind(x.vault, msg.sender, a.to, a.shares, f);
    }

    /// @dev The leaver's slice of every counted vault token (not left behind), less the escrow its slices' debt
    ///      repayment needs (held by the teller); what its slice does not cover the leaver brings.
    function _paySlice(
        Ctx memory x,
        ExitArgs memory a,
        Amount[][] memory escrow,
        mapping(address => uint256) storage owed
    ) private {
        Amount[] memory need = _sumNeeds(escrow);
        address[] memory tracked = IFundVault(x.vault).trackedTokens();
        for (uint256 i; i < tracked.length; ++i) {
            address t = tracked[i];
            uint256 n = _take(need, t);
            if (_has(a.leave, t)) {
                if (n != 0) _bring(address(this), t, n);
            } else {
                uint256 bal = IERC20(t).balanceOf(x.vault);
                uint256 slice = Math.mulDiv(bal, a.shares, a.supply);
                if (slice > n) {
                    IFundVault(x.vault).pay(t, a.to, slice - n);
                    emit SlicePaid(x.vault, a.to, t, slice - n);
                }
                uint256 kept = slice < n ? slice : n;
                if (kept != 0) IFundVault(x.vault).pay(t, address(this), kept);
                if (n > slice) _bring(address(this), t, n - slice);
                if (IERC20(t).balanceOf(x.vault) < bal - slice) revert VaultShort(t);
            }
            owed[t] += n;
        }
        // Debt tokens the vault does not count: the leaver brings the whole repayment.
        for (uint256 i; i < need.length; ++i) {
            if (need[i].amount == 0) continue;
            _bring(address(this), need[i].token, need[i].amount);
            owed[need[i].token] += need[i].amount;
        }
    }

    /**
     * @notice Pay out one adapter's slice of an exit in kind to `to` (anyone may call it for an exit in parts):
     *         1. unless the fees were collected in this same call (`fresh`), the adapter's fees are collected into
     *            the vault first, so its positions read without them (fees it earned after the exit began stay
     *            with the Fund);
     *         2. the slice's escrow goes into the vault and the controller splits the adapter by the slice's units
     *            (`splitUnitsFor`), repaying the slice's debt from the vault;
     *         3. measured: the adapter keeps at least `(1 - x)` of every position and owes no more than `(1 - x)`
     *            of every debt (an adapter that cannot be read is split anyway: leaving must work, and its debt
     *            mark is left to the controller); with `FULL` (someone other than the leaver pays it out) it must
     *            also have paid at least `x` of every position (`TellerMath.checkSplit`). The vault ends with at
     *            least what it held before the escrow went in: escrow left over goes to the leaver, a shortfall
     *            (interest beyond the margin) is brought by the caller.
     * @param  flags `FRESH`, `PROBE`, `FULL`.
     */
    function exitClaim(
        Ctx memory x,
        address adapter,
        uint256 units,
        Amount[] memory esc,
        address to,
        uint8 flags,
        mapping(address => uint256) storage owed
    ) public {
        if (flags & FRESH == 0 && x.c.isAdapter(adapter)) {
            try x.c.collectFor(adapter) {} catch {}
        }
        IPriceRouter router = x.c.router();
        Pos memory pre;
        pre.adapter = adapter;
        (pre.measured, pre.assets, pre.debts) = TellerMath.positionsOf(adapter, router);
        uint256[] memory vb = new uint256[](esc.length);
        for (uint256 i; i < esc.length; ++i) {
            vb[i] = IERC20(esc[i].token).balanceOf(x.vault);
            if (esc[i].amount != 0) IERC20(esc[i].token).safeTransfer(x.vault, esc[i].amount);
            owed[esc[i].token] -= esc[i].amount;
        }
        (, uint256 f) = x.c.splitUnitsFor(adapter, units, to);
        bool owes = !pre.measured || TellerMath.checkSplit(pre, router, f, flags & FULL != 0);
        if (flags & PROBE != 0) return; // only whether the split works (the caller rolls it back)
        _settleEscrow(x.vault, esc, vb, to);
        if (owes) x.c.noteDebt(adapter);
    }

    /// @dev The vault ends a slice's payout with at least what it held before its escrow went in: escrow left over
    ///      goes to the leaver, a shortfall is brought by the caller.
    function _settleEscrow(address vault, Amount[] memory esc, uint256[] memory vb, address to) private {
        for (uint256 i; i < esc.length; ++i) {
            address t = esc[i].token;
            uint256 bal = IERC20(t).balanceOf(vault);
            if (bal < vb[i]) {
                _bring(vault, t, vb[i] - bal); // measured, as the escrow was
            } else if (bal > vb[i]) {
                uint256 back = bal - vb[i] > esc[i].amount ? esc[i].amount : bal - vb[i];
                if (back != 0) IFundVault(vault).pay(t, to, back);
            }
        }
    }

    /// @notice A slice that will not be paid out: its units go back to the Fund, and its escrow into the vault. The
    ///         slice comes back with its share of the adapter's debt, which the escrow was held to repay: handing the
    ///         escrow to the leaver instead would let it leave an underwater adapter's debt to the holders.
    function exitRelease(
        Ctx memory x,
        address adapter,
        uint256 units,
        Amount[] memory esc,
        mapping(address => uint256) storage owed
    ) public {
        x.c.releaseUnits(adapter, units);
        for (uint256 i; i < esc.length; ++i) {
            owed[esc[i].token] -= esc[i].amount;
            if (esc[i].amount != 0) IERC20(esc[i].token).safeTransfer(x.vault, esc[i].amount);
        }
        emit Left(x.vault, adapter);
    }

    function _sumNeeds(Amount[][] memory escrow) private pure returns (Amount[] memory need) {
        uint256 rows;
        for (uint256 k; k < escrow.length; ++k) {
            rows += escrow[k].length;
        }
        need = new Amount[](rows);
        uint256 m;
        for (uint256 k; k < escrow.length; ++k) {
            for (uint256 j; j < escrow[k].length; ++j) {
                address t = escrow[k][j].token;
                uint256 at;
                while (at < m && need[at].token != t) ++at;
                if (at == m) need[m++].token = t;
                need[at].amount += escrow[k][j].amount;
            }
        }
        assembly ("memory-safe") {
            mstore(need, m)
        }
    }

    /// @dev `need`'s amount for `t`, zeroed in the list (what is left is for tokens the vault does not count).
    function _take(Amount[] memory need, address t) private pure returns (uint256 n) {
        for (uint256 i; i < need.length; ++i) {
            if (need[i].token == t) {
                n = need[i].amount;
                need[i].amount = 0;
                return n;
            }
        }
    }

    /// @dev The controller's `everOwed` mark for adapters that reported a debt after the teller moved them (or
    ///      could not be measured); the controller reads each itself and marks it once.
    function _noteDebts(IFundController c, address[] memory owing) private {
        for (uint256 i; i < owing.length; ++i) {
            c.noteDebt(owing[i]);
        }
    }

    /// @notice `grow(0)` on every enabled adapter not left behind, so fees count as holdings before an exit reads
    ///         the Fund. A failure is skipped: a broken adapter never blocks leaving. Fees an adapter earned while
    ///         an earlier leaver's slice of it waits go to the vault too, so they stay with the Fund (as when that
    ///         slice is paid out: `exitClaim` collects first).
    function collect(IFundController c, address[] memory leave) public {
        address[] memory ads = c.adapters();
        for (uint256 i; i < ads.length; ++i) {
            if (!c.isAdapter(ads[i]) || _has(leave, ads[i])) continue;
            try c.collectFor(ads[i]) {} catch {}
        }
    }

    // ---------------------------------------------------------------- fees

    /// @notice Accrue the Fund's fees as shares: burn first-loss shares the fall below the mark took, mint the
    ///         split. `nav` is the Fund's bid NAV and `ok` its completeness, from the settlement's one reading;
    ///         `ok` false charges management only.
    function accrue(Ctx memory x, FundFees fees, uint256 nav, bool ok) public {
        IFundVault v = IFundVault(x.vault);
        FundFees.Accrual memory a = fees.accrue(x.vault, IERC20(x.vault).totalSupply(), nav, ok);
        if (a.burnLocked != 0) v.burn(address(fees), a.burnLocked);
        if (a.managerShares != 0) v.mint(a.manager, a.managerShares);
        if (a.aixShares != 0) v.mint(a.aix, a.aixShares);
        if (a.treasuryShares != 0) v.mint(a.treasury, a.treasuryShares);
        if (a.lockedShares != 0) v.mint(address(fees), a.lockedShares);
        uint256 minted = a.managerShares + a.aixShares + a.treasuryShares + a.lockedShares;
        if (minted != 0 || a.burnLocked != 0) emit FeesAccrued(x.vault, minted, a.lockedShares, a.burnLocked);
    }

    // ---------------------------------------------------------------- holders' pockets

    /**
     * @notice Set `token` aside for the holders of this moment: a token with no market price (class None), or a
     *         claim in `token` that adapters report as valued at zero (`IUnvalued`), above `dustWad` whole tokens.
     *         Anyone may call it. Takes a snapshot of the Fund's shares and opens pocket `id`, or, with `into`, adds
     *         to pocket `into` (same token, opened within `POCKET_CONTINUE`, and no share minted since: the holders
     *         it belongs to are still the only ones), so a token many adapters hold can be pocketed over several
     *         transactions. Then:
     *         - for each adapter in `adapters` (the caller names those that hold it; each must): an adapter that
     *           implements `IPocketable` moves its unvalued claims in `token` into the pocket itself (paying the
     *           rest over time through `drain`); any other is unwound whole into the vault (a no-market token cannot
     *           be taken out of a position on its own), what it returns is counted, and that adapter's positions plus
     *           what the vault got from it may be worth at most `POCKET_LOSS_BPS` less, at fair, than its positions
     *           were (an unwind at a moved pool price returns more than a position's oracle value, never less);
     *         - for a no-market token, the vault's whole balance goes to the pocket and the token is no longer
     *           counted.
     *         What the caller leaves out stays in the Fund, and the settlement's hold check still sees it: a keeper
     *         names every adapter that holds the token, or new money keeps waiting.
     */
    function pocket(
        Ctx memory x,
        address token,
        address[] calldata adapters,
        uint256 dustWad,
        IPockets pockets,
        uint256 into
    ) public returns (uint256 id, uint256 amount) {
        bool none = x.c.router().classOf(token) == PriceClass.None;
        (uint256 total, bool[] memory own) = _held(x, token, adapters, none);
        id = _openPocket(x.vault, token, total, dustWad, pockets, into);
        pockets.mark(token); // the pocket is credited with what arrives from here on, measured
        _pocketAdapters(x, token, adapters, own, address(pockets), id);
        if (none) {
            uint256 bal = IERC20(token).balanceOf(x.vault);
            // The whole balance: what the unwinds just returned is not counted (`_unwindMeasured` leaves `token`
            // out), and an uncounted crumb is nobody's but the holders'.
            if (bal != 0) IFundVault(x.vault).pay(token, address(pockets), bal);
            IFundVault(x.vault).untrack(token);
        }
        pockets.credit(x.vault, id);
        (, amount,,) = pockets.pocketInfo(x.vault, id);
        emit Pocketed(x.vault, id, token, amount);
    }

    /// @dev A new pocket (a snapshot) for a holding above dust, or `into` when it may still be added to: the same
    ///         token, opened within `POCKET_CONTINUE`, and no share minted since.
    function _openPocket(address vault, address token, uint256 total, uint256 dustWad, IPockets pockets, uint256 into)
        private
        returns (uint256 id)
    {
        if (into == 0) {
            if (!_aboveDust(token, total, dustWad)) revert NotPocketable(token);
            id = IFundVault(vault).snapshot();
            pockets.open(vault, id, token, IERC20(vault).totalSupply());
            return id;
        }
        (address t,, uint256 supplyAt, uint64 at) = pockets.pocketInfo(vault, into);
        if (
            t != token || total == 0 || IERC20(vault).totalSupply() > supplyAt || block.timestamp > at + POCKET_CONTINUE
        ) revert NotPocketable(token);
        return into;
    }

    /// @dev What the Fund holds of `token` that NAV values at zero: the vault's counted balance of a no-market
    ///      token and, per named adapter (each must be listed, named once, and hold some), its unvalued claims in
    ///      `token` (`own`: the adapter's own pocket hook is tried for them) and, for a no-market token, its rows.
    function _held(Ctx memory x, address token, address[] calldata adapters, bool none)
        private
        view
        returns (uint256 total, bool[] memory own)
    {
        IPriceRouter router = x.c.router();
        total = none && IFundVault(x.vault).isTracked(token) ? IERC20(token).balanceOf(x.vault) : 0;
        own = new bool[](adapters.length);
        for (uint256 i; i < adapters.length; ++i) {
            if (!x.c.isListed(adapters[i]) || _has2(adapters, i)) revert NotHeld(adapters[i]);
            uint256 u = _sumOf(TellerMath.unvaluedOf(adapters[i]), token);
            uint256 h;
            if (none) {
                (bool ok, Amount[] memory a,) = TellerMath.positionsOf(adapters[i], router);
                if (ok) h = _sumOf(a, token);
            }
            if (u == 0 && h == 0) revert NotHeld(adapters[i]);
            own[i] = u != 0;
            total += u + h;
        }
    }

    /// @dev Each named adapter: its own `IPocketable` hook for an unvalued claim, else a whole unwind, measured on
    ///      that adapter.
    function _pocketAdapters(
        Ctx memory x,
        address token,
        address[] calldata adapters,
        bool[] memory own,
        address pockets,
        uint256 id
    ) private {
        for (uint256 i; i < adapters.length; ++i) {
            if (own[i]) {
                // An adapter with its own hook pays its unvalued claim into the pocket; one that refuses for a
                // reason says so (the pocket fails). Only one without the hook (no reason given) is unwound whole.
                try x.c.pocketFor(adapters[i], token, pockets, id) {
                    continue;
                } catch (bytes memory err) {
                    if (err.length != 0) {
                        assembly ("memory-safe") {
                            revert(add(err, 0x20), mload(err))
                        }
                    }
                }
            }
            _unwindMeasured(x, adapters[i], token);
        }
    }

    /// @dev Unwind `adapter` whole into the vault, count what it returns (but `token`), and check that its positions
    ///      plus what the vault got from it are worth, at fair, at least what its positions were, less
    ///      `POCKET_LOSS_BPS`.
    function _unwindMeasured(Ctx memory x, address adapter, address token) private {
        IPriceRouter router = x.c.router();
        (bool ok, Amount[] memory a, Amount[] memory d) = TellerMath.positionsOf(adapter, router);
        if (!ok) revert NotHeld(adapter);
        address[] memory toks = _tokensOf(a, d);
        uint256[] memory vb = new uint256[](toks.length);
        for (uint256 i; i < toks.length; ++i) {
            vb[i] = IERC20(toks[i]).balanceOf(x.vault);
        }
        int256 before = _worth(router, a) - _worth(router, d);
        Amount[] memory got = x.c.unwindFor(adapter, WAD);
        for (uint256 j; j < got.length; ++j) {
            if (got[j].amount != 0 && got[j].token != token) IFundVault(x.vault).track(got[j].token);
        }
        (ok, a, d) = TellerMath.positionsOf(adapter, router);
        if (!ok) revert NotHeld(adapter);
        int256 afterward = _worth(router, a) - _worth(router, d);
        for (uint256 i; i < toks.length; ++i) {
            uint256 bal = IERC20(toks[i]).balanceOf(x.vault);
            (uint256 v,,) = TellerMath.valueOf(router, toks[i], bal > vb[i] ? bal - vb[i] : vb[i] - bal, Side.Fair);
            afterward = bal > vb[i] ? afterward + int256(v) : afterward - int256(v);
        }
        if (afterward * 10_000 < before * int256(10_000 - POCKET_LOSS_BPS)) {
            revert PocketLoss(uint256(before > 0 ? before : int256(0)), uint256(afterward > 0 ? afterward : int256(0)));
        }
        _noteDebts(x.c, _one(adapter));
    }

    function _worth(IPriceRouter router, Amount[] memory list) private view returns (int256 usd) {
        for (uint256 i; i < list.length; ++i) {
            (uint256 v,, bool ok) = TellerMath.valueOf(router, list[i].token, list[i].amount, Side.Fair);
            if (!ok) revert PocketLoss(0, 0);
            usd += int256(v);
        }
    }

    function _tokensOf(Amount[] memory a, Amount[] memory d) private pure returns (address[] memory t) {
        t = new address[](a.length + d.length);
        uint256 n;
        for (uint256 i; i < a.length + d.length; ++i) {
            address x = i < a.length ? a[i].token : d[i - a.length].token;
            uint256 k;
            while (k < n && t[k] != x) ++k;
            if (k == n) t[n++] = x;
        }
        assembly ("memory-safe") {
            mstore(t, n)
        }
    }

    function _sumOf(Amount[] memory list, address t) private pure returns (uint256 s) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i].token == t) s += list[i].amount;
        }
    }

    /// @dev True when `list[i]` appeared earlier in `list`.
    function _has2(address[] calldata list, uint256 i) private pure returns (bool) {
        for (uint256 k; k < i; ++k) {
            if (list[k] == list[i]) return true;
        }
        return false;
    }

    function _one(address a) private pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    /// @dev More than `dustWad` whole tokens (1e18 = one). A token whose decimals cannot be read is never dust.
    function _aboveDust(address t, uint256 amount, uint256 dustWad) private view returns (bool) {
        if (amount == 0) return false;
        try IERC20Metadata(t).decimals() returns (uint8 d) {
            return d > 36 || amount > Math.mulDiv(dustWad, 10 ** d, WAD);
        } catch {
            return true;
        }
    }

    // ---------------------------------------------------------------- dust

    /// @notice Stop counting a holding worth less than `dustUsd`, or one that cannot be priced and is no more than
    ///         `maxWad` whole tokens. The crumbs stay in the vault, uncounted.
    function writeOff(Ctx memory x, address token, uint256 dustUsd, uint256 maxWad) public returns (uint256 bal) {
        bal = _dustBalance(x, token);
        if (bal != 0) {
            (uint256 usd, PriceClass cl, bool ok) = TellerMath.valueOf(x.c.router(), token, bal, Side.Fair);
            if (ok && cl != PriceClass.None) {
                if (usd >= dustUsd) revert NotDust(token);
            } else {
                uint8 d;
                try IERC20Metadata(token).decimals() returns (uint8 dec) {
                    d = dec;
                } catch {
                    revert NotDust(token);
                }
                if (d > 36 || bal * 1e18 > maxWad * 10 ** d) revert NotDust(token);
            }
        }
        IFundVault(x.vault).untrack(token);
    }

    /// @dev A holding that may be written off: tracked, not USDG, and not a token any of the Fund's adapters holds
    ///      or owes (a borrowed token the vault holds none of is still the Fund's debt). An adapter that cannot be
    ///      read cannot show it does not hold the token, so it blocks this too.
    function _dustBalance(Ctx memory x, address token) private view returns (uint256) {
        if (token == x.usdg || !IFundVault(x.vault).isTracked(token)) revert NotDust(token);
        address[] memory ads = x.c.adapters();
        IPriceRouter router = x.c.router();
        for (uint256 i; i < ads.length; ++i) {
            (bool ok, Amount[] memory a, Amount[] memory d) = TellerMath.positionsOf(ads[i], router);
            if (!ok || _lists(a, token) || _lists(d, token)) revert NotDust(token);
        }
        return IERC20(token).balanceOf(x.vault);
    }

    function _lists(Amount[] memory list, address token) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i].token == token) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Pull `amount` of `token` from the caller to `dest`, measured: a token that arrives short (a fee on
    ///      transfer) would let escrow promise more than arrived, drawn from other Funds' balances here.
    function _bring(address dest, address token, uint256 amount) private {
        uint256 before = IERC20(token).balanceOf(dest);
        IERC20(token).safeTransferFrom(msg.sender, dest, amount);
        if (IERC20(token).balanceOf(dest) - before < amount) revert ShortArrival(token);
        emit SliceFunded(dest, msg.sender, token, amount);
    }

    function _has(address[] memory list, address t) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == t) return true;
        }
        return false;
    }
}
