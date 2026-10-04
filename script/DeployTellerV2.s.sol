// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Pockets} from "../src/core/Pockets.sol";
import {IPockets} from "../src/interfaces/IPockets.sol";
import {FundFactory} from "../src/core/FundFactory.sol";
import {Teller, IFundFactoryLike} from "../src/core/Teller.sol";
import {FeeConfig, FundFees} from "../src/core/Fees.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {IPriceRouter} from "../src/interfaces/IPriceRouter.sol";

/**
 * @title  DeployTellerV2
 * @notice Deploys the second public teller for new Funds next to the live AINDEX Funds deployment
 *         (deployments/4663.json), and the contracts that are wired to one teller or one controller build once. Run it
 *         through `script/deploy-teller-v2.sh`, which checks the tree, the chain, the signer and the linked libraries
 *         first and supports DRY_RUN=1.
 *
 * @dev    ## Why these, and only these
 *         The second teller mints the owner's opening deposit to its wallet (no stake held in custody) and creates a
 *         Fund ready to trade in one transaction (`createFundWith`). Existing Funds stay bound to the first teller
 *         (a vault names its teller once, `FundVault.wire`). What is new:
 *         - FundFactory, and the ControllerDeployer it creates in its constructor: the controller gained `setup`
 *           (the creation's one-time adapters and manager), its code lives in the ControllerDeployer, which the
 *           factory holds as an immutable. Same registry, router, guardian and USDG as the first factory;
 *         - Pockets: wired to one teller, once (`wireTeller`);
 *         - FundFees: wired to one teller, once; it reads the existing FeeConfig (one split for both tellers);
 *         - Teller.
 *         Reused unchanged: the adapter registry and every adapter implementation, the price router and its sources,
 *         the Morpho market registry, the index sources, FeeConfig, and the linked libraries FundBook, TellerMath,
 *         TellerOps and TellerQueue (their source is unchanged since the first deployment; the wrapper links the
 *         deployed ones and checks their code on chain).
 *
 *         ## Settings
 *         The new teller takes the first teller's settings, read on chain: minOpeningStake, minDeposit, dustUsd,
 *         writeOffMaxWad, the weekend inflow and outflow caps, the pool-price flow cap and its floor, maxLive. Its
 *         keepers are FUNDS_KEEPERS (default: the first deployment's `tellerKeepers`). The deployer is its admin
 *         while it sets these, then starts a two-step transfer to FUNDS_TELLER_ADMIN (default: the first teller's
 *         admin) unless that is the deployer. The new factory's guardian is FUNDS_GUARDIAN (default: the first
 *         factory's guardian).
 *
 *         Writes FUNDS_DEPLOYMENT_OUT (default deployments/4663-teller-v2.json): the first record with the new
 *         addresses in place (so `script/create-fund.sh` with FUNDS_DEPLOYMENT pointing at it creates Funds on the
 *         new teller), `oneTxCreate` true, and the first deployment's teller, factory, fees and pockets under
 *         `v1`.
 */
