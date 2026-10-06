// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/registry/AdapterRegistry.sol";
import {PendleAdapter} from "../src/adapters/pendle/PendleAdapter.sol";
import {
    IPendleMarketFactory,
    IPendlePYLpOracle,
    IPendleRouter
} from "../src/interfaces/external/pendle/IPendle.sol";

/**
 * @title  DeployPendleAdapter
 * @notice Deploys the Pendle adapter implementation and registers it with the AdapterRegistry, as `DeployFunds` does for
 *         every AINDEX adapter: the metadata URI points at its source, and when the deployer is also the registry's
 *         reviewer it is marked verified in the same run. Funds then enable it with `addAdapter(implementation, "")`.
 *
 * @dev    Addresses default to Pendle V2 on Robinhood Chain (4663), checked on chain 2026-10-05: RouterV4, the PT/YT/LP
 *         oracle and MarketFactoryV6 (the only market factory on the chain). Override with PENDLE_ROUTER, PENDLE_ORACLE,
 *         PENDLE_FACTORY and PENDLE_FACTORY2. Writes the implementation to deployments/4663-pendle.json.
 */
contract DeployPendleAdapter is Script {
    string internal constant SOURCE = "https://github.com/aindex-capital/funds-contracts/blob/";

    function run() external {
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        AdapterRegistry registry = AdapterRegistry(vm.parseJsonAddress(dep, ".adapterRegistry"));
        address reviewer = registry.reviewer();
        address pendleRouter = vm.envOr("PENDLE_ROUTER", address(0x888888888889758F76e7103c6CbF23ABbF58F946));
        address oracle = vm.envOr("PENDLE_ORACLE", address(0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2));
        address factory = vm.envOr("PENDLE_FACTORY", address(0x544BF81c855AE84c1e8b65d5E38770898D01EeE2));
        address factory2 = vm.envOr("PENDLE_FACTORY2", address(0));
        string memory ref = vm.envOr("FUNDS_SOURCE_REF", string("main"));
        require(pendleRouter.code.length != 0 && oracle.code.length != 0 && factory.code.length != 0, "Pendle not found on this chain");

        vm.startBroadcast();
        PendleAdapter impl = new PendleAdapter(
            IPendleRouter(pendleRouter), IPendlePYLpOracle(oracle), IPendleMarketFactory(factory), IPendleMarketFactory(factory2)
        );
        registry.register(address(impl), string.concat(SOURCE, ref, "/src/adapters/pendle/PendleAdapter.sol"));
        bool verified = msg.sender == reviewer;
        if (verified) registry.setVerified(address(impl), true);
        vm.stopBroadcast();

        console.log("PendleAdapter", address(impl));
        console.log(verified ? "registered and verified" : "registered; the reviewer must call setVerified");
        string memory k = "pendle";
        vm.serializeAddress(k, "pendleAdapter", address(impl));
        vm.serializeAddress(k, "pendleRouter", pendleRouter);
        vm.serializeAddress(k, "pendleOracle", oracle);
        vm.serializeAddress(k, "pendleMarketFactory", factory);
        vm.serializeAddress(k, "adapterRegistry", address(registry));
        string memory out = vm.serializeUint(k, "deployedAt", block.timestamp);
        vm.writeJson(out, "deployments/4663-pendle.json");
    }
}
