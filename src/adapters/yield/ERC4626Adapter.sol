// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";

/**
 * @title  ERC4626Adapter
 * @notice Puts a Fund's tokens to work in ERC-4626 yield vaults the owner allowed (on Robinhood Chain:
 *         steakUSDG, Spark's spUSDG, and any other ERC-4626 vault named at enable time).
 *
 * @dev    ## Why the clone holds the vault shares
 *         Vault shares are a claim, not cash: the Fund's NAV should count what they redeem for, in the
 *         underlying asset the router already prices, rather than ask the router to price every vault share
 *         token. So the shares stay in this clone and are reported as a position: `previewRedeem` of the
 *         shares held, which is what redeeming them returns after any exit fee (rule 5). If a vault's preview
 *         reverts, `convertToAssets` stands in.
 *
 *         ## Trust in the vault
 *         The adapter measures everything by balance: shares minted on deposit, shares burned on withdraw,
 *         assets received on withdraw and redeem. The manager sets the bound on each (`minShares`,
 *         `maxShares`, `minAssets`), so a vault that misreports its own return values cannot move more than
 *         the manager agreed to.
 *
 *         ## Exits
 *         `unwind` redeems a fraction of every vault's shares. A vault that cannot pay right now (a Morpho
 *         vault whose markets are fully borrowed, say) is skipped with an event instead of blocking the
 *         others; its shares stay counted and can be unwound later or split in kind. `split` hands `to` its
 *         fraction of each vault's shares directly; where a vault refuses share transfers, it redeems that
 *         fraction straight to `to` instead, and reverts only if neither works, so a leaver is never quietly
 *         paid less.
 *
 *         ## Deposits into the existing mix
 *         `grow` mints the same fraction more of every vault's shares (any fraction: a batch may more than double
 *         a small Fund), paid in the asset the teller bought. See `grow`.
 */
