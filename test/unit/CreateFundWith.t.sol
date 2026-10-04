// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {IFundController} from "../../src/interfaces/IFundController.sol";
import {Teller} from "../../src/core/Teller.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {FundController} from "../../src/core/FundController.sol";
import {AdapterRegistry} from "../../src/registry/AdapterRegistry.sol";

/// @notice `Teller.createFundWith`: a Fund created, opened, with its adapters, manager and fee recipient, in one
///         transaction after the USDG approval, through the same checks as the calls it replaces, and a setup
///         window nobody else can reach.
contract CreateFundWithTest is TellerBase {
    address internal ali = makeAddr("ali");
    address internal agent = makeAddr("agent");
    MockBook internal implB;

    function setUp() public {
        _setUpTeller();
        implB = new MockBook();
        registry.register(address(implB), "");
    }

    function _setup(uint256 n, address impl) internal pure returns (ITeller.FundSetup memory s) {
        s.adapters = new address[](n);
        s.configs = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            s.adapters[i] = impl;
            s.configs[i] = abi.encode(uint8(0), address(0xBEEF));
        }
    }

    function _create(address who, ITeller.FundSetup memory s) internal returns (FundVault v, FundController c) {
        usdg.mint(who, 10e6);
        vm.startPrank(who);
        usdg.approve(address(tel), 10e6);
        (address va, address ca) = tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 100, 1000, s);
        vm.stopPrank();
        (v, c) = (FundVault(va), FundController(ca));
    }

    function test_OneTransactionReadiesTheFund() public {
        ITeller.FundSetup memory s = _setup(2, address(bookImpl));
        s.adapters[1] = address(implB);
        s.manager = agent;
        s.managerExpiresAt = uint64(block.timestamp + 90 days);
        s.feeRecipient = carol;
        vm.recordLogs();
        (FundVault v, FundController c) = _create(ali, s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 enabled;
        bool managerSet;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c)) continue;
            if (logs[i].topics[0] == IFundController.AdapterEnabled.selector) ++enabled;
            if (logs[i].topics[0] == IFundController.ManagerSet.selector) {
                managerSet = logs[i].topics[1] == bytes32(uint256(uint160(agent)));
            }
        }
        assertEq(enabled, 2, "AdapterEnabled for each, as addAdapter");
        assertTrue(managerSet, "ManagerSet, as setManager");
        assertEq(c.owner(), ali);
        assertTrue(c.setupDone());
        address[] memory ads = c.adapters();
        assertEq(ads.length, 2);
        assertTrue(c.isAdapter(ads[0]) && c.isAdapter(ads[1]));
        assertEq(registry.implementationOf(ads[0]), address(bookImpl));
        assertEq(registry.implementationOf(ads[1]), address(implB));
        assertEq(MockBook(ads[0]).controller(), address(c), "a clone bound to this Fund");
        assertEq(MockBook(ads[0]).vault(), address(v));
        assertEq(c.manager(), agent);
        assertEq(c.managerExpiresAt(), s.managerExpiresAt);
        assertEq(fees.terms(address(v)).recipient, carol);
        assertEq(fees.terms(address(v)).management, 100);
        assertEq(v.balanceOf(ali), 10e18, "the opening shares in the owner's wallet");
        assertFalse(v.hadOutsideHolder());
        // The manager can act at once.
        vm.prank(agent);
        c.act(ads[0], "");
    }

    function test_EmptySetupIsCreateFund() public {
        (FundVault v, FundController c) = _create(ali, _setup(0, address(0)));
        assertEq(c.adapters().length, 0);
        assertEq(c.manager(), address(0));
        assertEq(fees.terms(address(v)).recipient, ali, "the owner by default");
        assertTrue(c.setupDone(), "closed even when unused");
    }

    function test_SameChecksAsTheOwnerCalls() public {
        // Unknown implementation.
        ITeller.FundSetup memory s = _setup(1, address(0x1234));
        usdg.mint(ali, 10e6);
        vm.startPrank(ali);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(AdapterRegistry.UnknownImplementation.selector);
        tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 0, 0, s);
        // Retired implementation.
        vm.stopPrank();
        vm.prank(guardian);
        registry.retire(address(implB));
        s = _setup(1, address(implB));
        vm.prank(ali);
        vm.expectRevert(AdapterRegistry.RetiredImplementation.selector);
        tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 0, 0, s);
        // More than MAX_ADAPTERS.
        s = _setup(13, address(bookImpl));
        vm.prank(ali);
        vm.expectRevert(FundController.TooManyAdapters.selector);
        tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 0, 0, s);
        // A manager term past MAX_MANAGER_TERM.
        s = _setup(1, address(bookImpl));
        s.manager = agent;
        s.managerExpiresAt = uint64(block.timestamp + 367 days);
        vm.prank(ali);
        vm.expectRevert(FundController.BadTerm.selector);
        tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 0, 0, s);
        // Lists of different lengths.
        s = _setup(2, address(bookImpl));
        s.configs = new bytes[](1);
        vm.prank(ali);
        vm.expectRevert(FundController.SetupClosed.selector);
        tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 0, 0, s);
        // Over the fee maxima, as setTerms.
        s = _setup(0, address(0));
        vm.prank(ali);
        vm.expectRevert();
        tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 201, 0, s);
        // Under the opening minimum.
        vm.prank(ali);
        vm.expectRevert(Teller.StakeTooSmall.selector);
        tel.createFundWith("Ali", "ALI", _openDial(), 9e6, 0, 0, s);
        // Twelve fit.
        s = _setup(12, address(bookImpl));
        vm.prank(ali);
        (, address c) = tel.createFundWith("Ali", "ALI", _openDial(), 10e6, 0, 0, s);
        assertEq(FundController(c).adapters().length, 12);
    }

    function test_NobodyElseCanRunTheSetup() public {
        ITeller.FundSetup memory s = _setup(1, address(bookImpl));
        (FundVault v, FundController c) = _create(ali, s);
        address[] memory impls = new address[](1);
        impls[0] = address(bookImpl);
        bytes[] memory cfg = new bytes[](1);
        // Not the owner, not the manager, not a stranger: only the teller.
        address[3] memory who = [ali, agent, bob];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(FundController.NotTeller.selector);
            c.setup(impls, cfg, bob, 0);
        }
        // Not even the teller a second time, nor once the Fund has shares.
        vm.prank(address(tel));
        vm.expectRevert(FundController.SetupClosed.selector);
        c.setup(impls, cfg, bob, 0);
        assertEq(c.adapters().length, 1);
        assertEq(c.manager(), address(0));
        v;
    }

    function test_PlainCreateFundStillWorksAndCannotBeSetUpLater() public {
        // The old flow: a plain createFund, then the owner's own calls.
        address[] memory impls = new address[](1);
        impls[0] = address(bookImpl);
        bytes[] memory cfg = new bytes[](1);
        cfg[0] = abi.encode(uint8(0), address(0xBEEF));
        vm.prank(address(tel));
        vm.expectRevert(FundController.SetupClosed.selector); // the Fund has shares since its opening
        controller.setup(impls, cfg, bob, 0);
        vm.prank(owner);
        address inst = controller.addAdapter(address(bookImpl), cfg[0]);
        assertTrue(controller.isAdapter(inst));
        vm.prank(owner);
        controller.setManager(agent, uint64(block.timestamp + 30 days));
        assertEq(controller.manager(), agent);
    }

    /// Someone creates a Fund naming Ali its owner and this teller (the factory lets anyone): they cannot run a setup
    /// on it, the teller never does for a Fund it did not just create for its caller, and only Ali can open it.
    function test_AFundSomeoneElseMadeForAliCannotBeSetUp() public {
        (FundVault fv, FundController fc) = factory.create("Ali", "ALI", ali, address(tel), _openDial());
        (address v, address c) = (address(fv), address(fc));
        address[] memory impls = new address[](1);
        impls[0] = address(bookImpl);
        bytes[] memory cfg = new bytes[](1);
        cfg[0] = abi.encode(uint8(0), address(0xBEEF));
        vm.prank(bob);
        vm.expectRevert(FundController.NotTeller.selector);
        FundController(c).setup(impls, cfg, bob, uint64(block.timestamp + 1 days));
        usdg.mint(bob, 10e6);
        vm.startPrank(bob);
        usdg.approve(address(tel), 10e6);
        vm.expectRevert(Teller.NotOwner.selector);
        tel.open(v, 10e6, 0, 0);
        // Bob's createFundWith makes Bob's own Fund, never touches Ali's.
        (, address c2) = tel.createFundWith("Bob", "BOB", _openDial(), 10e6, 0, 0, _setup(1, address(bookImpl)));
        vm.stopPrank();
        assertEq(FundController(c2).owner(), bob);
        assertEq(FundController(c).adapters().length, 0);
        assertFalse(FundController(c).setupDone());
    }
}
