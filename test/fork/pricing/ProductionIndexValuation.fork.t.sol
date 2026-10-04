// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeployFunds} from "../../../script/DeployFunds.s.sol";
import {ApplyPending} from "../../../script/ApplyPending.s.sol";
import {FundsConfig} from "../../../script/FundsConfig.sol";
import {FreshFeed} from "../../../script/rehearsal/FreshFeed.sol";
import {PriceRouter} from "../../../src/pricing/PriceRouter.sol";
import {ChainlinkSource, IChainlinkFeed} from "../../../src/pricing/sources/ChainlinkSource.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IPriceRouter, PriceClass, Side} from "../../../src/interfaces/IPriceRouter.sol";
import {IFolio} from "../../../src/interfaces/external/folio/IFolio.sol";

/**
 * @notice The production price configuration, deployed and applied by the real scripts on a fork, valuing
 *         AINDEX's AIXSTR index token by look-through. Regression for the 2026-10-01 rehearsal, where AIXSTR read
 *         5% low because LMT (4.9% of the basket) had no price, and a thin pool's execution cost had been
 *         mistaken for a valuation gap. Skipped without ROBINHOOD_RPC. Run with -vv for the per-token table.
 *
 *         Checks, for every basket token: priced (not None, available, nonzero), and for feed tokens the router's
 *         value equals the amount times the Chainlink answer computed here independently (catches decimals, feed
 *         units and the stock-token multiplier counted twice). Then the index's look-through price equals the
 *         sum of the parts.
 */
contract ProductionIndexValuationForkTest is Test {
    address constant AIXSTR = 0xe7c9209D3C35d7cf1895e46a2d62b9A30841bB98;
    string constant OUT = "deployments/.fork-test-4663.json";

    PriceRouter router;
    ChainlinkSource chainlink;
    IPriceSource indexNav;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        vm.createDir("deployments", true);
        vm.setEnv("FUNDS_REVIEWER", vm.toString(makeAddr("reviewer")));
        vm.setEnv("FUNDS_PRICE_OWNER", vm.toString(makeAddr("priceOwner")));
        vm.setEnv("FUNDS_GUARDIAN", vm.toString(makeAddr("guardian")));
        vm.setEnv("FUNDS_KEEPERS", vm.toString(makeAddr("keeper")));
        vm.setEnv("FUNDS_DEPLOYMENT_OUT", OUT);
        vm.setEnv("FUNDS_DEPLOYMENT", OUT);
        new DeployFunds().run();

        // A day later, as on mainnet. The fork cannot see Chainlink publish meanwhile, so each feed answers its
        // last price with a fresh timestamp (FreshFeed: same answer, only the clock).
        vm.warp(block.timestamp + 1 days + 60);
        string memory json = vm.readFile("script/funds-config.json");
        FundsConfig.ChainlinkEntry[] memory feeds = FundsConfig.chainlink(json);
        bytes memory fresh = type(FreshFeed).runtimeCode;
        for (uint256 i; i < feeds.length; ++i) {
            address f = feeds[i].feed;
            (, int256 answer,,,) = IChainlinkFeed(f).latestRoundData();
            uint8 d = IChainlinkFeed(f).decimals();
            vm.etch(f, fresh);
            vm.store(f, bytes32(uint256(0)), bytes32(uint256(answer)));
            vm.store(f, bytes32(uint256(1)), bytes32(uint256(d)));
        }
        new ApplyPending().run();

        string memory dep = vm.readFile(OUT);
        router = PriceRouter(vm.parseJsonAddress(dep, ".priceRouter"));
        // Value on a weekday: while the US market is closed, stock tokens are priced by the worse-of rule from
        // their weekend pools (fair is the middle of that range, not the feed's last answer), by design.
        if (router.closedSince() != 0) {
            uint256 day = block.timestamp / 1 days + 1;
            while (day % 7 == 2 || day % 7 == 3) ++day; // not Saturday or Sunday (1970-01-01 was a Thursday)
            vm.warp(day * 1 days + 15 hours);
        }
        chainlink = ChainlinkSource(vm.parseJsonAddress(dep, ".chainlinkSource"));
        indexNav = IPriceSource(vm.parseJsonAddress(dep, ".indexNavSource"));
        vm.removeFile(OUT);
    }

    function test_AixstrBasketFullyPricedAndConsistent() public view {
        (address[] memory assets, uint256[] memory amounts) = IFolio(AIXSTR).toAssets(1e18, 0);
        uint256 sum;
        console.log("AIXSTR, per whole share: token, amount (raw), class, fair price (USD 1e18), value (USD 1e18)");
        for (uint256 i; i < assets.length; ++i) {
            IPriceRouter.Quote memory q = router.quote(assets[i]);
            (uint256 v, PriceClass c, bool ok) = router.value(assets[i], amounts[i], Side.Fair);
            console.log(IERC20Metadata(assets[i]).symbol(), amounts[i], uint8(c));
            console.log("    fair, value:", q.fair, v);
            assertTrue(ok && q.available, "a basket token is unavailable");
            assertTrue(c != PriceClass.None, "a basket token has no market");
            assertGt(v, 0, "a basket token counts as zero");

            ChainlinkSource.Feed memory f = chainlink.feedOf(assets[i]);
            if (address(f.feed) != address(0) && address(f.quoteSource) == address(0)) {
                (, int256 answer,,,) = f.feed.latestRoundData();
                uint256 direct = amounts[i] * uint256(answer) * 1e18 / 10 ** f.feed.decimals() / 10
                    ** IERC20Metadata(assets[i]).decimals();
                assertApproxEqRel(v, direct, 1e12, "feed value differs from amount x answer");
            }
            sum += v;
        }
        (uint256 p,, bool okIndex) = indexNav.price(AIXSTR);
        console.log("sum of parts, look-through price:", sum, p);
        assertTrue(okIndex, "AIXSTR look-through unavailable");
        assertApproxEqRel(p, sum, 1e12, "look-through is not the sum of its parts");
        IPriceRouter.Quote memory qi = router.quote(AIXSTR);
        assertEq(qi.fair, p, "router does not use the look-through price");
        assertTrue(qi.class_ != PriceClass.None);
    }
}
