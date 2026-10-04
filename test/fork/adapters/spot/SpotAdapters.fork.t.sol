// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AdapterRegistry} from "../../../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../../../src/core/FundFactory.sol";
import {FundVault} from "../../../../src/core/FundVault.sol";
import {FundController} from "../../../../src/core/FundController.sol";
import {SeedTeller} from "../../../../src/core/SeedTeller.sol";
import {Dial} from "../../../../src/interfaces/IFundController.sol";
import {DialPresets} from "../../../../src/core/DialPresets.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {GrowCheck} from "../GrowCheck.sol";
import {IPriceRouter, PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../../src/interfaces/IPriceSource.sol";
import {IPermit2} from "../../../../src/interfaces/external/permit2/IPermit2.sol";
import {IFolio} from "../../../../src/interfaces/external/folio/IFolio.sol";
import {AggregatorSwapAdapter} from "../../../../src/adapters/swap/AggregatorSwapAdapter.sol";
import {ERC4626Adapter} from "../../../../src/adapters/yield/ERC4626Adapter.sol";
import {AindexIndexAdapter} from "../../../../src/adapters/index/AindexIndexAdapter.sol";
import {IndexNavSource} from "../../../../src/adapters/index/IndexNavSource.sol";
import {MockPriceSource} from "../../../utils/Mocks.sol";

/**
 * @notice The three spot adapters against Robinhood Chain (4663) at the latest block. Skipped when
 *         ROBINHOOD_RPC is unset. Prices come from a hand-set source: these tests check that real protocols
 *         move real tokens the way the adapters expect, not the price feeds.
 *
 *         The KyberSwap test needs a route fetched beforehand (forge tests do not call out):
 *           eval "$(node test/fork/adapters/spot/kyber-route.mjs <swap adapter clone>)"
 *         `test_PrintSwapAdapter` prints the clone address; it is the same on every run.
 */
contract SpotAdaptersForkTest is Test, GrowCheck {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant KYBER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant PARASWAP = 0x6A000F20005980200259B80c5102003040001068;
    address constant LIFI = 0xB477751B76CF82d00a686A1232f5fCD772414Af3;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address constant SP_USDG = 0xde770c84FE66E063336b31737cFE9790f18c4087;
    address constant AIXSTR = 0xe7c9209D3C35d7cf1895e46a2d62b9A30841bB98;
    address constant INDEX_ZAP = 0x5F807BB130739F8d9A96d7d4383A1318E0669bFF;

    address guardian = makeAddr("guardian");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");

    bool forked;
    AdapterRegistry registry;
    PriceRouter router;
    MockPriceSource source;
    FundFactory factory;
    SeedTeller teller;
    FundVault vault;
    FundController controller;
    AggregatorSwapAdapter swap;
    ERC4626Adapter yield_;
    AindexIndexAdapter index;
    IndexNavSource indexNav;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        uint256 t0 = block.timestamp;

        // Deployment order is fixed so the swap clone lands at the same address every run.
        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        factory = new FundFactory(registry, router, guardian, USDG);
        teller = new SeedTeller();
        _price(USDG, 1e18);
        _price(NVDA, 180e18);
        _price(WETH, 4000e18);
        // Router changes wait a day; step back so protocols and the KyberSwap deadline see the real time.
        vm.warp(t0);

        (vault, controller) = factory.create("Fork Fund", "FF", owner, address(teller), _openDial());
        deal(USDG, owner, 1000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), 1000e6);
        teller.seed(vault, USDG, 1000e6, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        AggregatorSwapAdapter swapImpl = new AggregatorSwapAdapter(IPermit2(PERMIT2));
        registry.register(address(swapImpl), "");
        AggregatorSwapAdapter.Target[] memory t = new AggregatorSwapAdapter.Target[](5);
        t[0] = AggregatorSwapAdapter.Target(KYBER, AggregatorSwapAdapter.Approval.Direct);
        t[1] = AggregatorSwapAdapter.Target(ZEROX_ALLOWANCE_HOLDER, AggregatorSwapAdapter.Approval.Direct);
        t[2] = AggregatorSwapAdapter.Target(PARASWAP, AggregatorSwapAdapter.Approval.Direct);
        t[3] = AggregatorSwapAdapter.Target(LIFI, AggregatorSwapAdapter.Approval.Direct);
        t[4] = AggregatorSwapAdapter.Target(UNIVERSAL_ROUTER, AggregatorSwapAdapter.Approval.Permit2);
        vm.prank(owner);
        swap = AggregatorSwapAdapter(controller.addAdapter(address(swapImpl), abi.encode(t)));

        ERC4626Adapter yieldImpl = new ERC4626Adapter();
        registry.register(address(yieldImpl), "");
        address[] memory vaults = new address[](2);
        vaults[0] = STEAK_USDG;
        vaults[1] = SP_USDG;
        vm.prank(owner);
        yield_ = ERC4626Adapter(controller.addAdapter(address(yieldImpl), abi.encode(vaults)));

        AindexIndexAdapter indexImpl = new AindexIndexAdapter();
        registry.register(address(indexImpl), "");
        vm.prank(owner);
        index = AindexIndexAdapter(payable(controller.addAdapter(address(indexImpl), abi.encode(INDEX_ZAP, new address[](0)))));
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ---------------------------------------------------------------- swap

    function test_PrintSwapAdapter() public onFork {
        console.log("swap adapter clone (use as KyberSwap sender and recipient):", address(swap));
    }

    function test_KyberSwapUsdgToNvda() public onFork {
        address sender = vm.envOr("KYBER_SENDER", address(0));
        if (sender != address(swap)) {
            console.log(
                "KYBER_* not set for this clone; run: eval \"$(node test/fork/adapters/spot/kyber-route.mjs",
                address(swap),
                ')"'
            );
            vm.skip(true);
            return;
        }
        address target = vm.envAddress("KYBER_TARGET");
        uint256 amountIn = vm.envUint("KYBER_AMOUNT_IN");
        uint256 minOut = vm.envUint("KYBER_MIN_OUT");
        bytes memory data = vm.envBytes("KYBER_DATA");
        assertEq(target, KYBER, "route is not for the allowed KyberSwap router");

        uint256 usdgBefore = IERC20(USDG).balanceOf(address(vault));
        vm.prank(manager);
        bytes memory r = controller.act(address(swap), abi.encode(uint8(0), USDG, amountIn, NVDA, minOut, target, data));
        (uint256 received, uint256 spent) = abi.decode(r, (uint256, uint256));
        console.log("NVDA received", received, "USDG spent", spent);
        assertGe(received, minOut);
        assertEq(IERC20(NVDA).balanceOf(address(vault)), received);
        assertEq(IERC20(USDG).balanceOf(address(vault)), usdgBefore - spent);
        assertEq(IERC20(NVDA).balanceOf(address(swap)), 0);
        assertEq(IERC20(USDG).balanceOf(address(swap)), 0);
        assertEq(IERC20(USDG).allowance(address(swap), KYBER), 0);
    }

    // ---------------------------------------------------------------- ERC-4626

    function test_SteakUsdgDepositAndBack() public onFork {
        _roundTrip(STEAK_USDG);
    }

    function test_SparkUsdgDepositAndBack() public onFork {
        _roundTrip(SP_USDG);
    }

    function _roundTrip(address v) internal {
        vm.prank(manager);
        controller.act(address(yield_), abi.encode(uint8(0), v, uint256(100e6), uint256(1)));
        uint256 shares = IERC20(v).balanceOf(address(yield_));
        assertGt(shares, 0, "no shares");
        (Amount[] memory held,) = yield_.positions(IPriceRouter(address(router)));
        uint256 counted = held[v == STEAK_USDG ? 0 : 1].amount;
        assertApproxEqAbs(counted, 100e6, 2, "position is not the deposit");
        (uint256 fair,) = controller.nav(uint8(Side.Fair));
        assertApproxEqAbs(fair, 1000e18, 2e12, "NAV moved on deposit");

        vm.prank(manager);
        controller.act(address(yield_), abi.encode(uint8(2), v, type(uint256).max, uint256(99.99e6)));
        assertEq(IERC20(v).balanceOf(address(yield_)), 0);
        assertApproxEqAbs(IERC20(USDG).balanceOf(address(vault)), 1000e6, 2, "did not come back");
    }

    /// Deposits into the existing mix: both live USDG vaults mint 10%, then 100%, more shares.
    function test_YieldVaultsGrowByFraction() public onFork {
        vm.startPrank(manager);
        controller.act(address(yield_), abi.encode(uint8(0), STEAK_USDG, uint256(300e6), uint256(1)));
        controller.act(address(yield_), abi.encode(uint8(0), SP_USDG, uint256(200e6), uint256(1)));
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours); // let the vaults' share prices move off round numbers
        IPriceRouter r = IPriceRouter(address(router));
        _growChecked(IAdapter(address(yield_)), address(vault), address(controller), r, 0.1e18, 0);
        _growChecked(IAdapter(address(yield_)), address(vault), address(controller), r, 1e18, 0);
    }

    /// Swap and index adapters hold no positions: nothing to grow, nothing pulled.
    function test_FlatAdaptersGrowNothing() public onFork {
        assertEq(swap.growInputs(1e18).length, 0);
        assertEq(index.growInputs(1e18).length, 0);
        vm.startPrank(address(controller));
        assertEq(swap.grow(1e18).length, 0);
        assertEq(index.grow(1e18).length, 0);
        vm.stopPrank();
    }

    function test_SteakUsdgSplitInKind() public onFork {
        vm.prank(manager);
        controller.act(address(yield_), abi.encode(uint8(0), STEAK_USDG, uint256(100e6), uint256(1)));
        uint256 shares = IERC20(STEAK_USDG).balanceOf(address(yield_));
        address leaver = makeAddr("leaver");
        uint256 unit = IERC4626Like(STEAK_USDG).previewWithdraw(1);
        vm.prank(address(controller));
        Amount[] memory sent = yield_.split(0.5e18, leaver);
        // Either the shares themselves (half, less the shares one raw unit of USDG is worth: the slice rounds
        // against the leaver) or, for a gated vault, their USDG.
        assertTrue(
            IERC20(STEAK_USDG).balanceOf(leaver) == shares / 2 - unit || IERC20(USDG).balanceOf(leaver) == sent[0].amount
        );
    }

    // ---------------------------------------------------------------- AINDEX index

    function test_AixstrRedeemAndMintAtBacking() public onFork {
        uint256 t0 = block.timestamp;
        indexNav = new IndexNavSource(IPriceRouter(address(router)));
        (address[] memory basket,) = IFolio(AIXSTR).totalAssets();
        for (uint256 i; i < basket.length; ++i) {
            if (source.prices(basket[i]) == 0) _price(basket[i], 1e18 * (i + 1));
        }
        _priceWith(AIXSTR, indexNav);
        vm.warp(t0);
        (uint256 p,, bool ok) = indexNav.price(AIXSTR);
        assertTrue(ok, "look-through price unavailable");
        console.log("AIXSTR look-through at test prices", p);

        // The Fund holds one AIXSTR share (dealt: there is no faucet for a live index).
        vm.prank(address(controller));
        vault.track(AIXSTR);
        deal(AIXSTR, address(vault), 1e18);
        (uint256 navStart,) = controller.nav(uint8(Side.Fair));

        vm.prank(manager);
        controller.act(address(index), abi.encode(uint8(1), AIXSTR, uint256(0.5e18), new uint256[](0)));
        assertEq(IERC20(AIXSTR).balanceOf(address(vault)), 0.5e18);
        for (uint256 i; i < basket.length; ++i) {
            assertEq(IERC20(basket[i]).balanceOf(address(index)), 0, "loose basket token");
        }
        (uint256 navRedeemed,) = controller.nav(uint8(Side.Fair));
        assertApproxEqRel(navRedeemed, navStart, 1e12, "redeem at backing moved NAV");

        // Mint back a little less than was redeemed, from the basket the vault now holds.
        uint256 fee = IFolioFee(AIXSTR).mintFee();
        uint256 shares = 0.4e18;
        uint256 minOut = shares - shares * fee / 1e18 - 1;
        vm.prank(manager);
        bytes memory r = controller.act(address(index), abi.encode(uint8(0), AIXSTR, shares, minOut));
        uint256 got = abi.decode(r, (uint256));
        assertGe(got, minOut);
        assertEq(IERC20(AIXSTR).balanceOf(address(vault)), 0.5e18 + got);
        (uint256 navMinted,) = controller.nav(uint8(Side.Fair));
        // Minting costs exactly the mint fee on the minted shares.
        assertApproxEqRel(navStart - navMinted, (shares - got) * p / 1e18, 0.01e18);
    }

    // ---------------------------------------------------------------- helpers

    function _openDial() internal pure returns (Dial memory d) {
        d = DialPresets.open();
        d.allowBorrow = false;
    }

    function _price(address token, uint256 usdWad) internal {
        source.set(token, usdWad);
        _priceWith(token, IPriceSource(address(source)));
    }

    function _priceWith(address token, IPriceSource s) internal {
        PriceRouter.Config memory c = PriceRouter.Config({
            primary: s,
            check: IPriceSource(address(0)),
            class_: PriceClass.Feed,
            haircutBps: 0,
            maxDeviationBps: 0,
            decimals: 0,
            chained: 0
        });
        router.propose(token, c);
        if (router.pendingAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(token);
        }
    }
}

interface IFolioFee {
    function mintFee() external view returns (uint256);
}

interface IERC4626Like {
    function previewWithdraw(uint256 assets) external view returns (uint256);
}
