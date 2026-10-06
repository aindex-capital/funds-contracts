// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AdapterRegistry} from "../../../../src/registry/AdapterRegistry.sol";
import {PriceRouter} from "../../../../src/pricing/PriceRouter.sol";
import {FundFactory} from "../../../../src/core/FundFactory.sol";
import {FundVault} from "../../../../src/core/FundVault.sol";
import {FundController} from "../../../../src/core/FundController.sol";
import {SeedTeller} from "../../../../src/core/SeedTeller.sol";
import {DialPresets} from "../../../../src/core/DialPresets.sol";
import {IPriceRouter, PriceClass, Side} from "../../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../../src/interfaces/IPriceSource.sol";
import {IAdapter, Amount} from "../../../../src/interfaces/IAdapter.sol";
import {IUniswapV3Factory} from "../../../../src/interfaces/external/uniswap/IUniswapV3.sol";
import {IBeefyClmVault, IBeefyClmStrategy} from "../../../../src/interfaces/external/beefy/IBeefyClm.sol";
import {ClmVaultAdapter} from "../../../../src/adapters/liquidity/clm/ClmVaultAdapter.sol";
import {GrowCheck} from "../GrowCheck.sol";
import {MockPriceSource} from "../../../utils/Mocks.sol";

interface IArrowVaultFactory {
    function cloneVault() external returns (address);
}

/**
 * @notice ClmVaultAdapter against Beefy's and Arrowfarm's CLM vaults on Robinhood Chain (4663) at the latest block.
 *         Skips when ROBINHOOD_RPC is unset; nothing is broadcast. The Fund's router uses each token's fair price as
 *         the live AINDEX PriceRouter quotes it at the fork, so the valuation is checked against real prices.
 */
