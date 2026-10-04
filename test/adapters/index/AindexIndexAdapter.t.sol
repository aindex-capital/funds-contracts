// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../../utils/FundTestBase.sol";
import {AdapterSuite} from "../AdapterSuite.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {IAdapter, Amount} from "../../../src/interfaces/IAdapter.sol";
import {IPriceRouter, PriceClass, Side} from "../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {PriceRouter} from "../../../src/pricing/PriceRouter.sol";
import {AindexIndexAdapter} from "../../../src/adapters/index/AindexIndexAdapter.sol";
import {IndexNavSource} from "../../../src/adapters/index/IndexNavSource.sol";
import {MockFolio, MockIndexFactory, MockZap, MockWETH} from "./IndexMocks.sol";

/// @dev Basket: A ($10, 18 decimals) and B ($5, 6 decimals). One share backs 1 A + 2 B = $20.
abstract contract IndexWorld is FundTestBase {
    MockERC20 internal a;
    MockERC20 internal b;
    MockERC20 internal weth;
    MockFolio internal folio;
    MockIndexFactory internal idxFactory;
    MockZap internal zap;
    IndexNavSource internal nav;
    AindexIndexAdapter internal impl;
    AindexIndexAdapter internal idx;

    function _setUpIndex() internal {
        _setUpCore();
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 6);
        weth = new MockWETH();
        _price(address(a), 10e18, PriceClass.Feed, 0);
        _price(address(b), 5e18, PriceClass.Feed, 0);
        _price(address(weth), 4000e18, PriceClass.Feed, 0);

        address[] memory basket = new address[](2);
        basket[0] = address(a);
        basket[1] = address(b);
        folio = new MockFolio(basket);
        a.mint(address(folio), 100e18);
        b.mint(address(folio), 200e6);
        folio.seed(makeAddr("earlyHolder"), 100e18);

        nav = new IndexNavSource(IPriceRouter(address(router)));
        _priceWith(address(folio), nav);

        idxFactory = new MockIndexFactory();
        idxFactory.set(address(folio), true);
        zap = new MockZap(address(idxFactory), address(weth), address(usdg));

        _createFund(_openDial(), 1000e6);
        impl = new AindexIndexAdapter();
        registry.register(address(impl), "");
        idx = AindexIndexAdapter(payable(_enable(address(impl), abi.encode(address(zap), new address[](0)))));
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

    function _zapBuy(uint256 shares, uint256 pay, uint256 refund) internal view returns (bytes memory) {
        return abi.encode(
            uint8(2),
            address(folio),
            shares,
            shares,
            address(usdg),
            pay,
            abi.encode(refund),
            new bytes[](0),
            block.timestamp
        );
    }

    function _zapSell(uint256 shares, uint256 out) internal view returns (bytes memory) {
        return abi.encode(
            uint8(3), address(folio), shares, address(usdg), out, abi.encode(out), new bytes[](0), block.timestamp
        );
    }
}

