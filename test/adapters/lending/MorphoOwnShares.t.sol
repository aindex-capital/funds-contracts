// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoWorld} from "./MorphoBlueAdapter.t.sol";
import {Amount} from "../../../src/interfaces/IAdapter.sol";

/// @notice The Morpho adapter counts only supply it put in itself, and a leaver's supply the market cannot pay at the
///         split stays the leaver's.
contract MorphoOwnSharesTest is MorphoWorld {
    address internal eve = makeAddr("eve");
    address internal leaver = makeAddr("leaver");

    function setUp() public {
        _world(_openDial(), new bytes32[](0));
        usdg.mint(eve, 1_000_000e6);
        vm.prank(eve);
        usdg.approve(address(morpho), type(uint256).max);
    }

    function _eveSupplies(uint256 amount) internal {
        vm.prank(eve);
        morpho.supply(mkt, amount, 0, address(mb), "");
    }

    /// @notice Supply someone else put in on the clone's behalf changes nothing the Fund reports, is never withdrawn
    ///         with the Fund's, and does not keep a market open.
    function test_SupplyOnBehalfIsIgnored() public {
        _eveSupplies(5_000e6);
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 0, "not the Fund's");
        assertEq(mb.unvalued().length, 0);
        _do(SUPPLY, 10_000e6);
        (a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 10_000e6, 1, "only its own");
        uint256 v = usdg.balanceOf(address(vault));
        _do(WITHDRAW, ALL);
        assertApproxEqAbs(usdg.balanceOf(address(vault)) - v, 10_000e6, 1, "withdraws only its own");
        assertEq(mb.markets().length, 0, "forgotten, although the donation is still there");
        (uint256 left,,) = morpho.position(morpho.id(mkt), address(mb));
        assertGt(left, 0);
    }

    function test_WithdrawCannotReachTheDonation() public {
        _do(SUPPLY, 1_000e6);
        _eveSupplies(5_000e6);
        vm.prank(manager);
        vm.expectRevert(); // PocketedSupply: more than the Fund's own
        controller.act(address(mb), _a(WITHDRAW, 2_000e6));
    }

    /// @notice A split the market cannot pay in full: the leaver gets what is free now, and the rest of its slice
    ///         becomes its own supply shares, out of the Fund's positions, paid out by anyone once borrowers repay.
    function test_SplitShortfallStaysTheLeavers() public {
        _do(SUPPLY, 10_000e6);
        _drain(1_000e6); // only 1,000 USDG free in the market
        vm.prank(address(controller));
        mb.split(0.5e18, leaver);
        assertApproxEqAbs(usdg.balanceOf(leaver), 1_000e6, 1, "what was free");
        bytes32 mid = morpho.id(mkt);
        assertGt(mb.leaverShares(mid, leaver), 0);
        (Amount[] memory a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 5_000e6, 2, "the Fund keeps exactly its half");
        // Nothing free: payLeaver pays nothing and changes nothing.
        assertEq(mb.payLeaver(mid, leaver), 0);
        // The borrower repays: anyone pays the leaver the rest.
        vm.startPrank(borrower);
        usdg.mint(borrower, 2_000_000e6);
        usdg.approve(address(morpho), type(uint256).max);
        (, uint128 bs,) = morpho.position(mid, borrower);
        morpho.repay(mkt, 0, bs, borrower, "");
        vm.stopPrank();
        mb.payLeaver(mid, leaver);
        assertApproxEqAbs(usdg.balanceOf(leaver), 5_000e6, 2, "the whole slice");
        assertEq(mb.leaverShares(mid, leaver), 0);
        (a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 5_000e6, 2, "and the Fund's half untouched");
    }

    /// @notice A low gas limit never turns a payable leaver into a silent zero: at every gas limit `payLeaver`
    ///         either reverts or pays, and the leaver's shares stay until it pays.
    function test_ShortGasNeverPaysNothing() public {
        _do(SUPPLY, 10_000e6);
        _drain(1_000e6);
        vm.prank(address(controller));
        mb.split(0.5e18, leaver);
        bytes32 mid = morpho.id(mkt);
        uint256 owed = mb.leaverShares(mid, leaver);
        vm.startPrank(borrower);
        usdg.mint(borrower, 2_000_000e6);
        usdg.approve(address(morpho), type(uint256).max);
        (, uint128 bs,) = morpho.position(mid, borrower);
        morpho.repay(mkt, 0, bs, borrower, "");
        vm.stopPrank();
        bool paid;
        for (uint256 gas = 30_000; gas <= 400_000 && !paid; gas += 2_000) {
            (bool ok, bytes memory ret) = address(mb).call{gas: gas}(abi.encodeCall(mb.payLeaver, (mid, leaver)));
            if (!ok) {
                assertEq(mb.leaverShares(mid, leaver), owed, "a revert changes nothing");
                continue;
            }
            uint256 got = abi.decode(ret, (uint256));
            assertGt(got, 0, "succeeded but paid nothing");
            paid = true;
        }
        assertTrue(paid, "pays with enough gas");
        assertApproxEqAbs(usdg.balanceOf(leaver), 5_000e6, 2);
    }

    /// @notice An unwind the market cannot pay in full leaves the rest with the Fund, as before.
    function test_UnwindShortfallStaysTheFunds() public {
        _do(SUPPLY, 10_000e6);
        _drain(1_000e6);
        vm.prank(address(controller));
        mb.unwind(0.5e18);
        assertEq(mb.leaverTotal(morpho.id(mkt)), 0);
        (Amount[] memory a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 9_000e6, 2);
    }
}
