// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TellerBase} from "./TellerBase.t.sol";
import {V4PoolManagerCode} from "../adapters/liquidity/uniswap/V4PoolManagerCode.sol";
import {V4Helper, MockWETH} from "../adapters/liquidity/uniswap/UniswapMocks.sol";
import {MockVault4626} from "../adapters/yield/MockVault4626.sol";
import {UniswapV4LiquidityAdapter} from "../../src/adapters/liquidity/UniswapV4LiquidityAdapter.sol";
import {OraclePositionMath} from "../../src/adapters/liquidity/OraclePositionMath.sol";
import {ERC4626Adapter} from "../../src/adapters/yield/ERC4626Adapter.sol";
import {IWETH9} from "../../src/interfaces/external/uniswap/IWETH9.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../adapters/lending/MockMorpho.sol";
import {MorphoBlueAdapter} from "../../src/adapters/lending/MorphoBlueAdapter.sol";
import {MorphoMarketRegistry} from "../../src/adapters/lending/MorphoMarketRegistry.sol";
import {IMorpho, MarketParams} from "../../src/interfaces/external/morpho/IMorpho.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";

/**
 * @notice Regression: exits in kind must not revert from rounding when one adapter reports the same token in many
 *         rows. The teller allows two raw units of slack per row, and every Morpho market, liquidity position and
 *         yield vault rounds on its own (assets down, debts up); before the adapters kept each row's rounding to
 *         themselves an exit in kind failed `NotShrunk`, about 0.2 units short, on a Uniswap v4 adapter with ten
 *         positions. Since deposits enter as cash (2026-10-02) no settlement grows or unwinds an adapter, so the
 *         deposit and cash-exit cases here only check that settlements with such books still settle; exits in
 *         kind run both in one transaction and in parts.
 *         Each test runs at the count it was seen at, or at the adapter's cap when that is lower. The holders join
 *         before any position is opened, and own most of the Fund, so their exits are large fractions: a row's
 *         rounding loses about `f / 2` of a unit on average, which is where the units add up past the slack.
 */
abstract contract RowsBase is TellerBase {
    /// @dev An exit in kind of `shares`, bringing what the slice's debt needs.
    function _inKind(address who, uint256 shares) internal {
        Amount[] memory bring = tel.inKindNeeds(address(vault), shares);
        vm.startPrank(who);
        for (uint256 i; i < bring.length; ++i) {
            if (bring[i].amount == 0) continue;
            MockERC20(bring[i].token).mint(who, bring[i].amount);
            IERC20(bring[i].token).approve(address(tel), bring[i].amount);
        }
        tel.redeemInKind(address(vault), shares, who);
        vm.stopPrank();
    }

    /// @dev The same exit in parts: the vault tokens at once, then every adapter's slice in its own call.
    function _inKindParts(address who, uint256 shares) internal {
        Amount[] memory bring = tel.inKindNeedsInParts(address(vault), shares);
        vm.startPrank(who);
        for (uint256 i; i < bring.length; ++i) {
            if (bring[i].amount == 0) continue;
            MockERC20(bring[i].token).mint(who, bring[i].amount + 1e6);
            IERC20(bring[i].token).approve(address(tel), type(uint256).max);
        }
        uint256 id = tel.startInKind(address(vault), shares, who, new address[](0));
        address[] memory ads = controller.adapters();
        for (uint256 i; i < ads.length; ++i) {
            if (tel.exitUnits(id, ads[i]) == 0) continue;
            address[] memory one = new address[](1);
            one[0] = ads[i];
            tel.claimInKind(id, one);
        }
        vm.stopPrank();
        assertEq(tel.exit(id).pending, 0);
    }

    function _inKindPartsSeries(address who, uint256[6] memory parts, address last) internal {
        for (uint256 k; k < parts.length; ++k) {
            vm.warp(block.timestamp + 1 days + k * 977);
            _inKindParts(who, vault.balanceOf(who) * parts[k] / 1000);
        }
        _inKindParts(last, vault.balanceOf(last));
        assertEq(vault.balanceOf(last), 0);
    }

    /// @dev Exits in kind of these thousandths of the holder's balance, a day apart, then the rest of `last`.
    function _inKindSeries(address who, uint256[6] memory parts, address last) internal {
        for (uint256 k; k < parts.length; ++k) {
            vm.warp(block.timestamp + 1 days + k * 977);
            _inKind(who, vault.balanceOf(who) * parts[k] / 1000);
        }
        _inKind(last, vault.balanceOf(last));
        assertEq(vault.balanceOf(last), 0);
    }

    /// @dev Cash exits of these thousandths of the holder's balance, a batch each; what the Fund's cash cannot cover
    ///      comes back and leaves in kind.
    function _cashSeries(address who, uint256[5] memory parts) internal {
        for (uint256 k; k < parts.length; ++k) {
            uint256 r = _redeem(who, vault.balanceOf(who) * parts[k] / 1000, 1);
            uint64 b = _batchOf(r);
            _toCutoff(b);
            vm.warp(block.timestamp + k * 613);
            vm.prank(keeper);
            tel.settle(address(vault), b, _noSkip());
            (uint256 back, uint256 out) = _claim(r);
            assertGt(out + back, 0, "paid in cash, or handed back when the cash ran out");
            if (back != 0) _inKind(who, back); // the rest leaves in kind
        }
    }

    /// @dev The Fund's opening book for these tests: USDG and token A in the vault, Alice with most of the Fund.
    function _holders() internal {
        usdg.mint(address(vault), 60_000e6);
        tokA.mint(address(vault), 300e18);
        vm.prank(address(controller));
        vault.track(address(tokA));
        _join(alice, 900_000e6);
        _join(carol, 3_000e6);
    }
}

