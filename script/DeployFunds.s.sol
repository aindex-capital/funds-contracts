// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {ChainlinkSource, IChainlinkFeed} from "../src/pricing/sources/ChainlinkSource.sol";
import {UniswapV3TwapSource, IUniswapV3PoolOracle} from "../src/pricing/sources/UniswapV3TwapSource.sol";
import {PriceRecorder} from "../src/pricing/sources/PriceRecorder.sol";
import {SessionPoolSource, IUniswapV3PoolSession} from "../src/pricing/sources/SessionPoolSource.sol";
import {IClosedMarketSource} from "../src/interfaces/IClosedMarketSource.sol";
import {Pockets} from "../src/core/Pockets.sol";
import {IPockets} from "../src/interfaces/IPockets.sol";
import {IndexNavSource} from "../src/adapters/index/IndexNavSource.sol";
import {IndexLookThrough} from "../src/adapters/index/IndexLookThrough.sol";
import {MorphoMarketRegistry} from "../src/adapters/lending/MorphoMarketRegistry.sol";
import {MorphoBlueAdapter} from "../src/adapters/lending/MorphoBlueAdapter.sol";
import {AggregatorSwapAdapter} from "../src/adapters/swap/AggregatorSwapAdapter.sol";
import {ERC4626Adapter} from "../src/adapters/yield/ERC4626Adapter.sol";
import {AindexIndexAdapter} from "../src/adapters/index/AindexIndexAdapter.sol";
import {UniswapV3LiquidityAdapter} from "../src/adapters/liquidity/UniswapV3LiquidityAdapter.sol";
import {UniswapV4LiquidityAdapter} from "../src/adapters/liquidity/UniswapV4LiquidityAdapter.sol";
import {FablesLiquidityAdapter} from "../src/adapters/liquidity/FablesLiquidityAdapter.sol";
import {FundFactory} from "../src/core/FundFactory.sol";
import {Teller, IFundFactoryLike} from "../src/core/Teller.sol";
import {FeeConfig, FundFees} from "../src/core/Fees.sol";
import {PriceClass} from "../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {IPriceRouter} from "../src/interfaces/IPriceRouter.sol";
import {IMorpho} from "../src/interfaces/external/morpho/IMorpho.sol";
import {IPermit2} from "../src/interfaces/external/permit2/IPermit2.sol";
import {INonfungiblePositionManager} from "../src/interfaces/external/uniswap/IUniswapV3.sol";
import {IWETH9} from "../src/interfaces/external/uniswap/IWETH9.sol";
import {IFablesPoolRegistry} from "../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../src/interfaces/external/fables/IFablesFeeDistributor.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ILookThrough} from "../src/interfaces/ILookThrough.sol";
import {FundsConfig} from "./FundsConfig.sol";