contract ERC4626Adapter is BaseAdapter {
    using Strings for address;
    using Strings for uint256;

    error BadConfig();
    error UnknownAction(uint8 id);
    error VaultNotAllowed(address vault4626);
    error ZeroAmount();
    error TooFewShares(uint256 shares, uint256 minShares);
    error TooManyShares(uint256 shares, uint256 maxShares);
    error TooLittle(uint256 assets, uint256 minAssets);
    error BadFraction();
    error SplitFailed(address vault4626);

    event Deposited(address indexed vault4626, uint256 assets, uint256 shares);
    event Withdrawn(address indexed vault4626, uint256 assets, uint256 shares);
    event UnwindSkipped(address indexed vault4626, uint256 shares);

    uint8 public constant DEPOSIT = 0;
    uint8 public constant WITHDRAW = 1;
    uint8 public constant REDEEM = 2;
    /// @notice Most vaults one Fund may use through this adapter. `positions` runs on every action and settlement,
    ///         and an exit in kind splits every vault, so this bounds both (docs/DEPOSITS-AND-EXITS.md, "Gas").
    uint256 public constant MAX_VAULTS = 8;
    uint256 private constant WAD = 1e18;

    address[] private _vaults;
    /// @notice The underlying asset of each allowed vault (zero when not allowed). Read once at enable time:
    ///         ERC-4626 fixes a vault's asset for life.
    mapping(address => address) public assetOf;

    /// @param config abi.encode(address[] vaults): the ERC-4626 vaults this Fund may use, fixed for life.
    function _configure(bytes calldata config) internal override {
        address[] memory v = abi.decode(config, (address[]));
        if (v.length == 0 || v.length > MAX_VAULTS) revert BadConfig();
        for (uint256 i; i < v.length; ++i) {
            if (v[i].code.length == 0 || assetOf[v[i]] != address(0) || v[i] == vault) revert BadConfig();
            address a = IERC4626(v[i]).asset();
            if (a == address(0) || a == v[i]) revert BadConfig();
            assetOf[v[i]] = a;
            _vaults.push(v[i]);
        }
    }

    // ---------------------------------------------------------------- reads

    function name() external pure returns (string memory) {
        return "ERC-4626 yield v1";
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function describe() external view returns (string memory) {
        string memory list;
        for (uint256 i; i < _vaults.length; ++i) {
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                '{"vault":"',
                _vaults[i].toHexString(),
                '","asset":"',
                assetOf[_vaults[i]].toHexString(),
                '","sharesHeld":"',
                IERC20(_vaults[i]).balanceOf(address(this)).toString(),
                '"}'
            );
        }
        return string.concat(
            '{"adapter":"ERC-4626 yield v1","kind":"yield","positions":true,',
            '"about":"Deposit the vault asset into an allowed ERC-4626 vault and take it back. This adapter holds the shares; the Fund counts them at previewRedeem.",',
            '"vaults":[',
            list,
            '],"actions":[',
            '{"id":0,"name":"deposit","params":[{"name":"vault","type":"address","about":"an allowed ERC-4626 vault"},',
            '{"name":"assets","type":"uint256","about":"raw units of the vault asset pulled from the Fund"},',
            '{"name":"minShares","type":"uint256","about":"least vault shares that must be minted"}],',
            '"encoding":"abi.encode(uint8 0, address vault, uint256 assets, uint256 minShares)","returns":"abi.encode(uint256 shares)"},',
            '{"id":1,"name":"withdraw","params":[{"name":"vault","type":"address","about":"an allowed ERC-4626 vault"},',
            '{"name":"assets","type":"uint256","about":"exact raw units of the asset to take back to the Fund"},',
            '{"name":"maxShares","type":"uint256","about":"most vault shares that may be burned"}],',
            '"encoding":"abi.encode(uint8 1, address vault, uint256 assets, uint256 maxShares)","returns":"abi.encode(uint256 sharesBurned)"},',
            '{"id":2,"name":"redeem","params":[{"name":"vault","type":"address","about":"an allowed ERC-4626 vault"},',
            '{"name":"shares","type":"uint256","about":"vault shares to burn; type(uint256).max for all held"},',
            '{"name":"minAssets","type":"uint256","about":"least raw units of the asset the Fund must receive"}],',
            '"encoding":"abi.encode(uint8 2, address vault, uint256 shares, uint256 minAssets)","returns":"abi.encode(uint256 assets)"}]}'
        );
    }

    function inputs(bytes calldata action) external view returns (Amount[] memory) {
        (uint8 id, address v, uint256 amount,) = abi.decode(action, (uint8, address, uint256, uint256));
        if (id == DEPOSIT) return _one(assetOf[v], amount);
        return _none();
    }

    function outputs(bytes calldata action) external view returns (address[] memory) {
        (, address v,,) = abi.decode(action, (uint8, address, uint256, uint256));
        return _tokens1(assetOf[v]);
    }

    // ---------------------------------------------------------------- actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 id, address v, uint256 amount, uint256 bound) = abi.decode(action, (uint8, address, uint256, uint256));
        address asset = assetOf[v];
        if (asset == address(0)) revert VaultNotAllowed(v);
        if (amount == 0) revert ZeroAmount();

        if (id == DEPOSIT) {
            _pull(asset, amount);
            uint256 before = IERC20(v).balanceOf(address(this));
            _approve(asset, v, amount);
            IERC4626(v).deposit(amount, address(this));
            _approve(asset, v, 0);
            uint256 shares = IERC20(v).balanceOf(address(this)) - before;
            if (shares < bound) revert TooFewShares(shares, bound);
            _pushAll(asset); // anything the vault did not take
            emit Deposited(v, amount, shares);
            return abi.encode(shares);
        }
        if (id == WITHDRAW) {
            uint256 sharesBefore = IERC20(v).balanceOf(address(this));
            uint256 got = _received(asset, v, amount, true);
            uint256 burned = sharesBefore - IERC20(v).balanceOf(address(this));
            if (burned > bound) revert TooManyShares(burned, bound);
            if (got < amount) revert TooLittle(got, amount);
            _pushAll(asset);
            emit Withdrawn(v, got, burned);
            return abi.encode(burned);
        }
        if (id == REDEEM) {
            uint256 held = IERC20(v).balanceOf(address(this));
            uint256 shares = amount == type(uint256).max ? held : amount;
            uint256 got = _received(asset, v, shares, false);
            if (got < bound) revert TooLittle(got, bound);
            _pushAll(asset);
            emit Withdrawn(v, got, shares);
            return abi.encode(got);
        }
        revert UnknownAction(id);
    }

    /// @dev Withdraw `amount` assets or redeem `amount` shares into this adapter; returns the assets that arrived.
    function _received(address asset, address v, uint256 amount, bool byAssets) private returns (uint256) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        if (byAssets) IERC4626(v).withdraw(amount, address(this), address(this));
        else IERC4626(v).redeem(amount, address(this), address(this));
        return IERC20(asset).balanceOf(address(this)) - before;
    }

    // ---------------------------------------------------------------- positions and exits

    function positions(IPriceRouter) external view returns (Amount[] memory assets, Amount[] memory debts) {
        uint256 n = _vaults.length;
        assets = new Amount[](n);
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            uint256 shares = IERC20(v).balanceOf(address(this));
            uint256 amount;
            if (shares != 0) {
                try IERC4626(v).previewRedeem(shares) returns (uint256 a) {
                    amount = a;
                } catch {
                    amount = IERC4626(v).convertToAssets(shares);
                }
            }
            assets[i] = Amount(assetOf[v], amount);
        }
        debts = new Amount[](0);
    }

    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        uint256 n = _vaults.length;
        received = new Amount[](n);
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            address asset = assetOf[v];
            uint256 shares = _slice(v, IERC20(v).balanceOf(address(this)), fractionWad);
            received[i].token = asset;
            if (shares == 0) continue;
            uint256 before = IERC20(asset).balanceOf(address(this));
            try IERC4626(v).redeem(shares, address(this), address(this)) {
                received[i].amount = IERC20(asset).balanceOf(address(this)) - before;
                _pushAll(asset);
            } catch {
                emit UnwindSkipped(v, shares);
            }
        }
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    function split(uint256 fractionWad, address to)
        external
        onlyController
        nonReentrant
        returns (Amount[] memory sent)
    {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        if (to == address(0)) revert ZeroAddress();
        uint256 n = _vaults.length;
        sent = new Amount[](n);
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            uint256 shares = _slice(v, IERC20(v).balanceOf(address(this)), fractionWad);
            sent[i].token = v;
            if (shares == 0) continue;
            sent[i].amount = shares;
            if (_tryTransfer(v, to, shares)) continue;
            // The vault refuses share transfers (a gated vault): pay the slice in its asset instead.
            address asset = assetOf[v];
            uint256 before = IERC20(asset).balanceOf(to);
            try IERC4626(v).redeem(shares, to, address(this)) {
                sent[i] = Amount(asset, IERC20(asset).balanceOf(to) - before);
            } catch {
                revert SplitFailed(v);
            }
        }
    }

    // ---------------------------------------------------------------- deposits into the existing mix

    /**
     * @notice The vault asset `grow(fractionWad)` pulls: for every vault whose shares the Fund holds, what
     *         minting `_growShares` new shares costs now (`previewMint`, which rounds up), one entry per asset.
     */
    function growInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        (needs,,) = _growAll(fractionWad);
    }

    /// @dev Every vault's grow (shares to mint and their cost) and the inputs they sum to, worked out once for
    ///      `growInputs` and `grow` (minting in one vault moves no other vault's price; vaults are distinct).
    function _growAll(uint256 fractionWad)
        internal
        view
        returns (Amount[] memory needs, uint256[] memory shares, uint256[] memory costs)
    {
        uint256 n = _vaults.length;
        needs = new Amount[](n);
        shares = new uint256[](n);
        costs = new uint256[](n);
        uint256 rows;
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            shares[i] = _growShares(v, fractionWad);
            if (shares[i] == 0) continue;
            costs[i] = IERC4626(v).previewMint(shares[i]);
            rows = _tally(needs, rows, assetOf[v], costs[i]);
        }
        needs = _trim(needs, rows);
    }

    /**
     * @notice Grows every vault position by `fractionWad` (1e18 = double): mints at least that fraction of the
     *         shares held, paying with the asset the teller bought into the vault. No price is involved: the
     *         share count is what grows, and `positions` reads it back through the vault's own `previewRedeem`.
     * @dev    Minting exact shares (rather than depositing an asset amount) is what makes the result certain:
     *         the vault rounds what it charges up, so its share price never falls on our mint and every share we
     *         add is worth at least what the old ones were. A vault that refuses the mint (paused, capped) reverts
     *         the grow, and with it the deposit batch: the Fund cannot take new money into a mix it cannot buy.
     */
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        (Amount[] memory needs, uint256[] memory toMint, uint256[] memory costs) = _growAll(fractionWad);
        Amount[] memory pulled = _pullAll(needs);
        uint256 n = _vaults.length;
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            uint256 shares = toMint[i];
            if (shares == 0) continue;
            address asset = assetOf[v];
            uint256 cost = costs[i];
            _approve(asset, v, cost);
            IERC4626(v).mint(shares, address(this));
            _approve(asset, v, 0);
            emit Deposited(v, cost, shares);
        }
        used = _settleGrow(pulled);
    }

    /// @dev Shares to add to grow a vault position by `fractionWad`: the fraction rounded up, plus the shares one
    ///      raw unit of the asset is worth, so `previewRedeem` of the result is at least the fraction more even
    ///      after its own rounding down.
    function _growShares(address v, uint256 fractionWad) private view returns (uint256) {
        uint256 held = IERC20(v).balanceOf(address(this));
        if (held == 0 || fractionWad == 0) return 0;
        return Math.mulDiv(held, fractionWad, WAD, Math.Rounding.Ceil) + IERC4626(v).previewWithdraw(1);
    }

    // ---------------------------------------------------------------- helpers

    /**
     * @dev The shares an exit of `fractionWad` takes from vault `v`: all of them when the fraction is whole, so a
     *      full exit leaves no dust behind; otherwise the fraction rounded down, less the shares one raw unit of
     *      the asset is worth (the mirror of `_growShares`). What `positions` then reads for the remaining holders
     *      (`previewRedeem`, rounded down) is at least `(1 - f)` of what it read before in this vault, so the
     *      leaver's slice rounds against the leaver, by at most a unit, in every vault, instead of the units
     *      adding up across vaults of the same asset.
     */
    function _slice(address v, uint256 held, uint256 fractionWad) private view returns (uint256) {
        if (fractionWad == WAD) return held;
        uint256 shares = held * fractionWad / WAD;
        uint256 unit = _unitShares(v);
        return shares > unit ? shares - unit : 0;
    }

    /// @dev Shares one raw unit of the asset is worth, rounded up; a vault that cannot say is given the share
    ///      count `convertToShares` names plus one, and nothing when that fails too (the exit still goes ahead).
    function _unitShares(address v) private view returns (uint256) {
        try IERC4626(v).previewWithdraw(1) returns (uint256 s) {
            return s;
        } catch {
            try IERC4626(v).convertToShares(1) returns (uint256 s) {
                return s + 1;
            } catch {
                return 0;
            }
        }
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }
}