abstract contract MorphoRowsWorld is RowsBase {
    MockMorpho internal morpho;
    MockIrm internal irm;
    MorphoBlueAdapter internal mb;
    MorphoMarketRegistry internal markets;
    MarketParams[] internal mkts;
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    /// @dev `n` USDG markets against token A (distinct oracles, so distinct ids), every one reviewed, with outside
    ///      lenders and borrowers so interest runs and no share price is a round number. The Fund lends in each,
    ///      and when `borrows`, also posts token A and borrows USDG in each.
    function _world(uint256 n, bool borrows) internal {
        _setUpTeller();
        morpho = new MockMorpho();
        irm = new MockIrm();
        irm.set(uint256(0.137e18) / 365 days);
        MorphoBlueAdapter impl = new MorphoBlueAdapter(IMorpho(address(morpho)));
        if (n > impl.MAX_MARKETS()) n = impl.MAX_MARKETS();
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            MockMorphoOracle o = new MockMorphoOracle();
            o.set(100e24); // $100 a token A: 100e6 raw USDG per 1e18 raw, times 1e36
            MarketParams memory p = MarketParams(address(usdg), address(tokA), address(o), address(irm), 0.625e18);
            morpho.createMarket(p);
            mkts.push(p);
            ids[i] = morpho.id(p);
        }
        markets = new MorphoMarketRegistry(makeAddr("aindex"), IMorpho(address(morpho)), ids);
        registry.register(address(impl), "");
        vm.prank(owner);
        mb = MorphoBlueAdapter(controller.addAdapter(address(impl), abi.encode(address(markets), new bytes32[](0))));

        usdg.mint(lender, 1e16);
        tokA.mint(borrower, 1e30);
        for (uint256 i; i < n; ++i) {
            vm.startPrank(lender);
            usdg.approve(address(morpho), type(uint256).max);
            morpho.supply(mkts[i], 1_000_000e6 + i * 12_345_679, 0, lender, "");
            vm.stopPrank();
            vm.startPrank(borrower);
            tokA.approve(address(morpho), type(uint256).max);
            morpho.supplyCollateral(mkts[i], 100_000e18, borrower, "");
            morpho.borrow(mkts[i], 600_000e6 + i * 7_654_321, 0, borrower, borrower);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 37 days + 3 hours);

        // The holders join before any position is opened, so their exits test the exits alone.
        _holders();
        for (uint256 i; i < n; ++i) {
            _act(0, i, 3_000e6 + i * 1_234_567); // supply
            if (!borrows) continue;
            _act(2, i, 5e18 + i * 1e15); // collateral
            _act(4, i, 101e6 + i * 987_653); // borrow
        }
        vm.warp(block.timestamp + 5 days + 7 minutes);
    }

    function _act(uint8 kind, uint256 i, uint256 amount) internal {
        vm.prank(manager);
        controller.act(address(mb), abi.encode(kind, mkts[i], amount));
    }

    /// @dev The Fund's borrow shares across every market.
    function _borrowShares() internal view returns (uint256 s) {
        for (uint256 i; i < mkts.length; ++i) {
            (, uint256 b,) = morpho.position(morpho.id(mkts[i]), address(mb));
            s += b;
        }
    }

    /// @dev What the adapter reports in `token`, debts or assets, summed over its rows.
    function _reported(address token, bool debt) internal view returns (uint256 s, uint256 rows) {
        (Amount[] memory a, Amount[] memory d) = mb.positions(router);
        Amount[] memory list = debt ? d : a;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].token == token) {
                s += list[i].amount;
                ++rows;
            }
        }
    }
}

