// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {IAdapter, Amount} from "../../src/interfaces/IAdapter.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {IFundController} from "../../src/interfaces/IFundController.sol";
import {MockERC20, MockPriceSource} from "./Mocks.sol";

/// @notice Shared pieces for the core's test adapters: no positions, no unwind, no split, nothing to grow.
abstract contract FlatAdapter is BaseAdapter {
    function describe() external pure virtual returns (string memory) {
        return "{}";
    }

    function positions(IPriceRouter) external view virtual returns (Amount[] memory, Amount[] memory) {
        return (new Amount[](0), new Amount[](0));
    }

    function unwind(uint256) external virtual onlyController returns (Amount[] memory) {
        return _none();
    }

    function unwindInputs(uint256) external view virtual returns (Amount[] memory) {
        return _none();
    }

    function split(uint256, address) external virtual onlyController returns (Amount[] memory) {
        return _none();
    }

    function grow(uint256) external virtual onlyController returns (Amount[] memory) {
        return _none();
    }

    function growInputs(uint256) public view virtual returns (Amount[] memory) {
        return _none();
    }
}

/**
 * @notice An honest swap venue for any pair of mock tokens: converts at the mock source's price, less `feeBps`,
 *         by burning what it takes and minting what it gives. Config: abi.encode(source, feeBps).
 *         Action: abi.encode(tokenIn, tokenOut, amountIn).
 */
contract MockSwap is FlatAdapter {
    MockPriceSource public src;
    uint256 public feeBps;

    function _configure(bytes calldata config) internal override {
        (src, feeBps) = abi.decode(config, (MockPriceSource, uint256));
    }

    function name() external pure returns (string memory) {
        return "Mock swap";
    }

    function inputs(bytes calldata action) external pure returns (Amount[] memory) {
        (address tin,, uint256 amt) = abi.decode(action, (address, address, uint256));
        return _one(tin, amt);
    }

    function outputs(bytes calldata action) external pure returns (address[] memory) {
        (, address tout,) = abi.decode(action, (address, address, uint256));
        return _tokens1(tout);
    }

    function quoteOut(address tin, address tout, uint256 amt) public view returns (uint256) {
        uint256 usd = amt * src.prices(tin) / 10 ** IERC20Metadata(tin).decimals();
        return usd * 10 ** IERC20Metadata(tout).decimals() / src.prices(tout) * (10_000 - feeBps) / 10_000;
    }

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (address tin, address tout, uint256 amt) = abi.decode(action, (address, address, uint256));
        _pull(tin, amt);
        MockERC20(tin).burn(address(this), amt);
        uint256 out = quoteOut(tin, tout, amt);
        MockERC20(tout).mint(address(this), out);
        _pushAll(tout);
        return abi.encode(out);
    }
}

/**
 * @notice A lending market for mock tokens. Supplied tokens stay in the adapter (its position); borrowing mints
 *         the token to the vault and records a debt; repaying burns it.
 *         Actions: abi.encode(uint8 op, address token, uint256 amount) with op 0 supply, 1 withdraw, 2 borrow,
 *         3 repay.
 */