contract DeployTellerV2 is Script {
    string internal v1;
    address internal deployer;
    address internal tellerAdmin;
    address internal guardian;
    address[] internal keepers;

    Teller internal oldTeller;
    FundFactory internal oldFactory;
    FeeConfig internal feeConfig;

    FundFactory internal factory;
    Pockets internal pockets;
    FundFees internal fundFees;
    Teller internal teller;

    function run() external {
        v1 = vm.readFile(vm.envOr("FUNDS_V1_RECORD", string("deployments/4663.json")));
        require(vm.parseJsonUint(v1, ".chainId") == block.chainid, "the first record is for another chain");
        oldTeller = Teller(vm.parseJsonAddress(v1, ".teller"));
        oldFactory = FundFactory(vm.parseJsonAddress(v1, ".fundFactory"));
        feeConfig = FeeConfig(vm.parseJsonAddress(v1, ".feeConfig"));
        _checkV1();
        tellerAdmin = vm.envOr("FUNDS_TELLER_ADMIN", oldTeller.admin());
        guardian = vm.envOr("FUNDS_GUARDIAN", oldFactory.guardian());
        keepers = vm.envOr("FUNDS_KEEPERS", ",", vm.parseJsonAddressArray(v1, ".tellerKeepers"));
        require(keepers.length != 0, "no keepers");
        uint256 startBlock = block.number;

        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        factory = new FundFactory(
            IAdapterRegistry(address(oldFactory.registry())),
            IPriceRouter(address(oldFactory.router())),
            guardian,
            oldFactory.baseAsset()
        );
        pockets = new Pockets();
        fundFees = new FundFees(feeConfig);
        teller = new Teller(IFundFactoryLike(address(factory)), fundFees, IPockets(address(pockets)), deployer);
        fundFees.wireTeller(address(teller));
        pockets.wireTeller(address(teller));
        _settings();
        for (uint256 i; i < keepers.length; ++i) teller.setKeeper(keepers[i], true);
        if (tellerAdmin != deployer) teller.transferAdmin(tellerAdmin);
        vm.stopBroadcast();

        _check();
        _print();
        _record(startBlock);
    }

    /// @dev The first deployment is what the record says it is, so nothing is wired to a wrong address.
    function _checkV1() internal view {
        require(address(oldTeller.factory()) == address(oldFactory), "first teller's factory");
        require(address(oldTeller.fees().config()) == address(feeConfig), "first teller's fee config");
        require(address(oldFactory.registry()) == vm.parseJsonAddress(v1, ".adapterRegistry"), "registry");
        require(address(oldFactory.router()) == vm.parseJsonAddress(v1, ".priceRouter"), "router");
        require(oldFactory.baseAsset() == vm.parseJsonAddress(v1, ".baseAsset"), "base asset");
        require(oldTeller.usdg() == oldFactory.baseAsset(), "USDG");
    }

    /// @dev The first teller's settings, each set only where the constructor's default differs.
    function _settings() internal {
        if (
            teller.minOpeningStake() != oldTeller.minOpeningStake() || teller.minDeposit() != oldTeller.minDeposit()
                || teller.dustUsd() != oldTeller.dustUsd() || teller.writeOffMaxWad() != oldTeller.writeOffMaxWad()
                || teller.weekendInflowBps() != oldTeller.weekendInflowBps()
        ) {
            teller.setParams(
                oldTeller.minOpeningStake(),
                oldTeller.minDeposit(),
                oldTeller.dustUsd(),
                oldTeller.writeOffMaxWad(),
                oldTeller.weekendInflowBps()
            );
        }
        if (teller.weekendOutflowBps() != oldTeller.weekendOutflowBps()) {
            teller.setWeekendOutflowBps(oldTeller.weekendOutflowBps());
        }
        if (teller.poolFlowBps() != oldTeller.poolFlowBps()) teller.setPoolFlowBps(oldTeller.poolFlowBps());
        if (teller.poolFlowFloorUsd() != oldTeller.poolFlowFloorUsd()) {
            teller.setPoolFlowFloor(oldTeller.poolFlowFloorUsd());
        }
        if (teller.maxLive() != oldTeller.maxLive()) teller.setMaxLive(oldTeller.maxLive());
        if (teller.openSettlement() != oldTeller.openSettlement()) teller.setOpenSettlement(oldTeller.openSettlement());
    }

    function _check() internal view {
        require(fundFees.teller() == address(teller) && pockets.teller() == address(teller), "wiring");
        require(address(teller.factory()) == address(factory), "teller's factory");
        require(address(factory.registry()) == address(oldFactory.registry()), "factory's registry");
        require(address(factory.router()) == address(oldFactory.router()), "factory's router");
        require(factory.baseAsset() == oldFactory.baseAsset() && teller.usdg() == oldTeller.usdg(), "USDG");
        require(teller.minOpeningStake() == oldTeller.minOpeningStake(), "minOpeningStake");
        require(teller.minDeposit() == oldTeller.minDeposit(), "minDeposit");
        require(teller.dustUsd() == oldTeller.dustUsd(), "dustUsd");
        require(teller.writeOffMaxWad() == oldTeller.writeOffMaxWad(), "writeOffMaxWad");
        require(teller.weekendInflowBps() == oldTeller.weekendInflowBps(), "weekendInflowBps");
        require(teller.weekendOutflowBps() == oldTeller.weekendOutflowBps(), "weekendOutflowBps");
        require(teller.poolFlowBps() == oldTeller.poolFlowBps(), "poolFlowBps");
        require(teller.poolFlowFloorUsd() == oldTeller.poolFlowFloorUsd(), "poolFlowFloorUsd");
        require(teller.maxLive() == oldTeller.maxLive(), "maxLive");
        require(teller.openSettlement() == oldTeller.openSettlement(), "openSettlement");
        for (uint256 i; i < keepers.length; ++i) require(teller.isKeeper(keepers[i]), "keeper");
    }

    function _print() internal view {
        console.log("teller v2", address(teller));
        console.log("fund factory v2", address(factory), "controller deployer", address(factory.controllerDeployer()));
        console.log("fund fees v2", address(fundFees), "pockets v2", address(pockets));
        console.log("fee config (reused)", address(feeConfig));
        console.log("min opening, min deposit (raw USDG):", teller.minOpeningStake(), teller.minDeposit());
        console.log("weekend caps in, out (bps):", teller.weekendInflowBps(), teller.weekendOutflowBps());
        console.log("pool flow cap (bps), floor (USD):", teller.poolFlowBps(), teller.poolFlowFloorUsd() / 1e18);
        console.log("max live:", teller.maxLive(), "keepers:", keepers.length);
        if (tellerAdmin != deployer) {
            console.log("teller admin", tellerAdmin, "must accept:");
            console.log(string.concat("  cast send ", vm.toString(address(teller)), " 'acceptAdmin()'"));
        }
    }

    function _record(uint256 startBlock) internal {
        string memory p = "v1";
        vm.serializeAddress(p, "teller", address(oldTeller));
        vm.serializeAddress(p, "fundFactory", address(oldFactory));
        vm.serializeAddress(p, "controllerDeployer", address(oldFactory.controllerDeployer()));
        vm.serializeAddress(p, "fundFees", address(oldTeller.fees()));
        vm.serializeUint(p, "startBlock", vm.parseJsonUint(v1, ".startBlock"));
        string memory prev = vm.serializeAddress(p, "pockets", address(oldTeller.pockets()));

        string memory k = "deployment";
        vm.serializeJson(k, v1);
        vm.serializeUint(k, "startBlock", startBlock);
        vm.serializeString(k, "sourceRef", vm.envOr("FUNDS_SOURCE_REF", string("main")));
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "guardian", guardian);
        vm.serializeAddress(k, "fundFactory", address(factory));
        vm.serializeAddress(k, "controllerDeployer", address(factory.controllerDeployer()));
        vm.serializeAddress(k, "fundFees", address(fundFees));
        vm.serializeAddress(k, "pockets", address(pockets));
        vm.serializeAddress(k, "teller", address(teller));
        vm.serializeAddress(k, "tellerAdmin", tellerAdmin);
        vm.serializeAddress(k, "tellerKeepers", keepers);
        vm.serializeUint(k, "minOpeningStake", teller.minOpeningStake());
        vm.serializeUint(k, "minDeposit", teller.minDeposit());
        vm.serializeUint(k, "weekendInflowBps", teller.weekendInflowBps());
        vm.serializeUint(k, "weekendOutflowBps", teller.weekendOutflowBps());
        vm.serializeUint(k, "poolFlowBps", teller.poolFlowBps());
        vm.serializeUint(k, "poolFlowFloorUsd", teller.poolFlowFloorUsd() / 1e18);
        vm.serializeUint(k, "maxLive", teller.maxLive());
        vm.serializeBool(k, "oneTxCreate", true);
        string memory out = vm.serializeString(k, "v1", prev);
        string memory path = vm.envOr("FUNDS_DEPLOYMENT_OUT", string("deployments/4663-teller-v2.json"));
        vm.writeJson(out, path);
        console.log("record written to", path);
    }
}
