// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface IPendleOracleState {
    function getOracleState(address market, uint32 duration)
        external view returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}

interface IPendleMarketCardinality {
    function increaseObservationsCardinalityNext(uint16 cardinalityNext) external;
}

/**
 * @title  PendleOracles
 * @notice Makes Pendle markets' 15-minute price oracle usable, so a Fund's Pendle adapter can enter them: for each market
 *         in PENDLE_MARKETS (comma-separated) whose oracle needs more observations, calls the market's permissionless
 *         `increaseObservationsCardinalityNext(901)`. The oracle is ready about 15 minutes later, once the new slots
 *         have filled. Anyone may run it, with any funded key; it costs a little gas per market.
 */
contract PendleOracles is Script {
    address constant ORACLE = 0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2;
    uint32 constant DURATION = 900;

    function run() external {
        address[] memory markets = vm.envAddress("PENDLE_MARKETS", ",");
        uint256 sent;
        vm.startBroadcast();
        for (uint256 i; i < markets.length; ++i) {
            (bool increase, uint16 need,) = IPendleOracleState(ORACLE).getOracleState(markets[i], DURATION);
            if (!increase) { console.log("ready already:", markets[i]); continue; }
            IPendleMarketCardinality(markets[i]).increaseObservationsCardinalityNext(need);
            console.log("raised to", need, markets[i]);
            ++sent;
        }
        vm.stopBroadcast();
        console.log("markets raised:", sent, "- ready in about 15 minutes");
    }
}