contract MockLending is FlatAdapter {
    address[] public supplied;
    address[] public borrowed;
    mapping(address => uint256) public supply;
    mapping(address => uint256) public debt;
    mapping(address => bool) public listedSupply;
    mapping(address => bool) public listedDebt;

    function name() external pure returns (string memory) {
        return "Mock lending";
    }

    function inputs(bytes calldata action) external pure returns (Amount[] memory) {
        (uint8 op, address t, uint256 amt) = abi.decode(action, (uint8, address, uint256));
        if (op == 0 || op == 3) return _one(t, amt);
        return _none();
    }

    function outputs(bytes calldata action) external pure returns (address[] memory) {
        (uint8 op, address t,) = abi.decode(action, (uint8, address, uint256));
        if (op == 1 || op == 2) return _tokens1(t);
        return new address[](0);
    }

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 op, address t, uint256 amt) = abi.decode(action, (uint8, address, uint256));
        if (op == 0) {
            _pull(t, amt);
            if (!listedSupply[t]) {
                listedSupply[t] = true;
                supplied.push(t);
            }
            supply[t] += amt;
        } else if (op == 1) {
            supply[t] -= amt;
            _push(t, vault, amt);
        } else if (op == 2) {
            if (!listedDebt[t]) {
                listedDebt[t] = true;
                borrowed.push(t);
            }
            debt[t] += amt;
            MockERC20(t).mint(vault, amt);
        } else {
            _pull(t, amt);
            debt[t] -= amt;
            MockERC20(t).burn(address(this), amt);
        }
        return "";
    }

    function positions(IPriceRouter) external view override returns (Amount[] memory a, Amount[] memory d) {
        a = new Amount[](supplied.length);
        for (uint256 i; i < supplied.length; ++i) a[i] = Amount(supplied[i], supply[supplied[i]]);
        d = new Amount[](borrowed.length);
        for (uint256 i; i < borrowed.length; ++i) d[i] = Amount(borrowed[i], debt[borrowed[i]]);
    }

    function unwindInputs(uint256 f) public view override returns (Amount[] memory n) {
        n = new Amount[](borrowed.length);
        for (uint256 i; i < borrowed.length; ++i) n[i] = Amount(borrowed[i], debt[borrowed[i]] * f / 1e18);
    }

    /// @dev Honest: every supply grows by the fraction rounded up, paid from the vault; every debt grows by the
    ///      fraction rounded up, minted to the vault (as a borrow would send it).
    function growInputs(uint256 f) public view virtual override returns (Amount[] memory n) {
        n = new Amount[](supplied.length);
        for (uint256 i; i < supplied.length; ++i) n[i] = Amount(supplied[i], _up(supply[supplied[i]], f));
    }

    function grow(uint256 f) external virtual override onlyController returns (Amount[] memory used) {
        used = growInputs(f);
        for (uint256 i; i < used.length; ++i) {
            _pull(used[i].token, used[i].amount);
            supply[used[i].token] += used[i].amount;
        }
        for (uint256 i; i < borrowed.length; ++i) {
            address t = borrowed[i];
            uint256 more = _up(debt[t], f);
            debt[t] += more;
            MockERC20(t).mint(vault, more);
        }
    }

    function _up(uint256 x, uint256 f) internal pure returns (uint256) {
        return (x * f + 1e18 - 1) / 1e18;
    }

    function unwind(uint256 f) external override onlyController returns (Amount[] memory r) {
        Amount[] memory n = unwindInputs(f);
        for (uint256 i; i < n.length; ++i) {
            _pull(n[i].token, n[i].amount);
            debt[n[i].token] -= n[i].amount;
            MockERC20(n[i].token).burn(address(this), n[i].amount);
        }
        r = new Amount[](supplied.length);
        for (uint256 i; i < supplied.length; ++i) {
            address t = supplied[i];
            uint256 x = supply[t] * f / 1e18;
            supply[t] -= x;
            _push(t, vault, x);
            r[i] = Amount(t, x);
        }
    }
}

/**
 * @notice A dishonest grower, for the teller's tests: it declares and pulls the honest `growInputs`, but grows
 *         by less than the fraction. Mode 0: supply grows by half the fraction and the other half of what it
 *         pulled goes to `sink` (theft). Mode 1: supply grows honestly, debt by only half the fraction (the new
 *         money is less levered than the old). Mode 2: grows nothing and keeps everything it pulled (loose in the
 *         adapter). Config: abi.encode(uint8 mode, address sink). Actions as `MockLending`.
 */
contract MockShortGrower is MockLending {
    uint8 public mode;
    address public sink;

    function _configure(bytes calldata config) internal override {
        (mode, sink) = abi.decode(config, (uint8, address));
    }

    function grow(uint256 f) external override onlyController returns (Amount[] memory used) {
        used = growInputs(f);
        for (uint256 i; i < used.length; ++i) {
            address t = used[i].token;
            _pull(t, used[i].amount);
            if (mode == 0) {
                uint256 half = used[i].amount / 2;
                supply[t] += half;
                _push(t, sink, used[i].amount - half);
            } else if (mode == 1) {
                supply[t] += used[i].amount;
            }
        }
        if (mode == 2) return used;
        for (uint256 i; i < borrowed.length; ++i) {
            address t = borrowed[i];
            uint256 more = mode == 1 ? _up(debt[t], f) / 2 : _up(debt[t], f);
            debt[t] += more;
            MockERC20(t).mint(vault, more);
        }
    }
}

/**
 * @notice A hostile adapter. It declares `amount` of `token` as its input (split into two entries of the same
 *         token, to check the controller sums them), records the allowance it was given, pulls only half, and either keeps it
 *         (mode 0), sends it to `sink` (mode 1), or sends it to `sink` and reports the whole declared amount as a
 *         position it does not have (mode 2, misreporting). Config: abi.encode(mode, sink).
 *         Action: abi.encode(token, amount).
 */
