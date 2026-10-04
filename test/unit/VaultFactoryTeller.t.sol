// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FundTestBase} from "../utils/FundTestBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockReenter, OpenTeller} from "../utils/MockAdapters.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {FundController} from "../../src/core/FundController.sol";
import {FundFactory} from "../../src/core/FundFactory.sol";
import {SeedTeller} from "../../src/core/SeedTeller.sol";
import {Dial} from "../../src/interfaces/IFundController.sol";
import {DialPresets} from "../../src/core/DialPresets.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

contract VaultTest is FundTestBase {
    address x = makeAddr("x");

    function setUp() public {
        _setUpCore();
        _createFund(_openDial(), 1000e6);
    }

    function test_OnlyControllerApprovesAndUntracks() public {
        vm.startPrank(x);
        vm.expectRevert(FundVault.NotController.selector);
        vault.approveFor(address(usdg), x, 1);
        vm.expectRevert(FundVault.NotController.selector);
        vault.untrack(address(usdg));
        vm.expectRevert(FundVault.NotController.selector);
        vault.track(address(usdg));
        vm.stopPrank();
        vm.prank(address(teller));
        vault.track(makeAddr("tok"));
        assertTrue(vault.isTracked(makeAddr("tok")));
    }

    function test_OnlyTellerMintsBurnsPays() public {
        vm.startPrank(address(controller));
        vm.expectRevert(FundVault.NotTeller.selector);
        vault.mint(x, 1);
        vm.expectRevert(FundVault.NotTeller.selector);
        vault.burn(owner, 1);
        vm.expectRevert(FundVault.NotTeller.selector);
        vault.pay(address(usdg), x, 1);
        vm.stopPrank();
        vm.startPrank(address(teller));
        vault.pay(address(usdg), x, 1e6);
        vault.burn(owner, 1e18);
        vm.stopPrank();
        assertEq(usdg.balanceOf(x), 1e6);
    }

    function test_WireOnlyOnce() public {
        vm.expectRevert(FundVault.AlreadyWired.selector);
        vault.wire(x, x);
        FundVault v = new FundVault("a", "a");
        vm.prank(x);
        vm.expectRevert(FundVault.AlreadyWired.selector);
        v.wire(x, x);
    }

    function test_TrackedListIsBoundedAndUntrackFreesSlots() public {
        uint256 max = vault.MAX_TRACKED();
        vm.startPrank(address(controller));
        for (uint256 i = vault.trackedTokens().length; i < max; ++i) {
            vault.track(address(uint160(0x1000 + i)));
        }
        vm.expectRevert(FundVault.TooManyTokens.selector);
        vault.track(address(0xBEEF));
        vault.track(address(usdg)); // already tracked: no-op, no revert
        vault.untrack(address(uint160(0x1000 + 5)));
        assertFalse(vault.isTracked(address(uint160(0x1000 + 5))));
        assertEq(vault.trackedTokens().length, max - 1);
        vault.track(address(0xBEEF));
        vm.stopPrank();
    }

    function test_OutsideHolderLatchSticks() public {
        assertFalse(vault.hadOutsideHolder());
        vm.prank(owner);
        vault.transfer(x, 1);
        assertTrue(vault.hadOutsideHolder());
        vm.prank(x);
        vault.transfer(owner, 1);
        assertTrue(vault.hadOutsideHolder(), "returning shares reopens the shortcut");
    }

    function test_TellerCannotMintDuringAnAction() public {
        OpenTeller open = new OpenTeller();
        (FundVault v, FundController c) = factory.create("F", "F", owner, address(open), _openDial());
        MockReenter impl = new MockReenter();
        registry.register(address(impl), "");
        vm.startPrank(owner);
        address inst = c.addAdapter(address(impl), abi.encode(open));
        c.setManager(manager, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        // Outside an action the teller works.
        open.mint(address(v), owner, 1e18);
        vm.prank(manager);
        c.act(inst, "");
        MockReenter r = MockReenter(inst);
        assertTrue(r.sawActing(), "controller reports acting");
        assertTrue(r.actBlocked(), "act re-entered");
        assertTrue(r.approveBlocked(), "adapter approved itself");
        assertTrue(r.mintBlocked(), "teller minted mid-action");
        assertFalse(c.isActing());
    }
}

contract FactoryTest is FundTestBase {
    function setUp() public {
        _setUpCore();
    }

    function test_CreatesWiredFund() public {
        (FundVault v, FundController c) = factory.create("F", "F", owner, address(teller), _openDial());
        assertEq(v.controller(), address(c));
        assertEq(v.teller(), address(teller));
        assertEq(c.vault(), address(v));
        assertEq(c.owner(), owner);
        assertEq(c.guardian(), guardian);
        assertEq(c.baseAsset(), address(usdg));
        assertTrue(factory.isFund(address(v)));
        assertEq(factory.funds().length, 1);
    }

    function test_RejectsZeroRolesAndBadDial() public {
        vm.expectRevert(FundFactory.ZeroAddress.selector);
        factory.create("F", "F", address(0), address(teller), _openDial());
        vm.expectRevert(FundFactory.ZeroAddress.selector);
        factory.create("F", "F", owner, address(0), _openDial());
        Dial memory d = _openDial();
        d.maxThinBps = 10_001;
        vm.expectRevert(FundController.BadDial.selector);
        factory.create("F", "F", owner, address(teller), d);
        d = _openDial();
        d.minHealthBps = 9_999;
        vm.expectRevert(FundController.BadDial.selector);
        factory.create("F", "F", owner, address(teller), d);
    }

    /// Presets are suggestions for pages and scripts; the factory takes each of them, and any other valid dial.
    function test_PresetsAreValidDials() public {
        Dial memory o = DialPresets.open();
        assertEq(o.maxNoMarketBps, 10_000);
        assertEq(o.maxThinBps, 10_000);
        assertEq(o.maxPoolBps, 10_000);
        assertEq(o.maxPerTokenBps, 10_000);
        assertEq(o.dailyLossBps, 2_500, "the open preset caps losses at a quarter a day");
        assertTrue(o.allowBorrow);
        assertEq(o.minHealthBps, 10_000);
        assertTrue(o.allowUnreviewed);
        Dial[3] memory all = [o, DialPresets.balanced(), DialPresets.conservative()];
        for (uint256 i; i < 3; ++i) {
            (, FundController c) = factory.create("P", "P", owner, address(teller), all[i]);
            assertEq(keccak256(abi.encode(c.dial())), keccak256(abi.encode(all[i])));
        }
        assertFalse(DialPresets.conservative().allowBorrow);
        assertFalse(DialPresets.balanced().allowUnreviewed);
    }

    function test_GuardianRotatesForNewFunds() public {
        address g2 = makeAddr("g2");
        vm.expectRevert(FundFactory.NotGuardian.selector);
        factory.transferGuardian(g2);
        vm.prank(guardian);
        factory.transferGuardian(g2);
        (, FundController c1) = factory.create("F", "F", owner, address(teller), _openDial());
        assertEq(c1.guardian(), guardian, "pending until accepted");
        vm.prank(g2);
        factory.acceptGuardian();
        (, FundController c2) = factory.create("F", "F", owner, address(teller), _openDial());
        assertEq(c2.guardian(), g2);
        assertEq(c1.guardian(), guardian, "existing Funds keep theirs");
    }
}

contract SeedTellerTest is FundTestBase {
    address x = makeAddr("x");

    function setUp() public {
        _setUpCore();
        (vault, controller) = factory.create("F", "F", owner, address(teller), _openDial());
        usdg.mint(owner, 1000e6);
        usdg.mint(x, 1000e6);
        vm.prank(owner);
        usdg.approve(address(teller), type(uint256).max);
        vm.prank(x);
        usdg.approve(address(teller), type(uint256).max);
    }

    function test_OwnerSeedsOnce() public {
        vm.prank(owner);
        uint256 shares = teller.seed(vault, address(usdg), 500e6, 6, owner);
        assertEq(shares, 500e18);
        assertEq(vault.balanceOf(owner), 500e18);
        assertTrue(vault.isTracked(address(usdg)));
        assertFalse(vault.hadOutsideHolder());
        vm.prank(owner);
        vm.expectRevert(SeedTeller.AlreadySeeded.selector);
        teller.seed(vault, address(usdg), 1e6, 6, owner);
    }

    function test_StrangerCannotSeedFirst() public {
        vm.prank(x);
        vm.expectRevert(SeedTeller.NotSeeder.selector);
        teller.seed(vault, address(usdg), 1e6, 6, x);
        // A donation before seeding only gifts the owner.
        vm.prank(x);
        usdg.transfer(address(vault), 100e6);
        vm.prank(owner);
        teller.seed(vault, address(usdg), 500e6, 6, owner);
        assertEq(vault.totalSupply(), vault.balanceOf(owner));
    }

    function test_RejectsWrongTokenDecimalsAndZero() public {
        MockERC20 other = new MockERC20("O", "O", 6);
        _price(address(other), 1e18, PriceClass.Feed, 0);
        other.mint(owner, 1e6);
        vm.startPrank(owner);
        other.approve(address(teller), 1e6);
        vm.expectRevert(SeedTeller.BadSeed.selector);
        teller.seed(vault, address(other), 1e6, 6, owner);
        vm.expectRevert(SeedTeller.BadSeed.selector);
        teller.seed(vault, address(usdg), 1e6, 18, owner);
        vm.expectRevert(SeedTeller.BadSeed.selector);
        teller.seed(vault, address(usdg), 0, 6, owner);
        vm.expectRevert(SeedTeller.BadSeed.selector);
        teller.seed(vault, address(usdg), 1e6, 6, address(0));
        vm.stopPrank();
    }

    function test_RejectsVaultWithAnotherTeller() public {
        (FundVault v2,) = factory.create("G", "G", owner, makeAddr("otherTeller"), _openDial());
        vm.prank(owner);
        vm.expectRevert(SeedTeller.NotSeeder.selector);
        teller.seed(v2, address(usdg), 1e6, 6, owner);
    }

    function test_SeedingSomeoneElseCountsAsOutsideHolder() public {
        vm.prank(owner);
        teller.seed(vault, address(usdg), 500e6, 6, x);
        assertTrue(vault.hadOutsideHolder());
    }
}
