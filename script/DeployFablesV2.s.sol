// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AdapterRegistry} from "../src/registry/AdapterRegistry.sol";
import {FablesLiquidityAdapterV2} from "../src/adapters/liquidity/FablesLiquidityAdapterV2.sol";
import {IFablesPoolRegistry} from "../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../src/interfaces/external/fables/IFablesFeeDistributor.sol";
import {IWETH9} from "../src/interfaces/external/uniswap/IWETH9.sol";

/**
 * @title  DeployFablesV2
 * @notice Deploys FablesLiquidityAdapterV2 (v1 plus native ETH pools, served to the vault as WETH) and registers it
 *         with the Funds' AdapterRegistry, marking it verified when the sender is the registry's reviewer. Then, in
 *         simulation only (nothing broadcast), initialises a throwaway clone with every active Fables hook, ETH
 *         hooks included, so a hook that no longer passes the registry checks stops the run before anyone enables it.
 *
 * @dev    Same constructor arguments as v1 (script/funds-config.json `external`), plus WETH. Writes
 *         deployments/4663-fables-v2.json: the implementation, the hooks with their witness pools, and the `config`
 *         bytes a Fund's owner passes to `FundController.addAdapter(implementation, config)` (spot guard off, the
 *         default for Funds, as `fablesMaxSpotDeviationBps` in funds-config.json).
 */
contract DeployFablesV2 is Script {
    address constant FABLES_REGISTRY = 0x159A113E012593D9B3cC63ad45E30F0467e13Ef3;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant FABLES_POT = 0xC9EcC11728a4955B31f77c077B97FEC521D78760;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    string constant SOURCE = "https://github.com/aindex-capital/funds-contracts/blob/";

    /// @notice Every hook of an active Fables pool, ETH pools included, each with one of its pools as the witness
    ///         the adapter checks against Fables' registry. Same walk as CreateFund's `_fablesHooks`, without the
    ///         native-ETH skip.
    function fablesHooks() public view returns (address[] memory hooks, bytes32[] memory witness) {
        IFablesPoolRegistry reg = IFablesPoolRegistry(FABLES_REGISTRY);
        uint256 n = reg.poolCount();
        hooks = new address[](n);
        witness = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            IFablesPoolRegistry.PoolInfo memory p = reg.poolAt(i);
            if (!p.active) continue;
            address h = address(p.key.hooks);
            bool seen;
            for (uint256 j; j < k; ++j) {
                if (hooks[j] == h) seen = true;
            }
            if (seen) continue;
            hooks[k] = h;
            witness[k] = PoolId.unwrap(p.id);
            ++k;
        }
        assembly ("memory-safe") {
            mstore(hooks, k)
            mstore(witness, k)
        }
    }

    function defaultConfig() public view returns (bytes memory) {
        (address[] memory hooks, bytes32[] memory witness) = fablesHooks();
        return abi.encode(hooks, witness, uint16(0));
    }

    function run() external {
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        AdapterRegistry registry = AdapterRegistry(vm.parseJsonAddress(dep, ".adapterRegistry"));
        string memory ref = vm.envOr("FUNDS_SOURCE_REF", string("main"));

        vm.startBroadcast();
        FablesLiquidityAdapterV2 impl = new FablesLiquidityAdapterV2(
            IFablesPoolRegistry(FABLES_REGISTRY),
            IPoolManager(POOL_MANAGER),
            IFablesFeeDistributor(FABLES_POT),
            IWETH9(WETH)
        );
        registry.register(address(impl), string.concat(SOURCE, ref, "/src/adapters/liquidity/FablesLiquidityAdapterV2.sol"));
        bool reviewer = registry.reviewer() == msg.sender;
        if (reviewer) registry.setVerified(address(impl), true);
        vm.stopBroadcast();

        // Simulation only: every active hook must pass the registry and PoolManager checks today.
        (address[] memory hooks, bytes32[] memory witness) = fablesHooks();
        bytes memory config = abi.encode(hooks, witness, uint16(0));
        FablesLiquidityAdapterV2 probe = FablesLiquidityAdapterV2(payable(Clones.clone(address(impl))));
        probe.initialize(address(0xF00D), address(0xBEEF), config);
        console.log("FablesLiquidityAdapterV2 implementation", address(impl));
        console.log("active Fables hooks that pass the checks:", probe.hooks().length);
        if (!reviewer) {
            console.log("registered, NOT verified. The reviewer", registry.reviewer(), "should send:");
            console.log(string.concat("  cast send ", vm.toString(address(registry)), " 'setVerified(address,bool)' ", vm.toString(address(impl)), " true"));
        }
        console.log("A Fund's owner enables it with FundController.addAdapter(implementation, config); config:");
        console.logBytes(config);

        string memory k = "fablesV2";
        vm.serializeAddress(k, "implementation", address(impl));
        vm.serializeAddress(k, "adapterRegistry", address(registry));
        vm.serializeAddress(k, "hooks", hooks);
        vm.serializeBytes32(k, "witnessPools", witness);
        vm.serializeUint(k, "maxSpotDeviationBps", 0);
        vm.serializeBytes(k, "defaultConfig", config);
        string memory out = vm.serializeBool(k, "verified", reviewer);
        vm.writeJson(out, vm.envOr("FABLES_V2_OUT", string("deployments/4663-fables-v2.json")));
    }
}
