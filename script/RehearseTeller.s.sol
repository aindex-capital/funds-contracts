// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Teller} from "../src/core/Teller.sol";
import {FundFees} from "../src/core/Fees.sol";
import {FundController} from "../src/core/FundController.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {ITeller} from "../src/interfaces/ITeller.sol";
import {IPockets} from "../src/interfaces/IPockets.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {IPriceRouter, PriceClass, Side} from "../src/interfaces/IPriceRouter.sol";
import {Amount} from "../src/interfaces/IAdapter.sol";

/**
 * @title  RehearseTeller
 * @notice The public half of the Funds rehearsal, cash in at NAV: deposits whose USDG enters the Fund as cash and
 *         mints shares at the ask NAV, batches matching entrants and cash leavers at fair, cash exits paid from the
 *         Fund's USDG at bid (and in kind for what the cash cannot cover), exits in kind in one transaction and in
 *         parts, a weekend settlement at the router's worse-of prices within the closure's inflow cap, a holders'
 *         pocket for a token downgraded to no market, and fees. Run step by step by `script/rehearse-funds.sh` on an
 *         anvil fork of Robinhood Chain (each step is one `--sig` call, with the anvil key of whoever acts); nothing
 *         here is meant for mainnet.
 *
 * @dev    Every settlement is judged after the fact: each entrant paid at most the round's ask NAV per share (or
 *         the batch's fair price where it was matched), each leaver got at least the bid NAV per share for the
 *         shares paid in cash (or the fair price where matched), and the holders who stayed kept their fair NAV per
 *         share (fee shares counted apart) to within rounding. Exits in kind and pockets are judged on the holders
 *         who stay.
 */
