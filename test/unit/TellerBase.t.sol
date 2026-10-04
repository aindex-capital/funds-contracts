// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundTestBase} from "../utils/FundTestBase.sol";
import {MockERC20, MockPriceSource} from "../utils/Mocks.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {IPriceRouter, PriceClass} from "../../src/interfaces/IPriceRouter.sol";
import {ITeller} from "../../src/interfaces/ITeller.sol";
import {IPockets} from "../../src/interfaces/IPockets.sol";
import {IClosedMarketSource} from "../../src/interfaces/IClosedMarketSource.sol";
import {Teller, IFundFactoryLike} from "../../src/core/Teller.sol";
import {Pockets} from "../../src/core/Pockets.sol";
import {FeeConfig, FundFees} from "../../src/core/Fees.sol";
import {FundVault} from "../../src/core/FundVault.sol";
import {FundController} from "../../src/core/FundController.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";

/**
 * @notice A test adapter with real positions: tokens it holds (supply), uncollected fees on them, and a debt.
 *         Honest by default (`grow` and `split` move exactly the fraction, fees are collected into the vault by
 *         any `grow`, debt grows and shrinks in ratio). Modes make it dishonest:
 *         1 grows assets by half the fraction (the other half to `sink`), 2 splits twice the fraction to the
 *         leaver, 3 grows debt twice, 4 grows no debt, 5 splits nothing (keeps the slice), 6 split reverts without
 *         data, 7 split runs out of gas.
 *         Config: abi.encode(uint8 mode, address sink). Helpers are open to tests.
 */