/**
 * @title  DeployFunds
 * @notice Deploys every AINDEX Funds contract to Robinhood Chain and proposes the production price
 *         configuration in `script/funds-config.json`. Run it through `script/deploy-funds.sh`, which checks
 *         the tree, the chain and the environment first and supports DRY_RUN=1.
 *
 * @dev    ## What it deploys, in order
 *         AdapterRegistry (reviewer: FUNDS_REVIEWER), PriceRouter, ChainlinkSource, UniswapV3TwapSource,
 *         SessionPoolSource (weekend worse-of pricing from the config's `weekend` pools), PriceRecorder
 *         (FUNDS_RECORDERS listed as recorders), IndexNavSource, IndexLookThrough, MorphoMarketRegistry (owner
 *         FUNDS_REVIEWER, seeded with the reviewed markets in the config's `morphoMarkets`, by id, so each approval
 *         covers one market's five parameters), FundFactory (guardian FUNDS_GUARDIAN, base asset USDG), Pockets
 *         (holders' pockets, one for every Fund), the public teller (FeeConfig, FundFees, Teller, then
 *         `fees.wireTeller` and `pockets.wireTeller`, the weekend inflow cap from the config's `teller` and one `setKeeper` per address in
 *         FUNDS_KEEPERS), and one implementation of every adapter, each registered in the registry.
 *         FundBook, TellerOps, TellerMath and TellerQueue are linked libraries; forge deploys them first and links
 *         them on its own.
 *
 *         ## The teller and fees
 *         FeeConfig starts at the 70 / 15 / 15 split (manager / $AIX holders / treasury) with FUNDS_AIX_RECIPIENT
 *         (default: the AINDEX payout wallet) and FUNDS_TREASURY (default: the AINDEX Safe) as recipients, and
 *         FUNDS_TELLER_ADMIN (default FUNDS_REVIEWER) as admin. The teller's minimum opening stake is 10 USDG (its
 *         constructor's default; checked here). The deployer is the teller's admin while it lists the keepers and
 *         sets the weekend inflow cap, then starts a two-step transfer to FUNDS_TELLER_ADMIN, which must call
 *         `acceptAdmin`. The teller has no swap routers: deposits enter as cash.
 *         Only the keepers in FUNDS_KEEPERS (comma-separated) may settle batches at launch; the admin can list
 *         more, or open settlement to anyone, later. Stale batches never need a keeper: anyone can cancel out
 *         of them.
 *         The SeedTeller (owner-only seed money, no public deposits) is no longer deployed: every Fund opens
 *         through the public teller, whose opening stake replaces the seed.
 *
 *         ## Why prices are only proposed
 *         The router and the sources make any change that could raise a value wait a day, a first
 *         configuration included. So this script proposes everything and `script/ApplyPending.s.sol` (anyone
 *         may run it) applies it after `CONFIG_DELAY`. Until then every token reads as no market, and a Fund
 *         holding anything but cash cannot act: create Funds after applying.
 *
 *         ## Who ends up owning what
 *         The deployer proposes the price configuration, so it owns the router and sources while the script
 *         runs; at the end it starts a two-step transfer to FUNDS_PRICE_OWNER (unless that is the deployer),
 *         which must call `acceptOwnership` on the router, the Chainlink source, the TWAP source, the session pool
 *         source and the price recorder (the deployer owns the recorder only long enough to list FUNDS_RECORDERS, default
 *         FUNDS_KEEPERS). Adapters are marked verified here only when the deployer
 *         is the reviewer; otherwise the script prints the reviewer's calls.
 *
 *         Writes the record to FUNDS_DEPLOYMENT_OUT (default deployments/4663.json).
 */
