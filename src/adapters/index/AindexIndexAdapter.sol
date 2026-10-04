// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {IFolio} from "../../interfaces/external/folio/IFolio.sol";
import {IIndexZap, IIndexFactory} from "../../interfaces/external/aindex/IIndexZap.sol";
import {IWETH9} from "../../interfaces/external/uniswap/IWETH9.sol";

/**
 * @title  AindexIndexAdapter
 * @notice Lets a Fund hold AINDEX index shares (Reserve Folios): mint them at backing from basket tokens the
 *         Fund already holds, redeem them back into the basket, or buy and sell a whole index for one token
 *         (USDG or WETH) through AINDEX's IndexZap.
 *
 * @dev    ## Index shares sit in the vault, not here
 *         An index share is an ordinary ERC-20 the Fund can transfer, so it lives in the vault like any token
 *         and leaves in kind like any token. This adapter only runs actions; it holds nothing between calls
 *         and reports no positions. The Fund values index shares through the PriceRouter, configured with
 *         `IndexNavSource` for each index: a look-through price from the basket one share redeems for.
 *
 *         ## Outputs list the whole basket
 *         Redeem returns every basket token, and mint or a zap can hand back leftovers of any of them, so
 *         `outputs` reads the basket from the index at the time of the action and declares all of it. A
 *         token the vault was not tracking starts being counted before any of it arrives.
 *
 *         ## Mint and redeem are exact, the zap is bounded
 *         Mint pulls exactly `toAssets(shares, Ceil)` (what the controller approved, read in the same
 *         transaction) and redeem pays `toAssets(shares, Floor)`, both at backing with no swap. The zap runs a
 *         Universal Router plan built off chain; the adapter measures what arrived against `minSharesOut` or
 *         `minOut` and returns every leftover to the vault. The plan runs as the zap against the zap's own
 *         balances, so it cannot reach the Fund's other tokens.
 *
 *         ## Native ETH
 *         Funds hold WETH, not ETH. The zap is always paid in an ERC-20 and sells only into an ERC-20. But the
 *         plans AINDEX's API builds end by unwrapping leftover WETH and the zap refunds that dust to its caller
 *         as native ETH (seen on a fork 2026-10-01: 2.8e12 wei on a $30 buy). So the adapter accepts ETH from
 *         the zap only, and wraps whatever it holds into WETH before the call ends, which goes to the vault
 *         with the other leftovers (WETH is always among the declared outputs of a zap action).
 *
 *         ## Which indexes
 *         Fixed per Fund at enable time: an explicit list, or, when the list is empty, any index the AINDEX
 *         IndexFactory created (checked through the zap's factory).
 */
