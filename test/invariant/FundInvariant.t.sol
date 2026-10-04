// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../utils/FundTestBase.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {MockSwap, MockLending, MockThief} from "../utils/MockAdapters.sol";
import {FundController} from "../../src/core/FundController.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {IAdapter, Amount} from "../../src/interfaces/IAdapter.sol";
import {PriceClass, Side} from "../../src/interfaces/IPriceRouter.sol";

/**
 * @notice Drives a hostile manager through honest venues (a swap with no fee, a swap with a 3% fee, a lending
 *         market) and hostile adapters (one keeps half its input, one sends it to an outside address, one sends
 *         it out and misreports it as a position), while prices move and days pass. Each successful action is
 *         checked as it happens; the invariants read what the handler recorded.
 */
contract FundHandler is Test {
    struct Snap {
        uint256 navBid;
        uint256 navFair;
        uint256 assetsBid;
        uint256 debtsAsk;
        uint256 thinFair; // whole thin class
        uint256[3] fairOf; // usdg, thin, feed
    }

    FundController public controller;
    FundVault public vault;
    PriceRouter public router;
    MockPriceSource public source;
    address public manager;
    address public sink;
    MockERC20[3] public tokens; // usdg, thin, feed
    address public swap;
    address public lossy;
    address public lend;
    address[3] public thieves; // keep, send, liar

    uint256 public constant LOSSY_FEE_BPS = 300;
    /// @dev The mock venue truncates twice to whole raw units of a 6-decimal token: 1e12 each in USD wad.
    uint256 public constant ROUNDING = 1e13;

    // Ghosts.
    uint256 public ghostDay;
    uint256 public ghostDayStartNav;
    uint256 public ghostDayLoss;
    bool public ghostLossOverBudget;
    bool public honestLeak;
    bool public capBroken;
    uint256 public successes;
    uint256 public honestSuccesses;
    uint256 public thefts;
    uint256 public leakPre;
    uint256 public leakPost;
    uint256 public leakCost;
    string public leakWhy;

    constructor(
        FundController c,
        PriceRouter r,
        MockPriceSource s,
        address m,
        address sink_,
        MockERC20[3] memory t,
        address[3] memory honest,
        address[3] memory bad
    ) {
        controller = c;
        vault = FundVault(c.vault());
        router = r;
        source = s;
        manager = m;
        sink = sink_;
        tokens = t;
        (swap, lossy, lend) = (honest[0], honest[1], honest[2]);
        thieves = bad;
    }

    // ------------------------------------------------------------ actions

    function trade(uint256 venueSeed, uint256 inSeed, uint256 outSeed, uint256 amountSeed) external {
        address venue = venueSeed % 2 == 0 ? swap : lossy;
        MockERC20 tin = tokens[inSeed % 3];
        MockERC20 tout = tokens[outSeed % 3];
        uint256 bal = tin.balanceOf(address(vault));
        if (bal == 0) return;
        uint256 amt = bound(amountSeed, 1, bal);
        (uint256 inFair,,) = router.value(address(tin), amt, Side.Fair);
        _act(venue, abi.encode(address(tin), address(tout), amt), true, inFair * (venue == lossy ? LOSSY_FEE_BPS : 0) / 10_000);
    }

    function lending(uint256 opSeed, uint256 tokenSeed, uint256 amountSeed) external {
        uint8 op = uint8(opSeed % 4);
        MockERC20 t = tokens[tokenSeed % 3];
        uint256 amt;
        if (op == 0) amt = bound(amountSeed, 0, t.balanceOf(address(vault)));
        else if (op == 1) amt = bound(amountSeed, 0, MockLending(lend).supply(address(t)));
        else if (op == 2) amt = bound(amountSeed, 0, 10 ** t.decimals() * 50);
        else amt = bound(amountSeed, 0, _min(MockLending(lend).debt(address(t)), t.balanceOf(address(vault))));
        _act(lend, abi.encode(op, address(t), amt), true, 0);
    }

    function steal(uint256 whichSeed, uint256 tokenSeed, uint256 amountSeed) external {
        MockERC20 t = tokens[tokenSeed % 3];
        uint256 bal = t.balanceOf(address(vault));
        if (bal < 2) return;
        _act(thieves[whichSeed % 3], abi.encode(address(t), bound(amountSeed, 2, bal)), false, 0);
    }

    function unwindLending(uint256 fractionSeed) external {
        uint256 f = bound(fractionSeed, 1, 1e18);
        Snap memory pre = _snap();
        uint256 sinkBefore = _sinkValue();
        vm.prank(manager);
        try controller.unwindAdapter(lend, f) {
            Snap memory post = _snap();
            _recordLoss(pre, post);
            if (_sinkValue() != sinkBefore) (honestLeak, leakWhy) = (true, "unwind sink");
            if (post.navFair + ROUNDING < pre.navFair) {
                (honestLeak, leakWhy) = (true, "unwind nav");
                (leakPre, leakPost) = (pre.navFair, post.navFair);
            }
            successes++;
        } catch {}
    }

    function movePrice(uint256 tokenSeed, uint256 bpsSeed) external {
        MockERC20 t = tokens[1 + tokenSeed % 2]; // thin or feed; cash stays at $1
        uint256 p = source.prices(address(t));
        uint256 bps = bound(bpsSeed, 9_000, 11_000);
        uint256 next = p * bps / 10_000;
        if (next < 1e15 || next > 1e24) return;
        source.set(address(t), next);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 30 hours));
    }

    // ------------------------------------------------------------ checks around one action

    function _act(address adapter, bytes memory action, bool honest, uint256 allowedCost) internal {
        Snap memory pre = _snap();
        uint256 sinkBefore = _sinkValue();
        vm.prank(manager);
        try controller.act(adapter, action) {
            Snap memory post = _snap();
            successes++;
            _recordLoss(pre, post);
            _checkCaps(pre, post);
            if (honest) {
                honestSuccesses++;
                // Value never leaves through an honest adapter: only the venue's own fee, at fair prices.
                if (post.navFair + allowedCost + ROUNDING < pre.navFair) {
                    (honestLeak, leakWhy) = (true, "act nav");
                    (leakPre, leakPost, leakCost) = (pre.navFair, post.navFair, allowedCost);
                }
                if (_sinkValue() != sinkBefore) (honestLeak, leakWhy) = (true, "act sink");
            } else {
                thefts++;
            }
        } catch {}
    }

    function _recordLoss(Snap memory pre, Snap memory post) internal {
        uint256 day = block.timestamp / 1 days;
        if (day != ghostDay) {
            ghostDay = day;
            ghostDayStartNav = pre.navBid;
            ghostDayLoss = 0;
        }
        if (post.navBid < pre.navBid) ghostDayLoss += pre.navBid - post.navBid;
        if (ghostDayLoss > ghostDayStartNav * controller.dial().dailyLossBps / 10_000) ghostLossOverBudget = true;
    }

    function _checkCaps(Snap memory pre, Snap memory post) internal {
        Dial memory d = controller.dial();
        uint256 thinCap = post.navFair * d.maxThinBps / 10_000;
        if (post.thinFair > thinCap && post.thinFair > pre.thinFair) capBroken = true;
        uint256 perToken = post.navFair * d.maxPerTokenBps / 10_000;
        for (uint256 i = 1; i < 3; ++i) {
            if (post.fairOf[i] > perToken && post.fairOf[i] > pre.fairOf[i]) capBroken = true;
        }
        if (post.debtsAsk > 0) {
            uint256 h = post.assetsBid * 10_000 / post.debtsAsk;
            uint256 hPre = pre.debtsAsk == 0 ? type(uint256).max : pre.assetsBid * 10_000 / pre.debtsAsk;
            if (h < d.minHealthBps && h < hPre) capBroken = true;
        }
    }

    // ------------------------------------------------------------ an independent book

    function _snap() internal view returns (Snap memory s) {
        address[] memory list = controller.adapters();
        uint256 fairAssets;
        uint256 fairDebts;
        for (uint256 i; i < 3; ++i) {
            address t = address(tokens[i]);
            uint256 held = IERC20(t).balanceOf(address(vault));
            uint256 owed;
            for (uint256 j; j < list.length; ++j) {
                (Amount[] memory a, Amount[] memory o) = IAdapter(list[j]).positions(router);
                for (uint256 k; k < a.length; ++k) if (a[k].token == t) held += a[k].amount;
                for (uint256 k; k < o.length; ++k) if (o[k].token == t) owed += o[k].amount;
            }
            (uint256 f,,) = router.value(t, held, Side.Fair);
            (uint256 b,,) = router.value(t, held, Side.Bid);
            (uint256 df,,) = router.value(t, owed, Side.Fair);
            (uint256 da,,) = router.value(t, owed, Side.Ask);
            s.fairOf[i] = f;
            fairAssets += f;
            fairDebts += df;
            s.assetsBid += b;
            s.debtsAsk += da;
            if (i == 1) s.thinFair = f;
        }
        s.navFair = fairAssets > fairDebts ? fairAssets - fairDebts : 0;
        s.navBid = s.assetsBid > s.debtsAsk ? s.assetsBid - s.debtsAsk : 0;
    }

    function _sinkValue() internal view returns (uint256 v) {
        for (uint256 i; i < 3; ++i) v += tokens[i].balanceOf(sink);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function snap() external view returns (Snap memory) {
        return _snap();
    }

    function allAdapters() external view returns (address[] memory a) {
        a = new address[](6);
        (a[0], a[1], a[2]) = (swap, lossy, lend);
        (a[3], a[4], a[5]) = (thieves[0], thieves[1], thieves[2]);
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
contract FundInvariantTest is FundTestBase {
    FundHandler handler;
    MockERC20 thin;
    MockERC20 feed;
    address sink = makeAddr("sink");

    function setUp() public {
        _setUpCore();
        thin = new MockERC20("Thin", "THIN", 18);
        feed = new MockERC20("Feed", "FEED", 18);
        _price(address(thin), 2e18, PriceClass.Thin, 500);
        _price(address(feed), 100e18, PriceClass.Feed, 50);
        Dial memory d = Dial({
            maxNoMarketBps: 0,
            maxThinBps: 2000,
            maxPoolBps: 10_000,
            maxPerTokenBps: 5000,
            dailyLossBps: 300,
            allowBorrow: true,
            minHealthBps: 15_000,
            allowUnreviewed: true // the hostile adapters are unverified on purpose
        });
        _createFund(d, 10_000e6);
        MockSwap swapImpl = new MockSwap();
        MockLending lendImpl = new MockLending();
        MockThief thiefImpl = new MockThief();
        registry.register(address(swapImpl), "");
        registry.register(address(lendImpl), "");
        registry.register(address(thiefImpl), "");
        address[3] memory honest = [
            _enable(address(swapImpl), abi.encode(source, uint256(0))),
            _enable(address(swapImpl), abi.encode(source, uint256(300))),
            _enable(address(lendImpl), "")
        ];
        address[3] memory bad = [
            _enable(address(thiefImpl), abi.encode(uint8(0), sink)),
            _enable(address(thiefImpl), abi.encode(uint8(1), sink)),
            _enable(address(thiefImpl), abi.encode(uint8(2), sink))
        ];
        handler = new FundHandler(controller, router, source, manager, sink, [usdg, thin, feed], honest, bad);
        // The Fund's manager may extend its expiry window over the run.
        vm.prank(owner);
        controller.setManager(manager, uint64(block.timestamp + 366 days));
        targetContract(address(handler));
    }

    /// Vault approvals are zero between calls, for every adapter and every token.
    function invariant_NoApprovalsBetweenCalls() public view {
        address[] memory a = handler.allAdapters();
        address[3] memory t = [address(usdg), address(thin), address(feed)];
        for (uint256 i; i < a.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                assertEq(IERC20(t[j]).allowance(address(vault), a[i]), 0, "approval left between calls");
            }
        }
    }

    /// What the manager's actions cost in a day, measured independently, never exceeds the day's budget.
    function invariant_DailyLossWithinBudget() public view {
        assertFalse(handler.ghostLossOverBudget(), "a day's losses exceeded the budget");
        uint256 allowed = controller.windowStartNav() * controller.dial().dailyLossBps / 10_000;
        assertLe(controller.windowLoss(), allowed, "controller's own tally over budget");
    }

    /// Value never leaves the Fund through an honest adapter.
    function invariant_HonestAdaptersLeakNothing() public {
        if (handler.honestLeak()) {
            emit log_named_string("why", handler.leakWhy());
            emit log_named_uint("pre", handler.leakPre());
            emit log_named_uint("post", handler.leakPost());
            emit log_named_uint("cost", handler.leakCost());
        }
        assertFalse(handler.honestLeak(), "value left through an honest adapter");
    }

    /// Caps hold after every successful action (or the action did not add to an existing breach).
    function invariant_CapsHoldAfterEveryAction() public view {
        assertFalse(handler.capBroken(), "a cap was broken by an action");
    }

    /// Adapters hold no loose tokens of the honest venues between calls.
    function invariant_HonestSwapsHoldNothing() public view {
        address[] memory a = handler.allAdapters();
        address[3] memory t = [address(usdg), address(thin), address(feed)];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 3; ++j) assertEq(IERC20(t[j]).balanceOf(a[i]), 0);
        }
    }

    function afterInvariant() external {
        // Make sure the run did something: honest actions and thefts went through.
        emit log_named_uint("successful actions", handler.successes());
        emit log_named_uint("of which honest", handler.honestSuccesses());
        emit log_named_uint("of which thefts", handler.thefts());
        assertGt(handler.honestSuccesses(), 0, "no honest action ever succeeded");
    }
}
