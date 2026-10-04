// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../adapters/lending/MockMorpho.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {MorphoBlueAdapter} from "../../src/adapters/lending/MorphoBlueAdapter.sol";
import {MorphoMarketRegistry} from "../../src/adapters/lending/MorphoMarketRegistry.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/external/morpho/IMorpho.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {IPriceRouter, PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {Teller} from "../../src/core/Teller.sol";
import {TellerOps} from "../../src/core/TellerOps.sol";
import {Pockets} from "../../src/core/Pockets.sol";
import {FundFees} from "../../src/core/Fees.sol";

/// @notice An adapter holding a no-market token and some A whose unwind loses half of the A (a dishonest or
///         broken unwind a pocket must refuse).
contract LossyHolder is BaseAdapter {
    address public n;
    address public a;
    bool public lossy;

    function _configure(bytes calldata config) internal override {
        (n, a, lossy) = abi.decode(config, (address, address, bool));
    }

    function name() external pure returns (string memory) {
        return "Lossy";
    }

    function describe() external pure returns (string memory) {
        return "{}";
    }

    function inputs(bytes calldata) external pure returns (Amount[] memory) {
        return _none();
    }

    function outputs(bytes calldata) external pure returns (address[] memory) {
        return new address[](0);
    }

    function execute(bytes calldata) external view onlyController returns (bytes memory) {
        return "";
    }

    function positions(IPriceRouter) external view returns (Amount[] memory h, Amount[] memory d) {
        h = new Amount[](2);
        h[0] = Amount(n, IERC20(n).balanceOf(address(this)));
        h[1] = Amount(a, IERC20(a).balanceOf(address(this)));
        d = new Amount[](0);
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    function unwind(uint256) external onlyController returns (Amount[] memory r) {
        r = new Amount[](2);
        r[0] = Amount(n, _pushAll(n));
        uint256 x = IERC20(a).balanceOf(address(this));
        if (lossy) _push(a, address(0xdead), x / 2);
        r[1] = Amount(a, _pushAll(a));
    }

    function growInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    function grow(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function split(uint256, address) external view onlyController returns (Amount[] memory) {
        return _none();
    }
}

/// @notice Holders' pockets: lazy snapshots of the shares, the `Pockets` contract, the teller's custody passing its
///         part to request owners, `pocket` for no-market tokens and claims valued at zero, and settlements waiting
///         for it.
contract PocketsTest is TellerBase {
    MockERC20 internal tokN;
    LossyHolder internal lossyImpl;

    function setUp() public {
        _setUpTeller();
        tokN = new MockERC20("No market", "N", 18);
        _price(address(tokN), 1e18, PriceClass.None, 0);
        lossyImpl = new LossyHolder();
        registry.register(address(lossyImpl), "");
    }

    function _snap() internal returns (uint256 id) {
        vm.prank(address(tel));
        id = vault.snapshot();
    }

    function _pocket(address[] memory ads, uint256 into) internal returns (uint256) {
        return tel.pocket(address(vault), address(tokN), ads, into);
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    // ------------------------------------------------------------ lazy snapshots

    function test_BalanceOfAtAcrossSnapshotsMintsBurnsAndTransfers() public {
        uint256 a = _join(alice, 100e6);
        uint256 id1 = _snap();
        vm.prank(alice);
        vault.transfer(bob, a / 4);
        uint256 id2 = _snap();
        uint256 id3 = _snap(); // nothing moves between 2 and 3
        uint256 b2 = _join(bob, 50e6);
        vm.prank(alice);
        tel.redeemInKind(address(vault), a / 4, alice);
        assertEq(vault.balanceOfAt(alice, id1), a);
        assertEq(vault.balanceOfAt(bob, id1), 0);
        assertEq(vault.balanceOfAt(alice, id2), a - a / 4);
        assertEq(vault.balanceOfAt(bob, id2), a / 4);
        assertEq(vault.balanceOfAt(alice, id3), a - a / 4);
        assertEq(vault.balanceOfAt(bob, id3), a / 4);
        assertEq(vault.balanceOf(bob), a / 4 + b2);
        assertEq(vault.balanceOfAt(alice, 99), 0, "an id not taken yet");
        assertEq(vault.balanceOfAt(alice, 0), 0);
        assertEq(vault.balanceOfAt(carol, id1), 0);
    }

    function test_SnapshotIsTellerOnly() public {
        vm.expectRevert();
        vault.snapshot();
    }

    function test_GasPerMove() public {
        uint256 a = _join(alice, 100e6);
        vm.startPrank(alice);
        vault.transfer(bob, 1);
        vault.transfer(carol, 1); // warm-up of the recipients' balance slots
        vm.stopPrank();
        uint256 g0 = _gasTransfer(bob);
        _snap();
        uint256 g1 = _gasTransfer(bob);
        uint256 g2 = _gasTransfer(bob);
        emit log_named_uint("transfer gas, no snapshot taken", g0);
        emit log_named_uint("transfer gas, first move after a snapshot (both accounts checkpointed)", g1);
        emit log_named_uint("transfer gas, later moves", g2);
        assertLt(g1 - g0, 2 * 46_000, "about 44k per account at its first move (a new checkpoint entry)");
        assertLt(g2 - g0, 2 * 5_000, "a read per account after that");
        a;
    }

    function _gasTransfer(address to) internal returns (uint256 g) {
        vm.prank(alice);
        g = gasleft();
        vault.transfer(to, 1);
        g -= gasleft();
    }

    // ------------------------------------------------------------ Pockets

    function test_ClaimProRataNeverExpiresAndAnyonePaysTheAccount() public {
        uint256 a = _join(alice, 1000e6);
        _hold(tokN, 300e18);
        uint256 id = _pocket(_none(), 0);
        uint256 supplyAt = vault.totalSupply();
        assertEq(tokN.balanceOf(address(pockets)), 300e18);
        assertFalse(vault.isTracked(address(tokN)), "no longer counted");
        vm.warp(block.timestamp + 3650 days);
        vm.prank(makeAddr("anyone"));
        uint256 paid = pockets.claim(address(vault), id, alice);
        assertEq(paid, 300e18 * a / supplyAt);
        assertEq(tokN.balanceOf(alice), paid, "paid to the account, not the caller");
        assertEq(pockets.claim(address(vault), id, alice), 0, "once");
        vm.expectRevert(Pockets.TellerAccount.selector);
        pockets.claim(address(vault), id, address(tel));
        vm.expectRevert(Pockets.NoPocket.selector);
        pockets.claim(address(vault), id + 1, alice);
    }

    function test_SharesBoughtAfterTheSnapshotGetNothing() public {
        uint256 a = _join(alice, 1000e6);
        _hold(tokN, 300e18);
        uint256 id = _pocket(_none(), 0);
        vm.prank(alice);
        vault.transfer(bob, a / 2); // after the snapshot
        assertEq(pockets.due(address(vault), id, bob), 0);
        assertGt(pockets.due(address(vault), id, alice), 0);
    }

    function test_TopUpAndCreditAccounting() public {
        _join(alice, 1000e6);
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        (, uint256 amt,) = pockets.pocket(address(vault), id);
        assertEq(amt, 100e18);
        tokN.mint(address(this), 50e18);
        tokN.approve(address(pockets), 50e18);
        assertEq(pockets.topUp(address(vault), id, 50e18), 50e18);
        (, amt,) = pockets.pocket(address(vault), id);
        assertEq(amt, 150e18, "a top-up grows every holder's part");
        assertEq(pockets.held(address(tokN)), 150e18);
        vm.expectRevert(Pockets.NotTeller.selector);
        pockets.credit(address(vault), id);
        vm.expectRevert(Pockets.NotTeller.selector);
        pockets.mark(address(tokN));
    }

    // ------------------------------------------------------------ the teller's custody

    function test_StakePartAssignedToTheOwner() public {
        _join(alice, 1000e6);
        _hold(tokN, 200e18);
        uint256 id = _pocket(_none(), 0);
        uint256 stake = tel.fund(address(vault)).stake;
        assertEq(pockets.due(address(vault), id, owner), 0);
        tel.assignStakePockets(address(vault));
        (, uint256 amt, uint256 supplyAt) = pockets.pocket(address(vault), id);
        assertEq(pockets.due(address(vault), id, owner), amt * stake / supplyAt);
        tel.assignStakePockets(address(vault)); // nothing twice
        assertEq(tel.custodyAt(address(vault), id, owner), stake);
        // Alice leaves; the owner, now the last holder, takes the stake back: no second assignment.
        vm.startPrank(alice);
        tel.redeemInKind(address(vault), vault.balanceOf(alice), alice);
        vm.stopPrank();
        vm.prank(owner);
        tel.releaseStake(address(vault));
        assertEq(tel.custodyAt(address(vault), id, owner), stake);
        pockets.claim(address(vault), id, owner);
        assertEq(tokN.balanceOf(owner), amt * stake / supplyAt);
    }

    function test_ReleaseStakeAssignsWhatWasNotYet() public {
        _hold(tokN, 200e18);
        uint256 id = _pocket(_none(), 0);
        vm.prank(owner);
        tel.releaseStake(address(vault));
        assertEq(tel.custodyAt(address(vault), id, owner), STAKE * 1e12);
    }

    function test_EscrowedCashExitAndUnclaimedDepositShares() public {
        uint256 b = _join(bob, 500e6);
        uint256 r = _redeem(bob, b, 1);
        uint256 d = _deposit(alice, 200e6, 1);
        uint64 bt = _batchOf(r);
        _settle(bt);
        (uint256 aliceShares,,) = tel.due(d);
        // The batch has settled: bob's escrow went to alice (matched) and the rest was paid; alice has not
        // claimed. A pocket now: alice's unclaimed shares are hers, bob's are gone.
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        _claim(d);
        _claim(r);
        assertEq(tel.custodyAt(address(vault), id, alice), aliceShares, "unclaimed deposit shares");
        assertEq(tel.custodyAt(address(vault), id, bob), 0, "bob's escrow left custody at the round");
    }

    function test_PocketWhileACashExitWaits() public {
        uint256 b = _join(bob, 500e6);
        uint256 r = _redeem(bob, b, 1);
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0); // between the request and the round
        _settle(_batchOf(r));
        _claim(r);
        assertEq(tel.custodyAt(address(vault), id, bob), b, "his escrowed shares were his at the snapshot");
        assertEq(pockets.due(address(vault), id, bob), _part(id, b));
    }

    function _part(uint256 id, uint256 shares) internal view returns (uint256) {
        (, uint256 amt, uint256 supplyAt) = pockets.pocket(address(vault), id);
        return amt * shares / supplyAt;
    }

    function test_CancelledCashExitGetsItsPart() public {
        uint256 b = _join(bob, 500e6);
        uint256 r = _redeem(bob, b, 1);
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        vm.prank(bob);
        tel.cancel(r);
        assertEq(tel.custodyAt(address(vault), id, bob), b);
        assertEq(pockets.due(address(vault), id, bob), _part(id, b));
    }

    function test_SharesHandedBackGetTheirPart() public {
        uint256 b = _join(bob, 1000e6);
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), 1900e6);
        _hold(tokA, 19e18);
        uint256 r = _redeem(bob, b, 1);
        _settle(_batchOf(r));
        (uint256 back,,) = tel.due(r);
        assertGt(back, 0);
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        _claim(r);
        assertEq(tel.custodyAt(address(vault), id, bob), back, "only what was still in custody");
    }

    function test_SkippedCashExitGetsItsPart() public {
        uint256 b = _join(bob, 500e6);
        uint256 r = _redeem(bob, b, type(uint128).max);
        _settleSkip(_batchOf(r), _one(r)); // moved once
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        _settleSkip(_batchOf(r), _one(r)); // fails again: paid back
        assertEq(uint8(tel.request(r).status), uint8(ITeller.Status.Skipped));
        _claim(r);
        assertEq(tel.custodyAt(address(vault), id, bob), b);
    }

    function test_DeadSharesNeverAssigned() public {
        _join(alice, 100e6);
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        tel.assignStakePockets(address(vault));
        uint256 tellerAt = vault.balanceOfAt(address(tel), id);
        assertEq(tellerAt - tel.custodyAt(address(vault), id, owner), tel.DEAD_SHARES(), "only the dead shares stay");
        // Every holder claims: the pocket keeps the dead shares' part and rounding, never pays more.
        pockets.claim(address(vault), id, alice);
        pockets.claim(address(vault), id, owner);
        assertGe(tokN.balanceOf(address(pockets)), 0);
        assertLe(tokN.balanceOf(alice) + tokN.balanceOf(owner), 100e18);
    }

    // ------------------------------------------------------------ pocket(): what it takes and from where

    function test_NotPocketableBelowDustOrPriced() public {
        _hold(tokN, 1e13); // 0.00001 tokens, under writeOffMaxWad (0.0001)
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotPocketable.selector, address(tokN)));
        _pocket(_none(), 0);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotPocketable.selector, address(tokA)));
        tel.pocket(address(vault), address(tokA), _none(), 0);
    }

    function test_NotHeldUnlistedDuplicateOrEmptyAdapter() public {
        _hold(tokN, 10e18);
        MockBook bk = _book(0);
        bk.seed(address(tokA), 1e18);
        address[] memory ads = new address[](1);
        ads[0] = address(bk);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotHeld.selector, address(bk)));
        _pocket(ads, 0);
        bk.seed(address(tokN), 1e18);
        ads = new address[](2);
        (ads[0], ads[1]) = (address(bk), address(bk));
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotHeld.selector, address(bk)));
        _pocket(ads, 0);
        ads = new address[](1);
        ads[0] = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotHeld.selector, ads[0]));
        _pocket(ads, 0);
    }

    function test_AdapterHoldingItIsUnwoundWholeAndMeasured() public {
        MockBook bk = _book(0);
        bk.seed(address(tokN), 40e18);
        bk.seed(address(tokA), 2e18);
        _hold(tokN, 10e18);
        address[] memory ads = new address[](1);
        ads[0] = address(bk);
        uint256 navBefore = _nav(0);
        uint256 id = _pocket(ads, 0);
        (, uint256 amt,) = pockets.pocket(address(vault), id);
        assertEq(amt, 50e18, "the vault's and the adapter's");
        assertEq(tokA.balanceOf(address(vault)), 2e18, "the rest of the position comes home and is counted");
        assertTrue(vault.isTracked(address(tokA)));
        assertApproxEqAbs(_nav(0), navBefore, 1, "nothing priced was lost");
    }

    function test_LossyUnwindRefused() public {
        vm.prank(owner);
        LossyHolder lh = LossyHolder(controller.addAdapter(address(lossyImpl), abi.encode(tokN, tokA, true)));
        tokN.mint(address(lh), 10e18);
        tokA.mint(address(lh), 2e18);
        address[] memory ads = new address[](1);
        ads[0] = address(lh);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.PocketLoss.selector, 200e18, 100e18));
        _pocket(ads, 0);
    }

    function test_ContinuationIntoTheSamePocket() public {
        MockBook b1 = _book(0);
        MockBook b2 = _book(0);
        b1.seed(address(tokN), 10e18);
        b2.seed(address(tokN), 20e18);
        address[] memory one = new address[](1);
        one[0] = address(b1);
        uint256 id = _pocket(one, 0);
        uint256 snaps = vault.currentSnapshotId();
        one[0] = address(b2);
        assertEq(_pocket(one, id), id);
        assertEq(vault.currentSnapshotId(), snaps, "no second snapshot");
        (, uint256 amt,) = pockets.pocket(address(vault), id);
        assertEq(amt, 30e18);
    }

    function test_ContinuationRefusedLateOtherTokenOrAfterAMint() public {
        MockBook b1 = _book(0);
        MockBook b2 = _book(0);
        b1.seed(address(tokN), 10e18);
        b2.seed(address(tokN), 20e18);
        address[] memory one = new address[](1);
        one[0] = address(b1);
        uint256 id = _pocket(one, 0);
        one[0] = address(b2);
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + TellerOps.POCKET_CONTINUE + 1);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotPocketable.selector, address(tokN)));
        _pocket(one, id);
        vm.revertToState(snap);
        vm.prank(address(tel));
        vault.mint(alice, 1); // a share minted since the snapshot
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotPocketable.selector, address(tokN)));
        _pocket(one, id);
        vm.revertToState(snap);
        MockERC20 tokM = new MockERC20("M", "M", 18);
        _price(address(tokM), 1e18, PriceClass.None, 0);
        _hold(tokM, 5e18);
        vm.expectRevert(abi.encodeWithSelector(TellerOps.NotPocketable.selector, address(tokM)));
        tel.pocket(address(vault), address(tokM), _none(), id);
    }

    /// @dev A holder at the snapshot who left in kind, taking its slice of the token still inside an adapter, could
    ///      then add that adapter to the same pocket, whose snapshot balance would pay it a second part (a 50% holder
    ///      would take 125 of a fair 100). An exit in kind since the pocket opened refuses `into`;
    ///      the rest goes to a fresh pocket for those who hold then.
    function test_ContinuationRefusedAfterAnExitInKind() public {
        MockBook b1 = _book(0);
        _join(bob, 1000e6);
        _hold(tokN, 100e18);
        b1.seed(address(tokN), 100e18);
        uint256 bobSh = vault.balanceOf(bob);
        uint256 fair = 200e18 * bobSh / vault.totalSupply();
        vm.prank(bob);
        uint256 id = _pocket(_none(), 0);
        vm.prank(bob);
        tel.redeemInKind(address(vault), bobSh, bob);
        assertEq(tel.lastInKindAt(address(vault)), block.timestamp);
        address[] memory one = new address[](1);
        one[0] = address(b1);
        vm.prank(bob);
        vm.expectRevert(Teller.NotReady.selector);
        _pocket(one, id);
        uint256 id2 = _pocket(one, 0);
        pockets.claim(address(vault), id, bob);
        pockets.claim(address(vault), id2, bob);
        assertApproxEqAbs(tokN.balanceOf(bob), fair, 1e15, "bob gets his part once");
    }

    /// @dev An exit in kind that began before the pocket opened does not block it.
    function test_ContinuationAfterAnEarlierExitInKind() public {
        MockBook b1 = _book(0);
        MockBook b2 = _book(0);
        uint256 a = _join(alice, 100e6); // before the no-market holding, which holds new money back
        b1.seed(address(tokN), 10e18);
        b2.seed(address(tokN), 20e18);
        vm.prank(alice);
        tel.redeemInKind(address(vault), a / 2, alice);
        vm.warp(block.timestamp + 1);
        address[] memory one = new address[](1);
        one[0] = address(b1);
        uint256 id = _pocket(one, 0);
        one[0] = address(b2);
        assertEq(_pocket(one, id), id);
    }

    // ------------------------------------------------------------ settlements wait for it

    function test_EntrantsWaitAndFeesWaitUntilThePocket() public {
        _openFund(200, 0); // a new Fund with a 2% management fee
        uint256 b = _join(bob, 1000e6);
        b;
        vm.warp(block.timestamp + 30 days);
        _hold(tokN, 100e18);
        (ITeller.Hold h, address t) = tel.depositHold(address(vault));
        assertEq(uint8(h), uint8(ITeller.Hold.NoMarket));
        assertEq(t, address(tokN));
        uint256 a = _deposit(alice, 100e6, 1);
        uint64 bt = _batchOf(a);
        uint256 supply = vault.totalSupply();
        uint256 aixBefore = vault.balanceOf(aix);
        _settle(bt);
        assertEq(vault.totalSupply(), supply, "no new share: neither the entrant's nor a fee");
        assertEq(vault.balanceOf(aix), aixBefore);
        _pocket(_none(), 0);
        (h,) = tel.depositHold(address(vault));
        assertEq(uint8(h), uint8(ITeller.Hold.Open));
        _settle(bt);
        // At least the 30 days of 2% (the $AIX holders' 15% of it): the waiting settlement deferred them, it did not
        // drop them (plus the days to the cut-offs).
        uint256 got = vault.balanceOf(aix) - aixBefore;
        assertGe(got, supply * 2 / 100 * 30 / 365 * 15 / 100);
        assertLe(got, supply * 2 / 100 * 34 / 365 * 15 / 100);
        (uint256 sa,) = _claim(a);
        assertGt(sa, 0);
    }

    // ------------------------------------------------------------ claims valued at zero: Morpho through the teller

    MockMorpho internal morpho;
    MarketParams internal mkt;
    MorphoBlueAdapter internal mb;
    address internal borrower = makeAddr("borrower");

    /// @dev A Morpho market AINDEX never reviewed; the Fund lends 200 USDG into it (valued at zero) and an outsider
    ///      borrows 150, so only 50 of its 200 can be withdrawn now.
    function _unvaluedSupply() internal {
        morpho = new MockMorpho();
        MockIrm irm = new MockIrm();
        MockMorphoOracle oracle = new MockMorphoOracle();
        oracle.set(100e24);
        mkt = MarketParams(address(usdg), address(tokA), address(oracle), address(irm), 0.625e18);
        morpho.createMarket(mkt);
        MorphoMarketRegistry reg =
            new MorphoMarketRegistry(makeAddr("aindex"), IMorpho(address(morpho)), new bytes32[](0));
        MorphoBlueAdapter impl = new MorphoBlueAdapter(IMorpho(address(morpho)));
        registry.register(address(impl), "");
        vm.prank(owner);
        mb = MorphoBlueAdapter(controller.addAdapter(address(impl), abi.encode(address(reg), new bytes32[](0))));
        if (!controller.isAdapter(address(mb))) {
            vm.warp(block.timestamp + controller.RISK_NOTICE());
            controller.enablePendingAdapter(address(impl));
        }
        vm.prank(manager);
        controller.act(address(mb), abi.encode(uint8(0), mkt, uint256(200e6))); // within the 25% loss budget
        tokA.mint(borrower, 100e18);
        vm.startPrank(borrower);
        tokA.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(mkt, 100e18, borrower, "");
        morpho.borrow(mkt, 150e6, 0, borrower, borrower);
        vm.stopPrank();
    }

    function test_UnvaluedMorphoSupplyPocketedAndDrained() public {
        uint256 aliceShares = _join(alice, 700e6); // a holder before the claim valued at zero exists
        _unvaluedSupply();
        aliceShares;
        uint256 d = _deposit(carol, 100e6, 1);
        _settle(_batchOf(d));
        (,, bool waiting) = tel.due(d);
        assertTrue(waiting, "carol waits: the Fund holds a claim valued at zero");

        address[] memory ads = new address[](1);
        ads[0] = address(mb);
        uint256 id = tel.pocket(address(vault), address(usdg), ads, 0);
        assertTrue(vault.isTracked(address(usdg)), "a valued token stays counted");
        (, uint256 amt,) = pockets.pocket(address(vault), id);
        assertApproxEqAbs(amt, 50e6, 2, "what was free now");
        assertEq(mb.unvalued().length, 0, "no longer the Fund's");
        (Amount[] memory pos,) = mb.positions(router);
        assertEq(pos.length, 0);

        _settle(_batchOf(d));
        (uint256 sc,,) = tel.due(d);
        assertGt(sc, 0, "carol goes in, without a claim on the pocket");
        assertEq(pockets.due(address(vault), id, carol), 0);

        // The borrower repays; anyone drains the rest into the pocket.
        usdg.mint(borrower, 150e6);
        vm.startPrank(borrower);
        usdg.approve(address(morpho), type(uint256).max);
        morpho.repay(mkt, 150e6, 0, borrower, "");
        vm.stopPrank();
        mb.drain();
        (, amt,) = pockets.pocket(address(vault), id);
        assertApproxEqAbs(amt, 200e6, 3, "all of it, over time");
        assertEq(mb.pocketedMarkets(), 0);
        assertGt(pockets.due(address(vault), id, alice), 0);
    }

    // ------------------------------------------------------------ custody records, checkpoints, arrivals

    /// @notice A claim, a cancel or a stake release never walks the snapshots taken meanwhile: the teller records the
    ///         custody once and the pocket asks it (`custodyAt`). Cost is flat in the number of snapshots.
    function test_ClaimCostDoesNotGrowWithSnapshots() public {
        uint256 b = _join(bob, 500e6);
        uint256 r = _redeem(bob, b, 1);
        _hold(tokN, 1e18);
        uint256 first = _pocket(_none(), 0);
        for (uint256 i; i < 300; ++i) _snap();
        _settle(_batchOf(r));
        uint256 g = gasleft();
        _claim(r);
        g -= gasleft();
        emit log_named_uint("claim gas after 300 snapshots", g);
        assertLt(g, 200_000);
        assertEq(tel.custodyAt(address(vault), first, bob), b, "his escrow counts in the pocket taken meanwhile");
        assertEq(tel.custodyAt(address(vault), first + 300, bob), b);
        assertEq(tel.custodyAt(address(vault), first + 302, bob), 0, "after his custody ended");
        assertEq(pockets.due(address(vault), first, bob), _part(first, b));
    }

    /// @notice `balanceOfAt` by binary search over the account's own checkpoints agrees with what it held.
    function test_BalanceOfAtBinarySearch() public {
        uint256 a = _join(alice, 100e6);
        uint256[] memory ids = new uint256[](40);
        uint256[] memory bal = new uint256[](40);
        for (uint256 i; i < 40; ++i) {
            ids[i] = _snap();
            bal[i] = vault.balanceOf(alice);
            if (i % 3 == 0) {
                vm.prank(alice);
                vault.transfer(bob, a / 100);
            }
        }
        for (uint256 i; i < 40; ++i) {
            assertEq(vault.balanceOfAt(alice, ids[i]), bal[i]);
        }
        assertEq(vault.balanceOfAt(alice, 0), 0);
        assertEq(vault.balanceOfAt(alice, ids[39] + 1), 0, "not taken yet");
    }

    /// @notice A pocket is credited only with what arrived for it: growth nobody sent (a rebase, a dividend
    ///         multiplier) is nobody's credit, so no pocket can capture another Fund's.
    function test_GrowthNobodySentIsNotCredited() public {
        _join(alice, 1000e6);
        _hold(tokN, 100e18);
        uint256 id = _pocket(_none(), 0);
        tokN.mint(address(pockets), 7e18); // the token's balances grew on their own
        assertEq(pockets.topUp(address(vault), id, 0), 0);
        (, uint256 amt,) = pockets.pocket(address(vault), id);
        assertEq(amt, 100e18);
        // The next pocket of the token is credited with its own arrival only.
        _hold(tokN, 5e18);
        uint256 id2 = _pocket(_none(), 0);
        (, amt,) = pockets.pocket(address(vault), id2);
        assertEq(amt, 5e18);
        assertEq(pockets.held(address(tokN)), 105e18);
        vm.prank(address(tel));
        vm.expectRevert(Pockets.NotMarked.selector);
        pockets.credit(address(vault), id2);
    }
}