contract DeployFunds is Script {
    string internal constant CONFIG = "script/funds-config.json";
    string internal constant SOURCE = "https://github.com/aindex-capital/funds-contracts/blob/";
    /// @notice Default $AIX holders' recipient: the AINDEX payout wallet (pays $AIX holders daily).
    address internal constant AINDEX_PAYOUT_WALLET = 0x8d3e8ccCD0062f3b780a166bdd1DFCB3dfbAEFc5;
    /// @notice Default treasury: the AINDEX Safe.
    address internal constant AINDEX_SAFE = 0x230C4Df28A0065216F2BEf86122125c0F8e4A5af;
    /// @notice Every Fund's least opening stake, raw USDG (10 USDG).
    uint256 internal constant MIN_OPENING_STAKE = 10e6;
    /// @notice The least deposit request, raw USDG (10 USDG); a cash exit needs as many shares at one per USDG.
    uint256 internal constant MIN_DEPOSIT = 10e6;

    string internal json;
    address internal deployer;
    address internal reviewer;
    address internal priceOwner;
    address internal guardian;
    address internal tellerAdmin;
    address internal aixRecipient;
    address internal treasury;
    address[] internal keepers;
    address[] internal recorders;
    string internal ref;

    AdapterRegistry internal registry;
    PriceRouter internal router;
    ChainlinkSource internal chainlink;
    UniswapV3TwapSource internal twap;
    SessionPoolSource internal sessionPools;
    PriceRecorder internal recorder;
    IndexNavSource internal indexNav;
    IndexLookThrough internal lookThrough;
    MorphoMarketRegistry internal markets;
    FundFactory internal factory;
    FeeConfig internal feeConfig;
    FundFees internal fundFees;
    Pockets internal pockets;
    Teller internal teller;
    /// @dev Per token, the weekend spread and band when it has weekend pools (spread 0: none).
    mapping(address => uint256) internal weekendSpread;
    mapping(address => uint256) internal weekendClamp;

    string[] internal adapterNames;
    address[] internal adapterImpls;
    uint256 internal proposed;

    function run() external {
        json = vm.readFile(CONFIG);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "config is for another chain");
        reviewer = vm.envAddress("FUNDS_REVIEWER");
        priceOwner = vm.envAddress("FUNDS_PRICE_OWNER");
        guardian = vm.envAddress("FUNDS_GUARDIAN");
        tellerAdmin = vm.envOr("FUNDS_TELLER_ADMIN", reviewer);
        aixRecipient = vm.envOr("FUNDS_AIX_RECIPIENT", AINDEX_PAYOUT_WALLET);
        treasury = vm.envOr("FUNDS_TREASURY", AINDEX_SAFE);
        ref = vm.envOr("FUNDS_SOURCE_REF", string("main"));
        keepers = vm.envAddress("FUNDS_KEEPERS", ",");
        recorders = vm.envOr("FUNDS_RECORDERS", ",", keepers);
        require(keepers.length != 0, "FUNDS_KEEPERS is empty");
        uint256 startBlock = block.number;

        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        _core();
        _teller();
        _adapters();
        _prices();
        _handOver();
        vm.stopBroadcast();

        _verifyOrPrint();
        _record(startBlock);
    }

    // ---------------------------------------------------------------- contracts

    function _core() internal {
        address usdg = vm.parseJsonAddress(json, ".baseAsset");
        registry = new AdapterRegistry(reviewer);
        router = new PriceRouter(deployer);
        chainlink = new ChainlinkSource(deployer);
        twap = new UniswapV3TwapSource(deployer);
        sessionPools = new SessionPoolSource(deployer);
        recorder = new PriceRecorder(deployer, IPoolManager(_ext("v4PoolManager")));
        for (uint256 i; i < recorders.length; ++i) recorder.setRecorder(recorders[i], true);
        indexNav = new IndexNavSource(IPriceRouter(address(router)));
        lookThrough = new IndexLookThrough();

        FundsConfig.MarketEntry[] memory seed = FundsConfig.morphoMarkets(json);
        bytes32[] memory ids = new bytes32[](seed.length);
        for (uint256 i; i < seed.length; ++i) ids[i] = seed[i].market;
        markets = new MorphoMarketRegistry(reviewer, IMorpho(_ext("morpho")), ids);

        factory = new FundFactory(IAdapterRegistry(address(registry)), IPriceRouter(address(router)), guardian, usdg);
        pockets = new Pockets();
    }

    /// @dev The public teller: fees first (the teller takes them in its constructor), then its keepers and the
    ///      weekend inflow cap.
    function _teller() internal {
        feeConfig = new FeeConfig(tellerAdmin, aixRecipient, treasury);
        (uint16 m, uint16 a, uint16 t,,) = feeConfig.split();
        require(m == 7000 && a == 1500 && t == 1500, "fee split is not 70/15/15");
        fundFees = new FundFees(feeConfig);
        teller = new Teller(IFundFactoryLike(address(factory)), fundFees, IPockets(address(pockets)), deployer);
        fundFees.wireTeller(address(teller));
        pockets.wireTeller(address(teller));
        require(pockets.teller() == address(teller), "pockets not wired to the teller");
        require(teller.minOpeningStake() == MIN_OPENING_STAKE, "opening stake is not 10 USDG");
        require(teller.minDeposit() == MIN_DEPOSIT, "minimum deposit is not 10 USDG");
        require(teller.STALE_AFTER() == 7 days, "a waiting request is not returnable after 7 days");
        uint256 inflow = FundsConfig.weekendInflowBps(json);
        if (inflow != teller.weekendInflowBps()) {
            teller.setParams(
                teller.minOpeningStake(), teller.minDeposit(), teller.dustUsd(), teller.writeOffMaxWad(), uint16(inflow)
            );
        }
        uint256 outflow = FundsConfig.weekendOutflowBps(json);
        if (outflow != teller.weekendOutflowBps()) teller.setWeekendOutflowBps(uint16(outflow));
        uint256 poolFlow = FundsConfig.poolFlowBps(json);
        if (poolFlow != teller.poolFlowBps()) teller.setPoolFlowBps(uint16(poolFlow));
        uint256 floor = FundsConfig.poolFlowFloorUsd(json);
        if (floor != teller.poolFlowFloorUsd()) teller.setPoolFlowFloor(floor);
        for (uint256 i; i < keepers.length; ++i) teller.setKeeper(keepers[i], true);
        require(teller.maxLive() == 3, "waiting requests per address is not 3");
        if (tellerAdmin != deployer) teller.transferAdmin(tellerAdmin);
    }

    function _adapters() internal {
        _add("swap", address(new AggregatorSwapAdapter(IPermit2(_ext("permit2")))), "swap/AggregatorSwapAdapter.sol");
        _add("erc4626", address(new ERC4626Adapter()), "yield/ERC4626Adapter.sol");
        _add("index", address(new AindexIndexAdapter()), "index/AindexIndexAdapter.sol");
        _add("morpho", address(new MorphoBlueAdapter(IMorpho(_ext("morpho")))), "lending/MorphoBlueAdapter.sol");
        _add(
            "uniswapV3",
            address(new UniswapV3LiquidityAdapter(INonfungiblePositionManager(_ext("v3PositionManager")))),
            "liquidity/UniswapV3LiquidityAdapter.sol"
        );
        _add(
            "uniswapV4",
            address(new UniswapV4LiquidityAdapter(IPoolManager(_ext("v4PoolManager")), IWETH9(_ext("weth")))),
            "liquidity/UniswapV4LiquidityAdapter.sol"
        );
        _add(
            "fables",
            address(
                new FablesLiquidityAdapter(
                    IFablesPoolRegistry(_ext("fablesRegistry")),
                    IPoolManager(_ext("v4PoolManager")),
                    IFablesFeeDistributor(_ext("fablesPot"))
                )
            ),
            "liquidity/FablesLiquidityAdapter.sol"
        );
    }

    function _add(string memory label, address impl, string memory path) internal {
        registry.register(impl, string.concat(SOURCE, ref, "/src/adapters/", path));
        adapterNames.push(label);
        adapterImpls.push(impl);
        if (deployer == reviewer) registry.setVerified(impl, true);
    }

    // ---------------------------------------------------------------- prices

    function _prices() internal {
        FundsConfig.WeekendEntry[] memory wk = FundsConfig.weekend(json);
        for (uint256 i; i < wk.length; ++i) {
            SessionPoolSource.Spec[] memory specs = new SessionPoolSource.Spec[](wk[i].pools.length);
            for (uint256 j; j < specs.length; ++j) {
                specs[j] = SessionPoolSource.Spec(
                    IUniswapV3PoolSession(wk[i].pools[j].pool), uint128(wk[i].pools[j].minLiquidity)
                );
            }
            sessionPools.propose(wk[i].token, specs);
            require(wk[i].spreadBps != 0 && wk[i].clampBps != 0, "weekend spread or band is zero");
            weekendSpread[wk[i].token] = wk[i].spreadBps;
            weekendClamp[wk[i].token] = wk[i].clampBps;
        }
        FundsConfig.ChainlinkEntry[] memory feeds = FundsConfig.chainlink(json);
        for (uint256 i; i < feeds.length; ++i) _feed(feeds[i]);
        FundsConfig.TwapEntry[] memory pools = FundsConfig.twap(json);
        for (uint256 i; i < pools.length; ++i) _twap(pools[i]);
        FundsConfig.IndexEntry[] memory indexes = FundsConfig.indexes(json);
        for (uint256 i; i < indexes.length; ++i) _index(indexes[i]);
        router.addHolidays(vm.parseJsonUintArray(json, ".holidays"));
    }

    function _feed(FundsConfig.ChainlinkEntry memory e) internal {
        bool rated = e.quoteToken != address(0); // an exchange-rate feed, quoted in another token
        chainlink.propose(
            e.token,
            ChainlinkSource.Feed({
                feed: IChainlinkFeed(e.feed),
                maxAge: uint32(e.maxAge),
                checkPause: e.checkPause,
                weekendClosed: e.weekendClosed,
                quoteSource: rated ? IPriceSource(address(chainlink)) : IPriceSource(address(0)),
                quoteToken: e.quoteToken,
                decimals: 0
            })
        );
        _route(
            e.token, IPriceSource(address(chainlink)), false, PriceClass.Feed, e.haircutBps, e.usSession, e.closedHaircutBps
        );
    }

    /// @dev A pool-priced token: the TWAP source reports a price in the pool's other token (`quoteToken` in the
    ///      config, checked against the pool), which the router converts through its own price of it.
    function _twap(FundsConfig.TwapEntry memory e) internal {
        address t0 = IUniswapV3PoolOracle(e.pool).token0();
        address t1 = IUniswapV3PoolOracle(e.pool).token1();
        require((t0 == e.token && t1 == e.quoteToken) || (t1 == e.token && t0 == e.quoteToken), "twap pool pair");
        twap.propose(e.token, IUniswapV3PoolOracle(e.pool), uint32(e.window), e.checkPause);
        _route(
            e.token,
            IPriceSource(address(twap)),
            true,
            e.thin ? PriceClass.Thin : PriceClass.Pool,
            e.haircutBps,
            e.usSession,
            e.closedHaircutBps
        );
    }

    function _index(FundsConfig.IndexEntry memory e) internal {
        _route(
            e.token, IPriceSource(address(indexNav)), false, PriceClass.Pool, e.haircutBps, e.usSession, e.closedHaircutBps
        );
        router.proposeLookThrough(e.token, ILookThrough(address(lookThrough)));
    }

    function _route(
        address token,
        IPriceSource s,
        bool chained,
        PriceClass c,
        uint256 haircut,
        bool session,
        uint256 closed
    ) internal {
        router.propose(
            token,
            PriceRouter.Config({
                primary: s,
                check: IPriceSource(address(0)),
                class_: c,
                haircutBps: uint16(haircut),
                maxDeviationBps: 0,
                decimals: 0,
                chained: chained ? 1 : 0
            })
        );
        if (session) {
            uint256 spread = weekendSpread[token];
            router.proposeSession(
                token,
                PriceRouter.Session({
                    usSession: true,
                    closedHaircutBps: uint16(closed),
                    closedSpreadBps: uint16(spread),
                    closedClampBps: uint16(weekendClamp[token]),
                    closedSource: spread == 0
                        ? IClosedMarketSource(address(0))
                        : IClosedMarketSource(address(sessionPools))
                })
            );
        }
        ++proposed;
    }

    function _handOver() internal {
        if (priceOwner == deployer) return;
        router.transferOwnership(priceOwner);
        chainlink.transferOwnership(priceOwner);
        twap.transferOwnership(priceOwner);
        sessionPools.transferOwnership(priceOwner);
        recorder.transferOwnership(priceOwner);
    }

    // ---------------------------------------------------------------- report

    function _verifyOrPrint() internal view {
        console.log("tokens proposed:", proposed, "apply after", block.timestamp + router.CONFIG_DELAY());
        if (deployer == reviewer) {
            console.log("adapters registered and marked verified (deployer is the reviewer)");
        } else {
            console.log("adapters registered, NOT verified. The reviewer", reviewer, "should send:");
            for (uint256 i; i < adapterImpls.length; ++i) {
                console.log(
                    string.concat(
                        "  cast send ", vm.toString(address(registry)), " 'setVerified(address,bool)' ",
                        vm.toString(adapterImpls[i]), " true   # ", adapterNames[i]
                    )
                );
            }
        }
        if (priceOwner != deployer) {
            console.log("price owner", priceOwner, "must accept ownership of the router, sources and recorder:");
            console.log(string.concat("  cast send ", vm.toString(address(router)), " 'acceptOwnership()'"));
            console.log(string.concat("  cast send ", vm.toString(address(chainlink)), " 'acceptOwnership()'"));
            console.log(string.concat("  cast send ", vm.toString(address(twap)), " 'acceptOwnership()'"));
            console.log(string.concat("  cast send ", vm.toString(address(sessionPools)), " 'acceptOwnership()'"));
            console.log(string.concat("  cast send ", vm.toString(address(recorder)), " 'acceptOwnership()'"));
        }
        console.log("teller", address(teller), "weekend inflow cap (bps):", teller.weekendInflowBps());
        console.log("weekend outflow cap (bps):", teller.weekendOutflowBps());
        console.log("pool-price flow cap (bps of NAV over the share in Pool and Thin tokens):", teller.poolFlowBps());
        console.log("pool-price flow cap floor per day (USD):", teller.poolFlowFloorUsd() / 1e18);
        console.log("pockets", address(pockets));
        console.log("teller keepers listed:", keepers.length, "price recorders listed:", recorders.length);
        console.log("fee split 70/15/15; $AIX recipient", aixRecipient, "treasury", treasury);
        if (tellerAdmin != deployer) {
            console.log("teller admin", tellerAdmin, "must accept (FeeConfig names it admin already):");
            console.log(string.concat("  cast send ", vm.toString(address(teller)), " 'acceptAdmin()'"));
        }
    }

    function _record(uint256 startBlock) internal {
        string memory a = "adapters";
        string memory adaptersJson;
        for (uint256 i; i < adapterImpls.length; ++i) {
            adaptersJson = vm.serializeAddress(a, adapterNames[i], adapterImpls[i]);
        }
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", startBlock);
        vm.serializeUint(k, "applyAfter", block.timestamp + router.CONFIG_DELAY());
        vm.serializeString(k, "sourceRef", ref);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "reviewer", reviewer);
        vm.serializeAddress(k, "priceOwner", priceOwner);
        vm.serializeAddress(k, "guardian", guardian);
        vm.serializeAddress(k, "baseAsset", vm.parseJsonAddress(json, ".baseAsset"));
        vm.serializeAddress(k, "adapterRegistry", address(registry));
        vm.serializeAddress(k, "priceRouter", address(router));
        vm.serializeAddress(k, "chainlinkSource", address(chainlink));
        vm.serializeAddress(k, "uniswapV3TwapSource", address(twap));
        vm.serializeAddress(k, "sessionPoolSource", address(sessionPools));
        vm.serializeAddress(k, "pockets", address(pockets));
        vm.serializeAddress(k, "priceRecorder", address(recorder));
        vm.serializeAddress(k, "indexNavSource", address(indexNav));
        vm.serializeAddress(k, "indexLookThrough", address(lookThrough));
        vm.serializeAddress(k, "morphoMarketRegistry", address(markets));
        vm.serializeAddress(k, "tellerKeepers", keepers);
        vm.serializeAddress(k, "priceRecorders", recorders);
        vm.serializeAddress(k, "fundFactory", address(factory));
        vm.serializeAddress(k, "controllerDeployer", address(factory.controllerDeployer()));
        vm.serializeAddress(k, "feeConfig", address(feeConfig));
        vm.serializeAddress(k, "fundFees", address(fundFees));
        vm.serializeAddress(k, "teller", address(teller));
        vm.serializeAddress(k, "tellerAdmin", tellerAdmin);
        vm.serializeAddress(k, "aixRecipient", aixRecipient);
        vm.serializeAddress(k, "treasury", treasury);
        vm.serializeUint(k, "minOpeningStake", teller.minOpeningStake());
        vm.serializeUint(k, "minDeposit", teller.minDeposit());
        vm.serializeUint(k, "weekendInflowBps", teller.weekendInflowBps());
        vm.serializeUint(k, "weekendOutflowBps", teller.weekendOutflowBps());
        vm.serializeUint(k, "poolFlowBps", teller.poolFlowBps());
        vm.serializeUint(k, "poolFlowFloorUsd", teller.poolFlowFloorUsd() / 1e18);
        vm.serializeString(k, "feeSplit", "manager 7000, aix 1500, treasury 1500 (bps)");
        string memory out = vm.serializeString(k, "adapters", adaptersJson);
        string memory path = vm.envOr("FUNDS_DEPLOYMENT_OUT", string("deployments/4663.json"));
        vm.writeJson(out, path);
        console.log("record written to", path);
    }

    function _ext(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".external.", key));
    }
}