/// @notice USDG borrowed in seven markets (the cap when lower): a deposit grows the debt by the fraction within
///         the teller's slack. Seen on the fork: `DebtChanged`, 4 to 12 units over.
contract MorphoDebtRowsTest is MorphoRowsWorld {
    function setUp() public {
        _world(7, true);
    }

    /// Deposits into a Fund that borrows in many markets: cash in, no debt grown, nothing to round.
    function testFuzz_DepositsWithDebtAcrossMarkets(uint256 amount, uint256 wait) public {
        amount = bound(amount, 10e6, 200_000e6);
        wait = bound(wait, 0, 30 days);
        vm.warp(block.timestamp + wait);
        uint256 before = _borrowShares();
        _join(alice, amount);
        _join(bob, amount / 3 + 10e6);
        assertEq(_borrowShares(), before, "a deposit never touches the debt");
    }

    /// Exits in kind with a debt (and a supply) in every market, at odd sizes: the leaver's slice of each debt
    /// is repaid and the rest of the Fund keeps no more debt and no less supply than its share. An exit in kind
    /// is the guaranteed way out: it may never revert from rounding.
    function test_InKindExitsWithDebtInManyMarkets() public {
        _inKindSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function test_InKindExitsInPartsWithDebtInManyMarkets() public {
        _inKindPartsSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    /// Cash exits (paid from the Fund's USDG) with a debt in every market, at odd sizes.
    function test_CashExitsWithDebtInManyMarkets() public {
        _cashSeries(alice, [uint256(731), 613, 557, 409, 271]);
    }
}

/// @notice USDG lent in eight markets (the cap when lower), no debt: batches matching an entrant with a leaver and
///         paying the rest from cash, and exits in kind, at odd sizes.
contract MorphoLendRowsTest is MorphoRowsWorld {
    function setUp() public {
        _world(8, false);
    }

    /// Batch after batch at odd sizes: the entrant matched with the leaver, the rest paid from cash.
    function test_MatchAndCashLentInManyMarkets() public {
        (, uint256 rows) = _reported(address(usdg), false);
        assertEq(rows, mkts.length, "a supply in every market");
        assertGt(rows, 2, "more rows than the slack covers");
        uint256[6] memory parts = [uint256(731), 613, 557, 409, 271, 389];
        for (uint256 k; k < parts.length; ++k) {
            uint256 r = _redeem(alice, vault.balanceOf(alice) * parts[k] / 1000, 1);
            uint256 d = _deposit(bob, 10e6 + k * 333_333, 1);
            uint64 b = _batchOf(r);
            assertEq(_batchOf(d), b, "one batch");
            _toCutoff(b);
            vm.warp(block.timestamp + k * 1013);
            vm.prank(keeper);
            tel.settle(address(vault), b, _noSkip());
            (, uint256 out) = _claim(r);
            assertGt(out, 0, "the leaver was paid");
            (uint256 got,) = _claim(d);
            assertGt(got, 0, "the entrant was matched with the leaver");
        }
    }

    function test_InKindExitsLentInManyMarkets() public {
        _inKindSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function test_InKindExitsInPartsLentInManyMarkets() public {
        _inKindPartsSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function testFuzz_MatchAndCash(uint256 part, uint256 wait) public {
        uint256 sh = vault.balanceOf(alice);
        part = bound(part, 1, 999);
        vm.warp(block.timestamp + bound(wait, 0, 20 days));
        uint256 shares = sh * part / 1000;
        if (shares < tel.minDeposit() * 1e12) shares = tel.minDeposit() * 1e12;
        uint256 r = _redeem(alice, shares, 1);
        _deposit(bob, 10e6, 1);
        uint64 b = _batchOf(r);
        _toCutoff(b);
        vm.prank(keeper);
        tel.settle(address(vault), b, _noSkip());
    }
}

/// @notice A Uniswap v4 adapter with ten positions (the cap when lower) in one token A / USDG pool, at different
///         ranges: exits in kind (in one transaction and in parts) never revert from the positions' rounding. Seen
///         on the fork: an exit in kind `NotShrunk`, about 0.2 units short, with ten positions.
contract V4RowsTest is RowsBase {
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    V4Helper internal helper;
    UniswapV4LiquidityAdapter internal lp;
    PoolKey internal key;

    function setUp() public {
        _setUpTeller();
        pm = IPoolManager(V4PoolManagerCode.deploy(address(this)));
        helper = new V4Helper(pm);
        tokA.mint(address(helper), 1e30);
        usdg.mint(address(helper), 1e30);
        (address c0, address c1) = address(tokA) < address(usdg) ? (address(tokA), address(usdg)) : (address(usdg), address(tokA));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        pm.initialize(
            key,
            OraclePositionMath.sqrtPriceFromPrices(
                source.prices(c0), OraclePositionMath.decimalsOf(c0), source.prices(c1), OraclePositionMath.decimalsOf(c1)
            )
        );
        (int24 lo, int24 hi) = _range(3000);
        helper.addAmounts(key, lo, hi, c0 == address(usdg) ? 1e12 : 1e22, c0 == address(usdg) ? 1e22 : 1e12);
        UniswapV4LiquidityAdapter impl = new UniswapV4LiquidityAdapter(pm, IWETH9(address(new MockWETH())));
        registry.register(address(impl), "");
        vm.prank(owner);
        lp = UniswapV4LiquidityAdapter(payable(controller.addAdapter(address(impl), "")));

        _holders();
        uint256 n = lp.MAX_POSITIONS() < 10 ? lp.MAX_POSITIONS() : 10;
        for (uint256 i; i < n; ++i) {
            (lo, hi) = _range(int24(int256(300 + 180 * i)));
            (uint256 a0, uint256 a1) =
                c0 == address(usdg) ? (_usdgSide(i), 10e18 + i * 1e15 + 7) : (10e18 + i * 1e15 + 7, _usdgSide(i));
            vm.prank(manager);
            controller.act(address(lp), abi.encode(uint8(0), key, lo, hi, a0, a1, uint256(0), uint256(0)));
        }
        assertEq(lp.positionList().length, n);
        vm.warp(block.timestamp + 1 hours);
    }

    /// @dev The USDG each position is opened with (the A side is ample; the pool takes what the range needs).
    function _usdgSide(uint256 i) internal pure virtual returns (uint256) {
        return 1_000e6 + i * 1_234_567;
    }

    function _range(int24 half) internal view returns (int24 lo, int24 hi) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        int24 c = tick / 60;
        if (tick < 0 && tick % 60 != 0) c--;
        lo = c * 60 - (half / 60) * 60;
        hi = c * 60 + (half / 60 + 1) * 60;
    }

    function test_InKindExitsWithManyPositions() public {
        _inKindSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function test_InKindExitsInPartsWithManyPositions() public {
        _inKindPartsSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function test_CashExitsWithManyPositions() public {
        _cashSeries(alice, [uint256(731), 613, 557, 409, 271]);
    }

    function test_DepositsWithManyPositions() public {
        _join(bob, 50_000e6);
        _join(bob, 333_333e6);
    }

    function testFuzz_InKindExit(uint256 part) public {
        part = bound(part, 1, 1000);
        _inKind(alice, vault.balanceOf(alice) * part / 1000);
    }
}

/// @notice An ERC-4626 adapter with its cap of USDG vaults, share prices not round numbers: exits in kind never
///         revert from the vaults' rounding (one row of USDG each, two units of slack per row).
contract YieldRowsTest is RowsBase {
    ERC4626Adapter internal y;
    MockVault4626[] internal vs;

    function setUp() public {
        _setUpTeller();
        ERC4626Adapter impl = new ERC4626Adapter();
        registry.register(address(impl), "");
        address[] memory list = new address[](impl.MAX_VAULTS());
        for (uint256 i; i < list.length; ++i) {
            MockVault4626 v = new MockVault4626(usdg);
            vs.push(v);
            list[i] = address(v);
            // An outside depositor and some yield, so a share is not a round number of USDG.
            usdg.mint(address(this), 1_000_000e6);
            usdg.approve(address(v), type(uint256).max);
            v.deposit(777_777e6 + i * 13_579, address(this));
            v.earn(12_345_679 + i * 97);
        }
        vm.prank(owner);
        y = ERC4626Adapter(controller.addAdapter(address(impl), abi.encode(list)));
        _holders();
        for (uint256 i; i < vs.length; ++i) {
            vm.prank(manager);
            controller.act(address(y), abi.encode(uint8(0), address(vs[i]), 20_000e6 + i * 1_111_111, uint256(1)));
            vs[i].earn(3_333_331 + i * 7);
        }
    }

    function test_InKindExitsWithManyVaults() public {
        _inKindSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function test_InKindExitsInPartsWithManyVaults() public {
        _inKindPartsSeries(alice, [uint256(731), 613, 557, 409, 271, 997], carol);
    }

    function test_CashExitsWithManyVaults() public {
        _cashSeries(alice, [uint256(731), 613, 557, 409, 271]);
    }

    function testFuzz_InKindExit(uint256 part) public {
        part = bound(part, 1, 1000);
        _inKind(alice, vault.balanceOf(alice) * part / 1000);
    }
}

/// @notice Regression for the per-row slack: one v4 adapter with up to ten positions in the A / USDG pool,
///         each holding a tiny USDG side (well under a million raw units, so `GrowMath` gives it no margin and it may
///         read a unit short after an exit). With two units of slack per token those units added up past the slack
///         once three or more such ranges were open; with two units per row, exits in kind and to cash, and
///         deposits, settle. The suite above runs again on this book.
contract V4TinyRangesTest is V4RowsTest {
    function _usdgSide(uint256 i) internal pure override returns (uint256) {
        return 400_000 + i * 7_919; // 0.4 USDG and a little more each
    }

    function test_TinySidesInEveryRange() public view {
        (Amount[] memory a,) = lp.positions(router);
        uint256 rows;
        for (uint256 i; i < a.length; ++i) {
            if (a[i].token != address(usdg)) continue;
            ++rows;
            assertLt(a[i].amount, 1e6, "a tiny USDG side");
        }
        assertGe(rows, 3, "one USDG row per position: three or more");
    }

    /// Exits in kind of every size, each from the same book: with two units per token instead of per row, some
    /// of these failed `NotShrunk` on the USDG rows (about 0.3 USDG left where 2 USDG of rows were).
    function test_InKindExitAtEverySize() public {
        for (uint256 part = 1; part <= 1000; part += 37) {
            uint256 snap = vm.snapshotState();
            _inKind(alice, vault.balanceOf(alice) * part / 1000);
            vm.revertToState(snap);
        }
    }

    function test_InKindAndCashExitsWithTinyRanges() public {
        _cashSeries(alice, [uint256(731), 613, 557, 409, 271]);
        _inKindSeries(alice, [uint256(613), 731, 557, 409, 271, 997], carol);
    }
}
