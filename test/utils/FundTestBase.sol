// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AdapterRegistry} from "../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../src/core/FundFactory.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {FundController} from "../../src/core/FundController.sol";
import {SeedTeller} from "../../src/core/SeedTeller.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {DialPresets} from "../../src/core/DialPresets.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {MockERC20, MockPriceSource} from "./Mocks.sol";

/// @notice Shared setup: a registry, a router with a mock source, a factory, a seed teller and one Fund.
abstract contract FundTestBase is Test {
    address internal guardian = makeAddr("guardian");
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");

    AdapterRegistry internal registry;
    PriceRouter internal router;
    FundFactory internal factory;
    SeedTeller internal teller;
    MockPriceSource internal source;
    MockERC20 internal usdg;

    FundVault internal vault;
    FundController internal controller;

    /// @dev No limits, unreviewed adapters allowed (test mocks are unverified): the factory default.
    function _openDial() internal pure returns (Dial memory d) {
        d = DialPresets.open();
    }

    function _setUpCore() internal {
        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        factory = new FundFactory(registry, router, guardian, address(usdg));
        teller = new SeedTeller();
        _price(address(usdg), 1e18, PriceClass.Feed, 0);
    }

    /// @dev Configure a token's price now (warping past the router's delay when needed).
    function _price(address token, uint256 usdWad, PriceClass class_, uint16 haircutBps) internal {
        source.set(token, usdWad);
        PriceRouter.Config memory c = PriceRouter.Config({
            primary: IPriceSource(address(source)),
            check: IPriceSource(address(0)),
            class_: class_,
            haircutBps: haircutBps,
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

    function _createFund(Dial memory dial, uint256 seedUsdg) internal {
        (vault, controller) = factory.create("Test Fund", "TF", owner, address(teller), dial);
        usdg.mint(owner, seedUsdg);
        vm.startPrank(owner);
        usdg.approve(address(teller), seedUsdg);
        teller.seed(vault, address(usdg), seedUsdg, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 365 days));
        vm.stopPrank();
    }

    function _enable(address implementation, bytes memory config) internal returns (address instance) {
        vm.prank(owner);
        instance = controller.addAdapter(implementation, config);
    }
}