contract ClmVaultAdapterForkTest is Test, GrowCheck {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant LIVE_ROUTER = 0x7ca511aeA087381C8a1981A4F9850aE154e624BB;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    // Beefy: strategy factory, strategy owner, vault owner (read on chain 2026-10-05)
    address constant BEEFY_FACTORY = 0xD4E968d673bc2C4Ba5abcB773de6f07e65E94E44;
    address constant BEEFY_STRAT_OWNER = 0x14E05B7161f57F4F0e3428CC49B4d477EcBf6D51;
    address constant BEEFY_VAULT_OWNER = 0x03193Ef8c3f75C22fAf2995540602399cdcD4cbc;
    // Arrowfarm
    address constant ARROW_FACTORY = 0xd626504db63FBe10Ea98a99f52717c5315e9eD46;
    address constant ARROW_OWNER = 0xfa1A467D00d6763d3441f18A4abC6A0E1fb10ff2;
    address constant ARROW_VAULT_FACTORY = 0x086d837E84A59aB0E91861A773c8130ce4265440;

    address constant BEEFY_GLD = 0x2e35f0951cFfaF89eb9ADdE94C60475E3745Cc15;
    address constant ARROW_NVDA = 0x00413A44d521EF466217b573E5A060fd3D20A30f;

    address guardian = makeAddr("guardian");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");

    AdapterRegistry registry;
    PriceRouter router;
    MockPriceSource source;
    FundFactory factory;
    SeedTeller teller;
    FundVault vault;
    FundController controller;
    ClmVaultAdapter impl;
    ClmVaultAdapter c;
    bool forked;

    function _defaults() internal pure returns (address[] memory v) {
        v = new address[](10);
        v[0] = BEEFY_GLD;
        v[1] = 0xe12010f9560BC8b1E54393EDA32FB7ae41d412f8; // Beefy META/USDG
        v[2] = 0xaf5bfA1A18a9b1F77b5f240a8275acE8ADd82716; // Beefy AMZN/USDG
        v[3] = 0xE36274737D99273d353d8d9F0a51c1AeA7426C31; // Beefy MSFT/USDG
        v[4] = 0xd60BC30CF5E564e0B956AeBB338942273d62F93b; // Beefy AMD/USDG
        v[5] = ARROW_NVDA; // Arrowfarm NVDA/USDG
        v[6] = 0x75aFb3Ba8E743E9f4c4932f4b6A625678974835A; // Arrowfarm GME/USDG
        v[7] = 0x9Afd43FFb1e6F879F08C0083fFf6100A027764fd; // Arrowfarm GOOGL/USDG
        v[8] = 0x71B146Ab3824683e0e928d114CCe9CF95BF6CD5f; // Arrowfarm SPCX/USDG
        v[9] = 0x11f5d344B64CC31351Cdb92fbEE1395DFC8d20B9; // Arrowfarm TSLA/USDG
    }

    function _newImpl() internal returns (ClmVaultAdapter) {
        return new ClmVaultAdapter(
            IUniswapV3Factory(V3_FACTORY),
            ClmVaultAdapter.Family(BEEFY_FACTORY, BEEFY_STRAT_OWNER, BEEFY_VAULT_OWNER),
            ClmVaultAdapter.Family(ARROW_FACTORY, ARROW_OWNER, ARROW_OWNER)
        );
    }

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        registry = new AdapterRegistry(guardian);
        router = new PriceRouter(address(this));
        source = new MockPriceSource();
        factory = new FundFactory(registry, router, guardian, USDG);
        teller = new SeedTeller();
        // Every default vault's two tokens at the live router's fair price.
        address[] memory d = _defaults();
        for (uint256 i; i < d.length; ++i) {
            (address t0, address t1) = IBeefyClmVault(d[i]).wants();
            _priceLive(t0);
            _priceLive(t1);
        }
        (vault, controller) = factory.create("Fork Fund", "FF", owner, address(teller), DialPresets.open());
        deal(USDG, owner, 20_000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(teller), 20_000e6);
        teller.seed(vault, USDG, 20_000e6, 6, owner);
        controller.setManager(manager, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        impl = _newImpl();
        registry.register(address(impl), "");
        address[] memory two = new address[](2);
        two[0] = BEEFY_GLD;
        two[1] = ARROW_NVDA;
        vm.prank(owner);
        c = ClmVaultAdapter(controller.addAdapter(address(impl), abi.encode(two)));
    }

    function _priceLive(address token) internal {
        if (router.config(token).class_ != PriceClass.None) return;
        IPriceRouter.Quote memory q = IPriceRouter(LIVE_ROUTER).quote(token);
        require(q.available && q.fair != 0, "the live router does not price a default vault token");
        source.set(token, q.fair);
        router.propose(token, PriceRouter.Config({
            primary: IPriceSource(address(source)), check: IPriceSource(address(0)), class_: PriceClass.Feed,
            haircutBps: 0, maxDeviationBps: 0, decimals: 0, chained: 0
        }));
        if (router.pendingAt(token) != 0) {
            uint256 t = block.timestamp;
            vm.warp(t + router.CONFIG_DELAY());
            router.applyPending(token);
            vm.warp(t);
        }
    }

    /// @dev Give the Fund what a deposit of `usdgAmount` needs in the vault's other token (its current ratio, plus 2%).
    function _depositAction(address cv, uint256 usdgAmount) internal returns (bytes memory) {
        (address t0, address t1) = IBeefyClmVault(cv).wants();
        (uint256 b0, uint256 b1) = IBeefyClmVault(cv).balances();
        uint256 x;
        uint256 y;
        if (t0 == USDG) (x, y) = (usdgAmount, b1 * usdgAmount / b0 * 102 / 100);
        else (x, y) = (b0 * usdgAmount / b1 * 102 / 100, usdgAmount);
        address other = t0 == USDG ? t1 : t0;
        deal(other, address(vault), IERC20(other).balanceOf(address(vault)) + (t0 == USDG ? y : x));
        vm.prank(address(controller));
        vault.track(other);
        return abi.encode(uint8(0), cv, x, y, uint256(1));
    }

    function _act(bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(address(c), action);
    }

    function _usd(IPriceRouter r, address t, uint256 a) internal view returns (uint256 v) {
        (v,,) = r.value(t, a, Side.Fair);
    }

    // ------------------------------------------------ origin checks on live contracts

    function test_DefaultListPassesTheOriginChecks() public {
        if (!forked) return;
        ClmVaultAdapter clone = ClmVaultAdapter(Clones.clone(address(impl)));
        clone.initialize(address(0xF00D), address(0xBEEF), abi.encode(_defaults()));
        assertEq(clone.vaults().length, 10);
        for (uint256 i; i < 10; ++i) {
            (,,,, uint8 fam) = clone.infoOf(_defaults()[i]);
            assertEq(fam, i < 5 ? 1 : 2, i < 5 ? "Beefy" : "Arrowfarm");
        }
    }

    function test_RejectsAFreshVaultFromThePermissionlessFactory() public {
        if (!forked) return;
        address fake = IArrowVaultFactory(ARROW_VAULT_FACTORY).cloneVault();
        address[] memory one = new address[](1);
        one[0] = fake;
        ClmVaultAdapter clone = ClmVaultAdapter(Clones.clone(address(impl)));
        vm.expectRevert();
        clone.initialize(address(0xF00D), address(0xBEEF), abi.encode(one));
    }

    function test_RejectsARealVaultWhoseStrategyChangedHands() public {
        if (!forked) return;
        address s = IBeefyClmVault(ARROW_NVDA).strategy();
        vm.mockCall(s, abi.encodeWithSelector(IBeefyClmStrategy.owner.selector), abi.encode(makeAddr("attacker")));
        address[] memory one = new address[](1);
        one[0] = ARROW_NVDA;
        ClmVaultAdapter clone = ClmVaultAdapter(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotTrusted.selector, ARROW_NVDA));
        clone.initialize(address(0xF00D), address(0xBEEF), abi.encode(one));
    }

    // ------------------------------------------------ deposit, value, withdraw

    function _roundTrip(address cv, string memory label) internal {
        (uint256 shares, uint256 paid) = _depositAndMeasure(cv);
        _checkValue(cv, shares, paid, label);
        // Beefy's strategy refuses a withdrawal in the same second as a deposit (DepositTooRecent).
        vm.warp(block.timestamp + 1);
        uint256 u0 = IERC20(USDG).balanceOf(address(vault));
        _act(abi.encode(uint8(1), cv, shares / 2, uint256(0), uint256(0)));
        assertGt(IERC20(USDG).balanceOf(address(vault)) + 1, u0, "the Fund received its tokens");
        assertEq(IERC20(cv).balanceOf(address(c)), shares - shares / 2);
    }

    /// @dev Deposit, and what the vault actually took (it may take one side only), at the live fair prices.
    function _depositAndMeasure(address cv) internal returns (uint256 shares, uint256 paid) {
        (address t0, address t1) = IBeefyClmVault(cv).wants();
        bytes memory dep = _depositAction(cv, 2_000e6);
        uint256 v0 = IERC20(t0).balanceOf(address(vault));
        uint256 v1 = IERC20(t1).balanceOf(address(vault));
        _act(dep);
        paid = _usd(IPriceRouter(LIVE_ROUTER), t0, v0 - IERC20(t0).balanceOf(address(vault)))
            + _usd(IPriceRouter(LIVE_ROUTER), t1, v1 - IERC20(t1).balanceOf(address(vault)));
        shares = IERC20(cv).balanceOf(address(c));
        assertGt(shares, 0, "shares");
        assertEq(IERC20(t0).balanceOf(address(c)) + IERC20(t1).balanceOf(address(c)), 0, "nothing loose");
    }

    /// @dev Ours at the live fair prices against the vault's own preview (pool price) and against what was paid in.
    function _checkValue(address cv, uint256 shares, uint256 paid, string memory label) internal view {
        (address t0, address t1) = IBeefyClmVault(cv).wants();
        (uint256 a0, uint256 a1) = c.valueOf(IPriceRouter(LIVE_ROUTER), cv, shares);
        (uint256 p0, uint256 p1) = IBeefyClmVault(cv).previewWithdraw(shares);
        uint256 ours = _usd(IPriceRouter(LIVE_ROUTER), t0, a0) + _usd(IPriceRouter(LIVE_ROUTER), t1, a1);
        uint256 theirs = _usd(IPriceRouter(LIVE_ROUTER), t0, p0) + _usd(IPriceRouter(LIVE_ROUTER), t1, p1);
        console.log(label);
        console.log("  shares", shares);
        console.log("  ours at fair  (USD 1e-4)", ours / 1e14);
        console.log("  vault preview (USD 1e-4)", theirs / 1e14);
        console.log("  paid in       (USD 1e-4)", paid / 1e14);
        assertApproxEqRel(ours, theirs, 0.02e18, "fair valuation within 2% of the vault's own preview");
        assertApproxEqRel(ours, paid, 0.01e18, "within 1% of what the Fund paid in (entry fees)");
    }

    function test_BeefyGldRoundTrip() public {
        if (!forked) return;
        _roundTrip(BEEFY_GLD, "Beefy GLD/USDG");
    }

    function test_ArrowfarmNvdaRoundTrip() public {
        if (!forked) return;
        _roundTrip(ARROW_NVDA, "Arrowfarm NVDA/USDG");
    }

    function test_NotCalmRefuses() public {
        if (!forked) return;
        bytes memory dep = _depositAction(BEEFY_GLD, 1_000e6);
        vm.mockCall(BEEFY_GLD, abi.encodeWithSelector(IBeefyClmVault.isCalm.selector), abi.encode(false));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ClmVaultAdapter.NotCalm.selector, BEEFY_GLD));
        controller.act(address(c), dep);
    }

    function test_UnwindSplitAndGrow() public {
        if (!forked) return;
        _act(_depositAction(BEEFY_GLD, 2_000e6));
        _act(_depositAction(ARROW_NVDA, 2_000e6));
        (uint256 navBefore,) = controller.nav(uint8(Side.Fair));
        vm.warp(block.timestamp + 1);

        // Grow by a quarter, with the tokens the vaults ask for.
        _growChecked(IAdapter(address(c)), address(vault), address(controller), IPriceRouter(address(router)), 0.25e18, 2);

        // A leaver takes a fifth of the share tokens.
        address leaver = makeAddr("leaver");
        uint256 gld = IERC20(BEEFY_GLD).balanceOf(address(c));
        vm.prank(address(controller));
        c.split(0.2e18, leaver);
        assertEq(IERC20(BEEFY_GLD).balanceOf(leaver), gld / 5);

        // A full unwind pays out both vaults (a second later: no withdrawal in a deposit's second).
        vm.warp(block.timestamp + 1);
        vm.prank(address(controller));
        Amount[] memory got = c.unwind(1e18);
        assertEq(IERC20(BEEFY_GLD).balanceOf(address(c)), 0);
        assertEq(IERC20(ARROW_NVDA).balanceOf(address(c)), 0);
        (Amount[] memory left,) = c.positions(IPriceRouter(address(router)));
        for (uint256 i; i < left.length; ++i) assertEq(left[i].amount, 0);
        (uint256 navAfter,) = controller.nav(uint8(Side.Fair));
        console.log("NAV before grow/split/unwind, after (USD)", navBefore / 1e18, navAfter / 1e18);
        assertGt(got.length, 0);
    }
}
