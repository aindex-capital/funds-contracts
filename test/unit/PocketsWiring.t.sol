// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerFundedBase} from "./TellerExits.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {Pockets} from "../../src/core/Pockets.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

/// @dev Poses as a Fund's vault: names whoever it likes as its teller and reports any snapshot balance.
contract FakeVault {
    address public teller;
    uint256 public bal;

    constructor(address t) {
        teller = t;
    }

    function setBal(uint256 b) external {
        bal = b;
    }

    function balanceOfAt(address, uint256) external view returns (uint256) {
        return bal;
    }
}

/// @notice Only the wired teller opens, credits and assigns pockets, so a contract posing as a vault cannot open a
///         pocket and claim every Fund's tokens from the shared balance.
contract PocketsWiringTest is TellerFundedBase {
    MockERC20 internal tokN;
    address internal eve = makeAddr("eve");

    function setUp() public {
        _setUpFunded();
        tokN = new MockERC20("N", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        _hold(tokN, 100e18);
    }

    function test_WiredOnceByTheDeployerOnly() public {
        assertEq(pockets.teller(), address(tel));
        vm.expectRevert(Pockets.AlreadyWired.selector);
        pockets.wireTeller(eve);
        Pockets p = new Pockets();
        vm.prank(eve);
        vm.expectRevert(Pockets.AlreadyWired.selector);
        p.wireTeller(eve);
        vm.expectRevert(Pockets.AlreadyWired.selector);
        p.wireTeller(address(0));
    }

    function test_AFakeVaultCannotDrainThePockets() public {
        uint256 id = tel.pocket(address(vault), address(tokN), new address[](0), 0);
        assertEq(pockets.held(address(tokN)), 100e18);
        vm.startPrank(eve);
        FakeVault fake = new FakeVault(eve);
        vm.expectRevert(Pockets.NotTeller.selector);
        pockets.open(address(fake), 1, address(tokN), 1);
        vm.expectRevert(Pockets.NotTeller.selector);
        pockets.credit(address(fake), 1);
        vm.expectRevert(Pockets.NotTeller.selector);
        pockets.mark(address(tokN));
        // Nor through a real vault: only the teller itself may act.
        vm.expectRevert(Pockets.NotTeller.selector);
        pockets.open(address(vault), 999, address(tokN), 1);
        fake.setBal(1e30);
        vm.expectRevert(Pockets.NoPocket.selector);
        pockets.claim(address(fake), 1, carol);
        vm.stopPrank();
        // A fake vault that names the real teller gets nowhere either: the teller never opens a pocket for it.
        FakeVault mimic = new FakeVault(address(tel));
        vm.expectRevert(Pockets.NoPocket.selector);
        pockets.claim(address(mimic), id, eve);
        // The holders still claim their part.
        pockets.claim(address(vault), id, alice);
        assertGt(tokN.balanceOf(alice), 0);
    }
}
