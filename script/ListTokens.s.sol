// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {UniswapV3TwapSource, IUniswapV3PoolOracle} from "../src/pricing/sources/UniswapV3TwapSource.sol";
import {PriceRecorder} from "../src/pricing/sources/PriceRecorder.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {PriceClass} from "../src/interfaces/IPriceRouter.sol";
import {FundsConfig} from "./FundsConfig.sol";

/**
 * @title  ListTokens
 * @notice Lists tokens added to the config after the first deploy: `twap` entries the TWAP source does not know yet, and
 *         every `recorded` entry (the v4 PriceRecorder). Each gets its source's configuration and the router's, both
 *         waiting their 1-day delay; `ApplyPending` applies them after it. Run by the price owner.
 *
 * @dev    Skips any token the router already prices or has pending, so it can be run again after editing the config.
 *         A recorded token is priced only once the recorder holds `MIN_READINGS` (100) readings, about 17 hours of
 *         the settle keeper's recording after its configuration applies: list it in PRICE_RECORDER_TOKENS on the server.
 */
contract ListTokens is Script {
    function run() external {
        string memory json = vm.readFile("script/funds-config.json");
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        PriceRouter router = PriceRouter(vm.parseJsonAddress(dep, ".priceRouter"));
        UniswapV3TwapSource twap = UniswapV3TwapSource(vm.parseJsonAddress(dep, ".uniswapV3TwapSource"));
        PriceRecorder recorder = PriceRecorder(vm.parseJsonAddress(dep, ".priceRecorder"));
        FundsConfig.TwapEntry[] memory t = FundsConfig.twap(json);
        FundsConfig.RecordedEntry[] memory r = FundsConfig.recorded(json);

        uint256 proposed;
        vm.startBroadcast();
        for (uint256 i; i < t.length; ++i) {
            if (_known(router, t[i].token)) continue;
            address t0 = IUniswapV3PoolOracle(t[i].pool).token0();
            address t1 = IUniswapV3PoolOracle(t[i].pool).token1();
            require((t0 == t[i].token && t1 == t[i].quoteToken) || (t1 == t[i].token && t0 == t[i].quoteToken), "twap pool pair");
            twap.propose(t[i].token, IUniswapV3PoolOracle(t[i].pool), uint32(t[i].window), t[i].checkPause);
            _route(router, t[i].token, IPriceSource(address(twap)), t[i].thin ? PriceClass.Thin : PriceClass.Pool, t[i].haircutBps);
            console.log("proposed (v3 average)", t[i].symbol, t[i].token);
            ++proposed;
        }
        for (uint256 i; i < r.length; ++i) {
            if (_known(router, r[i].token)) continue;
            FundsConfig.PoolKeyEntry memory k = r[i].key;
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(k.currency0), currency1: Currency.wrap(k.currency1), fee: uint24(k.fee),
                tickSpacing: int24(k.tickSpacing), hooks: IHooks(k.hooks)
            });
            recorder.propose(r[i].token, key, r[i].quoteToken);
            _route(router, r[i].token, IPriceSource(address(recorder)), PriceClass.Thin, r[i].haircutBps);
            console.log("proposed (v4 recorder)", r[i].symbol, r[i].token);
            ++proposed;
        }
        vm.stopBroadcast();
        console.log("proposed", proposed, "tokens; they apply after the delay (seconds):", router.CONFIG_DELAY());
    }

    function _known(PriceRouter router, address token) internal view returns (bool) {
        if (address(router.config(token).primary) != address(0) || router.pendingAt(token) != 0) {
            console.log("already listed or pending:", token);
            return true;
        }
        return false;
    }

    function _route(PriceRouter router, address token, IPriceSource s, PriceClass c, uint256 haircut) internal {
        router.propose(token, PriceRouter.Config({
            primary: s, check: IPriceSource(address(0)), class_: c, haircutBps: uint16(haircut), maxDeviationBps: 0, decimals: 0, chained: 1
        }));
    }
}
