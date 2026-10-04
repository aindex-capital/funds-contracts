// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TellerBase, MockBook} from "./TellerBase.t.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {Amount} from "../../src/interfaces/IAdapter.sol";
import {PriceClass} from "../../src/interfaces/IPriceRouter.sol";

/**
 * @notice Teller gas with mock tokens and adapters, at a mid-sized Fund and at the caps: every counted token held,
 *         every adapter slot filled with a mock book of four tokens, every other one owing USDG, full batches of 100
 *         requests. Since deposits enter as cash a settlement reads the book and moves USDG; the heavy path is the
 *         exit in kind, done in parts at the caps. Mocks are far cheaper than live venues, so these are regression
 *         floors; the live figures are in test/fork/SettlementGas.fork.t.sol and docs/DEPOSITS-AND-EXITS.md ("Gas").
 *         Run with `forge test --match-contract TellerGas -vv` to see them.
 */
contract TellerGasTest is TellerBase {
    MockERC20[] internal toks;
    MockBook[] internal books;
    address[] internal users;
    string internal tag;

    function setUp() public {
        _setUpTeller();
        tel.setParams(10e6, 1e6, 1e18, 1e14, 500); // a one-USDG minimum, so small holders' cash exits clear it
    }

    function _build(uint256 nTokens, uint256 nAdapters) internal {
        for (uint256 i = vault.trackedTokens().length; i < nTokens; ++i) {
            MockERC20 t = new MockERC20("T", "T", 18);
            _price(address(t), 10e18, PriceClass.Feed, 50);
            _hold(t, 100e18);
            toks.push(t);
        }
        for (uint256 i; i < nAdapters; ++i) {
            MockBook b = _book(0);
            for (uint256 j; j < 4; ++j) {
                b.seed(address(toks[(i * 4 + j) % toks.length]), 20e18);
            }
            if (i % 2 == 0) b.borrow(address(usdg), 50e6);
            books.push(b);
        }
        tag = string.concat(vm.toString(nTokens), " tokens, ", vm.toString(nAdapters), " adapters");
    }

    function _settleMeasured(uint64 b, string memory what, uint256 max) internal {
        _toCutoff(b);
        vm.prank(keeper);
        uint256 g = gasleft();
        tel.settle(address(vault), b, _noSkip());
        g -= gasleft();
        emit log_named_uint(string.concat(what, ", ", tag), g);
        assertLt(g, max, what);
    }

    /// @dev 100 depositors of `each`, settled and claimed: 100 holders.
    function _holders(uint256 each) internal {
        uint64 b;
        uint256[] memory ids = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            address u = address(uint160(0x10000 + users.length));
            users.push(u);
            ids[i] = _deposit(u, each, 1);
            b = _batchOf(ids[i]);
        }
        _settleMeasured(b, "settle, 100 deposits, cash in", 4_000_000);
        for (uint256 i; i < 100; ++i) {
            _claim(ids[i]);
        }
    }

    function _measure(uint256 nTokens, uint256 nAdapters, uint256 settleMax) internal {
        _build(nTokens, nAdapters);
        _holders(200e6);

        // 50 cash leavers and 50 entrants: matched at fair, the rest minted at ask.
        uint64 b;
        for (uint256 i; i < 50; ++i) {
            address u = users[i];
            b = _batchOf(_redeem(u, vault.balanceOf(u), 1));
            _deposit(address(uint160(0x20000 + i)), 300e6, 1);
        }
        _settleMeasured(b, "settle, match plus entry (50 + 50)", settleMax);

        // 50 cash leavers with the Fund's cash short: part paid, the rest back in shares.
        uint256 spare = usdg.balanceOf(address(vault)) - 100e6;
        vm.prank(address(tel));
        vault.pay(address(usdg), address(0xdead), spare);
        for (uint256 i = 50; i < 100; ++i) {
            b = _batchOf(_redeem(users[i], vault.balanceOf(users[i]) / 2, 1));
        }
        _settleMeasured(b, "settle, 50 cash exits, cash short", settleMax);

        // An exit in kind in parts: shares and vault tokens, then each adapter's slice.
        address who = users[99];
        uint256 sh = vault.balanceOf(who);
        _bring(who, tel.inKindNeedsInParts(address(vault), sh));
        uint256 id = tel.nextExitId();
        vm.prank(who);
        uint256 g = gasleft();
        tel.startInKind(address(vault), sh, who, new address[](0));
        g -= gasleft();
        emit log_named_uint(string.concat("startInKind, ", tag), g);
        assertLt(g, 20_000_000, "startInKind");
        uint256 worst;
        for (uint256 i; i < books.length; ++i) {
            address[] memory one = new address[](1);
            one[0] = address(books[i]);
            vm.prank(who);
            g = gasleft();
            tel.claimInKind(id, one);
            g -= gasleft();
            if (g > worst) worst = g;
        }
        emit log_named_uint(string.concat("claimInKind, the heaviest adapter, ", tag), worst);
        assertLt(worst, 20_000_000, "claimInKind");
        assertEq(controller.pendingExits(), 0);

        // An exit in kind in one transaction.
        who = users[98];
        sh = vault.balanceOf(who);
        _bring(who, tel.inKindNeeds(address(vault), sh));
        vm.prank(who);
        g = gasleft();
        tel.redeemInKind(address(vault), sh, who);
        g -= gasleft();
        emit log_named_uint(string.concat("redeemInKind (one transaction), ", tag), g);

        // A pocket: a token downgraded to no market, held by the vault and one adapter (unwound whole; one that
        // owes nothing, since the cash exits above emptied the vault's USDG).
        address t = address(toks[4]);
        _price(t, 0, PriceClass.None, 0);
        address[] memory holding = new address[](1);
        holding[0] = address(books[1]);
        g = gasleft();
        tel.pocket(address(vault), t, holding, 0);
        g -= gasleft();
        emit log_named_uint(string.concat("pocket, the vault and one adapter, ", tag), g);
        assertLt(g, 20_000_000, "pocket");
    }

    function _bring(address who, Amount[] memory bring) internal {
        vm.startPrank(who);
        for (uint256 i; i < bring.length; ++i) {
            if (bring[i].amount == 0) continue;
            MockERC20(bring[i].token).mint(who, bring[i].amount);
            MockERC20(bring[i].token).approve(address(tel), bring[i].amount);
        }
        vm.stopPrank();
    }

    /// @notice A mid-sized Fund: 16 tokens, 4 adapters with positions.
    function test_GasRealistic_16Tokens4Adapters() public {
        _measure(16, 4, 2_000_000);
    }

    /// @notice The caps (40 tokens, 12 adapters). Mocks are floors: the live worst cases at these caps are measured
    ///         on a fork with real tokens and venues in test/fork/SettlementGas.fork.t.sol.
    function test_GasAtTheMaxima() public {
        _measure(vault.MAX_TRACKED(), controller.MAX_ADAPTERS(), 4_000_000);
    }
}
