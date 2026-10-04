// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FundTestBase} from "../utils/FundTestBase.sol";
import {MockSwap} from "../utils/MockAdapters.sol";
import {AdapterRegistry} from "../../src/registry/AdapterRegistry.sol";
import {IAdapterRegistry} from "../../src/interfaces/IAdapterRegistry.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {IAdapter} from "../../src/interfaces/IAdapter.sol";

/// @dev Pretends to be a Fund: a vault whose controller is the caller, and a controller naming that vault.
contract FakeFund {
    address public controller;
    address public vault;

    constructor() {
        controller = address(this);
        vault = address(this);
    }

    function instantiate(AdapterRegistry r, address impl) external returns (address) {
        return r.instantiate(impl, address(this), abi.encode(address(0), uint256(0)));
    }
}

/// @dev A vault that names the caller as controller, while the caller names another vault.
contract LyingVault {
    address public controller;

    constructor(address c) {
        controller = c;
    }
}

contract RegistryTest is FundTestBase {
    MockSwap impl;
    address alice = makeAddr("alice");

    function setUp() public {
        _setUpCore();
        _createFund(_openDial(), 1000e6);
        impl = new MockSwap();
    }

    function test_RegisterRecordsAuthor() public {
        vm.prank(alice);
        registry.register(address(impl), "ipfs://x");
        IAdapterRegistry.Entry memory e = registry.entry(address(impl));
        assertEq(e.author, alice);
        assertFalse(e.verified);
        assertFalse(e.retired);
        assertEq(e.metadataURI, "ipfs://x");
        assertEq(registry.implementations().length, 1);
    }

    function test_RegisterRejectsNoCodeAndDuplicates() public {
        vm.expectRevert(AdapterRegistry.NoCode.selector);
        registry.register(alice, "");
        registry.register(address(impl), "");
        vm.expectRevert(AdapterRegistry.AlreadyRegistered.selector);
        registry.register(address(impl), "");
    }

    function test_OnlyReviewerVerifies() public {
        registry.register(address(impl), "");
        vm.expectRevert(AdapterRegistry.NotReviewer.selector);
        registry.setVerified(address(impl), true);
        vm.prank(guardian);
        registry.setVerified(address(impl), true);
        assertTrue(registry.entry(address(impl)).verified);
        vm.prank(guardian);
        vm.expectRevert(AdapterRegistry.UnknownImplementation.selector);
        registry.setVerified(alice, true);
    }

    function test_RetireBlocksNewClonesAndReviewerCanReinstate() public {
        vm.prank(alice);
        registry.register(address(impl), "");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AdapterRegistry.NotReviewer.selector);
        registry.retire(address(impl));
        vm.prank(alice);
        registry.retire(address(impl));
        vm.prank(owner);
        vm.expectRevert(AdapterRegistry.RetiredImplementation.selector);
        controller.addAdapter(address(impl), abi.encode(source, uint256(0)));

        // A squatter who registered someone else's adapter first cannot keep it retired.
        vm.startPrank(guardian);
        registry.reinstate(address(impl));
        registry.setAuthor(address(impl), owner);
        vm.stopPrank();
        assertEq(registry.entry(address(impl)).author, owner);
        _enable(address(impl), abi.encode(source, uint256(0)));
    }

    function test_ReinstateAndSetAuthorOnlyReviewer() public {
        registry.register(address(impl), "");
        vm.expectRevert(AdapterRegistry.NotReviewer.selector);
        registry.reinstate(address(impl));
        vm.expectRevert(AdapterRegistry.NotReviewer.selector);
        registry.setAuthor(address(impl), alice);
    }

    function test_InstantiateOnlyByTheVaultsController() public {
        registry.register(address(impl), "");
        vm.expectRevert(AdapterRegistry.NotFundController.selector);
        registry.instantiate(address(impl), address(vault), "");
        vm.expectRevert(AdapterRegistry.UnknownImplementation.selector);
        vm.prank(address(controller));
        registry.instantiate(alice, address(vault), "");
    }

    function test_InstantiateRejectsVaultThatDoesNotNameCallerBack() public {
        registry.register(address(impl), "");
        // The real controller calls with a vault that claims it, but the controller names another vault.
        LyingVault lv = new LyingVault(address(controller));
        vm.prank(address(controller));
        vm.expectRevert(AdapterRegistry.NotFundController.selector);
        registry.instantiate(address(impl), address(lv), "");
    }

    function test_FakeFundOnlyReachesItself() public {
        registry.register(address(impl), "");
        FakeFund f = new FakeFund();
        address inst = f.instantiate(registry, address(impl));
        assertEq(IAdapter(inst).vault(), address(f));
        assertEq(BaseAdapter(inst).controller(), address(f));
    }

    function test_ClonesAreBoundAndImplementationLocked() public {
        registry.register(address(impl), "");
        address inst = _enable(address(impl), abi.encode(source, uint256(0)));
        assertEq(registry.implementationOf(inst), address(impl));
        assertEq(IAdapter(inst).vault(), address(vault));
        assertEq(BaseAdapter(inst).controller(), address(controller));
        vm.expectRevert(BaseAdapter.AlreadyInitialized.selector);
        IAdapter(inst).initialize(alice, alice, "");
        vm.expectRevert(BaseAdapter.AlreadyInitialized.selector);
        impl.initialize(alice, alice, "");
    }

    function test_ReviewerTwoStep() public {
        vm.prank(guardian);
        registry.transferReviewer(alice);
        assertEq(registry.reviewer(), guardian);
        vm.expectRevert(AdapterRegistry.NotReviewer.selector);
        registry.acceptReviewer();
        vm.prank(alice);
        registry.acceptReviewer();
        assertEq(registry.reviewer(), alice);
    }
}
