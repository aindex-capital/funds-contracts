// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoWorld} from "./MorphoBlueAdapter.t.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {Amount} from "../../../src/interfaces/IAdapter.sol";
import {MarketParams} from "../../../src/interfaces/external/morpho/IMorpho.sol";
import {Side} from "../../../src/interfaces/IPriceRouter.sol";
import {DialPresets} from "../../../src/core/DialPresets.sol";

/// @notice A market someone builds from a reviewed oracle and a collateral token they mint at will. The oracle is
///         sound; the market is not. Reviews must cover the whole market.
abstract contract ForeignCollateral is MorphoWorld {
    MockERC20 internal junk;
    MarketParams internal foreign;
    address internal accomplice = makeAddr("accomplice");

    function _foreignMarket() internal {
        junk = new MockERC20("Junk", "JUNK", 18);
        foreign = MarketParams(address(usdg), address(junk), address(oracle), address(irm), 0.625e18);
        morpho.createMarket(foreign);
    }

    /// @dev The accomplice posts junk the reviewed oracle prices as NVDA and borrows everything lent.
    function _drainForeign(uint256 amount) internal {
        junk.mint(accomplice, 1_000e18);
        vm.startPrank(accomplice);
        junk.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(foreign, 1_000e18, accomplice, "");
        morpho.borrow(foreign, amount, 0, accomplice, accomplice);
        vm.stopPrank();
    }

    function _nav() internal view returns (uint256 n) {
        (n,) = controller.nav(uint8(Side.Bid));
    }
}

/// @notice Reviewed instruments only (the balanced preset): a market that only reuses a reviewed oracle is refused.
contract MorphoMarketReviewGateTest is ForeignCollateral {
    function setUp() public {
        _world(DialPresets.balanced(), new bytes32[](0));
        _foreignMarket();
    }

    function test_ReviewedOracleDoesNotApproveAForeignMarket() public {
        assertFalse(controller.dial().allowUnreviewed);
        uint8[3] memory ids = [SUPPLY, SUPPLY_COLLATERAL, BORROW];
        bytes32 mid = keccak256(abi.encode(foreign));
        for (uint256 i; i < 3; ++i) {
            vm.prank(manager);
            vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("MarketNotApproved(bytes32)")), mid));
            controller.act(address(mb), abi.encode(ids[i], foreign, uint256(1e6)));
        }
    }

    function test_ReviewedMarketStillOpen() public {
        _do(SUPPLY, 10_000e6);
        (Amount[] memory a,) = mb.positions(router);
        assertApproxEqAbs(a[0].amount, 10_000e6, 1, "an approved market's supply counts in full");
        assertEq(mb.unvalued().length, 0, "nothing valued at zero");
    }
}

/// @notice Unreviewed instruments allowed (the open preset): any market, but supply in one AINDEX has not approved
///         counts as nothing, so lending into it is a loss at once, charged to the manager's daily budget.
contract MorphoUnapprovedSupplyTest is ForeignCollateral {
    function setUp() public {
        _world(_openDial(), new bytes32[](0));
        _foreignMarket();
    }

    function test_LendingIntoAnUnapprovedMarketIsChargedAtOnce() public {
        uint256 navBefore = _nav();
        uint256 lossBefore = controller.windowLoss();
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, foreign, uint256(10_000e6)));
        uint256 navAfter = _nav();
        assertApproxEqAbs(navBefore - navAfter, 10_000e18, 1e12, "the supply is worth nothing to NAV");
        assertApproxEqAbs(controller.windowLoss() - lossBefore, 10_000e18, 1e12, "and was charged to the budget");

        // The drain that follows changes nothing more: it was already counted.
        _drainForeign(10_000e6);
        assertApproxEqAbs(_nav(), navAfter, 1e12);
    }

    /// The drain itself: most of the Fund's cash into a market an accomplice empties. The daily loss
    /// budget stops it before any money moves.
    function test_DrainBeyondTheLossBudgetIsRefused() public {
        vm.prank(manager);
        vm.expectRevert();
        controller.act(address(mb), abi.encode(SUPPLY, foreign, uint256(90_000e6)));
    }

    /// Supply in an unapproved market keeps its place in exits (a row of zero) and is not bought by deposits.
    function test_UnapprovedSupplyStaysInExitsButIsNotGrown() public {
        vm.prank(manager);
        controller.act(address(mb), abi.encode(SUPPLY, foreign, uint256(10_000e6)));
        (Amount[] memory a,) = mb.positions(router);
        assertEq(a.length, 1);
        assertEq(a[0].token, address(usdg));
        assertEq(a[0].amount, 0);
        Amount[] memory u = mb.unvalued();
        assertEq(u.length, 1, "reported as a claim valued at zero, so the teller holds new money back");
        assertEq(u[0].token, address(usdg));
        assertApproxEqAbs(u[0].amount, 10_000e6, 1);
        Amount[] memory needs = mb.growInputs(0.5e18);
        assertEq(needs.length, 0, "a deposit does not buy more of it");
        address leaver = makeAddr("leaver");
        vm.prank(address(controller));
        mb.split(0.25e18, leaver);
        assertApproxEqAbs(usdg.balanceOf(leaver), 2_500e6, 1, "the leaver still takes its slice");
    }
}