contract MockBook is BaseAdapter {
    uint8 public mode;
    address public sink;
    address[] public held;
    mapping(address => uint256) public amt;
    mapping(address => uint256) public fee;
    address public debtToken;
    uint256 public debt;

    function _configure(bytes calldata config) internal override {
        (mode, sink) = abi.decode(config, (uint8, address));
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    // ------------------------------------------------ test helpers (the manager's past actions)

    function seed(address token, uint256 amount) external {
        if (amt[token] == 0 && fee[token] == 0) held.push(token);
        MockERC20(token).mint(address(this), amount);
        amt[token] += amount;
    }

    function addFees(address token, uint256 amount) external {
        if (amt[token] == 0 && fee[token] == 0) held.push(token);
        MockERC20(token).mint(address(this), amount);
        fee[token] += amount;
    }

    function borrow(address token, uint256 amount) external {
        debtToken = token;
        debt += amount;
        MockERC20(token).mint(vault, amount);
    }

    // ------------------------------------------------ IAdapter

    function name() external pure returns (string memory) {
        return "Mock book";
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

    function positions(IPriceRouter) external view returns (Amount[] memory a, Amount[] memory d) {
        a = new Amount[](held.length);
        for (uint256 i; i < held.length; ++i) {
            a[i] = Amount(held[i], amt[held[i]] + fee[held[i]]);
        }
        if (debt != 0) {
            d = new Amount[](1);
            d[0] = Amount(debtToken, debt);
        }
    }

    function growInputs(uint256 f) public view returns (Amount[] memory n) {
        n = new Amount[](held.length);
        for (uint256 i; i < held.length; ++i) {
            n[i] = Amount(held[i], _up(amt[held[i]], f));
        }
    }

    function grow(uint256 f) external onlyController returns (Amount[] memory used) {
        _collect();
        used = growInputs(f);
        for (uint256 i; i < used.length; ++i) {
            address t = used[i].token;
            _pull(t, used[i].amount);
            if (mode == 1) {
                uint256 half = used[i].amount / 2;
                amt[t] += half;
                _push(t, sink, used[i].amount - half);
            } else {
                amt[t] += used[i].amount;
            }
        }
        if (debt != 0 && f != 0 && mode != 4) {
            uint256 more = _up(debt, f) * (mode == 3 ? 2 : 1);
            debt += more;
            MockERC20(debtToken).mint(vault, more);
        }
    }

    function unwindInputs(uint256 f) public view returns (Amount[] memory n) {
        if (debt == 0) return _none();
        n = _one(debtToken, _up(debt, f));
    }

    function unwind(uint256 f) external onlyController returns (Amount[] memory r) {
        _repay(f);
        r = new Amount[](held.length);
        for (uint256 i; i < held.length; ++i) {
            address t = held[i];
            uint256 x = (amt[t] + fee[t]) * f / 1e18;
            _take(t, x);
            _push(t, vault, x);
            r[i] = Amount(t, x);
        }
    }

    function split(uint256 f, address to) external onlyController returns (Amount[] memory r) {
        if (mode == 6) revert();
        if (mode == 7) {
            while (gasleft() > 0) sink = address(uint160(gasleft()));
        }
        _repay(f);
        _collect(); // the worst case: a split that also sweeps every fee into the vault
        r = new Amount[](held.length);
        if (mode == 5) return r;
        for (uint256 i; i < held.length; ++i) {
            address t = held[i];
            uint256 x = amt[t] * f / 1e18 * (mode == 2 ? 2 : 1);
            if (x > amt[t]) x = amt[t];
            amt[t] -= x;
            _push(t, to, x);
            r[i] = Amount(t, x);
        }
    }

    function _repay(uint256 f) private {
        if (debt == 0) return;
        uint256 rep = _up(debt, f);
        if (rep > debt) rep = debt;
        _pull(debtToken, rep);
        MockERC20(debtToken).burn(address(this), rep);
        debt -= rep;
    }

    function _collect() private {
        for (uint256 i; i < held.length; ++i) {
            address t = held[i];
            if (fee[t] != 0) {
                uint256 x = fee[t];
                fee[t] = 0;
                _push(t, vault, x);
            }
        }
    }

    function _take(address t, uint256 x) private {
        uint256 fromFee = x > fee[t] ? fee[t] : x;
        fee[t] -= fromFee;
        amt[t] -= x - fromFee;
    }

    function _up(uint256 x, uint256 f) private pure returns (uint256) {
        return (x * f + 1e18 - 1) / 1e18;
    }
}

/// @notice Shared setup for the teller's tests: the core, the fee contracts, the holders' pockets, a teller, a
///         router, two priced tokens and one Fund opened by its owner with 1,000 USDG (cash in at NAV: a deposit's
///         USDG goes into the vault as cash, shares are minted at the ask NAV per share).
abstract contract TellerBase is FundTestBase {
    address internal admin = address(this);
    address internal aix = makeAddr("aix");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    FeeConfig internal feeConfig;
    FundFees internal fees;
    Pockets internal pockets;
    Teller internal tel;
    MockERC20 internal tokA; // 18 decimals, $100
    MockERC20 internal tokB; // 8 decimals, $50,000
    MockBook internal bookImpl;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant STAKE = 1000e6;

    function _setUpTeller() internal {
        _setUpCore();
        tokA = new MockERC20("Token A", "A", 18);
        tokB = new MockERC20("Token B", "B", 8);
        _price(address(tokA), 100e18, PriceClass.Feed, 0);
        _price(address(tokB), 50_000e18, PriceClass.Feed, 0);
        feeConfig = new FeeConfig(admin, aix, treasury);
        fees = new FundFees(feeConfig);
        pockets = new Pockets();
        tel = new Teller(IFundFactoryLike(address(factory)), fees, IPockets(address(pockets)), admin);
        fees.wireTeller(address(tel));
        pockets.wireTeller(address(tel));
        tel.setKeeper(keeper, true);
        tel.setKeeper(address(this), true); // tests that settle directly act as a listed keeper
        bookImpl = new MockBook();
        registry.register(address(bookImpl), "");
        _openFund(0, 0);
    }

    function _openFund(uint16 mgmt, uint16 perf) internal {
        usdg.mint(owner, STAKE);
        vm.startPrank(owner);
        usdg.approve(address(tel), STAKE);
        (address v, address c) = tel.createFund("Fund", "F", _openDial(), STAKE, mgmt, perf);
        vault = FundVault(v);
        controller = FundController(c);
        controller.setManager(manager, uint64(block.timestamp + 365 days));
        vm.stopPrank();
    }

    function _book(uint8 mode) internal returns (MockBook b) {
        vm.prank(owner);
        b = MockBook(controller.addAdapter(address(bookImpl), abi.encode(mode, makeAddr("sink"))));
    }

    /// @dev Put `amount` of `token` in the vault and count it (as the manager's trades would).
    function _hold(MockERC20 token, uint256 amount) internal {
        token.mint(address(vault), amount);
        vm.prank(address(controller));
        vault.track(address(token));
    }

    // ------------------------------------------------ requests

    /// @dev `minShares` 0 stands for the loosest limit the teller accepts (one wei of share for the whole amount).
    function _deposit(address who, uint256 amount, uint256 minShares) internal returns (uint256 id) {
        if (minShares == 0) minShares = 1;
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(tel), amount);
        id = tel.requestDeposit(address(vault), amount, minShares);
        vm.stopPrank();
    }

    function _redeem(address who, uint256 shares, uint256 minUsdg) internal returns (uint256 id) {
        if (minUsdg == 0) minUsdg = 1;
        vm.startPrank(who);
        vault.approve(address(tel), shares);
        id = tel.requestRedeem(address(vault), shares, minUsdg);
        vm.stopPrank();
    }

    function _batchOf(uint256 id) internal view returns (uint64) {
        return tel.request(id).batch;
    }

    function _toCutoff(uint64 b) internal {
        ITeller.Batch memory bt = tel.batch(address(vault), b);
        if (block.timestamp < bt.cutoff) vm.warp(bt.cutoff);
    }

    // ------------------------------------------------ the keeper

    function _noSkip() internal pure returns (uint256[] memory s) {
        s = new uint256[](0);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory s) {
        s = new uint256[](1);
        s[0] = id;
    }

    function _settle(uint64 b) internal {
        _toCutoff(b);
        vm.prank(keeper);
        tel.settle(address(vault), b, _noSkip());
    }

    function _settleSkip(uint64 b, uint256[] memory skip) internal {
        _toCutoff(b);
        vm.prank(keeper);
        tel.settle(address(vault), b, skip);
    }

    function _claim(uint256 id) internal returns (uint256 shares, uint256 usdgOut) {
        (shares, usdgOut) = tel.claim(id);
    }

    /// @dev A deposit request settled and claimed: the depositor holds the shares.
    function _join(address who, uint256 amount) internal returns (uint256 shares) {
        uint256 id = _deposit(who, amount, 1);
        _settle(_batchOf(id));
        (shares,) = _claim(id);
    }

    // ------------------------------------------------ prices

    function _nav(uint8 side) internal view returns (uint256 nav) {
        (nav,) = controller.nav(side);
    }

    function _navPerShare() internal view returns (uint256) {
        return _nav(0) * WAD / vault.totalSupply();
    }

    /// @dev Shares `amount` USDG buys at the Fund's ask NAV now (USDG at $1), rounded down.
    function _sharesAtAsk(uint256 amount) internal view returns (uint256) {
        return amount * 1e12 * vault.totalSupply() / _nav(2);
    }

    /// @dev Mark `token` as a US-session token with no weekend pool (the fallback spread `closedBps`).
    function _usSession(address token, uint16 closedBps) internal {
        _session(token, closedBps, 0, 0, IClosedMarketSource(address(0)));
    }

    function _session(address token, uint16 closedBps, uint16 spreadBps, uint16 clampBps, IClosedMarketSource src)
        internal
    {
        router.proposeSession(
            token,
            PriceRouter.Session({
                usSession: true,
                closedHaircutBps: closedBps,
                closedSpreadBps: spreadBps,
                closedClampBps: clampBps,
                closedSource: src
            })
        );
        if (router.pendingSessionAt(token) != 0) {
            vm.warp(block.timestamp + router.CONFIG_DELAY());
            router.applySession(token);
        }
    }

    /// @dev Next `weekday` (0 Thursday .. 6 Wednesday, as days since epoch mod 7) at `secs` past 00:00 UTC.
    function _next(uint256 weekday, uint256 secs) internal view returns (uint256) {
        uint256 day = block.timestamp / 1 days + 1;
        while (day % 7 != weekday) ++day;
        return day * 1 days + secs;
    }

    uint256 internal constant FRI = 1;
    uint256 internal constant SAT = 2;
    uint256 internal constant SUN = 3;
    uint256 internal constant MON = 4;
}
