// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

/// @notice An adapter that has borrowed and then stops answering `positions` cannot be written off: removing it
///         would hide a debt and raise NAV.
contract AdapterRemovalDebtTest is TellerBase {
    function setUp() public {
        _setUpTeller();
    }

    function test_UnreadableAdapterThatOwedIsNotRemoved() public {
        MockERC20 tokC = new MockERC20("C", "C", 18);
        _price(address(tokC), 100e18, PriceClass.Feed, 0);
        MockBook book = _book(0);
        book.seed(address(tokA), 10e18);
        book.borrow(address(tokC), 1e18);
        vm.prank(address(controller));
        vault.track(address(tokC));
        vm.prank(manager);
        controller.act(address(book), "");

        vm.mockCallRevert(address(book), abi.encodeWithSelector(IAdapter.positions.selector), "unreadable");
        vm.startPrank(owner);
        controller.disableAdapter(address(book));
        vm.warp(block.timestamp + controller.RISK_NOTICE());
        vm.expectRevert(bytes4(keccak256("AdapterOwes()")));
        controller.removeAdapter(address(book));
        vm.stopPrank();
    }

    function test_EmptyAdapterThatOwedIsRemoved() public {
        MockBook book = _book(0);
        vm.startPrank(owner);
        controller.disableAdapter(address(book));
        controller.removeAdapter(address(book));
        vm.stopPrank();
        assertFalse(controller.isListed(address(book)));
    }
}
