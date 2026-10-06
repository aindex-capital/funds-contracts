// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseAdapter} from "../../BaseAdapter.sol";
import {OraclePositionMath} from "../OraclePositionMath.sol";
import {Amount} from "../../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../../interfaces/IPriceRouter.sol";
import {IUniswapV3Factory} from "../../../interfaces/external/uniswap/IUniswapV3.sol";
import {IBeefyClmVault, IBeefyClmStrategy, IUniswapV3PoolKeyed, IClmFees} from "../../../interfaces/external/beefy/IBeefyClm.sol";

/**
 * @title  ClmVaultAdapter
 * @notice Holds shares of managed concentrated liquidity vaults for a Fund: Beefy's CLM vaults and those of its fork
 *         Arrowfarm, which run two Uniswap v3 ranges per pair (on Robinhood Chain mostly stock/USDG pairs) and move
 *         them as the price moves. The Fund earns the pool fees without managing ranges itself.
 *
 * @dev    ## Which vaults
 *         Both vault factories are permissionless: anyone can clone a vault, give it a strategy and point it at any pool.
 *         So a vault is allowed only when, at enable time, every link checks out on chain:
 *         - the vault's strategy names the vault back, and was made by a trusted strategy factory;
 *         - the strategy and the vault are owned by that family's known owners (Beefy's, or Arrowfarm's), which is
 *           what stops a stranger's strategy from the same factory passing, as `createStrategy` is open to anyone;
 *         - the strategy's pool is the canonical Uniswap v3 pool for its pair and fee (the factory's `getPool`), and
 *           the vault's two tokens are that pool's.
 *         The families are fixed in the implementation (constructor), so every Fund's clone checks against the same
 *         trusted addresses. Deposits check again that the strategy and both owners are still those, so new money never
 *         enters a vault whose control has moved; withdrawals always work.
 *
 *         ## Value
 *         Never the vault's `balances()`: it reads the pool's current price, which one transaction can move. Each
 *         vault's two ranges are read from the pool by key and valued at the PriceRouter's fair prices
 *         (`OraclePositionMath`), plus the strategy's idle tokens and the fees the pool already owes it, less the profit
 *         still locked (which a withdrawal would not pay), less the vault's withdraw fee; then this clone's share of
 *         the vault's supply. Fees the pool has not yet credited are left out, so the figure is a floor. One row per
 *         token per vault (rule 7).
 *
 *         ## Sandwiches
 *         The vaults' own guard is `isCalm()`: the pool's price is near its short time-weighted average. Deposits,
 *         withdrawals and growing refuse when a vault is not calm; an unwind skips such a vault (an event says so) and
 *         its shares stay counted. A split hands over share tokens, which needs no price. Beefy's strategy also
 *         refuses a withdrawal in the same second as any deposit (`DepositTooRecent`); an unwind then skips that vault
 *         the same way, and a later one takes it.
 *
 *         Rewards: Beefy's reward pools for these vaults pay nothing on Robinhood Chain (checked 2026-10-05: no reward
 *         tokens), so this adapter does not stake.
 */