contract RehearseTeller is Script {
    uint256 internal constant WAD = 1e18;
    /// @dev Holders who stay may lose at most this much NAV per share to rounding (1e18 = all).
    uint256 internal constant STAY_TOLERANCE = 5e14; // 0.05%

    Teller internal tel;
    FundController internal controller;
    IPriceRouter internal router;
    address internal vault;
    address internal usdg;
    string internal rec;

    struct Before {
        uint256 nav;
        uint256 supply;
        uint256 feeHeld;
        uint256[] ids;
    }

    function _load() internal {
        rec = vm.readFile(vm.envOr("FUND_RECORD", string("deployments/rehearsal-fund.json")));
        controller = FundController(vm.parseJsonAddress(rec, ".controller"));
        vault = controller.vault();
        tel = Teller(vm.parseJsonAddress(rec, ".teller"));
        router = controller.router();
        usdg = tel.usdg();
    }

    // ================================================================ requests

    /// @notice Queue a deposit of `amount` raw USDG asking at least 98% of the shares it buys at the ask NAV now.
    function deposit(uint256 pk, uint256 amount) external {
        _load();
        uint256 minShares = _sharesAt(amount, Side.Ask) * 98 / 100;
        vm.startBroadcast(pk);
        IERC20(usdg).approve(address(tel), amount);
        uint256 id = tel.requestDeposit(vault, amount, minShares);
        vm.stopBroadcast();
        console.log("deposit request", id, "batch", tel.request(id).batch);
        console.log("   USDG (raw), least shares:", amount, minShares);
    }

    /// @notice Queue a cash exit of `bps` of the caller's shares asking at least 98% of their bid value (a price:
    ///         judged on the part the Fund pays in cash).
    function redeem(uint256 pk, uint256 bps) external {
        _load();
        address who = vm.addr(pk);
        uint256 shares = IERC20(vault).balanceOf(who) * bps / 10_000;
        uint256 minUsdg = _usdgAt(shares, Side.Bid) * 98 / 100;
        vm.startBroadcast(pk);
        IERC20(vault).approve(address(tel), shares);
        uint256 id = tel.requestRedeem(vault, shares, minUsdg);
        vm.stopBroadcast();
        console.log("cash exit request", id, "batch", tel.request(id).batch);
        console.log("   shares, least USDG (raw):", shares, minUsdg);
    }

    // ================================================================ the keeper

    /// @notice Print `CUTOFF <batch> <cut-off>` for the batch the latest request joined.
    function cutoff() external {
        _load();
        uint64 b = tel.request(tel.nextId() - 1).batch;
        console.log(string.concat("CUTOFF ", vm.toString(b), " ", vm.toString(tel.batch(vault, b).cutoff)));
    }

    /// @notice Print `WAITS <batch> <cut-off>` when a batch's deposits still wait for a later round.
    function waits() external {
        _load();
        uint64 id = _target(false);
        if (id == 0) return;
        ITeller.Batch memory b = tel.batch(vault, id);
        if (b.rounds != 0 && !b.settled) console.log(string.concat("WAITS ", vm.toString(id), " ", vm.toString(b.cutoff)));
    }

    /// @notice Settle the closed batch (or the next round of one whose deposits wait), claim every request it paid,
    ///         and judge the result (see the contract notes).
    function settle(uint256 pk) external {
        _load();
        uint64 id = _target(true);
        require(id != 0, "no closed batch to settle");
        (ITeller.Hold hold, address why) = tel.depositHold(vault);
        if (hold != ITeller.Hold.Open) console.log("   hold (1 market closed: weekend prices, 2 a pocket first):", uint8(hold), why);
        Before memory pre = _before(id);
        uint16 round = tel.batch(vault, id).rounds + 1;
        vm.startBroadcast(pk);
        tel.settle(vault, id, new uint256[](0));
        uint256[] memory got = new uint256[](pre.ids.length * 2);
        bool[] memory paid = new bool[](pre.ids.length);
        for (uint256 i; i < pre.ids.length; ++i) {
            (,, bool waiting) = tel.due(pre.ids[i]);
            if (waiting) continue;
            (got[2 * i], got[2 * i + 1]) = tel.claim(pre.ids[i]);
            paid[i] = true;
        }
        vm.stopBroadcast();
        ITeller.Batch memory b = tel.batch(vault, id);
        console.log("batch", id, "round", round);
        console.log("   matched shares, matched USDG, fair NAV/share:", b.matchedShares, b.matchedUsdg, b.navPerShare);
        ITeller.Round memory ro = tel.round(vault, id, round);
        console.log("   deposits in this round (USDG), shares, ask NAV/share:", ro.dep, ro.minted, ro.askPerShare);
        if (round == 1) console.log("   leavers: USDG out, bid NAV/share, shares back:", b.usdgOut, b.bidPerShare, b.sharesBack);
        if (!b.settled) console.log("   deposits still waiting (USDG):", b.deposits);
        _judge(id, pre, got, paid);
        _stayers("settlement", pre.nav, pre.supply, pre.feeHeld);
    }

    /// @dev The batch to settle: the oldest one that closed and still has something to settle.
    function _target(bool closedOnly) internal view returns (uint64) {
        uint64 open = tel.fund(vault).openBatch;
        for (uint64 b = open > 12 ? open - 12 : 1; b <= open + 1; ++b) {
            ITeller.Batch memory x = tel.batch(vault, b);
            if (x.cutoff == 0 || x.settled || x.count == 0) continue;
            if (closedOnly && block.timestamp < x.cutoff) continue;
            return b;
        }
        return 0;
    }

    // ================================================================ exits in kind

    /// @notice Leave in kind with `bps` of the caller's shares, in one transaction.
    function inKind(uint256 pk, uint256 bps) external {
        _load();
        address who = vm.addr(pk);
        uint256 shares = IERC20(vault).balanceOf(who) * bps / 10_000;
        (uint256 nav0, uint256 s0, uint256 f0) = _state();
        vm.startBroadcast(pk);
        _bring(tel.inKindNeeds(vault, shares));
        tel.redeemInKind(vault, shares, who);
        vm.stopBroadcast();
        console.log("exit in kind, one transaction: shares", shares);
        _stayers("exit in kind", nav0, s0, f0);
    }

    /// @notice Leave in kind with `bps` of the caller's shares in parts: the shares and the vault tokens first, then
    ///         each adapter's slice in a transaction of its own.
    function inKindParts(uint256 pk, uint256 bps) external {
        _load();
        address who = vm.addr(pk);
        uint256 shares = IERC20(vault).balanceOf(who) * bps / 10_000;
        (uint256 nav0, uint256 s0, uint256 f0) = _state();
        address[] memory ads = controller.adapters();
        vm.startBroadcast(pk);
        _bring(tel.inKindNeedsInParts(vault, shares));
        uint256 id = tel.startInKind(vault, shares, who, new address[](0));
        vm.stopBroadcast();
        console.log("exit in kind in parts: exit", id, "shares", shares);
        _stayers("exit in parts, after the start (slices set aside)", nav0, s0, f0);
        for (uint256 i; i < ads.length; ++i) {
            if (tel.exitUnits(id, ads[i]) == 0) continue;
            address[] memory one = new address[](1);
            one[0] = ads[i];
            vm.startBroadcast(pk);
            tel.claimInKind(id, one);
            vm.stopBroadcast();
        }
        require(tel.exit(id).pending == 0, "a slice is still to be paid out");
        require(controller.pendingExits() == 0, "an adapter still owes a leaver");
        _stayers("exit in parts, every slice paid", nav0, s0, f0);
    }

    /// @notice Leave in kind with every share the caller holds (the ones a cash exit handed back).
    function backInKind(uint256 pk) external {
        _load();
        address who = vm.addr(pk);
        uint256 shares = IERC20(vault).balanceOf(who);
        require(shares != 0, "no shares came back");
        (uint256 nav0, uint256 s0, uint256 f0) = _state();
        vm.startBroadcast(pk);
        _bring(tel.inKindNeeds(vault, shares));
        tel.redeemInKind(vault, shares, who);
        vm.stopBroadcast();
        console.log("the shares the Fund's cash could not cover leave in kind:", shares);
        _stayers("exit in kind of the shares handed back", nav0, s0, f0);
    }

    /// @dev Approve the teller what an exit in kind may ask the leaver to bring (its slices' debt beyond its slice of
    ///      the vault), with room for a little interest.
    function _bring(Amount[] memory need) internal {
        for (uint256 i; i < need.length; ++i) {
            if (need[i].amount != 0) IERC20(need[i].token).approve(address(tel), need[i].amount * 2 + 10);
        }
    }

    // ================================================================ cash, weekends, pockets, fees

    /// @notice The cheap cash view the manager reads to see new cash to invest.
    function cash() external {
        _load();
        (uint256 now_, uint256 qIn, uint256 qOut, uint256 lastNav, uint256 lastCash, uint64 at) = tel.cash(vault);
        console.log("cash view: USDG in the vault, queued USDG in, queued shares out:", now_, qIn, qOut);
        console.log("   at the last settlement: fair NAV (USD 1e18), cash, time:", lastNav, lastCash, at);
        if (lastNav > lastCash * 1e12) console.log("   invested then (USD 1e18):", lastNav - lastCash * 1e12);
    }

    /// @notice What the router says of `token` now (fair, bid, ask) and of the Fund's current closure.
    function quote(address token) external {
        _load();
        IPriceRouter.Quote memory q = router.quote(token);
        console.log("quote fair, bid, ask (USD 1e18):", q.fair, q.bid, q.ask);
        console.log("   market closed:", router.marketClosed(token));
        Teller.Closure memory c = tel.closure(vault);
        console.log("   closure since, NAV sized on, inflow so far:", c.since, c.nav, c.inflow);
        console.log("   inflow cap (bps of NAV):", tel.weekendInflowBps());
    }

    /// @notice The closure's net inflow must stay within its cap.
    function inflowCheck() external {
        _load();
        Teller.Closure memory c = tel.closure(vault);
        uint256 cap = c.nav * tel.weekendInflowBps() / 10_000;
        console.log("closure inflow, cap (USD 1e18):", c.inflow, cap);
        require(c.since == 0 || c.inflow <= cap, "weekend inflow above its cap");
    }

    /// @notice The router's owner downgrades `token` to no market (applies at once).
    function downgrade(uint256 pk, address token) external {
        _load();
        vm.startBroadcast(pk);
        PriceRouter(address(router)).propose(
            token,
            PriceRouter.Config({
                primary: IPriceSource(address(0)),
                check: IPriceSource(address(0)),
                class_: PriceClass.None,
                haircutBps: 0,
                maxDeviationBps: 0,
                decimals: 0,
                chained: 0
            })
        );
        vm.stopBroadcast();
        (ITeller.Hold hold, address why) = tel.depositHold(vault);
        console.log("downgraded to no market; hold (2: a pocket first):", uint8(hold), why);
    }

    /// @notice Anyone sets `token` aside for the holders of this moment, then the pocket pays the listed holders
    ///         and the owner (its opening shares sit in its wallet, so the snapshot counts them).
    function pocket(uint256 pk, address token, address[] calldata holders) external {
        _load();
        (uint256 nav0, uint256 s0, uint256 f0) = _state();
        uint256 held = IERC20(token).balanceOf(vault);
        vm.startBroadcast(pk);
        uint256 id = tel.pocket(vault, token, new address[](0), 0);
        IPockets p = tel.pockets();
        uint256 total;
        for (uint256 i; i < holders.length; ++i) total += p.claim(vault, id, holders[i]);
        total += p.claim(vault, id, controller.owner());
        vm.stopBroadcast();
        (, uint256 amount, uint256 supplyAt) = p.pocket(vault, id);
        console.log("pocket", id, "token amount:", amount);
        console.log("   share supply at the snapshot, the vault held before:", supplyAt, held);
        console.log("   claimed by the holders and the owner:", total);
        require(amount == held && IERC20(token).balanceOf(vault) == 0, "the pocket did not take the holding");
        require(total <= amount, "claims above the pocket");
        _stayers("pocket", nav0, s0, f0);
    }

    function fees() external {
        _load();
        FundFees ff = tel.fees();
        FundFees.Terms memory t = ff.terms(vault);
        (uint256 lockedShares, uint256 openLocks) = ff.locked(vault);
        (uint16 mb, uint16 ab, uint16 tb, address aix, address tr) = ff.config().split();
        console.log("fees: management, performance (bps):", t.management, t.performance);
        console.log("   high-water mark (USD per share, 1e18):", ff.highWaterMark(vault));
        console.log("   split manager / AIX / treasury:", mb, ab, tb);
        console.log("   shares held by manager recipient, AIX, treasury:");
        console.log("     ", IERC20(vault).balanceOf(t.recipient), IERC20(vault).balanceOf(aix), IERC20(vault).balanceOf(tr));
        console.log("   locked first-loss shares, open locks:", lockedShares, openLocks);
    }

    // ================================================================ judging

    function _before(uint64 id) internal view returns (Before memory pre) {
        (pre.nav, pre.supply, pre.feeHeld) = _state();
        uint256[] memory all = tel.batchRequests(vault, id);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            ITeller.Request memory q = tel.request(all[i]);
            if (q.batch == id && q.status == ITeller.Status.Pending && q.round == 0) all[n++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(all, n)
        }
        pre.ids = all;
    }

    /// @dev Each entrant paid at most the dearest price the round could charge (ask, or fair where matched); each
    ///      leaver got at least the cheapest it could get for its cash part (bid, or fair where matched).
    function _judge(uint64 id, Before memory pre, uint256[] memory got, bool[] memory paid) internal view {
        ITeller.Batch memory b = tel.batch(vault, id);
        (uint256 usdgUsd,,) = router.value(usdg, 1e6, Side.Fair);
        for (uint256 i; i < pre.ids.length; ++i) {
            if (!paid[i]) continue;
            ITeller.Request memory q = tel.request(pre.ids[i]);
            if (q.kind == ITeller.Kind.Deposit) {
                uint256 shares = got[2 * i];
                if (shares == 0) continue; // paid back (a Fund winding down)
                uint16 rd = q.round != 0 ? q.round : b.rounds;
                ITeller.Round memory ro = tel.round(vault, id, rd);
                uint256 top = ro.askPerShare > b.navPerShare || rd != 1 ? ro.askPerShare : b.navPerShare;
                if (top == 0) top = b.navPerShare;
                uint256 perShare = uint256(q.amount) * usdgUsd / 1e6 * WAD / shares;
                console.log("   entrant", pre.ids[i], "paid per share, dearest allowed (USD 1e18):", perShare);
                console.log("      ", top);
                require(perShare <= top + top / 1e6 + 1, "an entrant paid above ask");
            } else {
                uint256 back = got[2 * i];
                uint256 out = got[2 * i + 1];
                uint256 sold = q.amount - back;
                if (sold == 0) continue;
                uint256 low = b.bidPerShare;
                if (b.matchedShares != 0 && (low == 0 || b.navPerShare < low)) low = b.navPerShare;
                uint256 perShare = out * usdgUsd / 1e6 * WAD / sold;
                console.log("   leaver", pre.ids[i], "got per cash share, least allowed (USD 1e18):", perShare);
                console.log("      ", low, "shares back:", back);
                require(perShare + perShare / 1e6 + 1 >= low, "a leaver got below bid");
            }
        }
    }

    /// @dev The holders who stayed: fair NAV per share now against before, the fee shares minted since counted
    ///      apart (they are what the fees cost, not a loss).
    function _stayers(string memory what, uint256 nav0, uint256 supply0, uint256 feeHeld0) internal view {
        (uint256 nav1, uint256 supply1, uint256 feeHeld1) = _state();
        uint256 fee = feeHeld1 > feeHeld0 ? feeHeld1 - feeHeld0 : 0;
        uint256 before = nav0 * WAD / (supply0 + fee);
        uint256 afterward = nav1 * WAD / supply1;
        console.log(string.concat("   holders who stayed, ", what, ": fair NAV per share before, after:"), before, afterward);
        require(afterward + before * STAY_TOLERANCE / WAD >= before, "holders who stayed lost value");
    }

    function _state() internal view returns (uint256 nav, uint256 supply, uint256 feeHeld) {
        bool ok;
        (nav, ok) = controller.nav(uint8(Side.Fair));
        require(ok, "book incomplete");
        supply = IERC20(vault).totalSupply();
        FundFees ff = tel.fees();
        FundFees.Terms memory t = ff.terms(vault);
        (,,, address aix, address tr) = ff.config().split();
        feeHeld = IERC20(vault).balanceOf(t.recipient) + IERC20(vault).balanceOf(aix) + IERC20(vault).balanceOf(tr)
            + IERC20(vault).balanceOf(address(ff));
    }

    function _sharesAt(uint256 amount, Side side) internal view returns (uint256) {
        (uint256 nav,) = controller.nav(uint8(side));
        (uint256 usd,,) = router.value(usdg, amount, Side.Fair);
        return usd * IERC20(vault).totalSupply() / nav;
    }

    function _usdgAt(uint256 shares, Side side) internal view returns (uint256) {
        (uint256 nav,) = controller.nav(uint8(side));
        (uint256 one,,) = router.value(usdg, 1e6, Side.Fair);
        return shares * nav / IERC20(vault).totalSupply() * 1e6 / one;
    }
}
