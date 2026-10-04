// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DeployFunds} from "../../script/DeployFunds.s.sol";
import {ApplyPending} from "../../script/ApplyPending.s.sol";
import {FundsConfig} from "../../script/FundsConfig.sol";
import {FreshFeed} from "../../script/rehearsal/FreshFeed.sol";
import {IChainlinkFeed} from "../../src/pricing/sources/ChainlinkSource.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {Teller} from "../../src/core/Teller.sol";
import {FundController} from "../../src/core/FundController.sol";
import {DialPresets} from "../../src/core/DialPresets.sol";
import {AggregatorSwapAdapter} from "../../src/adapters/swap/AggregatorSwapAdapter.sol";
import {IFundVault} from "../../src/interfaces/IFundVault.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {IAdapter, Amount} from "../../src/interfaces/IAdapter.sol";
import {Side, PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {MarketParams, IMorpho} from "../../src/interfaces/external/morpho/IMorpho.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3.sol";
import {IFablesPoolRegistry} from "../../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFolio} from "../../src/interfaces/external/folio/IFolio.sol";

/**
 * @notice Gas of the public teller at the caps, on a fork of Robinhood Chain with the production price
 *         configuration (deployed and applied by the real scripts), real tokens and real venues. Skipped without
 *         ROBINHOOD_RPC. Run alone, isolated, so every call is its own transaction and starts cold, as on chain:
 *
 *           ROBINHOOD_RPC=... forge test --match-contract SettlementGasFork --isolate --gas-limit 900000000000 -vv
 *
 *         The Fund: every counted token the vault allows (USDG, AINDEX's AIXSTR index share, priced by look-through
 *         over its ten basket tokens, and Chainlink- and pool-priced Robinhood stock, ETF and crypto tokens), and
 *         every adapter slot filled to the adapter's own cap: by default the swap adapter, ERC-4626 in two USDG
 *         vaults, Morpho lending in every market it can reach with collateral and a borrow in each stock market,
 *         and Uniswap v3, Uniswap v4 and Fables with ranges; the rest of the slots one more of each liquidity kind.
 *         Every batch is full (100 requests). Since deposits enter as cash (2026-10-02) a settlement reads the Fund
 *         once and moves USDG; the heaviest paths are the exit in kind (every adapter split) and a settlement's
 *         reading at the weekend (every stock token's pool read for the worse-of rule).
 *
 *         Knobs (environment): GAS_TOKENS, GAS_SWAP, GAS_MORPHO, GAS_V3, GAS_V4, GAS_FABLES, GAS_ERC4626 (adapter
 *         counts; GAS_SWAP and GAS_ERC4626 are 0 or 1), GAS_POSITIONS, GAS_MARKETS. Each path logs its gas net of
 *         refunds and before refunds (what its gas limit must cover: refunds are credited only at the end), flags it
 *         above its target (`SETTLE_TARGET`, or `IN_KIND_TARGET` for an exit in kind) and fails above `TX_LIMIT`.
 *         Figures: docs/DEPOSITS-AND-EXITS.md, "Gas".
 */
contract SettlementGasForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 77_897_467;
    uint256 internal constant TX_LIMIT = 32_000_000;
    /// @dev Every settlement path at or under this, gas before refunds.
    uint256 internal constant SETTLE_TARGET = 12_000_000;
    /// @dev The exit in kind (the guaranteed way out) at or under this, gas before refunds.
    uint256 internal constant IN_KIND_TARGET = 20_000_000;
    string internal OUT = vm.envOr("GAS_OUT", string("deployments/.fork-gas-4663.json"));

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant AIXSTR = 0xe7c9209D3C35d7cf1895e46a2d62b9A30841bB98;
    address internal constant INDEX_ZAP = 0x5F807BB130739F8d9A96d7d4383A1318E0669bFF;
    address internal constant UR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address internal constant SP_USDG = 0xde770c84FE66E063336b31737cFE9790f18c4087;
    IMorpho internal constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IFablesPoolRegistry internal constant FABLES = IFablesPoolRegistry(0x159A113E012593D9B3cC63ad45E30F0467e13Ef3);
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;

    /// @dev A counted token and its route to USDG: a v3 pool against USDG, or against WETH then WETH/USDG 0.05%.
    struct Tok {
        address t;
        uint24 fee;
        bool viaWeth;
    }

    Tok[] internal toks; // every counted token but USDG and AIXSTR
    mapping(address => Tok) internal routeOf;
    Tok[] internal basketRoutes;

    address internal admin = makeAddr("tellerAdmin");
    address internal keeper = makeAddr("keeper");
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");

    Teller internal tel;
    PriceRouter internal router;
    FundController internal controller;
    address internal vault;
    string internal dep;
    address[] internal ads;
    uint256 internal nextUser = 0x10000;
    uint64 internal lastBatch;
    uint256 internal target = SETTLE_TARGET;

    // ================================================================ setup

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        _tokens();
        _deploy();
        _createFund();
        _fill();
        _positions();
    }

    function _tokens() internal {
        // Chainlink-priced, routed against USDG (fee tier of the deepest USDG pool on 2026-10-02).
        _tok(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 500, false); // WETH
        _tok(0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4, 500, false); // cbBTC
        _tok(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 500, false); // AAPL
        _tok(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 500, false); // NVDA
        _tok(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 500, false); // SPY
        _tok(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 500, false); // GOOGL
        _tok(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 500, false); // SPCX
        _tok(0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 500, false); // QQQ
        _tok(0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e, 3000, false); // GLD
        _tok(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 3000, false); // TSLA
        _tok(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 3000, false); // AMD
        _tok(0x12f190a9F9d7D37a250758b26824B97CE941bF54, 3000, false); // AMZN
        _tok(0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA, 10000, false); // ASML
        _tok(0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4, 3000, false); // BABA
        _tok(0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5, 3000, false); // CRCL
        _tok(0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd, 10000, false); // DELL
        _tok(0x1b0E319c6A659F002271B69dB8A7df2F911c153E, 500, false); // GME
        _tok(0xc72b96e0E48ecd4DC75E1e45396e26300BC39681, 3000, false); // INTC
        _tok(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 3000, false); // META
        _tok(0xe93237C50D904957Cf27E7B1133b510C669c2e74, 3000, false); // MSFT
        _tok(0xec262a75e413fAfD0dF80480274532C79D42da09, 10000, false); // MSTR
        _tok(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 3000, false); // MU
        _tok(0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 3000, false); // PLTR
        _tok(0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5, 3000, false); // SGOV
        _tok(0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f, 3000, false); // SLV
        _tok(0xB90A19fF0Af67f7779afF50A882A9CfF42446400, 10000, false); // SNDK
        _tok(0x58FfE4a942d3885bAa22D7520691F611EF09e7AA, 10000, false); // TSM
        _tok(0xd917B029C761D264c6A312BBbcDA868658eF86a6, 3000, false); // USAR
        _tok(0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344, 3000, false); // USO
        _tok(0x6330D8C3178a418788dF01a47479c0ce7CCF450b, 3000, true); // COIN, through WETH
        // Pool-priced (30-minute TWAP), routed through the configured pool.
        _tok(0x39dBED3a2bd333467115dE45665cC57F813C4571, 3000, true); // PONS, through WETH
        _tok(0xCceE82fE024c36fA15E1005edE3E9e4787e23D09, 3000, false); // HIMS
        _tok(0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2, 3000, false); // COST
        _tok(0x1D11f0496982706C5e14A514D4E79F2e6BdE4516, 10000, false); // DJT
        _tok(0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C, 10000, false); // RDDT
        _tok(0x8005d266423c7ea827372c9c864491e5786600ea, 500, false); // LLY
        _tok(0x116F00968269B7bfbaD4109cE591d6E74c0601d4, 3000, false); // NET
        _tok(0x329fcACEb9AD6F9580DD5F643fed0646900D043c, 3000, false); // LMT (thin)
        // AIXSTR's basket, bought for the zap's mint: the same pools.
        (address[] memory basket,) = IFolio(AIXSTR).toAssets(1e18, 0);
        for (uint256 i; i < basket.length; ++i) {
            require(routeOf[basket[i]].t != address(0), "basket token without a route");
            basketRoutes.push(routeOf[basket[i]]);
        }
    }

    function _tok(address t, uint24 fee, bool viaWeth) internal {
        Tok memory k = Tok(t, fee, viaWeth);
        toks.push(k);
        routeOf[t] = k;
    }

    /// @dev The real deploy and apply scripts, then the clock on to a weekday inside the US session.
    function _deploy() internal {
        vm.createDir("deployments", true);
        vm.setEnv("FUNDS_REVIEWER", vm.toString(makeAddr("reviewer")));
        vm.setEnv("FUNDS_PRICE_OWNER", vm.toString(makeAddr("priceOwner")));
        vm.setEnv("FUNDS_GUARDIAN", vm.toString(makeAddr("guardian")));
        vm.setEnv("FUNDS_TELLER_ADMIN", vm.toString(admin));
        vm.setEnv("FUNDS_KEEPERS", vm.toString(keeper));
        vm.setEnv("FUNDS_DEPLOYMENT_OUT", OUT);
        vm.setEnv("FUNDS_DEPLOYMENT", OUT);
        new DeployFunds().run();
        _extraMarkets();

        // A day for the price delay, then on to the next weekday at 15:00 UTC (the US session is open).
        uint256 t = block.timestamp + 1 days + 60;
        t = _nextOpen(t);
        vm.warp(t);
        _freshFeeds();
        new ApplyPending().run();

        dep = vm.readFile(OUT);
        vm.removeFile(OUT);
        tel = Teller(vm.parseJsonAddress(dep, ".teller"));
        router = PriceRouter(vm.parseJsonAddress(dep, ".priceRouter"));
        vm.startPrank(admin);
        tel.acceptAdmin();
        // A share is worth about two USDG here: a one-USDG minimum lets every holder's cash exit clear it.
        tel.setParams(10e6, 1e6, 1e18, 1e14, 500);
        vm.stopPrank();
        MorphoMarketRegistryLike reg = MorphoMarketRegistryLike(vm.parseJsonAddress(dep, ".morphoMarketRegistry"));
        for (uint256 i; i < extraMarkets.length; ++i) reg.applyPending(extraMarkets[i]);
    }

    bytes32[] internal extraMarkets;

    /// @dev Eight more USDG markets, AINDEX-approved, so one Morpho clone can reach its 16-market cap: the busiest
    ///      reviewed NVDA market's oracle, rate model and LLTV, with other counted tokens as collateral (each a new
    ///      market id; the oracle's price only sizes the small borrow).
    function _extraMarkets() internal {
        string memory d = vm.readFile(OUT);
        MorphoMarketRegistryLike reg = MorphoMarketRegistryLike(vm.parseJsonAddress(d, ".morphoMarketRegistry"));
        FundsConfig.MarketEntry[] memory ms = FundsConfig.morphoMarkets(vm.readFile("script/funds-config.json"));
        (address loan,, address oracle, address irm, uint256 lltv) = MORPHO.idToMarketParams(ms[0].market);
        address[8] memory colls = [
            0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, // QQQ
            0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e, // GLD
            0x12f190a9F9d7D37a250758b26824B97CE941bF54, // AMZN
            0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, // META
            0xe93237C50D904957Cf27E7B1133b510C669c2e74, // MSFT
            0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, // AMD
            0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5, // CRCL
            0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD // MU
        ];
        for (uint256 i; i < colls.length; ++i) {
            MarketParams memory mp = MarketParams(loan, colls[i], oracle, irm, lltv);
            bytes32 id = keccak256(abi.encode(mp));
            (,,,, uint128 last,) = MORPHO.market(id);
            if (last == 0) {
                (bool ok,) = address(MORPHO).call(
                    abi.encodeWithSignature("createMarket((address,address,address,address,uint256))", mp)
                );
                require(ok, "createMarket");
            }
            vm.prank(vm.parseJsonAddress(d, ".reviewer"));
            reg.propose(id);
            extraMarkets.push(id);
        }
    }

    /// @dev The first weekday 15:00 UTC at or after `t`.
    function _nextOpen(uint256 t) internal pure returns (uint256) {
        uint256 day = t / 1 days;
        if (t % 1 days > 15 hours) day += 1;
        // 1970-01-01 was a Thursday: (day + 4) % 7 is 0 on Sunday, 6 on Saturday.
        while ((day + 4) % 7 == 0 || (day + 4) % 7 == 6) day += 1;
        return day * 1 days + 15 hours;
    }

    function _freshFeeds() internal {
        FundsConfig.ChainlinkEntry[] memory feeds = FundsConfig.chainlink(vm.readFile("script/funds-config.json"));
        bytes memory fresh = type(FreshFeed).runtimeCode;
        for (uint256 i; i < feeds.length; ++i) {
            address f = feeds[i].feed;
            if (f.code.length == fresh.length && keccak256(f.code) == keccak256(fresh)) continue;
            (, int256 answer,,,) = IChainlinkFeed(f).latestRoundData();
            uint8 d = IChainlinkFeed(f).decimals();
            vm.etch(f, fresh);
            vm.store(f, bytes32(uint256(0)), bytes32(uint256(answer)));
            vm.store(f, bytes32(uint256(1)), bytes32(uint256(d)));
        }
    }

    function _createFund() internal {
        // A large stake, so a share is worth about two USDG and every request clears the one-share minimum.
        deal(USDG, owner, 40_000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(tel), 40_000e6);
        address c;
        (vault, c) = tel.createFund("Gas Fund", "GAS", DialPresets.open(), 40_000e6, 100, 1000);
        controller = FundController(c);
        // Hourly cut-offs, so batches close inside the session.
        tel.setSchedule(vault, 1 hours, 0);

        // Default: the swap adapter, ERC-4626, and the rest of the slots shared by the position-holding kinds (12 in
        // all, the cap). GAS_SWAP=0 GAS_ERC4626=0 and one kind at 12 is a kind's heaviest mix (GAS_ERC4626 counts
        // clones; Robinhood Chain has two USDG ERC-4626 vaults, so each clone holds both).
        uint256 nMorpho = vm.envOr("GAS_MORPHO", uint256(3));
        uint256 nV3 = vm.envOr("GAS_V3", uint256(3));
        uint256 nV4 = vm.envOr("GAS_V4", uint256(2));
        uint256 nFables = vm.envOr("GAS_FABLES", uint256(2));
        if (vm.envOr("GAS_SWAP", uint256(1)) != 0) _add("swap", _swapConfig());
        for (uint256 i; i < vm.envOr("GAS_ERC4626", uint256(1)); ++i) {
            address[] memory v = new address[](2);
            (v[0], v[1]) = (STEAK_USDG, SP_USDG);
            _add("erc4626", abi.encode(v));
        }
        for (uint256 i; i < nMorpho; ++i) {
            _add("morpho", abi.encode(vm.parseJsonAddress(dep, ".morphoMarketRegistry"), new bytes32[](0)));
        }
        for (uint256 i; i < nV3; ++i) {
            _add("uniswapV3", "");
        }
        for (uint256 i; i < nV4; ++i) {
            _add("uniswapV4", "");
        }
        (address[] memory hooks, bytes32[] memory witness) = _fablesHooks();
        for (uint256 i; i < nFables; ++i) {
            _add("fables", abi.encode(hooks, witness, uint16(0)));
        }
        controller.setManager(manager, uint64(block.timestamp + 300 days));
        vm.stopPrank();
        console.log("adapters:", ads.length);
    }

    function _add(string memory label, bytes memory config) internal {
        address impl = vm.parseJsonAddress(dep, string.concat(".adapters.", label));
        ads.push(controller.addAdapter(impl, config));
    }

    function _swapConfig() internal pure returns (bytes memory) {
        AggregatorSwapAdapter.Target[] memory t = new AggregatorSwapAdapter.Target[](1);
        t[0] = AggregatorSwapAdapter.Target(UR, AggregatorSwapAdapter.Approval(uint8(1)));
        return abi.encode(t);
    }

    function _fablesHooks() internal view returns (address[] memory hooks, bytes32[] memory witness) {
        uint256 n = FABLES.poolCount();
        hooks = new address[](n);
        witness = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            IFablesPoolRegistry.PoolInfo memory p = FABLES.poolAt(i);
            if (!p.active || Currency.unwrap(p.key.currency0) == address(0)) continue;
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

    /// @dev Every counted token held by the vault, about $1,000 each, and USDG for the positions.
    function _fill() internal {
        // GAS_TOKENS: how many of the 38 to hold; by default as many as the vault counts, less USDG and AIXSTR.
        uint256 n = vm.envOr(
            "GAS_TOKENS", IFundVault(vault).trackedTokens().length == 0 ? 0 : FundVaultCaps(vault).MAX_TRACKED() - 2
        );
        while (toks.length > n) toks.pop();
        for (uint256 i; i < toks.length; ++i) {
            // WETH backs every Uniswap v4 position here (12 clones of 10 at the caps): more of it.
            _give(toks[i].t, vault, _amountFor(toks[i].t, toks[i].t == WETH ? 4000e18 : 1000e18));
            vm.prank(address(controller));
            IFundVault(vault).track(toks[i].t);
        }
        _give(AIXSTR, vault, _amountFor(AIXSTR, 150e18));
        vm.prank(address(controller));
        IFundVault(vault).track(AIXSTR);
        console.log("counted tokens:", IFundVault(vault).trackedTokens().length);
    }

    function _amountFor(address t, uint256 usd) internal view returns (uint256) {
        uint256 px = router.quote(t).fair;
        require(px != 0, "no price");
        return usd * (10 ** IERC20Metadata(t).decimals()) / px;
    }

    /// @dev `deal`, or, for a token whose balance is not a plain slot, a transfer from its deepest pool.
    function _give(address t, address to, uint256 amt) internal {
        try this.dealExt(t, to, amt) {}
        catch {
            Tok memory k = routeOf[t];
            address pool = IUniswapV3Factory(V3_FACTORY).getPool(t, k.viaWeth ? WETH : USDG, k.fee);
            vm.prank(pool);
            IERC20(t).transfer(to, amt);
        }
        require(IERC20(t).balanceOf(to) >= amt * 99 / 100, "give failed");
    }

    function dealExt(address t, address to, uint256 amt) external {
        deal(t, to, IERC20(t).balanceOf(to) + amt);
    }

    // ================================================================ positions

    function _positions() internal {
        uint256 per = vm.envOr("GAS_POSITIONS", type(uint256).max); // liquidity positions per adapter, at most its cap
        for (uint256 i; i < ads.length; ++i) {
            string memory n = IAdapterName(ads[i]).name();
            if (_startsWith(n, "ERC-4626")) _erc4626(ads[i]);
            else if (_startsWith(n, "Morpho")) _morpho(ads[i]);
            else if (_startsWith(n, "Uniswap v3")) _v3(ads[i], per, i);
            else if (_startsWith(n, "Uniswap v4")) _v4(ads[i], per, i);
            else if (_startsWith(n, "Fables")) _fables(ads[i], _min(per, AdapterCaps(ads[i]).MAX_RANGES()), i);
        }
        (uint256 nav, bool ok) = controller.nav(uint8(Side.Fair));
        require(ok, "book incomplete");
        console.log("NAV (USD) after positions:", nav / 1e18);
        for (uint256 i; i < ads.length; ++i) {
            (Amount[] memory a, Amount[] memory d) = IAdapter(ads[i]).positions(router);
            console.log(IAdapterName(ads[i]).name(), a.length, d.length);
        }
    }

    function _act(address a, bytes memory action) internal {
        vm.prank(manager);
        controller.act(a, action);
    }

    function _erc4626(address a) internal {
        _act(a, abi.encode(uint8(0), STEAK_USDG, uint256(150e6), uint256(1)));
        _act(a, abi.encode(uint8(0), SP_USDG, uint256(150e6), uint256(1)));
    }

    /// @dev Lend in every reviewed market, post collateral in every stock market and borrow USDG in each of them.
    ///      Seven borrows of USDG in one clone used to fail the teller's debt check (`DebtChanged`, 4 to 12 units
    ///      over: each market's debt rounded up on its own); the adapter now grows a loan token's debt across its
    ///      markets as a whole, so this is the heaviest Morpho book as well as a check of that.
    function _morpho(address a) internal {
        FundsConfig.MarketEntry[] memory ms = FundsConfig.morphoMarkets(vm.readFile("script/funds-config.json"));
        bytes32[] memory ids = new bytes32[](ms.length + extraMarkets.length);
        for (uint256 i; i < ms.length; ++i) ids[i] = ms[i].market;
        for (uint256 i; i < extraMarkets.length; ++i) ids[ms.length + i] = extraMarkets[i];
        uint256 nMarkets = vm.envOr("GAS_MARKETS", AdapterCaps(a).MAX_MARKETS());
        uint256 done;
        // Markets the Fund can borrow in first (their collateral is counted), so a cap below the market count
        // is measured at its heaviest; then lend-only ones (syrupUSDG).
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 i; i < ids.length && done < nMarkets; ++i) {
                (address loan, address coll, address oracle, address irm, uint256 lltv) = MORPHO.idToMarketParams(ids[i]);
                bool stock = IFundVault(vault).isTracked(coll);
                if (stock != (pass == 0)) continue;
                MarketParams memory mp = MarketParams(loan, coll, oracle, irm, lltv);
                _act(a, abi.encode(uint8(0), mp, uint256(60e6)));
                ++done;
                if (!stock) continue;
                _act(a, abi.encode(uint8(2), mp, _amountFor(coll, 40e18)));
                try this.actExt(a, abi.encode(uint8(4), mp, uint256(2e6))) {} catch {}
            }
        }
        console.log("morpho markets opened:", done);
    }

    /// @dev Pools for liquidity positions: token against USDG, deep enough.
    function _lpPool(uint256 k) internal view returns (address t, uint24 fee) {
        address[10] memory list = [
            WETH,
            0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, // NVDA
            0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, // SPY
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, // GOOGL
            0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, // AAPL
            0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, // SPCX
            0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, // QQQ
            0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4, // cbBTC
            0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e, // GLD
            0x322F0929c4625eD5bAd873c95208D54E1c003b2d // TSLA
        ];
        t = list[k % 10];
        fee = routeOf[t].fee;
    }

    function _v3(address a, uint256 n, uint256 salt) internal {
        n = _min(n, AdapterCaps(a).MAX_POSITIONS());
        for (uint256 k; k < n; ++k) {
            (address t, uint24 fee) = _lpPool(k + salt);
            address pool = IUniswapV3Factory(V3_FACTORY).getPool(t, USDG, fee);
            (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
            int24 sp = IUniswapV3Pool(pool).tickSpacing();
            (int24 lo, int24 hi) = _range(tick, sp, sp * int24(int256(5 + k + salt)));
            (address t0, address t1) = t < USDG ? (t, USDG) : (USDG, t);
            uint256 a0 = t0 == USDG ? 25e6 : _amountFor(t0, 25e18);
            uint256 a1 = t1 == USDG ? 25e6 : _amountFor(t1, 25e18);
            _act(a, abi.encode(uint8(0), t0, t1, fee, lo, hi, a0, a1, uint256(0), uint256(0)));
        }
    }

    function _v4(address a, uint256 n, uint256 salt) internal {
        n = _min(n, AdapterCaps(a).MAX_POSITIONS());
        PoolKey memory key = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 500, 10, IHooks(address(0)));
        (, int24 tick,,) = PM.getSlot0(key.toId());
        for (uint256 k; k < n; ++k) {
            (int24 lo, int24 hi) = _range(tick, 10, int24(int256(60 + 20 * k + salt * 7)) * 10);
            _act(a, abi.encode(uint8(0), key, lo, hi, _amountFor(WETH, 25e18), uint256(25e6), uint256(0), uint256(0)));
        }
    }

    /// @dev Fables pools whose tokens the Fund counts.
    function _fables(address a, uint256 n, uint256 salt) internal {
        uint256 count = FABLES.poolCount();
        uint256 done;
        for (uint256 i; i < count && done < n; ++i) {
            IFablesPoolRegistry.PoolInfo memory p = FABLES.poolAt((i + salt * 5) % count);
            address t0 = Currency.unwrap(p.key.currency0);
            address t1 = Currency.unwrap(p.key.currency1);
            if (!p.active || t0 == address(0)) continue;
            if (!IFundVault(vault).isTracked(t0) || !IFundVault(vault).isTracked(t1)) continue;
            (, int24 tick,,) = PM.getSlot0(p.key.toId());
            (int24 lo, int24 hi) = _range(tick, p.key.tickSpacing, 20 * p.key.tickSpacing);
            uint256 a0 = t0 == USDG ? 25e6 : _amountFor(t0, 25e18);
            uint256 a1 = t1 == USDG ? 25e6 : _amountFor(t1, 25e18);
            try this.actExt(
                a, abi.encode(uint8(0), PoolId.unwrap(p.id), lo, hi, uint128(a0), uint128(a1), uint128(0))
            ) {
                ++done;
            } catch {}
        }
        console.log("fables ranges opened:", done);
    }

    function actExt(address a, bytes memory action) external {
        _act(a, action);
    }

    function _range(int24 tick, int24 spacing, int24 half) internal pure returns (int24 lo, int24 hi) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        lo = c * spacing - (half / spacing) * spacing;
        hi = c * spacing + (half / spacing + 1) * spacing;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    // ================================================================ requests and batches

    function _user() internal returns (address u) {
        u = address(uint160(nextUser++));
    }

    function _deposits(uint256 n, uint256 each) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address u = _user();
            deal(USDG, u, each);
            vm.startPrank(u);
            IERC20(USDG).approve(address(tel), each);
            ids[i] = tel.requestDeposit(vault, each, 1);
            vm.stopPrank();
            lastBatch = tel.request(ids[i]).batch;
        }
    }

    function _redeems(address[] memory who) internal {
        for (uint256 i; i < who.length; ++i) {
            uint256 sh = IERC20(vault).balanceOf(who[i]);
            vm.startPrank(who[i]);
            IERC20(vault).approve(address(tel), sh);
            uint256 rid = tel.requestRedeem(vault, sh, 1);
            vm.stopPrank();
            lastBatch = tel.request(rid).batch;
        }
    }

    /// @dev Close the open batch: on to its cut-off, inside the US session.
    function _close() internal returns (uint64 id) {
        id = lastBatch;
        uint64 cutoff = tel.batch(vault, id).cutoff;
        uint256 t = cutoff + 1;
        uint256 s = t % 1 days;
        if (s < 14 hours || s > 19 hours) t = _nextOpen(t);
        vm.warp(t);
        console.log("batch, cutoff, now:", id, cutoff, block.timestamp);
    }

    // ================================================================ measuring

    /// @dev Logs the measured total (execution, 21k and calldata, net of refunds) and the gas the transaction's
    ///      limit must cover: the same before refunds (a slot cleared in the call is refunded only at its end, so it
    ///      still needs the gas while it runs). Returns the latter, the figure the caps are sized by.
    function _report(string memory what, uint256 execGas, uint256 refunded, bytes memory callData)
        internal
        view
        returns (uint256)
    {
        uint256 cd;
        for (uint256 i; i < callData.length; ++i) {
            cd += callData[i] == 0 ? 4 : 16;
        }
        uint256 total = execGas + 21_000 + cd;
        uint256 limit = total + refunded;
        console.log(what);
        console.log("   execution, calldata bytes, total with intrinsic (net of refunds):", execGas, callData.length, total);
        console.log("   refunded at the end, GAS BEFORE REFUNDS (what the limit must cover):", refunded, limit);
        console.log("   target, headroom:", target, limit < target ? target - limit : 0);
        if (limit > target) console.log("   ABOVE THE TARGET");
        return limit;
    }

    /// @dev One teller call from `from`, measured. A call that reverts is still measured and its reason logged.
    function _measure(address from, address to, bytes memory cd, string memory what) internal returns (uint256) {
        vm.prank(from);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = to.call(cd);
        g -= gasleft();
        uint256 refunded = uint256(int256(vm.lastCallGas().gasRefunded));
        if (!ok) {
            console.log("   REVERTED, reason selector and length:", uint256(bytes32(ret)) >> 224, ret.length);
            console.logBytes(ret);
        }
        require(ok, "call reverted");
        return _report(what, g, refunded, cd);
    }

    function _settle(uint64 id, string memory what) internal returns (uint256) {
        return _measure(keeper, address(tel), abi.encodeCall(Teller.settle, (vault, id, new uint256[](0))), what);
    }

    function _claimAll(uint64 id) internal {
        uint256[] memory ids = tel.batchRequests(vault, id);
        for (uint256 i; i < ids.length; ++i) {
            ITeller.Request memory r = tel.request(ids[i]);
            if (r.batch != id || r.status != ITeller.Status.Pending) continue;
            (,, bool waiting) = tel.due(ids[i]);
            if (!waiting) tel.claim(ids[i]);
        }
    }

    /// @dev Batch 1: a full batch of deposits, cash in at NAV. Leaves 100 holders.
    function _firstBatch() internal returns (uint256 g, address[] memory holders) {
        _deposits(100, 15e6);
        uint64 id = _close();
        g = _settle(id, "settle: 100 deposits, cash in at ask NAV");
        require(tel.round(vault, id, 1).minted != 0, "nothing minted");
        uint256[] memory ids = tel.batchRequests(vault, id);
        holders = new address[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            holders[i] = tel.request(ids[i]).owner;
        }
        _claimAll(id);
    }

    function _check(uint256 g) internal view {
        assertLt(g, TX_LIMIT, "above Robinhood Chain's 32M transaction limit");
        if (vm.envOr("GAS_STRICT", false)) assertLe(g, target, "above the target");
    }

    function _half(address[] memory holders, uint256 n) internal pure returns (address[] memory h) {
        h = new address[](n);
        for (uint256 i; i < n; ++i) {
            h[i] = holders[i];
        }
    }

    function test_01_Deposits() public {
        (uint256 g,) = _firstBatch();
        _check(g);
    }

    /// @notice 50 entrants and 50 cash leavers, the entrants larger: matched at fair, the rest minted at ask.
    function test_02_MatchPlusEntry() public {
        (, address[] memory holders) = _firstBatch();
        _redeems(_half(holders, 50));
        _deposits(50, 60e6);
        uint64 id = _close();
        uint256 g = _settle(id, "settle: match plus net entry (50 + 50)");
        require(tel.batch(vault, id).matchedShares != 0, "nothing matched");
        _check(g);
    }

    /// @notice 100 cash leavers, paid from the Fund's USDG at bid NAV.
    function test_03_CashExit() public {
        (, address[] memory holders) = _firstBatch();
        _redeems(holders);
        uint64 id = _close();
        uint256 g = _settle(id, "settle: cash exit (100 leavers, paid from cash)");
        require(tel.batch(vault, id).sharesBack == 0, "cash was short");
        _check(g);
    }

    /// @notice 100 cash leavers while the Fund holds almost no USDG: part paid, the rest handed back in shares.
    function test_04_CashExitShort() public {
        (, address[] memory holders) = _firstBatch();
        _redeems(holders);
        uint64 id = _close();
        deal(USDG, vault, 100e6);
        uint256 g = _settle(id, "settle: cash exit with USDG short (100 leavers, the rest back in shares)");
        require(tel.batch(vault, id).sharesBack != 0, "cash was not short");
        _check(g);
    }

    /// @notice 99 cash leavers and one entrant: the hold check and the match run too.
    function test_05_CashExitWithDeposit() public {
        (, address[] memory holders) = _firstBatch();
        _redeems(_half(holders, 99));
        _deposits(1, 10e6);
        uint64 id = _close();
        _check(_settle(id, "settle: cash exit with a deposit (99 leavers + 1 entrant)"));
    }

    /// @notice A Saturday: every stock token's weekend pool read for the worse-of rule, 50 + 50.
    function test_06_WeekendMatch() public {
        (, address[] memory holders) = _firstBatch();
        _redeems(_half(holders, 50));
        _deposits(50, 15e6);
        uint64 id = _close();
        vm.warp(_saturday(block.timestamp));
        (ITeller.Hold hold,) = tel.depositHold(vault);
        require(hold == ITeller.Hold.MarketClosed, "market not closed");
        _check(_settle(id, "settle: Saturday, worse-of prices, 50 + 50"));
    }

    /// @notice A Saturday with the inflow cap at its tightest: all 100 deposits wait for the next cut-off.
    function test_07_WeekendCapDefersAll() public {
        _firstBatch();
        _deposits(100, 15e6);
        uint64 id = _close();
        vm.warp(_saturday(block.timestamp));
        vm.prank(admin);
        tel.setParams(10e6, 1e6, 1e18, 1e14, 0);
        uint256 g = _settle(id, "settle: Saturday, inflow cap 0, 100 deposits wait for the next cut-off");
        require(tel.batch(vault, id).deposits != 0, "deposits went in");
        _check(g);
    }

    /// @notice A no-market holding above dust: nobody is minted, 100 deposits wait for the pocket.
    function test_08_NoMarketDefersAll() public {
        _firstBatch();
        _deposits(100, 15e6);
        uint64 id = _close();
        _downgrade(toks[toks.length - 1].t);
        (ITeller.Hold hold,) = tel.depositHold(vault);
        require(hold == ITeller.Hold.NoMarket, "no hold");
        _check(_settle(id, "settle: a no-market holding, 100 deposits wait for the pocket"));
    }

    /// @notice One holder leaves in kind: every token paid, every adapter split.
    function test_09_InKind() public {
        (, address[] memory holders) = _firstBatch();
        address who = holders[0];
        uint256 sh = IERC20(vault).balanceOf(who);
        Amount[] memory bring = tel.inKindNeeds(vault, sh);
        for (uint256 i; i < bring.length; ++i) {
            if (bring[i].amount == 0) continue;
            _giveFromTest(bring[i].token, who, bring[i].amount);
            vm.prank(who);
            IERC20(bring[i].token).approve(address(tel), bring[i].amount);
        }
        target = IN_KIND_TARGET;
        // For the record: at the caps one transaction cannot take every adapter's slice (that is what
        // `startInKind` and `claimInKind` are for, test_13); smaller Funds leave in one.
        uint256 g = _measureSoft(
            who, address(tel), abi.encodeCall(Teller.redeemInKind, (vault, sh, who)), "redeemInKind (one transaction)"
        );
        console.log("one transaction fits Robinhood Chain's 32M:", g < TX_LIMIT);
    }

    /// @dev `_measure` that logs a revert (an out-of-gas one at 32M included) instead of failing.
    function _measureSoft(address from, address to, bytes memory cd, string memory what) internal returns (uint256) {
        vm.prank(from);
        uint256 g = gasleft();
        (bool ok,) = to.call{gas: TX_LIMIT * 3}(cd);
        g -= gasleft();
        if (!ok) console.log("   reverted");
        return _report(what, g, uint256(int256(vm.lastCallGas().gasRefunded)), cd);
    }

    /// @notice One holder leaves in kind in parts: the shares and vault tokens first, then each adapter's slice in a
    ///         transaction of its own. Each part must fit the in-kind target.
    function test_13_InKindParts() public {
        (, address[] memory holders) = _firstBatch();
        address who = holders[0];
        uint256 sh = IERC20(vault).balanceOf(who);
        Amount[] memory bring = tel.inKindNeedsInParts(vault, sh);
        for (uint256 i; i < bring.length; ++i) {
            if (bring[i].amount == 0) continue;
            _giveFromTest(bring[i].token, who, bring[i].amount);
            vm.prank(who);
            IERC20(bring[i].token).approve(address(tel), bring[i].amount);
        }
        target = IN_KIND_TARGET;
        uint256 id = tel.nextExitId();
        uint256 worst = _measure(
            who,
            address(tel),
            abi.encodeCall(Teller.startInKind, (vault, sh, who, new address[](0))),
            "startInKind (shares burned, vault tokens paid, every adapter's slice set aside)"
        );
        _check(worst);
        for (uint256 i; i < ads.length; ++i) {
            if (tel.exitUnits(id, ads[i]) == 0) continue;
            address[] memory one = new address[](1);
            one[0] = ads[i];
            uint256 g = _measure(
                who,
                address(tel),
                abi.encodeCall(Teller.claimInKind, (id, one)),
                string.concat("claimInKind: ", IAdapterName(ads[i]).name())
            );
            _check(g);
            if (g > worst) worst = g;
        }
        console.log("in parts, the heaviest part:", worst);
    }

    /// @notice A deposit request: no longer reads the Fund.
    function test_10_RequestDeposit() public {
        _firstBatch();
        address u = _user();
        deal(USDG, u, 20e6);
        vm.prank(u);
        IERC20(USDG).approve(address(tel), 20e6);
        _check(
            _measure(
                u,
                address(tel),
                abi.encodeWithSignature("requestDeposit(address,uint256,uint256)", vault, 10e6, 1),
                "requestDeposit"
            )
        );
        _check(
            _measure(
                u,
                address(tel),
                abi.encodeWithSignature(
                    "requestDeposit(address,uint256,uint256,address,bytes32)",
                    vault,
                    10e6,
                    1,
                    address(0xBEEF),
                    bytes32("partner")
                ),
                "requestDeposit for a receiver, referred"
            )
        );
    }

    /// @notice A pocket for a no-market token the vault holds (no adapter holds it).
    function test_11_PocketVault() public {
        _firstBatch();
        address t = toks[toks.length - 1].t; // LMT: no liquidity position uses it
        _downgrade(t);
        _check(
            _measure(
                keeper,
                address(tel),
                abi.encodeWithSignature("pocket(address,address,address[],uint256)", vault, t, new address[](0), 0),
                "pocket (vault balance only)"
            )
        );
    }

    /// @notice A pocket for a no-market token liquidity adapters hold too: the vault's balance and the first
    ///         adapter (unwound whole) in one transaction, then one more adapter per transaction into the same pocket.
    function test_12_PocketWithUnwind() public {
        _firstBatch();
        address t = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // NVDA: in liquidity positions
        address[] memory holding = _holdersOf(t);
        _downgrade(t);
        target = IN_KIND_TARGET;
        uint256 id;
        uint256 worst;
        for (uint256 i; i < holding.length; ++i) {
            address[] memory one = new address[](1);
            one[0] = holding[i];
            uint256 g = _measure(
                keeper,
                address(tel),
                abi.encodeWithSignature("pocket(address,address,address[],uint256)", vault, t, one, id),
                string.concat("pocket, unwinding ", IAdapterName(holding[i]).name())
            );
            _check(g);
            if (g > worst) worst = g;
            if (id == 0) id = FundVaultCaps(vault).currentSnapshotId();
        }
        console.log("pocket in parts, the heaviest part:", worst);
    }

    /// @dev The adapters whose positions hold `t`.
    function _holdersOf(address t) internal view returns (address[] memory h) {
        h = new address[](ads.length);
        uint256 n;
        for (uint256 i; i < ads.length; ++i) {
            (Amount[] memory a,) = IAdapter(ads[i]).positions(router);
            for (uint256 j; j < a.length; ++j) {
                if (a[j].token == t && a[j].amount != 0) {
                    h[n++] = ads[i];
                    break;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(h, n)
        }
        console.log("adapters holding it:", n);
    }

    /// @dev The router's owner downgrades `t` to no market (instant).
    function _downgrade(address t) internal {
        vm.prank(router.owner());
        router.propose(
            t,
            PriceRouter.Config({
                primary: IPriceSource(address(0)),
                check: IPriceSource(address(0)),
                class_: PriceClass.None,
                haircutBps: 0,
                maxDeviationBps: 0,
                decimals: 0,
                chained: 0
            })
        );
    }

    function _giveFromTest(address t, address to, uint256 amt) internal {
        if (t == USDG) deal(USDG, to, IERC20(USDG).balanceOf(to) + amt);
        else _give(t, to, amt);
    }

    function _saturday(uint256 t) internal pure returns (uint256) {
        uint256 day = t / 1 days + 1;
        while ((day + 4) % 7 != 6) day += 1;
        return day * 1 days + 15 hours;
    }
}

interface MorphoMarketRegistryLike {
    function propose(bytes32 id) external;
    function applyPending(bytes32 id) external;
}

interface FundVaultCaps {
    function currentSnapshotId() external view returns (uint64);
    function MAX_TRACKED() external view returns (uint256);
}

interface AdapterCaps {
    function MAX_POSITIONS() external view returns (uint256);
    function MAX_RANGES() external view returns (uint256);
    function MAX_MARKETS() external view returns (uint256);
}

interface IAdapterName {
    function name() external view returns (string memory);
}