contract AindexIndexAdapter is BaseAdapter {
    using Strings for address;

    error BadConfig();
    error UnknownAction(uint8 id);
    error IndexNotAllowed(address index);
    error ZeroAmount();
    error NativeNotSupported();
    error NoZap();
    error TooLittle(uint256 received, uint256 minimum);

    event Minted(address indexed index, uint256 shares, uint256 received);
    event Redeemed(address indexed index, uint256 shares);
    event ZapBought(address indexed index, address payToken, uint256 payAmount, uint256 shares);
    event ZapSold(address indexed index, uint256 shares, address outToken, uint256 received);

    uint8 public constant MINT = 0;
    uint8 public constant REDEEM = 1;
    uint8 public constant ZAP_BUY = 2;
    uint8 public constant ZAP_SELL = 3;
    uint256 public constant MAX_INDEXES = 16;
    uint8 private constant FLOOR = 0;
    uint8 private constant CEIL = 1;

    /// @notice AINDEX's IndexZap for one-token buys and sells; zero disables the zap actions.
    IIndexZap public zap;
    /// @notice The AINDEX IndexFactory, from the zap, when any of its indexes is allowed.
    IIndexFactory public factory;
    address[] private _indexes;
    mapping(address => bool) private _listed;

    struct ZapBuy {
        address index;
        uint256 shares;
        uint256 minSharesOut;
        address payToken;
        uint256 payAmount;
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    struct ZapSell {
        address index;
        uint256 shares;
        address outToken;
        uint256 minOut;
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    /// @param config abi.encode(address zap, address[] indexes). An empty list allows every index the zap's
    ///        factory created (needs a zap). A zero zap allows only mint and redeem of the listed indexes.
    function _configure(bytes calldata config) internal override {
        (address zap_, address[] memory list) = abi.decode(config, (address, address[]));
        if (list.length > MAX_INDEXES) revert BadConfig();
        if (zap_ != address(0)) {
            if (zap_.code.length == 0) revert BadConfig();
            zap = IIndexZap(zap_);
            if (list.length == 0) factory = IIndexFactory(IIndexZap(zap_).factory());
        } else if (list.length == 0) {
            revert BadConfig();
        }
        for (uint256 i; i < list.length; ++i) {
            if (list[i].code.length == 0 || _listed[list[i]]) revert BadConfig();
            _listed[list[i]] = true;
            _indexes.push(list[i]);
        }
    }

    // ---------------------------------------------------------------- reads

    function name() external pure returns (string memory) {
        return "AINDEX index v1";
    }

    function indexes() external view returns (address[] memory) {
        return _indexes;
    }

    function isAllowed(address index) public view returns (bool) {
        if (_listed[index]) return true;
        return address(factory) != address(0) && factory.isIndex(index);
    }

    function describe() external view returns (string memory) {
        string memory list;
        for (uint256 i; i < _indexes.length; ++i) {
            list = string.concat(list, i == 0 ? '"' : ',"', _indexes[i].toHexString(), '"');
        }
        return string.concat(
            '{"adapter":"AINDEX index v1","kind":"index","positions":false,',
            '"about":"Hold AINDEX index shares in the vault. Mint at backing from basket tokens (toAssets(shares, Ceil) is pulled), redeem to the basket, or buy and sell with one ERC-20 through IndexZap using a Universal Router plan built with the zap as recipient. Native ETH is not supported: pay and receive WETH.",',
            '"zap":"',
            address(zap).toHexString(),
            '","indexes":',
            address(factory) != address(0) ? '"any AINDEX factory index"' : string.concat("[", list, "]"),
            ',"actions":[',
            '{"id":0,"name":"mint","params":[{"name":"index","type":"address"},{"name":"shares","type":"uint256","about":"shares before the mint fee"},{"name":"minSharesOut","type":"uint256","about":"least shares after the fee"}],',
            '"encoding":"abi.encode(uint8 0, address index, uint256 shares, uint256 minSharesOut)","returns":"abi.encode(uint256 sharesReceived)"},',
            '{"id":1,"name":"redeem","params":[{"name":"index","type":"address"},{"name":"shares","type":"uint256"},{"name":"minAmountsOut","type":"uint256[]","about":"per basket token in basket order, or empty for no minimum"}],',
            '"encoding":"abi.encode(uint8 1, address index, uint256 shares, uint256[] minAmountsOut)","returns":"abi.encode(uint256[] amounts)"},',
            '{"id":2,"name":"zapBuy","params":[{"name":"index","type":"address"},{"name":"shares","type":"uint256"},{"name":"minSharesOut","type":"uint256"},{"name":"payToken","type":"address","about":"USDG or WETH"},{"name":"payAmount","type":"uint256"},{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],',
            '"encoding":"abi.encode(uint8 2, address index, uint256 shares, uint256 minSharesOut, address payToken, uint256 payAmount, bytes commands, bytes[] inputs, uint256 deadline)","returns":"abi.encode(uint256 sharesReceived)"},',
            '{"id":3,"name":"zapSell","params":[{"name":"index","type":"address"},{"name":"shares","type":"uint256"},{"name":"outToken","type":"address","about":"USDG or WETH"},{"name":"minOut","type":"uint256"},{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],',
            '"encoding":"abi.encode(uint8 3, address index, uint256 shares, address outToken, uint256 minOut, bytes commands, bytes[] inputs, uint256 deadline)","returns":"abi.encode(uint256 received)"}]}'
        );
    }

    function inputs(bytes calldata action) external view returns (Amount[] memory a) {
        (uint8 id, address index, uint256 shares) = abi.decode(action, (uint8, address, uint256));
        if (id == MINT) {
            (address[] memory assets, uint256[] memory amounts) = IFolio(index).toAssets(shares, CEIL);
            a = new Amount[](assets.length);
            for (uint256 i; i < assets.length; ++i) {
                a[i] = Amount(assets[i], amounts[i]);
            }
            return a;
        }
        if (id == REDEEM || id == ZAP_SELL) return _one(index, shares);
        if (id == ZAP_BUY) {
            ZapBuy memory b = _zapBuy(action);
            if (b.payToken == address(0)) revert NativeNotSupported(); // the vault has no ETH to approve
            return _one(b.payToken, b.payAmount);
        }
        revert UnknownAction(id);
    }

    function outputs(bytes calldata action) external view returns (address[] memory) {
        (uint8 id, address index) = abi.decode(action, (uint8, address));
        if (id == MINT) return _withBasket(index, _tokens1(index));
        if (id == REDEEM) return _withBasket(index, new address[](0));
        if (id == ZAP_BUY) return _withBasket(index, _zapExtras(index, _zapBuy(action).payToken));
        if (id == ZAP_SELL) return _withBasket(index, _zapExtras(index, _zapSell(action).outToken));
        revert UnknownAction(id);
    }

    // ---------------------------------------------------------------- actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 id, address index, uint256 shares) = abi.decode(action, (uint8, address, uint256));
        if (!isAllowed(index)) revert IndexNotAllowed(index);
        if (shares == 0) revert ZeroAmount();
        if (id == MINT) {
            (,,, uint256 minSharesOut) = abi.decode(action, (uint8, address, uint256, uint256));
            return _mint(index, shares, minSharesOut);
        }
        if (id == REDEEM) {
            (,,, uint256[] memory mins) = abi.decode(action, (uint8, address, uint256, uint256[]));
            return _redeem(index, shares, mins);
        }
        if (id == ZAP_BUY) return _buy(_zapBuy(action));
        if (id == ZAP_SELL) return _sell(_zapSell(action));
        revert UnknownAction(id);
    }

    function _mint(address index, uint256 shares, uint256 minSharesOut) private returns (bytes memory) {
        (address[] memory assets, uint256[] memory amounts) = IFolio(index).toAssets(shares, CEIL);
        for (uint256 i; i < assets.length; ++i) {
            _pull(assets[i], amounts[i]);
            _approve(assets[i], index, amounts[i]);
        }
        uint256 before = IERC20(index).balanceOf(address(this));
        IFolio(index).mint(shares, address(this), minSharesOut);
        uint256 got = IERC20(index).balanceOf(address(this)) - before;
        if (got < minSharesOut) revert TooLittle(got, minSharesOut);
        for (uint256 i; i < assets.length; ++i) {
            _approve(assets[i], index, 0);
            _pushAll(assets[i]);
        }
        _pushAll(index);
        emit Minted(index, shares, got);
        return abi.encode(got);
    }

    function _redeem(address index, uint256 shares, uint256[] memory mins) private returns (bytes memory) {
        _pull(index, shares);
        (address[] memory assets,) = IFolio(index).toAssets(shares, FLOOR);
        if (mins.length == 0) mins = new uint256[](assets.length);
        uint256[] memory amounts = IFolio(index).redeem(shares, address(this), assets, mins);
        for (uint256 i; i < assets.length; ++i) {
            _pushAll(assets[i]);
        }
        emit Redeemed(index, shares);
        return abi.encode(amounts);
    }

    /// @dev Only the zap's refund of leftover ETH; wrapped in the same call (see Native ETH).
    receive() external payable {
        if (msg.sender != address(zap) || address(zap) == address(0)) revert NativeNotSupported();
    }

    function _wrapEth(IIndexZap z) private {
        uint256 bal = address(this).balance;
        if (bal != 0) IWETH9(z.weth()).deposit{value: bal}();
    }

    function _buy(ZapBuy memory b) private returns (bytes memory) {
        IIndexZap z = _needZap();
        if (b.payToken == address(0)) revert NativeNotSupported();
        if (b.payAmount == 0) revert ZeroAmount();
        _pull(b.payToken, b.payAmount);
        _approve(b.payToken, address(z), b.payAmount);
        uint256 before = IERC20(b.index).balanceOf(address(this));
        z.buy(b.index, b.shares, b.minSharesOut, b.payToken, b.payAmount, b.commands, b.inputs, b.deadline);
        _approve(b.payToken, address(z), 0);
        _wrapEth(z);
        uint256 got = IERC20(b.index).balanceOf(address(this)) - before;
        if (got < b.minSharesOut) revert TooLittle(got, b.minSharesOut);
        _pushEverything(b.index, b.payToken);
        emit ZapBought(b.index, b.payToken, b.payAmount, got);
        return abi.encode(got);
    }

    function _sell(ZapSell memory s) private returns (bytes memory) {
        IIndexZap z = _needZap();
        if (s.outToken == address(0)) revert NativeNotSupported();
        _pull(s.index, s.shares);
        _approve(s.index, address(z), s.shares);
        uint256 before = IERC20(s.outToken).balanceOf(address(this));
        z.sell(s.index, s.shares, s.outToken, s.minOut, s.commands, s.inputs, s.deadline);
        _approve(s.index, address(z), 0);
        _wrapEth(z);
        uint256 got = IERC20(s.outToken).balanceOf(address(this)) - before;
        if (got < s.minOut) revert TooLittle(got, s.minOut);
        _pushEverything(s.index, s.outToken);
        emit ZapSold(s.index, s.shares, s.outToken, got);
        return abi.encode(got);
    }

    // ---------------------------------------------------------------- positions: none (shares live in the vault)

    function positions(IPriceRouter) external pure returns (Amount[] memory assets, Amount[] memory debts) {
        return (new Amount[](0), new Amount[](0));
    }

    function unwind(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    function split(uint256, address) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    /// @notice Index shares the Fund holds sit in the vault as tokens, not here, so a deposit grows them by the
    ///         teller buying more of them; this adapter has nothing of its own to grow.
    function grow(uint256) external view onlyController returns (Amount[] memory) {
        return _none();
    }

    function growInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    // ---------------------------------------------------------------- helpers

    function _needZap() private view returns (IIndexZap z) {
        z = zap;
        if (address(z) == address(0)) revert NoZap();
    }

    /// @dev Everything a zap call can leave here: the index, the pay or out token, WETH, USDG and the basket.
    function _pushEverything(address index, address token) private {
        address[] memory all = _withBasket(index, _zapExtras(index, token));
        for (uint256 i; i < all.length; ++i) {
            _pushAll(all[i]);
        }
    }

    function _zapExtras(address index, address token) private view returns (address[] memory t) {
        t = new address[](4);
        t[0] = index;
        t[1] = token;
        t[2] = address(zap) == address(0) ? index : zap.weth();
        t[3] = address(zap) == address(0) ? index : zap.usdg();
    }

    /// @dev `head` followed by every basket token of `index` (read now, the same transaction as the action).
    function _withBasket(address index, address[] memory head) private view returns (address[] memory t) {
        (address[] memory assets,) = IFolio(index).totalAssets();
        t = new address[](head.length + assets.length);
        for (uint256 i; i < head.length; ++i) {
            t[i] = head[i];
        }
        for (uint256 i; i < assets.length; ++i) {
            t[head.length + i] = assets[i];
        }
    }

    function _zapBuy(bytes calldata action) private pure returns (ZapBuy memory b) {
        (, b.index, b.shares, b.minSharesOut, b.payToken, b.payAmount, b.commands, b.inputs, b.deadline) =
            abi.decode(action, (uint8, address, uint256, uint256, address, uint256, bytes, bytes[], uint256));
    }

    function _zapSell(bytes calldata action) private pure returns (ZapSell memory s) {
        (, s.index, s.shares, s.outToken, s.minOut, s.commands, s.inputs, s.deadline) =
            abi.decode(action, (uint8, address, uint256, address, uint256, bytes, bytes[], uint256));
    }
}