contract ClmVaultAdapter is BaseAdapter {
    using Strings for address;
    using Strings for uint256;

    struct Family {
        address strategyFactory;
        address strategyOwner;
        address vaultOwner;
    }

    struct VaultInfo {
        address strategy;
        address pool;
        address token0;
        address token1;
        uint8 family; // 1-based: 0 means not allowed
    }

    error BadConfig();
    error NotTrusted(address vault);
    error UnknownAction(uint8 id);
    error VaultNotAllowed(address vault);
    error NotCalm(address vault);
    error ZeroAmount();
    error TooFewShares(uint256 shares, uint256 minShares);
    error BadFraction();
    error SplitFailed(address vault);

    event Deposited(address indexed clmVault, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdrawn(address indexed clmVault, uint256 amount0, uint256 amount1, uint256 shares);
    event UnwindSkipped(address indexed clmVault, uint256 shares);

    uint8 public constant DEPOSIT = 0;
    uint8 public constant WITHDRAW = 1;
    /// @notice Most vaults one Fund may use: `positions` runs on every action and settlement (about 20 reads a vault).
    uint256 public constant MAX_VAULTS = 12;
    /// @notice What `growInputs` adds on top of the proportional amounts, for the vaults' entry fees (Arrowfarm 0.2%,
    ///         Beefy's fee on an off-ratio deposit) and rounding. The vault takes only what it needs; the rest goes back.
    uint256 public constant GROW_BUFFER_BPS = 100;
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    IUniswapV3Factory public immutable v3Factory;
    address public immutable factoryA;
    address public immutable strategyOwnerA;
    address public immutable vaultOwnerA;
    address public immutable factoryB;
    address public immutable strategyOwnerB;
    address public immutable vaultOwnerB;

    address[] private _vaults;
    mapping(address => VaultInfo) public infoOf;

    /// @param a the first trusted family (Beefy on Robinhood Chain)
    /// @param b the second (Arrowfarm); a zero strategy factory leaves it unused
    constructor(IUniswapV3Factory v3Factory_, Family memory a, Family memory b) {
        if (address(v3Factory_) == address(0) || a.strategyFactory == address(0)) revert BadConfig();
        v3Factory = v3Factory_;
        factoryA = a.strategyFactory;
        strategyOwnerA = a.strategyOwner;
        vaultOwnerA = a.vaultOwner;
        factoryB = b.strategyFactory;
        strategyOwnerB = b.strategyOwner;
        vaultOwnerB = b.vaultOwner;
    }

    /// @param config abi.encode(address[] vaults): the CLM vaults this Fund may use, fixed for life; each must pass the
    ///        origin checks in the header.
    function _configure(bytes calldata config) internal override {
        address[] memory v = abi.decode(config, (address[]));
        if (v.length == 0 || v.length > MAX_VAULTS) revert BadConfig();
        for (uint256 i; i < v.length; ++i) {
            address cv = v[i];
            if (cv.code.length == 0 || infoOf[cv].family != 0 || cv == vault) revert BadConfig();
            address s = IBeefyClmVault(cv).strategy();
            if (s.code.length == 0 || IBeefyClmStrategy(s).vault() != cv) revert NotTrusted(cv);
            uint8 fam = _familyOf(cv, s);
            if (fam == 0) revert NotTrusted(cv);
            address pool = IBeefyClmStrategy(s).pool();
            (address t0, address t1) = IBeefyClmVault(cv).wants();
            if (
                pool.code.length == 0 || IUniswapV3PoolKeyed(pool).token0() != t0 || IUniswapV3PoolKeyed(pool).token1() != t1
                    || IBeefyClmStrategy(s).lpToken0() != t0 || IBeefyClmStrategy(s).lpToken1() != t1
                    || v3Factory.getPool(t0, t1, IUniswapV3PoolKeyed(pool).fee()) != pool
            ) revert NotTrusted(cv);
            infoOf[cv] = VaultInfo(s, pool, t0, t1, fam);
            _vaults.push(cv);
        }
    }

    /// @dev The family whose factory made `s` and whose owners own `s` and `cv`; 0 for none.
    function _familyOf(address cv, address s) private view returns (uint8) {
        address f = IBeefyClmStrategy(s).factory();
        address so = IBeefyClmStrategy(s).owner();
        address vo = IBeefyClmVault(cv).owner();
        if (f == factoryA && so == strategyOwnerA && vo == vaultOwnerA) return 1;
        if (factoryB != address(0) && f == factoryB && so == strategyOwnerB && vo == vaultOwnerB) return 2;
        return 0;
    }

    /// @dev Still the strategy it was enabled with, under the same family's owners: new money only goes in then.
    function _stillTrusted(address cv, VaultInfo memory info) private view returns (bool) {
        return IBeefyClmVault(cv).strategy() == info.strategy && _familyOf(cv, info.strategy) == info.family;
    }

    // ---------------------------------------------------------------- reads

    function name() external pure returns (string memory) {
        return "Managed liquidity (Beefy CLM) v1";
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function describe() external view returns (string memory) {
        string memory list;
        for (uint256 i; i < _vaults.length; ++i) {
            address cv = _vaults[i];
            VaultInfo memory info = infoOf[cv];
            bool calm;
            try IBeefyClmVault(cv).isCalm() returns (bool c) {
                calm = c;
            } catch {}
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                '{"vault":"', cv.toHexString(), '","family":"', info.family == 1 ? "Beefy" : "Arrowfarm",
                '","token0":"', info.token0.toHexString(), '","token1":"', info.token1.toHexString(),
                '","pool":"', info.pool.toHexString(), '","sharesHeld":"', IERC20(cv).balanceOf(address(this)).toString(),
                '","calm":', calm ? "true" : "false", "}"
            );
        }
        return string.concat(
            '{"adapter":"Managed liquidity (Beefy CLM) v1","kind":"liquidity","positions":true,',
            '"about":"Put both tokens of a pair into a managed Uniswap v3 vault (Beefy or Arrowfarm) that keeps the ranges in place, and take them back. ',
            "The vault takes what its ranges need and the rest comes back: while its ranges are lopsided a vault may take only one of its two tokens (offer both, or check which one it takes by offering a little first). Arrowfarm keeps a 0.2% deposit fee; Beefy charges about 0.25% on a one-sided deposit. ",
            "Deposits and withdrawals refuse when the vault is not calm (its pool moved away from its short average), so wait and retry. ",
            'The Fund counts its shares at fair prices from the vault ranges, never at the pool price.",',
            '"vaults":[', list, '],"actions":[',
            '{"id":0,"name":"deposit","params":[{"name":"vault","type":"address","about":"an allowed CLM vault"},',
            '{"name":"amount0Max","type":"uint256","about":"most raw units of token0 to offer; the unused part returns to the Fund"},',
            '{"name":"amount1Max","type":"uint256","about":"most raw units of token1 to offer; the unused part returns to the Fund"},',
            '{"name":"minShares","type":"uint256","about":"least vault shares that must be minted"}],',
            '"encoding":"abi.encode(uint8 0, address vault, uint256 amount0Max, uint256 amount1Max, uint256 minShares)","returns":"abi.encode(uint256 shares)"},',
            '{"id":1,"name":"withdraw","params":[{"name":"vault","type":"address","about":"an allowed CLM vault"},',
            '{"name":"shares","type":"uint256","about":"vault shares to burn; type(uint256).max for all held"},',
            '{"name":"min0","type":"uint256","about":"least raw units of token0 the Fund must receive"},',
            '{"name":"min1","type":"uint256","about":"least raw units of token1 the Fund must receive"}],',
            '"encoding":"abi.encode(uint8 1, address vault, uint256 shares, uint256 min0, uint256 min1)","returns":"abi.encode(uint256 amount0, uint256 amount1)"}]}'
        );
    }

    function inputs(bytes calldata action) external view returns (Amount[] memory a) {
        (uint8 id, address cv, uint256 x, uint256 y,) = abi.decode(action, (uint8, address, uint256, uint256, uint256));
        if (id != DEPOSIT) return _none();
        VaultInfo memory info = infoOf[cv];
        a = new Amount[](2);
        a[0] = Amount(info.token0, x);
        a[1] = Amount(info.token1, y);
    }

    function outputs(bytes calldata action) external view returns (address[] memory) {
        (, address cv,,,) = abi.decode(action, (uint8, address, uint256, uint256, uint256));
        VaultInfo memory info = infoOf[cv];
        return _tokens2(info.token0, info.token1);
    }

    // ---------------------------------------------------------------- actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 id, address cv, uint256 x, uint256 y, uint256 z) = abi.decode(action, (uint8, address, uint256, uint256, uint256));
        VaultInfo memory info = infoOf[cv];
        if (info.family == 0) revert VaultNotAllowed(cv);
        if (!IBeefyClmVault(cv).isCalm()) revert NotCalm(cv);

        if (id == DEPOSIT) {
            if (x == 0 && y == 0) revert ZeroAmount();
            if (!_stillTrusted(cv, info)) revert NotTrusted(cv);
            _pull(info.token0, x);
            _pull(info.token1, y);
            uint256 shares = _deposit(cv, info, x, y, z);
            return abi.encode(shares);
        }
        if (id == WITHDRAW) {
            uint256 held = IERC20(cv).balanceOf(address(this));
            uint256 shares = x == type(uint256).max ? held : x;
            if (shares == 0) revert ZeroAmount();
            (uint256 got0, uint256 got1) = _withdraw(cv, info, shares, y, z);
            _pushAll(info.token0);
            _pushAll(info.token1);
            return abi.encode(got0, got1);
        }
        revert UnknownAction(id);
    }

    /// @dev Offer `x` and `y` (already in this clone), keep the shares, send back what the vault did not take.
    function _deposit(address cv, VaultInfo memory info, uint256 x, uint256 y, uint256 minShares) private returns (uint256 shares) {
        uint256 before = IERC20(cv).balanceOf(address(this));
        uint256 b0 = IERC20(info.token0).balanceOf(address(this));
        uint256 b1 = IERC20(info.token1).balanceOf(address(this));
        _approve(info.token0, cv, x);
        _approve(info.token1, cv, y);
        IBeefyClmVault(cv).deposit(x, y, minShares);
        _approve(info.token0, cv, 0);
        _approve(info.token1, cv, 0);
        shares = IERC20(cv).balanceOf(address(this)) - before;
        if (shares < minShares || shares == 0) revert TooFewShares(shares, minShares);
        emit Deposited(cv, b0 - IERC20(info.token0).balanceOf(address(this)), b1 - IERC20(info.token1).balanceOf(address(this)), shares);
        _pushAll(info.token0);
        _pushAll(info.token1);
    }

    /// @dev Burn `shares` into this clone; returns what arrived (the caller sends it on).
    function _withdraw(address cv, VaultInfo memory info, uint256 shares, uint256 min0, uint256 min1)
        private
        returns (uint256 got0, uint256 got1)
    {
        uint256 b0 = IERC20(info.token0).balanceOf(address(this));
        uint256 b1 = IERC20(info.token1).balanceOf(address(this));
        IBeefyClmVault(cv).withdraw(shares, min0, min1);
        got0 = IERC20(info.token0).balanceOf(address(this)) - b0;
        got1 = IERC20(info.token1).balanceOf(address(this)) - b1;
        emit Withdrawn(cv, got0, got1, shares);
    }

    // ---------------------------------------------------------------- positions and exits

    function positions(IPriceRouter router) external view returns (Amount[] memory assets, Amount[] memory debts) {
        uint256 n = _vaults.length;
        assets = new Amount[](2 * n);
        for (uint256 i; i < n; ++i) {
            address cv = _vaults[i];
            VaultInfo memory info = infoOf[cv];
            (uint256 a0, uint256 a1) = _held(router, cv, info, IERC20(cv).balanceOf(address(this)));
            assets[2 * i] = Amount(info.token0, a0);
            assets[2 * i + 1] = Amount(info.token1, a1);
        }
        debts = new Amount[](0);
    }

    /// @notice What `shares` of `cv` are worth in its two tokens at the router's fair prices (see the header).
    function valueOf(IPriceRouter router, address cv, uint256 shares) external view returns (uint256, uint256) {
        VaultInfo memory info = infoOf[cv];
        if (info.family == 0) revert VaultNotAllowed(cv);
        return _held(router, cv, info, shares);
    }

    function _held(IPriceRouter router, address cv, VaultInfo memory info, uint256 shares)
        private
        view
        returns (uint256 a0, uint256 a1)
    {
        if (shares == 0) return (0, 0);
        uint256 supply = IBeefyClmVault(cv).totalSupply();
        if (supply == 0) return (0, 0);
        (uint256 t0, uint256 t1) = _vaultTotals(router, info);
        a0 = Math.mulDiv(t0, shares, supply);
        a1 = Math.mulDiv(t1, shares, supply);
        uint256 fee = _withdrawFeeBps(cv);
        if (fee != 0) {
            a0 = a0 * (BPS - fee) / BPS;
            a1 = a1 * (BPS - fee) / BPS;
        }
    }

    /// @dev Everything the vault's holders own, at fair prices: idle, both ranges, owed fees, less locked profit.
    function _vaultTotals(IPriceRouter router, VaultInfo memory info) private view returns (uint256 t0, uint256 t1) {
        IBeefyClmStrategy s = IBeefyClmStrategy(info.strategy);
        (t0, t1) = s.balancesOfThis();
        (bytes32 kMain, bytes32 kAlt) = s.getKeys();
        (int24 lo, int24 hi) = s.positionMain();
        (uint256 m0, uint256 m1) = _range(router, info, kMain, lo, hi);
        t0 += m0;
        t1 += m1;
        if (kAlt != kMain) {
            (lo, hi) = s.positionAlt();
            (m0, m1) = _range(router, info, kAlt, lo, hi);
            t0 += m0;
            t1 += m1;
        }
        (uint256 l0, uint256 l1) = s.lockedProfit();
        t0 = t0 > l0 ? t0 - l0 : 0;
        t1 = t1 > l1 ? t1 - l1 : 0;
    }

    function _range(IPriceRouter router, VaultInfo memory info, bytes32 key, int24 lo, int24 hi)
        private
        view
        returns (uint256 x, uint256 y)
    {
        (uint128 liquidity,,, uint128 owed0, uint128 owed1) = IUniswapV3PoolKeyed(info.pool).positions(key);
        (x, y) = OraclePositionMath.fairAmounts(router, info.token0, info.token1, lo, hi, liquidity);
        x += owed0;
        y += owed1;
    }

    /// @dev Arrowfarm's withdraw fee in basis points; Beefy's vaults have none (the call reverts, which reads as 0).
    function _withdrawFeeBps(address cv) private view returns (uint256) {
        try IClmFees(cv).withdrawFee() returns (uint256 f) {
            if (f == 0) return 0;
            uint256 den = BPS;
            try IClmFees(cv).FEE_DENOMINATOR() returns (uint256 d) {
                if (d != 0) den = d;
            } catch {}
            uint256 bps = f * BPS / den;
            return bps > BPS ? BPS : bps;
        } catch {
            return 0;
        }
    }

    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        uint256 n = _vaults.length;
        received = new Amount[](2 * n);
        for (uint256 i; i < n; ++i) {
            address cv = _vaults[i];
            VaultInfo memory info = infoOf[cv];
            received[2 * i].token = info.token0;
            received[2 * i + 1].token = info.token1;
            uint256 shares = _slice(IERC20(cv).balanceOf(address(this)), fractionWad);
            if (shares == 0) continue;
            bool calm;
            try IBeefyClmVault(cv).isCalm() returns (bool c) {
                calm = c;
            } catch {}
            if (!calm) {
                emit UnwindSkipped(cv, shares);
                continue;
            }
            uint256 b0 = IERC20(info.token0).balanceOf(address(this));
            uint256 b1 = IERC20(info.token1).balanceOf(address(this));
            try IBeefyClmVault(cv).withdraw(shares, 0, 0) {
                received[2 * i].amount = IERC20(info.token0).balanceOf(address(this)) - b0;
                received[2 * i + 1].amount = IERC20(info.token1).balanceOf(address(this)) - b1;
                emit Withdrawn(cv, received[2 * i].amount, received[2 * i + 1].amount, shares);
                _pushAll(info.token0);
                _pushAll(info.token1);
            } catch {
                emit UnwindSkipped(cv, shares);
            }
        }
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    /**
     * @notice In-kind exit: hands `to` its slice of each vault's share tokens. Where a vault refuses the transfer, it
     *         withdraws that slice and sends `to` the two tokens instead (two rows); reverts only if neither works.
     */
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        if (to == address(0)) revert ZeroAddress();
        uint256 n = _vaults.length;
        sent = new Amount[](2 * n);
        for (uint256 i; i < n; ++i) {
            address cv = _vaults[i];
            VaultInfo memory info = infoOf[cv];
            sent[2 * i].token = cv;
            sent[2 * i + 1].token = info.token1;
            uint256 shares = _slice(IERC20(cv).balanceOf(address(this)), fractionWad);
            if (shares == 0) continue;
            if (_tryTransfer(cv, to, shares)) {
                sent[2 * i].amount = shares;
                continue;
            }
            uint256 b0 = IERC20(info.token0).balanceOf(address(this));
            uint256 b1 = IERC20(info.token1).balanceOf(address(this));
            try IBeefyClmVault(cv).withdraw(shares, 0, 0) {
                uint256 g0 = IERC20(info.token0).balanceOf(address(this)) - b0;
                uint256 g1 = IERC20(info.token1).balanceOf(address(this)) - b1;
                _push(info.token0, to, g0);
                _push(info.token1, to, g1);
                sent[2 * i] = Amount(info.token0, g0);
                sent[2 * i + 1] = Amount(info.token1, g1);
            } catch {
                revert SplitFailed(cv);
            }
        }
    }

    // ---------------------------------------------------------------- deposits into the existing mix

    /**
     * @notice What `grow(fractionWad)` offers, per token. For each vault the Fund holds, the shares to add are the fraction
     *         of the shares held, rounded up. The offer is sized with the vault's own `previewDeposit`: the vault's
     *         current holdings in proportion when that mints enough; otherwise the one token the vault takes right now
     *         (a CLM vault may accept a single side while its ranges are lopsided: measured on 2026-10-05, Beefy's
     *         GLD vault took only USDG and Arrowfarm's NVDA vault only NVDA), enough of it alone to mint the shares.
     *         Plus `GROW_BUFFER_BPS`. The vault takes what it needs and `grow` sends the rest back to the Fund.
     */
    function growInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        (needs,,,) = _growAll(fractionWad);
    }

    function _growAll(uint256 fractionWad)
        private
        view
        returns (Amount[] memory needs, uint256[] memory toMint, uint256[] memory offer0, uint256[] memory offer1)
    {
        uint256 n = _vaults.length;
        needs = new Amount[](2 * n);
        toMint = new uint256[](n);
        offer0 = new uint256[](n);
        offer1 = new uint256[](n);
        uint256 rows;
        if (fractionWad == 0) return (_trim(needs, 0), toMint, offer0, offer1);
        for (uint256 i; i < n; ++i) {
            address cv = _vaults[i];
            uint256 held = IERC20(cv).balanceOf(address(this));
            if (held == 0) continue;
            VaultInfo memory info = infoOf[cv];
            toMint[i] = Math.mulDiv(held, fractionWad, WAD, Math.Rounding.Ceil) + 1;
            (offer0[i], offer1[i]) = _sizeOffer(cv, toMint[i]);
            rows = _tally(needs, rows, info.token0, offer0[i]);
            rows = _tally(needs, rows, info.token1, offer1[i]);
        }
        needs = _trim(needs, rows);
    }

    /// @dev Token amounts that make `cv` mint at least `shares`, with the buffer: in proportion when the vault takes both
    ///      that way, else the accepted side alone (shares are linear in what the vault takes).
    function _sizeOffer(address cv, uint256 shares) private view returns (uint256 x, uint256 y) {
        uint256 supply = IBeefyClmVault(cv).totalSupply();
        (uint256 b0, uint256 b1) = IBeefyClmVault(cv).balances();
        x = _buffered(Math.mulDiv(b0, shares, supply, Math.Rounding.Ceil) + 1);
        y = _buffered(Math.mulDiv(b1, shares, supply, Math.Rounding.Ceil) + 1);
        (uint256 both,,,,) = IBeefyClmVault(cv).previewDeposit(x, y);
        if (both >= shares) return (x, y);
        (uint256 s0,,,,) = IBeefyClmVault(cv).previewDeposit(x, 0);
        (uint256 s1,,,,) = IBeefyClmVault(cv).previewDeposit(0, y);
        // Whichever side mints more per offer, scaled to mint `shares` alone; both when neither is accepted (grow then
        // reverts in the vault, which is the honest answer).
        if (s0 >= s1 && s0 != 0) return (_buffered(Math.mulDiv(x, shares, s0, Math.Rounding.Ceil)), 0);
        if (s1 != 0) return (0, _buffered(Math.mulDiv(y, shares, s1, Math.Rounding.Ceil)));
    }

    function _buffered(uint256 amount) private pure returns (uint256) {
        return Math.mulDiv(amount, BPS + GROW_BUFFER_BPS, BPS, Math.Rounding.Ceil) + 1;
    }

    /**
     * @notice `grow(0)` does nothing (the vaults compound their own fees). `grow(f)` adds at least `f` more shares to
     *         every vault the Fund holds, from tokens the teller bought, and sends back what the vaults did not take.
     *         Reverts when a vault is not calm or no longer trusted: the Fund cannot take new money into a mix it
     *         cannot buy.
     */
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        if (fractionWad == 0) return _none();
        (Amount[] memory needs, uint256[] memory toMint, uint256[] memory offer0, uint256[] memory offer1) = _growAll(fractionWad);
        Amount[] memory pulled = _pullAll(needs);
        uint256 n = _vaults.length;
        for (uint256 i; i < n; ++i) {
            if (toMint[i] == 0) continue;
            address cv = _vaults[i];
            VaultInfo memory info = infoOf[cv];
            if (!IBeefyClmVault(cv).isCalm()) revert NotCalm(cv);
            if (!_stillTrusted(cv, info)) revert NotTrusted(cv);
            uint256 before = IERC20(cv).balanceOf(address(this));
            _approve(info.token0, cv, offer0[i]);
            _approve(info.token1, cv, offer1[i]);
            IBeefyClmVault(cv).deposit(offer0[i], offer1[i], toMint[i]);
            _approve(info.token0, cv, 0);
            _approve(info.token1, cv, 0);
            uint256 got = IERC20(cv).balanceOf(address(this)) - before;
            if (got < toMint[i]) revert TooFewShares(got, toMint[i]);
            emit Deposited(cv, offer0[i], offer1[i], got);
        }
        used = _settleGrow(pulled);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev An exit's shares: all of them for a whole exit, else the fraction rounded down (against the leaver).
    function _slice(uint256 held, uint256 fractionWad) private pure returns (uint256) {
        return fractionWad == WAD ? held : held * fractionWad / WAD;
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }
}
