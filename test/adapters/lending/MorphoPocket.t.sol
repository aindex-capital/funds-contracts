// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoWorld} from "./MorphoBlueAdapter.t.sol";
import {MockMorphoOracle} from "./MockMorpho.sol";
import {MorphoBlueAdapter} from "../../../src/adapters/lending/MorphoBlueAdapter.sol";
import {BaseAdapter} from "../../../src/adapters/BaseAdapter.sol";
import {Pockets} from "../../../src/core/Pockets.sol";
import {IPockets} from "../../../src/interfaces/IPockets.sol";
import {Amount} from "../../../src/interfaces/IAdapter.sol";
import {MarketParams} from "../../../src/interfaces/external/morpho/IMorpho.sol";

/// @notice `IPocketable` on the Morpho adapter: supply in a market AINDEX has not approved (valued at zero) leaves the
///         Fund's book for a holders' pocket, pays in what is free now and drains the rest as borrowers repay. The
///         Fund's teller (here the seed teller) drives it through the controller.
contract MorphoPocketTest is MorphoWorld {
    Pockets internal pockets;
    MarketParams internal evil;
    address internal thief = makeAddr("thief");

    function setUp() public {
        _world(_openDial(), new bytes32[](0));
        pockets = new Pockets();
        pockets.wireTeller(address(teller));
        MockMorphoOracle o = new MockMorphoOracle();
        o.set(1e40);
        evil = MarketParams(address(usdg), address(nvda), address(o), address(irm), 0.625e18);
        morpho.createMarket(evil);
        _supplyEvil(10_000e6);
        // Someone borrows 8,000 of it: only 2,000 is free.
        nvda.mint(thief, 1e18);
        vm.startPrank(thief);
        nvda.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(evil, 1e18, thief, "");
        morpho.borrow(evil, 8_000e6, 0, thief, thief);
        vm.stopPrank();
    }

    function _supplyEvil(uint256 amount) internal {
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, evil, amount));
    }

    /// @dev What the teller's `pocket` does for a claim valued at zero: a snapshot, a pocket, the adapter's hook.
    function _pocketNow() internal returns (uint256 id, uint256 paid) {
        vm.startPrank(address(teller));
        id = vault.snapshot();
        pockets.open(address(vault), id, address(usdg), vault.totalSupply());
        paid = controller.pocketFor(address(mb), address(usdg), address(pockets), id);
        vm.stopPrank();
    }

    function _held(uint256 id) internal view returns (uint256 amt) {
        (, amt,) = pockets.pocket(address(vault), id);
    }

    function test_PocketsTheUnvaluedSupplyAndDrainsItOverTime() public {
        assertEq(mb.unvalued().length, 1);
        (uint256 id, uint256 paid) = _pocketNow();
        assertApproxEqAbs(paid, 2_000e6, 2, "what is free now");
        assertEq(_held(id), paid);
        assertGt(mb.pocketedShares(morpho.id(evil)), 0);
        assertEq(mb.pocketedMarkets(), 1);
        assertEq(mb.unvalued().length, 0, "no longer the Fund's claim");
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 0, "no longer in the Fund's book");
        // Nothing frees up yet: a drain pays nothing.
        assertEq(mb.drain(), 0);
        // The borrower repays; anyone drains.
        usdg.mint(thief, 8_000e6);
        vm.startPrank(thief);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.repay(evil, 8_000e6, 0, thief, "");
        vm.stopPrank();
        vm.prank(makeAddr("anyone"));
        mb.drain();
        assertApproxEqAbs(_held(id), 10_000e6, 3);
        assertEq(mb.pocketedMarkets(), 0);
        assertEq(mb.pocketIdOf(morpho.id(evil)), 0);
        assertEq(mb.markets().length, 0, "an emptied market is forgotten");
        assertEq(usdg.balanceOf(address(mb)), 0);
    }

    function test_ASecondPocketWaitsForTheFirst() public {
        (uint256 id,) = _pocketNow();
        _supplyEvil(1_000e6); // the manager lends more into the same market
        bytes32 eid = morpho.id(evil);
        vm.startPrank(address(teller));
        uint256 id2 = vault.snapshot();
        pockets.open(address(vault), id2, address(usdg), vault.totalSupply());
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.PocketBusy.selector, eid));
        controller.pocketFor(address(mb), address(usdg), address(pockets), id2);
        // The same pocket may take it.
        controller.pocketFor(address(mb), address(usdg), address(pockets), id);
        vm.stopPrank();
    }

    function test_ManagerCannotWithdrawPocketedSupply() public {
        _pocketNow();
        _supplyEvil(3_000e6); // all of it free: the Fund's own
        // The borrower repays 1,000: now more is free than the Fund owns in the market.
        usdg.mint(thief, 1_000e6);
        vm.startPrank(thief);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.repay(evil, 1_000e6, 0, thief, "");
        vm.stopPrank();
        bytes32 eid = morpho.id(evil);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueAdapter.PocketedSupply.selector, eid));
        controller.act(address(mb), abi.encode(WITHDRAW, evil, uint256(3_500e6)));
        uint256 before = usdg.balanceOf(address(vault));
        vm.prank(manager);
        controller.act(address(mb), abi.encode(WITHDRAW, evil, ALL));
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - before, 3_000e6, 2, "all of the Fund's own, none of the pocket's");
        assertGt(mb.pocketedShares(morpho.id(evil)), 0);
    }

    function test_ExitsLeavePocketedSupplyAlone() public {
        _pocketNow();
        _do(SUPPLY, 5_000e6); // supply in the approved market
        uint256 shares = mb.pocketedShares(morpho.id(evil));
        vm.prank(address(controller));
        mb.unwind(1e18);
        assertEq(mb.pocketedShares(morpho.id(evil)), shares, "an unwind of everything leaves the pocket's part");
        (uint256 s,,) = morpho.position(morpho.id(evil), address(mb));
        assertEq(s, shares);
    }

    function test_OnlyOnePocketsContractAndOnlyTheController() public {
        _pocketNow();
        IPockets other = IPockets(address(new Pockets()));
        vm.prank(address(controller));
        vm.expectRevert(MorphoBlueAdapter.BadPockets.selector);
        mb.pocket(address(usdg), other, 9);
        vm.expectRevert(BaseAdapter.NotController.selector);
        mb.pocket(address(usdg), IPockets(address(pockets)), 1);
    }

    function test_ApprovedSupplyIsNotPocketed() public {
        _do(SUPPLY, 5_000e6);
        _pocketNow();
        (Amount[] memory a,) = mb.positions(router);
        uint256 approved;
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token == address(usdg)) approved += a[i].amount;
        }
        assertApproxEqAbs(approved, 5_000e6, 1, "supply in a reviewed market stays the Fund's and counts in full");
    }
}
