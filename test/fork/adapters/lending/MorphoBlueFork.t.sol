// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../../../utils/FundTestBase.sol";
import {MockERC20, MockPriceSource} from "../../../utils/Mocks.sol";
import {AdapterRegistry} from "../../../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../../../src/core/FundFactory.sol";
import {SeedTeller} from "../../../../src/core/SeedTeller.sol";
import {FundController} from "../../../../src/core/FundController.sol";
import {Dial} from "../../../../src/interfaces/IFundController.sol";
import {PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {GrowCheck} from "../GrowCheck.sol";
import {IMorpho, MarketParams} from "../../../../src/interfaces/external/morpho/IMorpho.sol";
import {MorphoBlueAdapter} from "../../../../src/adapters/lending/MorphoBlueAdapter.sol";
import {MorphoMarketRegistry} from "../../../../src/adapters/lending/MorphoMarketRegistry.sol";

interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/**
 * @notice Morpho Blue on Robinhood Chain, through a real Fund. Runs only when ROBINHOOD_RPC is set; forks at
 *         the latest block. Prices come from a mock source set to the live Chainlink answers, so the
 *         controller's health check sees today's NVDA price.
 */
contract MorphoBlueForkTest is FundTestBase, GrowCheck {
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant FEED_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    /// USDG lent against NVDA at 62.5% LLTV, little borrowed (liquid).
    bytes32 constant LIQUID = 0x66306c087add8907752320b309934abcc354d21626de8115c79df49d9c214edc;
    /// The same pair with another oracle, close to 100% utilised.
    bytes32 constant TIGHT = 0x8b16891f032a93b771347c9cb470a780e6699dd701553d3402aa3cdba6189c3e;

    uint8 constant SUPPLY = 0;
    uint8 constant WITHDRAW = 1;
    uint8 constant SUPPLY_COLLATERAL = 2;
    uint8 constant WITHDRAW_COLLATERAL = 3;
    uint8 constant BORROW = 4;
    uint8 constant REPAY_SHARES = 6;
    uint256 constant ALL = type(uint256).max;

    MorphoBlueAdapter mb;
    MarketParams liquid;
    MarketParams tight;
    uint256 nvdaUsd;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        uint256 t0 = block.timestamp;

        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        usdg = MockERC20(USDG); // typed for the shared helpers; only ERC-20 calls are used
        factory = new FundFactory(registry, router, guardian, USDG);
        teller = new SeedTeller();
        _price(USDG, _feed(FEED_USDG), PriceClass.Feed, 0);
        nvdaUsd = _feed(FEED_NVDA);
        _price(NVDA, nvdaUsd, PriceClass.Feed, 0);

        liquid = _params(LIQUID);
        tight = _params(TIGHT);
        // `_price` jumps past the router's config delay; come back to the fork's real time, or Morpho's
        // oracles (which refuse quotes older than 25 hours) would see stale prices.
        vm.warp(t0);
    }

    function _feed(address feed) internal view returns (uint256) {
        (, int256 answer,,,) = IChainlinkFeed(feed).latestRoundData();
        return uint256(answer) * 1e10; // 8 decimals to 18
    }

    function _params(bytes32 id) internal view returns (MarketParams memory p) {
        (p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv) = MORPHO.idToMarketParams(id);
        assertEq(keccak256(abi.encode(p)), id, "market id is not keccak of its params");
    }

    function _fund(Dial memory dial) internal {
        (vault, controller) = factory.create("Fork Fund", "FF", owner, address(teller), dial);
        deal(USDG, owner, 50_000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), 50_000e6);
        teller.seed(vault, USDG, 50_000e6, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 365 days));
        vm.stopPrank();
        deal(NVDA, address(vault), 20e18);
        vm.prank(address(controller));
        vault.track(NVDA);
        MorphoBlueAdapter impl = new MorphoBlueAdapter(MORPHO);
        registry.register(address(impl), "");
        // The two live NVDA/USDG markets, as AINDEX would seed them (by id: all five parameters).
        bytes32[] memory seed = new bytes32[](2);
        seed[0] = keccak256(abi.encode(liquid));
        seed[1] = keccak256(abi.encode(tight));
        MorphoMarketRegistry markets = new MorphoMarketRegistry(guardian, MORPHO, seed);
        mb = MorphoBlueAdapter(_enable(address(impl), abi.encode(address(markets), new bytes32[](0))));
    }

    function _do(MarketParams memory p, uint8 id, uint256 amount) internal {
        vm.prank(manager);
        controller.act(address(mb), abi.encode(id, p, amount));
    }

    function _dial(bool allowBorrow, uint32 minHealthBps) internal pure returns (Dial memory d) {
        d = _openDial();
        d.allowBorrow = allowBorrow;
        d.minHealthBps = minHealthBps;
    }

    function testFork_SupplyBorrowRepayWithdraw() public {
        _fund(_dial(true, 15_000));
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 20e18, "deal NVDA");

        // Lend 1,000 USDG.
        _do(liquid, SUPPLY, 1_000e6);
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        assertEq(a.length, 1);
        assertApproxEqAbs(a[0].amount, 1_000e6, 1);

        // Post 20 NVDA and borrow 40% of its value at the market's own oracle.
        _do(liquid, SUPPLY_COLLATERAL, 20e18);
        uint256 collateralUsdg = 20e18 * nvdaUsd / 1e18 / 1e12;
        uint256 loan = collateralUsdg * 40 / 100;
        _do(liquid, BORROW, loan);
        (a, d) = mb.positions(router);
        assertEq(d.length, 1);
        assertEq(d[0].token, USDG);
        assertGe(d[0].amount, loan);

        MorphoBlueAdapter.MarketHealth memory h = mb.marketHealth(liquid);
        assertApproxEqRel(h.ltv, 0.4e18, 0.02e18, "LTV at the Morpho oracle");
        assertGt(h.liquidationPrice, 0);
        assertLt(h.liquidationPrice, h.oraclePrice);

        // Over the market's LLTV, Morpho refuses.
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(mb), abi.encode(BORROW, liquid, collateralUsdg * 25 / 100));

        // A day of interest: the view equals what Morpho writes when it accrues.
        vm.warp(block.timestamp + 1 days);
        uint256 g = gasleft();
        (Amount[] memory a1, Amount[] memory d1) = mb.positions(router);
        emit log_named_uint("positions gas, 1 market, real rate model", g - gasleft());
        MORPHO.accrueInterest(liquid);
        (Amount[] memory a2, Amount[] memory d2) = mb.positions(router);
        assertEq(d1[0].amount, d2[0].amount, "debt view vs accrual");
        assertEq(a1[0].amount, a2[0].amount, "supply view vs accrual");
        assertGt(d2[0].amount, loan, "no interest after a day");

        // Repay everything, take collateral and supply back.
        _do(liquid, REPAY_SHARES, ALL);
        _do(liquid, WITHDRAW_COLLATERAL, ALL);
        _do(liquid, WITHDRAW, ALL);
        (a, d) = mb.positions(router);
        assertEq(a.length + d.length, 0, "position left");
        assertEq(mb.markets().length, 0);
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 20e18);
        assertApproxEqAbs(IERC20(USDG).balanceOf(address(vault)), 50_000e6, 5e6, "lost more than interest");
        assertEq(IERC20(USDG).balanceOf(address(mb)), 0);
        assertEq(IERC20(NVDA).balanceOf(address(mb)), 0);
    }

    function testFork_DialBlocksBorrowing() public {
        _fund(_dial(false, 10_000));
        _do(liquid, SUPPLY_COLLATERAL, 10e18);
        vm.prank(manager);
        vm.expectRevert(FundController.BorrowNotAllowed.selector);
        controller.act(address(mb), abi.encode(BORROW, liquid, uint256(100e6)));
    }

    function testFork_DialMinHealth() public {
        // Fund: 50k USDG + 20 NVDA. Require assets to be 100x debts.
        _fund(_dial(true, 1_000_000));
        _do(liquid, SUPPLY_COLLATERAL, 20e18);
        _do(liquid, BORROW, 100e6); // tiny: health far above 100x
        vm.prank(manager);
        vm.expectRevert(); // FundController.Unhealthy: borrowing 1,000 more takes health under 100x
        controller.act(address(mb), abi.encode(BORROW, liquid, uint256(1_000e6)));
        (, Amount[] memory d) = mb.positions(router);
        assertApproxEqAbs(d[0].amount, 100e6, 1);
    }

    /// The utilisation caveat on a real, nearly fully borrowed market: once someone borrows the liquidity
    /// our supply added, a full unwind returns only what is free and keeps reporting the rest.
    function testFork_UnwindPartialInTightMarket() public {
        _fund(_dial(true, 10_000));
        _do(tight, SUPPLY, 10_000e6);

        // Someone else borrows all but 1,000 USDG of the market's free liquidity.
        address other = makeAddr("other");
        MorphoBlueAdapter.MarketHealth memory h = mb.marketHealth(tight);
        deal(NVDA, other, 1_000e18);
        vm.startPrank(other);
        IERC20(NVDA).approve(address(MORPHO), 1_000e18);
        MORPHO.supplyCollateral(tight, 1_000e18, other, "");
        MORPHO.borrow(tight, h.liquidity - 1_000e6, 0, other, other);
        vm.stopPrank();

        vm.prank(address(controller));
        Amount[] memory got = mb.unwind(1e18);
        assertEq(got.length, 1);
        assertApproxEqAbs(got[0].amount, 1_000e6, 2);
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 1, "unpaid supply must still be reported");
        assertApproxEqAbs(a[0].amount, 9_000e6, 3);
    }

    /// Deposits into the existing mix on the live market: supply, collateral and debt each grow by 10% and
    /// then by 100%, and the market's LTV at Morpho's own oracle stays where it was.
    function testFork_GrowSupplyCollateralAndDebt() public {
        _fund(_dial(true, 15_000));
        _do(liquid, SUPPLY, 1_000e6);
        _do(liquid, SUPPLY_COLLATERAL, 10e18);
        _do(liquid, BORROW, 10e18 * nvdaUsd / 1e18 / 1e12 * 30 / 100);
        vm.warp(block.timestamp + 1 hours);
        MorphoBlueAdapter.MarketHealth memory h0 = mb.marketHealth(liquid);
        uint256 usdgBefore = IERC20(USDG).balanceOf(address(vault));
        _growChecked(IAdapter(address(mb)), address(vault), address(controller), router, 0.1e18, 0);
        _growChecked(IAdapter(address(mb)), address(vault), address(controller), router, 1e18, 0);
        MorphoBlueAdapter.MarketHealth memory h1 = mb.marketHealth(liquid);
        assertApproxEqRel(h1.ltv, h0.ltv, 1e10, "LTV moved");
        assertGe(h1.collateral * 10, h0.collateral * 22);
        assertGt(IERC20(USDG).balanceOf(address(vault)), usdgBefore, "borrowed USDG did not reach the vault");
    }
}
