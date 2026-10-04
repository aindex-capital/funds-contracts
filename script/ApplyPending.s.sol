// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {ChainlinkSource} from "../src/pricing/sources/ChainlinkSource.sol";
import {UniswapV3TwapSource} from "../src/pricing/sources/UniswapV3TwapSource.sol";
import {SessionPoolSource} from "../src/pricing/sources/SessionPoolSource.sol";
import {IPriceRouter} from "../src/interfaces/IPriceRouter.sol";
import {FundsConfig} from "./FundsConfig.sol";

interface IMulticall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (bytes[] memory);
}

/**
 * @title  ApplyPending
 * @notice Applies the price configuration `DeployFunds` proposed, once the 1-day delay has passed: every
 *         Chainlink, TWAP and session pool source entry, every router configuration, session and look-through. Anyone may run
 *         it; applying a pending change needs no role, which is the point of the delay.
 *
 * @dev    Reads the token list from `script/funds-config.json` and the addresses from FUNDS_DEPLOYMENT (default
 *         deployments/4663.json). Skips what is not pending (already applied, or cancelled) and stops with an
 *         error if anything is pending but not yet due, so a half-applied state is never mistaken for done.
 *         Ends by quoting every configured token and listing any that is still unavailable (a stale feed, a
 *         paused stock token, a pool with too little history): those need a look before Funds hold them.
 *
 *         The applies go out through Multicall3, `BATCH` at a time and in the same order as before (each
 *         source before the router entry that reads it), so about 150 applies take a handful of
 *         transactions. Every call must succeed (`allowFailure` false): one failure reverts its batch.
 */
contract ApplyPending is Script {
    PriceRouter internal router;
    ChainlinkSource internal chainlink;
    UniswapV3TwapSource internal twap;
    SessionPoolSource internal sessionPools;
    uint256 internal applied;
    IMulticall3 internal constant MULTICALL3 = IMulticall3(0xcA11bde05977b3631167028862bE2a173976CA11);
    uint256 internal constant BATCH = 40;
    IMulticall3.Call3[] internal calls;

    function _queue(address target, bytes memory data) internal {
        calls.push(IMulticall3.Call3(target, false, data));
        ++applied;
    }

    function run() external {
        string memory json = vm.readFile("script/funds-config.json");
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        router = PriceRouter(vm.parseJsonAddress(dep, ".priceRouter"));
        chainlink = ChainlinkSource(vm.parseJsonAddress(dep, ".chainlinkSource"));
        twap = UniswapV3TwapSource(vm.parseJsonAddress(dep, ".uniswapV3TwapSource"));
        sessionPools = SessionPoolSource(vm.parseJsonAddress(dep, ".sessionPoolSource"));
        FundsConfig.WeekendEntry[] memory w = FundsConfig.weekend(json);

        FundsConfig.ChainlinkEntry[] memory c = FundsConfig.chainlink(json);
        FundsConfig.TwapEntry[] memory t = FundsConfig.twap(json);
        FundsConfig.IndexEntry[] memory x = FundsConfig.indexes(json);
        address[] memory feeds = new address[](c.length);
        address[] memory pools = new address[](t.length);
        address[] memory indexes = new address[](x.length);
        for (uint256 i; i < c.length; ++i) feeds[i] = c[i].token;
        for (uint256 i; i < t.length; ++i) pools[i] = t[i].token;
        for (uint256 i; i < x.length; ++i) indexes[i] = x[i].token;

        for (uint256 i; i < w.length; ++i) {
            uint64 at = sessionPools.pendingAt(w[i].token);
            if (at != 0) {
                _due(at, w[i].token);
                _queue(address(sessionPools), abi.encodeCall(sessionPools.applyPending, (w[i].token)));
            }
        }
        for (uint256 i; i < feeds.length; ++i) {
            _source(address(chainlink), chainlink.pendingAt(feeds[i]), feeds[i]);
            _router(feeds[i]);
        }
        for (uint256 i; i < pools.length; ++i) {
            _source(address(twap), twap.pendingAt(pools[i]), pools[i]);
            _router(pools[i]);
        }
        for (uint256 i; i < indexes.length; ++i) {
            _router(indexes[i]);
            uint64 at = router.pendingLookThroughAt(indexes[i]);
            if (at != 0) {
                _due(at, indexes[i]);
                _queue(address(router), abi.encodeCall(router.applyLookThrough, (indexes[i])));
            }
        }
        vm.startBroadcast();
        for (uint256 i; i < calls.length; i += BATCH) {
            uint256 n = calls.length - i < BATCH ? calls.length - i : BATCH;
            IMulticall3.Call3[] memory batch = new IMulticall3.Call3[](n);
            for (uint256 j; j < n; ++j) batch[j] = calls[i + j];
            MULTICALL3.aggregate3(batch);
        }
        vm.stopBroadcast();
        console.log("pending changes applied:", applied);

        _report(feeds);
        _report(pools);
        _report(indexes);
    }

    function _source(address s, uint64 at, address token) internal {
        if (at == 0) return;
        _due(at, token);
        if (s == address(chainlink)) _queue(s, abi.encodeCall(chainlink.applyPending, (token)));
        else _queue(s, abi.encodeCall(twap.applyPending, (token)));
    }

    function _router(address token) internal {
        uint64 at = router.pendingAt(token);
        if (at != 0) {
            _due(at, token);
            _queue(address(router), abi.encodeCall(router.applyPending, (token)));
        }
        at = router.pendingSessionAt(token);
        if (at != 0) {
            _due(at, token);
            _queue(address(router), abi.encodeCall(router.applySession, (token)));
        }
    }

    function _due(uint64 at, address token) internal view {
        if (block.timestamp < at) {
            console.log("not due yet:", token, "seconds left", at - block.timestamp);
            revert("a pending change is not due yet: run again after the delay");
        }
    }

    function _report(address[] memory tokens) internal view {
        for (uint256 i; i < tokens.length; ++i) {
            IPriceRouter.Quote memory q = router.quote(tokens[i]);
            if (!q.available || q.fair == 0) console.log("UNAVAILABLE after apply:", tokens[i]);
        }
    }
}
