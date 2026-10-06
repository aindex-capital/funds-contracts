// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AdapterRegistry} from "../src/registry/AdapterRegistry.sol";
import {IUniswapV3Factory} from "../src/interfaces/external/uniswap/IUniswapV3.sol";
import {ClmVaultAdapter} from "../src/adapters/liquidity/clm/ClmVaultAdapter.sol";

/**
 * @title  DeployClmAdapter
 * @notice Deploys the managed liquidity adapter (Beefy CLM and Arrowfarm vaults) and registers it with the Funds'
 *         AdapterRegistry, marking it verified when the sender is the registry's reviewer. Then, in simulation only
 *         (nothing broadcast), initialises a throwaway clone with the default vault list, so a vault that no longer
 *         passes the origin checks stops the run before anyone enables it.
 *
 * @dev    Trusted families, read on chain on 2026-10-05:
 *         - Beefy: strategy factory 0xD4E968..., strategy owner 0x14E05B..., vault owner 0x03193E...
 *         - Arrowfarm: strategy factory 0xd62650..., strategy and vault owner 0xfa1A46...
 *         Writes deployments/4663-clm.json: the implementation, the default vaults, and the `config` bytes a Fund's
 *         owner passes to `FundController.addAdapter(implementation, config)` to enable it.
 */
contract DeployClmAdapter is Script {
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    string constant SOURCE = "https://github.com/aindex-capital/funds-contracts/blob/";

    function defaults() public pure returns (address[] memory v) {
        v = new address[](10);
        v[0] = 0x2e35f0951cFfaF89eb9ADdE94C60475E3745Cc15; // Beefy GLD/USDG
        v[1] = 0xe12010f9560BC8b1E54393EDA32FB7ae41d412f8; // Beefy META/USDG
        v[2] = 0xaf5bfA1A18a9b1F77b5f240a8275acE8ADd82716; // Beefy AMZN/USDG
        v[3] = 0xE36274737D99273d353d8d9F0a51c1AeA7426C31; // Beefy MSFT/USDG
        v[4] = 0xd60BC30CF5E564e0B956AeBB338942273d62F93b; // Beefy AMD/USDG
        v[5] = 0x00413A44d521EF466217b573E5A060fd3D20A30f; // Arrowfarm NVDA/USDG
        v[6] = 0x75aFb3Ba8E743E9f4c4932f4b6A625678974835A; // Arrowfarm GME/USDG
        v[7] = 0x9Afd43FFb1e6F879F08C0083fFf6100A027764fd; // Arrowfarm GOOGL/USDG
        v[8] = 0x71B146Ab3824683e0e928d114CCe9CF95BF6CD5f; // Arrowfarm SPCX/USDG
        v[9] = 0x11f5d344B64CC31351Cdb92fbEE1395DFC8d20B9; // Arrowfarm TSLA/USDG
    }

    function run() external {
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        AdapterRegistry registry = AdapterRegistry(vm.parseJsonAddress(dep, ".adapterRegistry"));
        string memory ref = vm.envOr("FUNDS_SOURCE_REF", string("main"));

        vm.startBroadcast();
        ClmVaultAdapter impl = new ClmVaultAdapter(
            IUniswapV3Factory(V3_FACTORY),
            ClmVaultAdapter.Family(0xD4E968d673bc2C4Ba5abcB773de6f07e65E94E44, 0x14E05B7161f57F4F0e3428CC49B4d477EcBf6D51, 0x03193Ef8c3f75C22fAf2995540602399cdcD4cbc),
            ClmVaultAdapter.Family(0xd626504db63FBe10Ea98a99f52717c5315e9eD46, 0xfa1A467D00d6763d3441f18A4abC6A0E1fb10ff2, 0xfa1A467D00d6763d3441f18A4abC6A0E1fb10ff2)
        );
        registry.register(address(impl), string.concat(SOURCE, ref, "/src/adapters/liquidity/clm/ClmVaultAdapter.sol"));
        bool reviewer = registry.reviewer() == msg.sender;
        if (reviewer) registry.setVerified(address(impl), true);
        vm.stopBroadcast();

        // Simulation only: the default list must pass the origin checks today.
        bytes memory config = abi.encode(defaults());
        ClmVaultAdapter probe = ClmVaultAdapter(Clones.clone(address(impl)));
        probe.initialize(address(0xF00D), address(0xBEEF), config);
        console.log("ClmVaultAdapter implementation", address(impl));
        console.log("default vaults pass the origin checks:", probe.vaults().length);
        if (!reviewer) {
            console.log("registered, NOT verified. The reviewer", registry.reviewer(), "should send:");
            console.log(string.concat("  cast send ", vm.toString(address(registry)), " 'setVerified(address,bool)' ", vm.toString(address(impl)), " true"));
        }
        console.log("A Fund's owner enables it with FundController.addAdapter(implementation, config); config:");
        console.logBytes(config);

        string memory k = "clm";
        vm.serializeAddress(k, "implementation", address(impl));
        vm.serializeAddress(k, "adapterRegistry", address(registry));
        vm.serializeAddress(k, "defaultVaults", defaults());
        vm.serializeBytes(k, "defaultConfig", config);
        string memory out = vm.serializeBool(k, "verified", reviewer);
        vm.writeJson(out, "deployments/4663-clm.json");
    }
}