contract AindexIndexAdapterTest is IndexWorld {
    /// The zap refunds leftover ETH (AINDEX's API plans unwrap WETH dust): the adapter wraps it and the vault
    /// gets it as WETH, nothing stays behind. Regression for the 2026-10-01 rehearsal ("ETH refund failed").
    function test_ZapBuyEthRefundIsWrappedIntoTheVault() public {
        vm.deal(address(zap), 2.8e12);
        uint256 wethBefore = weth.balanceOf(address(vault));
        vm.prank(manager);
        controller.act(address(idx), _zapBuy(1e18, 30e6, 1e6));
        assertEq(weth.balanceOf(address(vault)) - wethBefore, 2.8e12, "refund did not reach the vault as WETH");
        assertEq(address(idx).balance, 0);
        assertEq(weth.balanceOf(address(idx)), 0);
    }

    function test_EthFromAnyoneButTheZapRefused() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(idx).call{value: 1}("");
        assertFalse(ok);
    }

    function setUp() public {
        _setUpIndex();
    }

    function _actAs(bytes memory action) internal returns (bytes memory r) {
        vm.prank(manager);
        r = controller.act(address(idx), action);
    }

    function _fairNav() internal view returns (uint256 n) {
        (n,) = controller.nav(uint8(Side.Fair));
    }

    /// Give the vault basket tokens, counted.
    function _giveBasket(uint256 amtA, uint256 amtB) internal {
        vm.startPrank(address(controller));
        vault.track(address(a));
        vault.track(address(b));
        vm.stopPrank();
        a.mint(address(vault), amtA);
        b.mint(address(vault), amtB);
    }

    function test_NavSourceLooksThrough() public view {
        (uint256 p,, bool ok) = nav.price(address(folio));
        assertTrue(ok);
        assertEq(p, 20e18);
    }

    function test_NavSourceCountsPendingFees() public {
        folio.setPendingFeeShares(25e18); // supply 125, backing unchanged: $16 a share
        (uint256 p,,) = nav.price(address(folio));
        assertEq(p, 16e18);
    }

    function test_NavSourceUnavailableMidFill() public {
        folio.setMidFill(true);
        (,, bool ok) = nav.price(address(folio));
        assertFalse(ok);
    }

    function test_NavSourceUnavailableWhenABasketPriceIs() public {
        source.setDown(address(b), true);
        (,, bool ok) = nav.price(address(folio));
        assertFalse(ok);
    }

    function test_NavSourceNeverRevertsOnNonFolio() public view {
        (,, bool ok) = nav.price(address(usdg));
        assertFalse(ok);
    }

    function test_MintFromBasket() public {
        _giveBasket(10e18, 20e6);
        uint256 navBefore = _fairNav();
        bytes memory r = _actAs(abi.encode(uint8(0), address(folio), uint256(10e18), uint256(10e18)));
        assertEq(abi.decode(r, (uint256)), 10e18);
        assertEq(folio.balanceOf(address(vault)), 10e18);
        assertEq(a.balanceOf(address(vault)), 0);
        assertEq(b.balanceOf(address(vault)), 0);
        assertEq(_fairNav(), navBefore, "minting at backing keeps NAV");
        assertEq(a.allowance(address(idx), address(folio)), 0);
    }

    function test_MintFeeAndMinSharesOut() public {
        folio.setMintFee(0.01e18);
        _giveBasket(10e18, 20e6);
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(idx), abi.encode(uint8(0), address(folio), uint256(10e18), uint256(10e18)));
        _actAs(abi.encode(uint8(0), address(folio), uint256(10e18), uint256(9.9e18)));
        assertEq(folio.balanceOf(address(vault)), 9.9e18);
    }

    function test_RedeemListsWholeBasket() public {
        _giveBasket(10e18, 20e6);
        _actAs(abi.encode(uint8(0), address(folio), uint256(10e18), uint256(0)));
        bytes memory action = abi.encode(uint8(1), address(folio), uint256(5e18), new uint256[](0));
        address[] memory outs = idx.outputs(action);
        assertEq(outs.length, 2);
        assertEq(outs[0], address(a));
        assertEq(outs[1], address(b));
        _actAs(action);
        assertEq(folio.balanceOf(address(vault)), 5e18);
        assertEq(a.balanceOf(address(vault)), 5e18);
        assertEq(b.balanceOf(address(vault)), 10e6);
    }

    function test_RedeemMinimums() public {
        _giveBasket(10e18, 20e6);
        _actAs(abi.encode(uint8(0), address(folio), uint256(10e18), uint256(0)));
        uint256[] memory mins = new uint256[](2);
        mins[0] = 5e18;
        mins[1] = 10e6 + 1;
        vm.prank(manager);
        vm.expectRevert(bytes("min"));
        controller.act(address(idx), abi.encode(uint8(1), address(folio), uint256(5e18), mins));
    }

    function test_ZapBuyAndSell() public {
        uint256 navBefore = _fairNav();
        bytes memory r = _actAs(_zapBuy(10e18, 200e6, 0));
        assertEq(abi.decode(r, (uint256)), 10e18);
        assertEq(folio.balanceOf(address(vault)), 10e18);
        assertEq(usdg.balanceOf(address(vault)), 800e6);
        // The one-unit leftovers came back too.
        assertEq(a.balanceOf(address(vault)), 1);
        assertEq(b.balanceOf(address(vault)), 1);
        assertApproxEqAbs(_fairNav(), navBefore, 1e13);
        assertEq(usdg.allowance(address(idx), address(zap)), 0);

        _actAs(_zapSell(10e18, 199e6));
        assertEq(folio.balanceOf(address(vault)), 0);
        assertEq(usdg.balanceOf(address(vault)), 999e6);
        assertEq(folio.allowance(address(idx), address(zap)), 0);
    }

    function test_ZapRefundReturnsToVault() public {
        _actAs(_zapBuy(10e18, 250e6, 50e6));
        assertEq(usdg.balanceOf(address(vault)), 800e6);
        assertEq(usdg.balanceOf(address(idx)), 0);
    }

    function test_ZapOutputsDeclareEverything() public view {
        address[] memory o = idx.outputs(_zapBuy(1e18, 20e6, 0));
        // index, pay token, WETH, USDG, then the basket
        assertEq(o.length, 6);
        assertEq(o[0], address(folio));
        assertEq(o[2], address(weth));
        assertEq(o[4], address(a));
        assertEq(o[5], address(b));
    }

    function test_NativeRefused() public {
        bytes memory buyEth = abi.encode(
            uint8(2),
            address(folio),
            uint256(1e18),
            uint256(1),
            address(0),
            uint256(1),
            bytes(""),
            new bytes[](0),
            block.timestamp
        );
        vm.prank(manager);
        vm.expectRevert(AindexIndexAdapter.NativeNotSupported.selector);
        controller.act(address(idx), buyEth);
    }

    function test_UnknownIndexRefused() public {
        address[] memory basket = new address[](1);
        basket[0] = address(a);
        MockFolio rogue = new MockFolio(basket);
        a.mint(address(rogue), 1e18);
        rogue.seed(address(this), 1e18);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AindexIndexAdapter.IndexNotAllowed.selector, address(rogue)));
        controller.act(address(idx), abi.encode(uint8(0), address(rogue), uint256(1e18), uint256(0)));
    }

    function test_ExplicitListWithoutZap() public {
        address[] memory list = new address[](1);
        list[0] = address(folio);
        vm.prank(owner);
        address inst = controller.addAdapter(address(impl), abi.encode(address(0), list));
        AindexIndexAdapter only = AindexIndexAdapter(payable(inst));
        assertTrue(only.isAllowed(address(folio)));
        assertFalse(only.isAllowed(address(usdg)));
        vm.prank(owner);
        vm.expectRevert(AindexIndexAdapter.BadConfig.selector);
        controller.addAdapter(address(impl), abi.encode(address(0), new address[](0)));
    }

    function test_NoPositions() public {
        _actAs(_zapBuy(10e18, 200e6, 0));
        (Amount[] memory held, Amount[] memory owed) = idx.positions(router);
        assertEq(held.length, 0);
        assertEq(owed.length, 0);
    }

    function test_Describe() public view {
        assertGt(bytes(idx.describe()).length, 500);
    }
}

contract AindexIndexAdapterSuite is AdapterSuite, IndexWorld {
    function _setUpAdapter() internal override returns (IAdapter) {
        _setUpIndex();
        return IAdapter(address(idx));
    }

    /// A zap buy at backing: $20 a share, paid in USDG rounded up to the raw unit.
    function _action(uint256 seed) internal view override returns (bytes memory) {
        uint256 shares = bound(seed, 1e15, 40e18);
        uint256 pay = (shares * 20 + 1e12 - 1) / 1e12;
        return _zapBuy(shares, pay, 0);
    }

    function _touchedTokens() internal view override returns (address[] memory t) {
        t = new address[](5);
        t[0] = address(usdg);
        t[1] = address(a);
        t[2] = address(b);
        t[3] = address(folio);
        t[4] = address(weth);
    }
}
