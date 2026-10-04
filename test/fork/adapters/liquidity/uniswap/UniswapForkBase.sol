// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {AdapterRegistry} from "../../../../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../../../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../../../../src/core/FundFactory.sol";
import {FundVault} from "../../../../../src/core/FundVault.sol";
import {FundController} from "../../../../../src/core/FundController.sol";
import {SeedTeller} from "../../../../../src/core/SeedTeller.sol";
import {Dial} from "../../../../../src/interfaces/IFundController.sol";
import {DialPresets} from "../../../../../src/core/DialPresets.sol";
import {PriceClass, Side} from "../../../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../../../src/interfaces/IPriceSource.sol";
import {IAdapter, Amount} from "../../../../../src/interfaces/IAdapter.sol";
import {IWETH9} from "../../../../../src/interfaces/external/uniswap/IWETH9.sol";
import {MockPriceSource} from "../../../../utils/Mocks.sol";

/**
 * @notice A Fund on a fork of Robinhood Chain (4663), with the real USDG and WETH. Skips when ROBINHOOD_RPC is
 *         unset. Forks at the latest block. Nothing is broadcast: everything happens in the local fork.
 *
 *         The router's WETH price is set from the pool's own price at the fork, as an oracle would read it;
 *         the tests then move the pool and show the Fund's value does not follow.
 */
abstract contract UniswapForkBase is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant V3_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    /// USDG/WETH 0.05% (token0 WETH, tick spacing 10)
    address internal constant V3_USDG_WETH_500 = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a;
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant PONS_V2_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    address internal guardian = makeAddr("guardian");
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");

    AdapterRegistry internal registry;
    PriceRouter internal router;
    FundFactory internal factory;
    SeedTeller internal teller;
    MockPriceSource internal source;
    FundVault internal vault;
    FundController internal controller;

    /// @dev Fork, or skip every test in the contract when there is no RPC.
    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ROBINHOOD_RPC not set");
            return false;
        }
        vm.createSelectFork(rpc);
        return true;
    }

    /// @dev Core contracts, prices, and a Fund holding `usdgSeed` USDG and `wethSeed` WETH.
    function _setUpFund(uint256 wethUsd, uint256 usdgSeed, uint256 wethSeed) internal {
        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        factory = new FundFactory(registry, router, guardian, USDG);
        teller = new SeedTeller();
        _price(USDG, 1e18);
        _price(WETH, wethUsd);

        Dial memory d = DialPresets.open();
        (vault, controller) = factory.create("Fork Fund", "FF", owner, address(teller), d);
        deal(USDG, owner, usdgSeed);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), usdgSeed);
        teller.seed(vault, USDG, usdgSeed, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        // Real WETH, wrapped from ether, so unwrapping it pays out.
        vm.deal(address(this), wethSeed);
        IWETH9(WETH).deposit{value: wethSeed}();
        IERC20(WETH).transfer(address(vault), wethSeed);
        vm.prank(address(controller));
        vault.track(WETH);
    }

    function _price(address token, uint256 usdWad) internal {
        source.set(token, usdWad);
        router.propose(
            token,
            PriceRouter.Config({
                primary: IPriceSource(address(source)),
                check: IPriceSource(address(0)),
                class_: PriceClass.Feed,
                haircutBps: 0,
                maxDeviationBps: 0,
                decimals: 0,
                chained: 0
            })
        );
        if (router.pendingAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applyPending(token);
        }
    }

    /// @dev WETH's USD price (1e18) at a WETH/USDG sqrt price with WETH as token0.
    function _wethUsd(uint160 sqrtP) internal pure returns (uint256) {
        // USDG raw per WETH raw = sqrtP^2 / 2^192; times 1e12 for whole tokens, times 1e18 for the wad.
        return FullMath.mulDiv(uint256(sqrtP) * uint256(sqrtP), 1e30, 1 << 192);
    }

    function _enable(address implementation, bytes memory config) internal returns (address instance) {
        registry.register(implementation, "");
        vm.prank(owner);
        instance = controller.addAdapter(implementation, config);
    }

    function _act(address adapter, bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(adapter, action);
    }

    function _nav() internal view returns (uint256 n) {
        bool complete;
        (n, complete) = controller.nav(uint8(Side.Fair));
        require(complete, "book incomplete");
    }

    function _positionUsd(IAdapter adapter) internal view returns (uint256 usd) {
        (Amount[] memory a,) = adapter.positions(router);
        for (uint256 i; i < a.length; ++i) {
            (uint256 v,,) = router.value(a[i].token, a[i].amount, Side.Fair);
            usd += v;
        }
    }

    function _held(IAdapter adapter, address token) internal view returns (uint256) {
        (Amount[] memory a,) = adapter.positions(router);
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token == token) return a[i].amount;
        }
        return 0;
    }

    /// @dev A range of +-`half` ticks around `tick`, on `spacing`.
    function _range(int24 tick, int24 spacing, int24 half) internal pure returns (int24 lo, int24 hi) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        lo = c * spacing - (half / spacing) * spacing;
        hi = c * spacing + (half / spacing + 1) * spacing;
    }
}