contract MockThief is FlatAdapter {
    uint8 public mode;
    address public sink;
    mapping(address => uint256) public claimed;
    address[] public claimedTokens;
    uint256 public seenAllowance;

    function _configure(bytes calldata config) internal override {
        (mode, sink) = abi.decode(config, (uint8, address));
    }

    function name() external pure returns (string memory) {
        return "Thief";
    }

    function inputs(bytes calldata action) external pure returns (Amount[] memory) {
        (address t, uint256 amt) = abi.decode(action, (address, uint256));
        Amount[] memory a = new Amount[](2);
        a[0] = Amount(t, amt - amt / 2);
        a[1] = Amount(t, amt / 2);
        return a;
    }

    function outputs(bytes calldata) external pure returns (address[] memory) {
        return new address[](0);
    }

    function execute(bytes calldata action) external onlyController returns (bytes memory) {
        (address t, uint256 amt) = abi.decode(action, (address, uint256));
        seenAllowance = IERC20(t).allowance(vault, address(this));
        uint256 half = amt / 2;
        _pull(t, half);
        if (mode != 0) _push(t, sink, half);
        if (mode == 2) {
            if (claimed[t] == 0) claimedTokens.push(t);
            claimed[t] += amt;
        }
        return "";
    }

    /// @dev Tries to take more than it was approved, or a token it never declared. Must fail.
    function grab(address token, uint256 amount) external {
        IERC20(token).transferFrom(vault, sink, amount);
    }

    function positions(IPriceRouter) external view override returns (Amount[] memory a, Amount[] memory d) {
        a = new Amount[](claimedTokens.length);
        for (uint256 i; i < claimedTokens.length; ++i) a[i] = Amount(claimedTokens[i], claimed[claimedTokens[i]]);
        d = new Amount[](0);
    }
}

/**
 * @notice An adapter whose `positions` misbehaves on demand: 0 fine, 1 reverts, 2 burns all gas, 3 returns
 *         malformed data, 4 reports a held amount of `token`, 5 reports an absurd amount. Config: abi.encode(token).
 */
contract MockBroken is FlatAdapter {
    uint8 public how;
    address public token;
    uint256 public amount;

    function _configure(bytes calldata config) internal override {
        token = abi.decode(config, (address));
    }

    function set(uint8 how_, uint256 amount_) external {
        how = how_;
        amount = amount_;
    }

    function name() external pure returns (string memory) {
        return "Broken";
    }

    function inputs(bytes calldata) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }

    function outputs(bytes calldata) external pure returns (address[] memory) {
        return new address[](0);
    }

    function execute(bytes calldata) external view onlyController returns (bytes memory) {
        return "";
    }

    function positions(IPriceRouter) external view override returns (Amount[] memory a, Amount[] memory d) {
        if (how == 1) revert("broken");
        if (how == 2) {
            uint256 x;
            while (true) x++;
        }
        if (how == 3) {
            assembly {
                mstore(0, 0x40)
                mstore(32, 0xffffffffffff)
                return(0, 64)
            }
        }
        if (how == 4 || how == 5) {
            a = new Amount[](1);
            a[0] = Amount(token, how == 5 ? type(uint256).max / 3 : amount);
        }
        d = new Amount[](0);
    }
}

/// @notice A teller stand-in that anyone may drive, to show the vault refuses teller calls mid-action.
contract OpenTeller {
    function mint(address vault, address to, uint256 shares) external {
        (bool ok, bytes memory ret) = vault.call(abi.encodeWithSignature("mint(address,uint256)", to, shares));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @notice Tries to re-enter the controller and the vault from inside `execute`, and records what happened.
///         Config: abi.encode(teller).
contract MockReenter is FlatAdapter {
    OpenTeller public teller;
    bool public sawActing;
    bool public actBlocked;
    bool public approveBlocked;
    bool public mintBlocked;
    bool public settingBlocked;

    function _configure(bytes calldata config) internal override {
        teller = abi.decode(config, (OpenTeller));
    }

    function name() external pure returns (string memory) {
        return "Reenter";
    }

    function inputs(bytes calldata) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }

    function outputs(bytes calldata) external pure returns (address[] memory) {
        return new address[](0);
    }

    function execute(bytes calldata) external onlyController returns (bytes memory) {
        IFundController c = IFundController(controller);
        sawActing = c.isActing();
        try c.act(address(this), "") {} catch {
            actBlocked = true;
        }
        (bool ok,) = vault.call(abi.encodeWithSignature("approveFor(address,address,uint256)", vault, address(this), 1));
        approveBlocked = !ok;
        try teller.mint(vault, address(this), 1e18) {} catch {
            mintBlocked = true;
        }
        (ok,) = controller.call(abi.encodeWithSignature("applyPendingDial()"));
        settingBlocked = !ok;
        return "";
    }
}
