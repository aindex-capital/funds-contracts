// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {VaultShareSource} from "../src/pricing/sources/VaultShareSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {IPriceRouter, PriceClass} from "../src/interfaces/IPriceRouter.sol";
import {FundsConfig} from "./FundsConfig.sol";

/**
 * @title  ListVaultShares
 * @notice Lists the config's `vaultShares` (Arcus pTokens) with the PriceRouter: deploys a `VaultShareSource` for the
 *         router unless VAULT_SHARE_SOURCE names one, then proposes each token at class Thin with its haircut. A new
 *         token can only raise values, so each waits the router's 1-day delay; `ApplyPending` applies them after it.
 *
 * @dev    Run by the router's owner (the price owner). Skips tokens already configured with this source or pending.
 *         Before proposing, checks that the source prices every token now, so nothing is announced that would be
 *         unavailable on the day it applies. Writes the source's address to deployments/4663-vault-shares.json.
 */
contract ListVaultShares is Script {
    function run() external {
        string memory json = vm.readFile("script/funds-config.json");
        string memory dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        PriceRouter router = PriceRouter(vm.parseJsonAddress(dep, ".priceRouter"));
        FundsConfig.VaultShareEntry[] memory list = FundsConfig.vaultShares(json);
        require(list.length > 0, "no vaultShares in script/funds-config.json");

        address existing = vm.envOr("VAULT_SHARE_SOURCE", address(0));
        vm.startBroadcast();
        VaultShareSource source = existing != address(0) ? VaultShareSource(existing) : new VaultShareSource(IPriceRouter(address(router)));
        require(address(source.router()) == address(router), "source is for another router");

        uint256 proposed;
        for (uint256 i; i < list.length; ++i) {
            address token = list[i].token;
            (, , bool ok) = source.price(token);
            if (!ok) { console.log("SKIPPED, the source cannot price it now:", list[i].symbol, token); continue; }
            PriceRouter.Config memory cur = router.config(token);
            if (address(cur.primary) == address(source) || router.pendingAt(token) != 0) { console.log("already listed or pending:", list[i].symbol); continue; }
            router.propose(token, PriceRouter.Config({
                primary: IPriceSource(address(source)), check: IPriceSource(address(0)), class_: PriceClass.Thin,
                haircutBps: uint16(list[i].haircutBps), maxDeviationBps: 0, decimals: 0, chained: 0
            }));
            proposed++;
            console.log("proposed", list[i].symbol, token);
        }
        vm.stopBroadcast();

        console.log("VaultShareSource", address(source));
        console.log("proposed", proposed, "of", list.length);
        console.log("applies after the router's delay (seconds):", router.CONFIG_DELAY());
        string memory k = "vaultShares";
        vm.serializeAddress(k, "vaultShareSource", address(source));
        vm.serializeAddress(k, "priceRouter", address(router));
        string memory out = vm.serializeUint(k, "proposedAt", block.timestamp);
        vm.writeJson(out, "deployments/4663-vault-shares.json");
    }
}
