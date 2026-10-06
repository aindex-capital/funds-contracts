// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/registry/AdapterRegistry.sol";
import {ArcusRedeemAdapter} from "../src/adapters/arcus/ArcusRedeemAdapter.sol";
import {IArcusPTokenFactory} from "../src/interfaces/external/arcus/IArcusPToken.sol";

/**
 * @title  DeployArcusRedeemAdapter
 * @notice Deploys the Arcus pToken redeem adapter and registers it with the Funds' AdapterRegistry, marking it verified
 *         when the sender is the registry's reviewer. It takes no settings: any token Arcus' factory reports as a pToken
 *         (`isPToken`) can be redeemed, so a Fund's owner enables it with `FundController.addAdapter(implementation, "")`.
 *         Writes deployments/4663-arcus-redeem.json.
 */
contract DeployArcusRedeemAdapter is Script {
    /// @dev Arcus' pToken factory on Robinhood Chain (a proxy Arcus controls), read on chain on 2026-10-06.
    address constant PTOKEN_FACTORY = 0x9c3663FA9ab976E67B42939486EC4966Cb41a0BB;
    address constant PHOOD3X = 0xe24CABDf76DD1c2576049167eB1755C84b985C36;
    string constant SOURCE = "https://github.com/aindex-capital/funds-contracts/blob/";

    function run() external {
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        AdapterRegistry registry = AdapterRegistry(vm.parseJsonAddress(dep, ".adapterRegistry"));
        string memory ref = vm.envOr("FUNDS_SOURCE_REF", string("main"));
        require(IArcusPTokenFactory(PTOKEN_FACTORY).isPToken(PHOOD3X), "Arcus factory does not answer isPToken");

        vm.startBroadcast();
        ArcusRedeemAdapter impl = new ArcusRedeemAdapter(IArcusPTokenFactory(PTOKEN_FACTORY));
        registry.register(address(impl), string.concat(SOURCE, ref, "/src/adapters/arcus/ArcusRedeemAdapter.sol"));
        bool reviewer = registry.reviewer() == msg.sender;
        if (reviewer) registry.setVerified(address(impl), true);
        vm.stopBroadcast();

        console.log("ArcusRedeemAdapter implementation", address(impl));
        if (!reviewer) {
            console.log("registered, NOT verified. The reviewer", registry.reviewer(), "should send:");
            console.log(string.concat("  cast send ", vm.toString(address(registry)), " 'setVerified(address,bool)' ", vm.toString(address(impl)), " true"));
        }
        console.log("A Fund's owner enables it with FundController.addAdapter(implementation, 0x) (no settings).");

        string memory k = "arcusRedeem";
        vm.serializeAddress(k, "implementation", address(impl));
        vm.serializeAddress(k, "adapterRegistry", address(registry));
        vm.serializeAddress(k, "pTokenFactory", PTOKEN_FACTORY);
        vm.serializeBytes(k, "defaultConfig", "");
        string memory out = vm.serializeBool(k, "verified", reviewer);
        vm.writeJson(out, "deployments/4663-arcus-redeem.json");
    }
}
