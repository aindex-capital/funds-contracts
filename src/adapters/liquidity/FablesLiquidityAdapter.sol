// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {
    IFablesLedger,
    FablesRangeState,
    FablesUserPosition
} from "../../interfaces/external/fables/IFablesLedger.sol";
import {IFablesPoolRegistry} from "../../interfaces/external/fables/IFablesPoolRegistry.sol";
import {IFablesFeeDistributor} from "../../interfaces/external/fables/IFablesFeeDistributor.sol";
import {OraclePositionMath} from "./OraclePositionMath.sol";
import {GrowMath} from "./GrowMath.sol";

/// @dev The controller exposes its router publicly but IFundController does not declare it yet.
interface IControllerRouter {
    function router() external view returns (IPriceRouter);
}

/**
 * @title  FablesLiquidityAdapter
 * @notice Lets a Fund provide liquidity on Fables (fables.fi), the Uniswap v4 fee hooks on Robinhood Chain that
 *         keep their own LP ledger. The Fund's clone of this adapter holds the Fables ERC-6909 shares; tokens
 *         always come from and go back to the Fund's vault.
 *
 * @dev    ## Why the ledger and not Uniswap's PositionManager
 *         Liquidity added through the hook's ledger earns the same swap fees plus Fables points and the weekly
 *         USDG pot, and is what Fables' future gauges will recognise. The price is a claim fee (10% of fees on
 *         most pools today, 0% on ETH/USDG, GLD/USDG and SPY/USDG; 20% ceiling in bytecode) taken by the ledger
 *         before fees are credited. A Fund that only wants fees can use a plain Uniswap v4 adapter on the same
 *         pool instead.
 *
 *         ## Per-Fund settings (fixed at enable time)
 *         `abi.encode(address[] hooks, bytes32[] witnessPools, uint16 maxSpotDeviationBps)`:
 *         - `hooks`: the Fables hooks this Fund may use. Each comes with `witnessPools[i]`, a pool id that Fables'
 *           own registry lists under that hook, which proves the address is a Fables hook. Every deposit also
 *           checks that its pool is listed and active in the registry and sits on an allowed hook.
 *         - `maxSpotDeviationBps`: the owner's choice. When set, deposits and rebalances refuse to run while the
 *           pool's price is further than this from the oracle price, so the Fund does not add liquidity into a
 *           moved pool. 0 turns the guard off, the default for new Funds.
 *
 *         ## Why the spot guard can be off
 *         It is a convenience, not what keeps NAV honest. Liquidity is valued at the oracle price, and at any
 *         given price a range is worth no more than the tokens that went into it at another price, so adding
 *         into a moved pool shows as a loss in the same action and is charged to the manager's daily loss
 *         budget. A manager who wants fewer surprises sets the guard; one who wants every deposit to go
 *         through (thin pools, closed stock markets where the oracle lags the pool) leaves it off.
 *
 *         ## Valuation
 *         Each range is valued at the sqrt price implied by the router's FAIR prices of its two tokens, never at
 *         the pool's price. Fees count too: what the ledger already owes the clone, plus fees the v4 position has
 *         earned but the ledger has not collected yet, read in view from the PoolManager's fee growth and net of
 *         the claim-fee rate the next collection will charge. Fee growth only rises when someone pays real fees
 *         or donates real tokens to in-range liquidity, so it cannot be inflated without giving the Fund that
 *         value. The principal math is the shared `OraclePositionMath` used by every liquidity adapter: a
 *         worthless token takes the whole range (the worst case for an LP), and an unavailable price is shown as
 *         such so the Fund's book is marked incomplete rather than counted at a made-up price.
 *
 *         ## Exits
 *         `withdraw` cannot be paused by Fables' admin (verified in both ledger generations), so `unwind` and
 *         `split` always return principal. Fee claims can be paused for up to 7 days at a time: unwind and split
 *         try to claim, and when the claim reverts they skip it and keep going. Skipped fees stay owed to the
 *         clone in the ledger, stay counted in `positions`, and are collected by a later claim or unwind.
 *
 *         ## Deposits into the existing mix
 *         `grow` deposits the same fraction more liquidity into every range, after claiming its fees to the
 *         vault. See `grow` and GrowMath.
 *
 *         ## Not built yet: Fables ve(3,3)
 *         FABLES, veFABLES, gauges, votes and bribes launch on 2026-10-20 and are not deployed today (every hook's
 *         `ballotGate` is zero, so `stake` reverts). This adapter never stakes, which keeps every share
 *         withdrawable at all times. Action ids 5 to 15 are reserved: a later version (a new implementation, since
 *         clones cannot be upgraded) can add stake, unstake and emission claims once the contracts are live and
 *         verified, and a Fund moves to it by withdrawing here and depositing there. The internal steps are
 *         `virtual` so that version can reuse them.
 *
 *         ## Native ETH pools
 *         Refused. The ETH hooks refund unused ETH with a bare call that reverts if the receiver cannot take
 *         ETH, and Fund vaults hold ERC20s only. USDG-quoted pools are the intended venue.
 */
contract FablesLiquidityAdapter is BaseAdapter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NoHooks();
    error HookNotFables(address hook);
    error HookNotAllowed(address hook);
    error PoolNotActive(bytes32 poolId);
    error NativeNotSupported();
    error UnknownAction(uint8 id);
    error UnknownRange(uint256 rangeId);
    error TooManyRanges();
    error BadFraction();
    error BadDeviation();
    error OraclePriceUnavailable(address token);
    error PoolPriceOffOracle(uint256 deviationBps, uint256 maxBps);
    error LiquidityTooLow(uint128 liquidity, uint128 minLiquidity);
    error NoPot();
    error NothingFromPot();
    error NothingToWithdraw();

    event RangeOpened(uint256 indexed rangeId, bytes32 indexed poolId, int24 tickLower, int24 tickUpper);
    event RangeClosed(uint256 indexed rangeId);
    event Deposited(uint256 indexed rangeId, uint128 liquidity);
    event Withdrawn(uint256 indexed rangeId, uint128 liquidity, address to);
    /// @notice An exit could not withdraw its share of this range (it reverted); the range stays as it was.
    event RangeSkipped(uint256 indexed rangeId);
    event FeesClaimed(uint256 indexed rangeId, address to);
    /// @notice A fee claim reverted (usually a Fables pause) during an exit; the fees stay owed to this clone.
    event FeesClaimSkipped(uint256 indexed rangeId);
    event PotClaimed(uint256 amount);

    uint8 internal constant DEPOSIT = 0;
    uint8 internal constant WITHDRAW = 1;
    uint8 internal constant CLAIM_FEES = 2;
    uint8 internal constant REBALANCE = 3;
    uint8 internal constant CLAIM_POT = 4;

    /// @notice Most ranges one Fund holds at once. `positions` runs on every action and settlement, and an exit in
    ///         kind splits every range, so this bounds both (docs/DEPOSITS-AND-EXITS.md, "Gas").
    uint256 public constant MAX_RANGES = 6;
    /// @dev `claimFees` reads 10_000 as "no bound". Used on exits, where the skim was already taken by the
    ///      withdrawal's own sync and refusing the payout would only leave fees stranded.
    uint16 internal constant ANY_CLAIM_FEE = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Fables' pool registry, the source of truth for which pools and hooks are Fables'.
    IFablesPoolRegistry public immutable fablesRegistry;
    /// @notice The Uniswap v4 PoolManager every Fables hook on this chain uses.
    IPoolManager public immutable poolManager;
    /// @notice Fables' weekly USDG pot, or zero when the chain has none.
    IFablesFeeDistributor public immutable potDistributor;
    /// @notice The token the pot pays (USDG), or zero.
    address public immutable potToken;

    struct Range {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
    }

    // ---- per Fund (clone storage), fixed at enable time
    mapping(address => bool) public allowedHook;
    address[] internal _hooks;
    /// @notice Owner's choice at enable time: the furthest the pool price may be from the oracle price for a
    ///         deposit or rebalance, in basis points. 0 = no check.
    uint16 public maxSpotDeviationBps;

    // ---- ranges this clone holds shares in, or is still owed fees on
    Range[] internal _ranges;
    mapping(uint256 => uint256) internal _slotOf; // rangeId => index + 1

    constructor(IFablesPoolRegistry registry_, IPoolManager poolManager_, IFablesFeeDistributor distributor_) {
        if (address(registry_) == address(0) || address(poolManager_) == address(0)) revert ZeroAddress();
        fablesRegistry = registry_;
        poolManager = poolManager_;
        potDistributor = distributor_;
        potToken = address(distributor_) == address(0) ? address(0) : distributor_.token();
    }

    // ================================================================ config

    function _configure(bytes calldata config) internal override {
        (address[] memory hookList, bytes32[] memory witnessPools, uint16 maxDev) =
            abi.decode(config, (address[], bytes32[], uint16));
        if (hookList.length == 0 || hookList.length != witnessPools.length) revert NoHooks();
        if (maxDev > 10_000) revert BadDeviation(); // 0 = guard off
        for (uint256 i; i < hookList.length; ++i) {
            address hook = hookList[i];
            if (hook == address(0) || hook.code.length == 0) revert HookNotFables(hook);
            // The registry is written only by Fables' admin, so a pool it lists under this hook proves the hook
            // is Fables'. The PoolManager check stops a look-alike on another v4 deployment.
            IFablesPoolRegistry.PoolInfo memory info = fablesRegistry.poolById(PoolId.wrap(witnessPools[i]));
            if (address(info.key.hooks) != hook) revert HookNotFables(hook);
            if (IFablesLedger(hook).poolManager() != address(poolManager)) revert HookNotFables(hook);
            if (!allowedHook[hook]) {
                allowedHook[hook] = true;
                _hooks.push(hook);
            }
        }
        maxSpotDeviationBps = maxDev;
    }

    // ================================================================ views

    function name() external pure returns (string memory) {
        return "Fables liquidity v1";
    }

    function describe() external pure returns (string memory) {
        // Adjacent literals are joined at compile time: one constant string, no runtime concatenation.
        return
            '{"adapter":"Fables liquidity v1","venue":"Fables (Uniswap v4 fee hooks with an LP ledger), Robinhood Chain",'
            '"notes":"poolId is the v4 PoolId listed in the Fables registry. Ticks must be multiples of the pool tickSpacing. '
            "Fables keeps a claim fee (10% of LP fees on most pools) before crediting fees. Native ETH pools are refused. "
            "maxSpotDeviationBps is this Fund's own setting, read it with maxSpotDeviationBps(): 0 means off; otherwise "
            "deposits and rebalances revert while the pool price is further than that from the oracle. Either way, "
            'liquidity is valued at the oracle price, so adding into a moved pool shows as a loss at once.",'
            '"actions":['
            '{"id":0,"name":"deposit","params":['
            '{"name":"poolId","type":"bytes32","about":"Fables pool"},'
            '{"name":"tickLower","type":"int24","about":"range lower tick"},'
            '{"name":"tickUpper","type":"int24","about":"range upper tick"},'
            '{"name":"amount0Max","type":"uint128","about":"most currency0 to spend, raw units"},'
            '{"name":"amount1Max","type":"uint128","about":"most currency1 to spend, raw units"},'
            '{"name":"minLiquidity","type":"uint128","about":"revert if fewer liquidity units would be added"}],'
            '"encoding":"abi.encode(uint8 0, bytes32 poolId, int24 tickLower, int24 tickUpper, uint128 amount0Max, uint128 amount1Max, uint128 minLiquidity)"},'
            '{"id":1,"name":"withdraw","params":['
            '{"name":"poolId","type":"bytes32","about":"Fables pool"},'
            '{"name":"tickLower","type":"int24","about":"range lower tick"},'
            '{"name":"tickUpper","type":"int24","about":"range upper tick"},'
            '{"name":"liquidity","type":"uint128","about":"liquidity units to remove, or 0 to use fractionWad"},'
            '{"name":"fractionWad","type":"uint256","about":"share of the range to remove, 1e18 = all (used when liquidity is 0)"},'
            '{"name":"amount0Min","type":"uint128","about":"least currency0 to receive"},'
            '{"name":"amount1Min","type":"uint128","about":"least currency1 to receive"}],'
            '"encoding":"abi.encode(uint8 1, bytes32 poolId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 fractionWad, uint128 amount0Min, uint128 amount1Min)",'
            '"about":"principal goes to the vault; owed fees are claimed too when Fables allows it"},'
            '{"id":2,"name":"claimFees","params":['
            '{"name":"poolId","type":"bytes32","about":"Fables pool"},'
            '{"name":"tickLower","type":"int24","about":"range lower tick"},'
            '{"name":"tickUpper","type":"int24","about":"range upper tick"},'
            '{"name":"maxFeeBps","type":"uint16","about":"highest claim-fee rate accepted, 1000 = 10%"}],'
            '"encoding":"abi.encode(uint8 2, bytes32 poolId, int24 tickLower, int24 tickUpper, uint16 maxFeeBps)"},'
            '{"id":3,"name":"rebalance","params":['
            '{"name":"poolId","type":"bytes32","about":"Fables pool"},'
            '{"name":"fromLower","type":"int24","about":"current range lower tick"},'
            '{"name":"fromUpper","type":"int24","about":"current range upper tick"},'
            '{"name":"fractionWad","type":"uint256","about":"share of the current range to move, 1e18 = all"},'
            '{"name":"toLower","type":"int24","about":"new range lower tick"},'
            '{"name":"toUpper","type":"int24","about":"new range upper tick"},'
            '{"name":"extra0","type":"uint128","about":"extra currency0 from the vault to add"},'
            '{"name":"extra1","type":"uint128","about":"extra currency1 from the vault to add"},'
            '{"name":"minLiquidity","type":"uint128","about":"revert if the new range gets fewer liquidity units"}],'
            '"encoding":"abi.encode(uint8 3, bytes32 poolId, int24 fromLower, int24 fromUpper, uint256 fractionWad, int24 toLower, int24 toUpper, uint128 extra0, uint128 extra1, uint128 minLiquidity)",'
            '"about":"withdraws, claims fees when allowed, redeposits what fits in the new range, returns the rest to the vault"},'
            '{"id":4,"name":"claimPot","params":['
            '{"name":"cumulativeAmount","type":"uint256","about":"this adapter instance\'s cumulative entitlement in the current Fables pot root"},'
            '{"name":"proof","type":"bytes32[]","about":"Merkle proof for (adapter instance, cumulativeAmount)"}],'
            '"encoding":"abi.encode(uint8 4, uint256 cumulativeAmount, bytes32[] proof)",'
            '"about":"claims the weekly Fables USDG pot for this Fund and sends it to the vault; also sweeps pot USDG someone else claimed for it"}'
            "]}";
    }

    /// @notice The Fables hooks this Fund may use.
    function hooks() external view returns (address[] memory) {
        return _hooks;
    }

    /// @notice Ranges this clone holds shares in or is still owed fees on.
    function ranges() external view returns (Range[] memory) {
        return _ranges;
    }

    /// @notice Fables' id for a range (same formula as the ledger's `rangeId`).
    function rangeIdOf(bytes32 poolId, int24 tickLower, int24 tickUpper) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, tickLower, tickUpper)));
    }

    function inputs(bytes calldata action) external view returns (Amount[] memory a) {
        uint8 id = uint8(action[31]);
        if (id == DEPOSIT) {
            (, bytes32 poolId,,, uint128 amount0Max, uint128 amount1Max,) =
                abi.decode(action, (uint8, bytes32, int24, int24, uint128, uint128, uint128));
            // Checked here too: the controller approves inputs before `execute` runs, so a bad pool must fail first.
            PoolKey memory key = _depositableKey(poolId);
            return _two(Currency.unwrap(key.currency0), amount0Max, Currency.unwrap(key.currency1), amount1Max);
        }
        if (id == REBALANCE) {
            (, bytes32 poolId,,,,,, uint128 extra0, uint128 extra1,) = abi.decode(
                action, (uint8, bytes32, int24, int24, uint256, int24, int24, uint128, uint128, uint128)
            );
            PoolKey memory key = _depositableKey(poolId);
            return _two(Currency.unwrap(key.currency0), extra0, Currency.unwrap(key.currency1), extra1);
        }
        return _none();
    }

    function outputs(bytes calldata action) external view returns (address[] memory) {
        uint8 id = uint8(action[31]);
        if (id == CLAIM_POT) {
            if (potToken == address(0)) revert NoPot();
            return _tokens1(potToken);
        }
        (, bytes32 poolId) = abi.decode(action[:64], (uint8, bytes32));
        PoolKey memory key = _registryKey(poolId);
        return _withPot(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
    }

    /**
     * @notice What the Fund holds through Fables: every range's principal at the oracle price, its fees (owed
     *         plus collectable), one row per range and token, and any pot USDG sitting in the clone (a row of its own).
     *         Never reverts on a missing price.
     */
    function positions(IPriceRouter router) external view returns (Amount[] memory assets, Amount[] memory debts) {
        debts = new Amount[](0);
        uint256 n = _ranges.length;
        Amount[] memory rows = new Amount[](2 * n + 1);
        uint256 used;
        for (uint256 i; i < n; ++i) {
            Range memory r = _ranges[i];
            (uint256 a0, uint256 a1) = _rangeValue(r, router);
            // One row per range and token, not summed: the teller allows each row its own rounding slack.
            rows[used++] = Amount(Currency.unwrap(r.key.currency0), a0);
            rows[used++] = Amount(Currency.unwrap(r.key.currency1), a1);
        }
        if (potToken != address(0)) rows[used++] = Amount(potToken, IERC20(potToken).balanceOf(address(this)));
        assets = new Amount[](used);
        for (uint256 i; i < used; ++i) assets[i] = rows[i];
    }

    /// @notice One range's principal at the oracle price plus its fees, in raw token units.
    function rangeValue(uint256 rangeId_, IPriceRouter router) external view returns (uint256 amount0, uint256 amount1) {
        uint256 slot = _slotOf[rangeId_];
        if (slot == 0) revert UnknownRange(rangeId_);
        return _rangeValue(_ranges[slot - 1], router);
    }

    /// @notice Fees on one range the clone could claim now: owed by the ledger plus earned in v4 but not yet
    ///         collected, net of the claim fee the next collection will charge.
    function pendingFees(uint256 rangeId_) external view returns (uint256 fee0, uint256 fee1) {
        uint256 slot = _slotOf[rangeId_];
        if (slot == 0) revert UnknownRange(rangeId_);
        return _fees(_ranges[slot - 1], rangeId_);
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }

    // ================================================================ actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        uint8 id = uint8(action[31]);
        if (id == DEPOSIT) return _executeDeposit(action);
        if (id == WITHDRAW) return _executeWithdraw(action);
        if (id == CLAIM_FEES) return _executeClaimFees(action);
        if (id == REBALANCE) return _executeRebalance(action);
        if (id == CLAIM_POT) return _executeClaimPot(action);
        revert UnknownAction(id);
    }

    function _executeDeposit(bytes calldata action) internal virtual returns (bytes memory) {
        (, bytes32 poolId, int24 tickLower, int24 tickUpper, uint128 amount0Max, uint128 amount1Max, uint128 minLiq) =
            abi.decode(action, (uint8, bytes32, int24, int24, uint128, uint128, uint128));
        PoolKey memory key = _depositableKey(poolId);
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _pull(t0, amount0Max);
        _pull(t1, amount1Max);
        uint128 liquidity = _deposit(key, tickLower, tickUpper, amount0Max, amount1Max, minLiq);
        _sweep(t0, t1);
        return abi.encode(liquidity);
    }

    function _executeWithdraw(bytes calldata action) internal virtual returns (bytes memory) {
        (
            ,
            bytes32 poolId,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 fractionWad,
            uint128 amount0Min,
            uint128 amount1Min
        ) = abi.decode(action, (uint8, bytes32, int24, int24, uint128, uint256, uint128, uint128));
        uint256 rid = rangeIdOf(poolId, tickLower, tickUpper);
        uint256 index = _indexOf(rid);
        Range memory r = _ranges[index];
        if (liquidity == 0) {
            if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
            liquidity = _sharesFor(rid, fractionWad);
        }
        if (liquidity == 0) revert NothingToWithdraw();
        _withdraw(r, rid, liquidity, vault, amount0Min, amount1Min);
        _tryClaim(r, rid, vault);
        _dropIfEmpty(index);
        _sweep(Currency.unwrap(r.key.currency0), Currency.unwrap(r.key.currency1));
        return abi.encode(liquidity);
    }

    function _executeClaimFees(bytes calldata action) internal virtual returns (bytes memory) {
        (, bytes32 poolId, int24 tickLower, int24 tickUpper, uint16 maxFeeBps) =
            abi.decode(action, (uint8, bytes32, int24, int24, uint16));
        uint256 rid = rangeIdOf(poolId, tickLower, tickUpper);
        uint256 index = _indexOf(rid);
        Range memory r = _ranges[index];
        // The manager asked for it: a pause or a rate above its bound is reported, not swallowed.
        IFablesLedger(address(r.key.hooks)).claimFees(r.key, r.tickLower, r.tickUpper, vault, maxFeeBps);
        emit FeesClaimed(rid, vault);
        _dropIfEmpty(index);
        _sweep(Currency.unwrap(r.key.currency0), Currency.unwrap(r.key.currency1));
        return "";
    }

    struct RebalanceArgs {
        bytes32 poolId;
        int24 fromLower;
        int24 fromUpper;
        uint256 fractionWad;
        int24 toLower;
        int24 toUpper;
        uint128 extra0;
        uint128 extra1;
        uint128 minLiquidity;
    }

    function _executeRebalance(bytes calldata action) internal virtual returns (bytes memory) {
        // A struct of static fields encodes exactly like the flat tuple after the action id.
        RebalanceArgs memory a = abi.decode(action[32:], (RebalanceArgs));
        if (a.fractionWad == 0 || a.fractionWad > WAD) revert BadFraction();
        uint256 rid = rangeIdOf(a.poolId, a.fromLower, a.fromUpper);
        uint256 index = _indexOf(rid);
        Range memory r = _ranges[index];
        // Same guards as a fresh deposit: the pool must still be listed, active and on an allowed hook, and its
        // price near the oracle, checked BEFORE the withdrawal so the old range is not sold into a moved pool.
        PoolKey memory key = _depositableKey(a.poolId);
        _checkSpot(key);

        uint128 liquidity = _sharesFor(rid, a.fractionWad);
        if (liquidity != 0) _withdraw(r, rid, liquidity, address(this), 0, 0);
        _tryClaim(r, rid, address(this));
        _dropIfEmpty(index);

        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _pull(t0, a.extra0);
        _pull(t1, a.extra1);
        uint128 added = _deposit(
            key,
            a.toLower,
            a.toUpper,
            IERC20(t0).balanceOf(address(this)),
            IERC20(t1).balanceOf(address(this)),
            a.minLiquidity
        );
        _sweep(t0, t1);
        return abi.encode(liquidity, added);
    }

    /// @dev Anyone may claim the pot for this clone straight on the distributor, which leaves USDG sitting here.
    ///      This action claims if it can and then sweeps whatever pot token the clone holds, so both paths end in
    ///      the vault. `positions` counts that balance in the meantime, so NAV never misses it.
    function _executeClaimPot(bytes calldata action) internal virtual returns (bytes memory) {
        if (potToken == address(0)) revert NoPot();
        (, uint256 cumulative, bytes32[] memory proof) = abi.decode(action, (uint8, uint256, bytes32[]));
        bool claimed;
        try potDistributor.claim(address(this), cumulative, proof) {
            claimed = true;
        } catch {}
        uint256 amount = _pushAll(potToken);
        if (amount == 0) {
            if (!claimed) {
                // Nothing to sweep and the claim failed: surface the distributor's reason.
                potDistributor.claim(address(this), cumulative, proof);
            }
            revert NothingFromPot();
        }
        emit PotClaimed(amount);
        return abi.encode(amount);
    }

    // ================================================================ exits

    /**
     * @notice Turns `fractionWad` of every range into tokens in the vault. Principal always comes out (Fables
     *         cannot pause withdrawals). Fees are claimed when Fables allows it and skipped otherwise.
     * @dev    No price bounds: an exit must not depend on the pool being calm. The controller values what arrives.
     */
    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        address[] memory tokens = _tokenSet();
        uint256[] memory before = _balances(tokens, vault);
        for (uint256 i = _ranges.length; i > 0; --i) {
            Range memory r = _ranges[i - 1];
            uint256 rid = rangeIdOf(PoolId.unwrap(r.key.toId()), r.tickLower, r.tickUpper);
            uint128 liquidity = _exitShares(r, rid, fractionWad);
            if (liquidity != 0) _tryWithdraw(r, rid, liquidity, vault);
            // All owed fees, not a fraction: they are the vault's either way, and the ledger pays them whole.
            _tryClaim(r, rid, vault);
            _dropIfEmpty(i - 1);
        }
        for (uint256 i; i < tokens.length; ++i) _pushAll(tokens[i]);
        received = _deltas(tokens, vault, before);
    }

    /**
     * @notice In-kind exit: `to` receives `fractionWad` of every range's principal straight from Fables, the
     *         same fraction of its claimable fees, and of any pot USDG held here. The rest of the fees go to the
     *         vault. Never needs a price.
     * @dev    The leaver gets tokens rather than Fables shares: share transfers are pausable and withdrawals are
     *         not. If Fables has paused claims, the leaver's slice of unclaimed fees stays with the Fund.
     */
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        if (to == address(0)) revert ZeroAddress();
        address[] memory tokens = _tokenSet();
        uint256[] memory before = _balances(tokens, to);
        for (uint256 i = _ranges.length; i > 0; --i) {
            Range memory r = _ranges[i - 1];
            uint256 rid = rangeIdOf(PoolId.unwrap(r.key.toId()), r.tickLower, r.tickUpper);
            uint128 liquidity = _exitShares(r, rid, fractionWad);
            if (liquidity != 0) _tryWithdraw(r, rid, liquidity, to);
            _tryClaim(r, rid, address(this));
            _dropIfEmpty(i - 1);
        }
        // Fees (and any pot USDG) claimed to the clone: the leaver's fraction, the rest back to the vault.
        for (uint256 i; i < tokens.length; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal == 0) continue;
            _push(tokens[i], to, fractionWad == WAD ? bal : FullMath.mulDiv(bal, fractionWad, WAD));
            _pushAll(tokens[i]);
        }
        sent = _deltas(tokens, to, before);
    }

    // ================================================================ deposits into the existing mix

    /**
     * @notice What `grow(fractionWad)` pulls: for every range, the tokens that add its share of liquidity at the
     *         pool's current price, rounded up as v4 charges them (see GrowMath), one entry per token.
     */
    function growInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        (needs,) = _growAll(fractionWad);
    }

    /// @dev One range's grow: the shares to add and what v4 charges for them.
    struct GrowStep {
        uint128 add;
        uint256 a0;
        uint256 a1;
    }

    /// @dev Every range's grow and the inputs they sum to, worked out once for `growInputs` and `grow` (growing one
    ///      range moves no other range's plan: adding liquidity never moves a pool's price, and claiming fees
    ///      changes no shares).
    function _growAll(uint256 fractionWad) internal view returns (Amount[] memory needs, GrowStep[] memory steps) {
        uint256 n = _ranges.length;
        needs = new Amount[](2 * n);
        steps = new GrowStep[](n);
        uint256 rows;
        if (fractionWad != 0) {
            IPriceRouter router = IControllerRouter(controller).router();
            for (uint256 i; i < n; ++i) {
                Range memory r = _ranges[i];
                GrowStep memory g = steps[i];
                (g.add, g.a0, g.a1) = _growPlan(router, r, fractionWad);
                if (g.a0 != 0) rows = _tally(needs, rows, Currency.unwrap(r.key.currency0), g.a0);
                if (g.a1 != 0) rows = _tally(needs, rows, Currency.unwrap(r.key.currency1), g.a1);
            }
        }
        needs = _trim(needs, rows);
    }

    /**
     * @notice Grows every range by `fractionWad` (1e18 = double): the ledger mints that fraction more shares in
     *         the same range, paid with tokens the teller bought into the vault. Claims every range's fees, and
     *         sweeps any pot USDG held here, to the vault first.
     * @dev    Why fees are claimed first: `positions` counts principal plus fees, and only principal can grow,
     *         so the teller calls `grow(0)` (claim only) before its "before" snapshot. While Fables has claims
     *         paused the fees stay owed here and the range reads as growing by a little less than the fraction;
     *         the teller's check then fails and the batch waits for the pause to end (at most 7 days a call).
     *
     *         The owner's spot guard (`maxSpotDeviationBps`) applies as it does to every deposit: adding liquidity
     *         pays at the pool's price, and a Fund that refuses to deposit into a moved pool refuses this too.
     *         Fables can pause deposits; then `grow` reverts and the batch waits. Pools Fables has since retired
     *         are not re-checked against its registry: the range is already the Fund's, and the ledger itself
     *         decides whether it still takes deposits.
     * @return used tokens the ledger took, per token.
     */
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        // Pot USDG first, before anything is pulled, so what goes back to the vault at the end is only change.
        if (potToken != address(0)) _pushAll(potToken);
        (Amount[] memory needs, GrowStep[] memory steps) = _growAll(fractionWad);
        Amount[] memory pulled = _pullAll(needs);
        uint256 n = _ranges.length;
        for (uint256 i; i < n; ++i) {
            Range memory r = _ranges[i];
            uint256 rid = rangeIdOf(PoolId.unwrap(r.key.toId()), r.tickLower, r.tickUpper);
            _tryClaim(r, rid, vault);
            (uint128 add, uint256 a0, uint256 a1) = (steps[i].add, steps[i].a0, steps[i].a1);
            if (add == 0) continue;
            _checkSpot(r.key);
            address hook = address(r.key.hooks);
            address t0 = Currency.unwrap(r.key.currency0);
            address t1 = Currency.unwrap(r.key.currency1);
            _approve(t0, hook, a0);
            _approve(t1, hook, a1);
            IFablesLedger(hook).deposit(r.key, r.tickLower, r.tickUpper, add, _u128(a0), _u128(a1), block.timestamp);
            _approve(t0, hook, 0);
            _approve(t1, hook, 0);
            emit Deposited(rid, add);
        }
        used = _settleGrow(pulled);
        // Claimed fees go straight to the vault; ranges that held only owed fees may now be empty.
        for (uint256 i = _ranges.length; i > 0; --i) _dropIfEmpty(i - 1);
    }

    /// @dev Liquidity (shares) to add to one range and what v4 charges for it at the pool's price now.
    function _growPlan(IPriceRouter router, Range memory r, uint256 fractionWad)
        internal
        view
        returns (uint128 add, uint256 a0, uint256 a1)
    {
        uint256 rid = rangeIdOf(PoolId.unwrap(r.key.toId()), r.tickLower, r.tickUpper);
        uint128 shares = _u128(IFablesLedger(address(r.key.hooks)).balanceOf(address(this), rid));
        if (shares == 0) return (0, 0, 0);
        (uint256 fair0, uint256 fair1) = OraclePositionMath.fairAmounts(
            router, Currency.unwrap(r.key.currency0), Currency.unwrap(r.key.currency1), r.tickLower, r.tickUpper, shares
        );
        add = GrowMath.added(shares, fractionWad, fair0, fair1);
        (uint160 sqrtP,,,) = poolManager.getSlot0(r.key.toId());
        (a0, a1) = GrowMath.cost(sqrtP, r.tickLower, r.tickUpper, add);
    }

    // ================================================================ internals: Fables

    /// @dev Adds what fits of `amount0`/`amount1` (held by the clone) to the range at the pool's current price.
    ///      Liquidity is sized one raw unit under each budget, so v4's rounding up of what it charges can never
    ///      push the pull above the budget the hook is told to respect.
    function _deposit(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiquidity
    ) internal virtual returns (uint128 liquidity) {
        uint160 spot = _checkSpot(key);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            spot,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0 == 0 ? 0 : amount0 - 1,
            amount1 == 0 ? 0 : amount1 - 1
        );
        if (liquidity == 0 || liquidity < minLiquidity) revert LiquidityTooLow(liquidity, minLiquidity);

        address hook = address(key.hooks);
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _approve(t0, hook, amount0);
        _approve(t1, hook, amount1);
        IFablesLedger(hook).deposit(
            key, tickLower, tickUpper, liquidity, _u128(amount0), _u128(amount1), block.timestamp
        );
        _approve(t0, hook, 0);
        _approve(t1, hook, 0);

        uint256 rid = rangeIdOf(PoolId.unwrap(key.toId()), tickLower, tickUpper);
        _track(rid, key, tickLower, tickUpper);
        emit Deposited(rid, liquidity);
    }

    function _withdraw(Range memory r, uint256 rid, uint128 liquidity, address to, uint128 min0, uint128 min1)
        internal
        virtual
    {
        IFablesLedger(address(r.key.hooks)).withdraw(
            r.key, r.tickLower, r.tickUpper, liquidity, to, min0, min1, block.timestamp
        );
        emit Withdrawn(rid, liquidity, to);
    }

    /// @dev An exit's withdrawal from one range, on its own: one that reverts is skipped and the range stays
    ///      whole, so it never blocks the exit from every other range.
    function _tryWithdraw(Range memory r, uint256 rid, uint128 liquidity, address to) internal {
        try this.withdrawOne(r, rid, liquidity, to) {}
        catch {
            emit RangeSkipped(rid);
        }
    }

    /// @notice This adapter only (a self-call, so one range's failure can be caught): an exit's withdrawal.
    function withdrawOne(Range calldata r, uint256 rid, uint128 liquidity, address to) external {
        if (msg.sender != address(this)) revert NotController();
        _withdraw(r, rid, liquidity, to, 0, 0);
    }

    /// @dev Claims everything owed on a range to `to`, or records that Fables refused (a pause, a blocked
    ///      recipient). Never reverts, so exits and rebalances do not depend on the claim path.
    function _tryClaim(Range memory r, uint256 rid, address to) internal virtual {
        IFablesLedger hook = IFablesLedger(address(r.key.hooks));
        if (hook.balanceOf(address(this), rid) == 0) {
            FablesUserPosition memory p = hook.userPosition(rid, address(this));
            if (p.owed0 == 0 && p.owed1 == 0) return; // the ledger would revert NothingToClaim
        }
        try hook.claimFees(r.key, r.tickLower, r.tickUpper, to, ANY_CLAIM_FEE) {
            emit FeesClaimed(rid, to);
        } catch {
            emit FeesClaimSkipped(rid);
        }
    }

    function _sharesFor(uint256 rid, uint256 fractionWad) internal view returns (uint128) {
        uint256 shares = IFablesLedger(address(_ranges[_indexOf(rid)].key.hooks)).balanceOf(address(this), rid);
        return _u128(fractionWad == WAD ? shares : FullMath.mulDiv(shares, fractionWad, WAD));
    }

    /// @dev The shares an exit (`unwind`, `split`) of `fractionWad` withdraws from a range: the fraction less a
    ///      unit's worth of each token at fair prices (GrowMath.taken), so what stays reads at least `(1 - f)` of
    ///      what the range read and rounding never adds up across ranges.
    function _exitShares(Range memory r, uint256 rid, uint256 fractionWad) internal view returns (uint128) {
        uint128 shares = _u128(IFablesLedger(address(r.key.hooks)).balanceOf(address(this), rid));
        if (fractionWad >= WAD || shares == 0) return shares;
        (uint256 fair0, uint256 fair1) = OraclePositionMath.fairAmounts(
            IControllerRouter(controller).router(),
            Currency.unwrap(r.key.currency0),
            Currency.unwrap(r.key.currency1),
            r.tickLower,
            r.tickUpper,
            shares
        );
        return GrowMath.taken(shares, fractionWad, fair0, fair1);
    }

    /// @dev A pool the Fund may add liquidity to: listed and active in Fables' registry, on a hook this Fund
    ///      allows, and not native ETH.
    function _depositableKey(bytes32 poolId) internal view returns (PoolKey memory key) {
        IFablesPoolRegistry.PoolInfo memory info = fablesRegistry.poolById(PoolId.wrap(poolId));
        if (!info.active) revert PoolNotActive(poolId);
        key = info.key;
        if (!allowedHook[address(key.hooks)]) revert HookNotAllowed(address(key.hooks));
        if (Currency.unwrap(key.currency0) == address(0)) revert NativeNotSupported();
    }

    /// @dev The registry's key for a pool id; for a range already held, the stored key (which also works for a
    ///      pool Fables later retired).
    function _registryKey(bytes32 poolId) internal view returns (PoolKey memory) {
        return fablesRegistry.poolById(PoolId.wrap(poolId)).key;
    }

    /// @dev Reverts unless the pool's price is within `maxSpotDeviationBps` of the oracle price (no check when
    ///      the setting is 0). Returns the pool's sqrt price for sizing the deposit.
    function _checkSpot(PoolKey memory key) internal view returns (uint160 spot) {
        (spot,,,) = poolManager.getSlot0(key.toId());
        if (maxSpotDeviationBps == 0) return spot;
        IPriceRouter router = IControllerRouter(controller).router();
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        IPriceRouter.Quote memory q0 = router.quote(t0);
        IPriceRouter.Quote memory q1 = router.quote(t1);
        if (!q0.available || q0.fair == 0) revert OraclePriceUnavailable(t0);
        if (!q1.available || q1.fair == 0) revert OraclePriceUnavailable(t1);
        uint160 oracle = OraclePositionMath.sqrtPriceFromPrices(
            q0.fair, OraclePositionMath.decimalsOf(t0), q1.fair, OraclePositionMath.decimalsOf(t1)
        );
        uint256 dev = _priceDeviationBps(spot, oracle);
        if (dev > maxSpotDeviationBps) revert PoolPriceOffOracle(dev, maxSpotDeviationBps);
    }

    // ================================================================ internals: valuation

    /// @dev Principal at the oracle price (shared OraclePositionMath: a worthless token takes the whole range,
    ///      an unavailable price shows up as such so the Fund's book is marked incomplete), plus fees.
    function _rangeValue(Range memory r, IPriceRouter router) internal view returns (uint256 a0, uint256 a1) {
        uint256 rid = rangeIdOf(PoolId.unwrap(r.key.toId()), r.tickLower, r.tickUpper);
        uint256 shares = IFablesLedger(address(r.key.hooks)).balanceOf(address(this), rid);
        if (shares != 0) {
            (a0, a1) = OraclePositionMath.fairAmounts(
                router,
                Currency.unwrap(r.key.currency0),
                Currency.unwrap(r.key.currency1),
                r.tickLower,
                r.tickUpper,
                _u128(shares)
            );
        }
        (uint256 f0, uint256 f1) = _fees(r, rid);
        a0 += f0;
        a1 += f1;
    }

    /// @dev Fees the clone would receive from a claim now, computed the way the ledger computes them:
    ///      1. owed: already credited to the clone;
    ///      2. credited to the range's per-share accumulator since the clone's last checkpoint;
    ///      3. earned by the hook's v4 position but not yet collected, split by shares, less the claim fee.
    ///      Every step rounds down. Step 3 divides by all shares, staked or not: the ledger first sets aside the
    ///      staked shares' proportional cut and splits the rest over unstaked shares, which comes to the same
    ///      per-share amount for an unstaked holder (up to the ledger's own rounding). Nobody can stake until
    ///      Fables' gauges launch anyway.
    function _fees(Range memory r, uint256 rid) internal view returns (uint256 f0, uint256 f1) {
        IFablesLedger hook = IFablesLedger(address(r.key.hooks));
        FablesUserPosition memory p = hook.userPosition(rid, address(this));
        f0 = p.owed0;
        f1 = p.owed1;
        uint256 shares = hook.balanceOf(address(this), rid);
        if (shares == 0) return (f0, f1);
        uint256 unstaked = shares - p.staked;
        FablesRangeState memory s = hook.rangeState(rid);
        if (s.totalShares == 0 || unstaked == 0) return (f0, f1);
        f0 += FullMath.mulDiv(unstaked, s.accFee0X128 - p.checkpoint0X128, Q128);
        f1 += FullMath.mulDiv(unstaked, s.accFee1X128 - p.checkpoint1X128, Q128);

        (uint256 u0, uint256 u1) = _uncollected(r, address(hook));
        if (u0 == 0 && u1 == 0) return (f0, f1);
        uint256 keepBps = 10_000 - _min(hook.effectiveClaimFee(rid), 10_000);
        f0 += FullMath.mulDiv(u0, unstaked, s.totalShares) * keepBps / 10_000;
        f1 += FullMath.mulDiv(u1, unstaked, s.totalShares) * keepBps / 10_000;
    }

    /// @dev Fees the hook's own v4 position for this range has earned since the ledger last collected.
    function _uncollected(Range memory r, address hook) internal view returns (uint256 u0, uint256 u1) {
        PoolId pid = r.key.toId();
        (uint128 liq, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(pid, hook, r.tickLower, r.tickUpper, bytes32(0));
        if (liq == 0) return (0, 0);
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthInside(pid, r.tickLower, r.tickUpper);
        u0 = OraclePositionMath.feesEarned(g0, last0, liq);
        u1 = OraclePositionMath.feesEarned(g1, last1, liq);
    }

    // ================================================================ internals: bookkeeping

    function _track(uint256 rid, PoolKey memory key, int24 tickLower, int24 tickUpper) internal {
        if (_slotOf[rid] != 0) return;
        if (_ranges.length >= MAX_RANGES) revert TooManyRanges();
        _ranges.push(
            Range({key: key, tickLower: tickLower, tickUpper: tickUpper})
        );
        _slotOf[rid] = _ranges.length;
        emit RangeOpened(rid, PoolId.unwrap(key.toId()), tickLower, tickUpper);
    }

    /// @dev Forgets a range once the clone has no shares in it and nothing owed on it.
    function _dropIfEmpty(uint256 index) internal {
        Range memory r = _ranges[index];
        uint256 rid = rangeIdOf(PoolId.unwrap(r.key.toId()), r.tickLower, r.tickUpper);
        IFablesLedger hook = IFablesLedger(address(r.key.hooks));
        if (hook.balanceOf(address(this), rid) != 0) return;
        FablesUserPosition memory p = hook.userPosition(rid, address(this));
        if (p.owed0 != 0 || p.owed1 != 0) return;
        uint256 last = _ranges.length - 1;
        if (index != last) {
            Range memory moved = _ranges[last];
            _ranges[index] = moved;
            _slotOf[rangeIdOf(PoolId.unwrap(moved.key.toId()), moved.tickLower, moved.tickUpper)] = index + 1;
        }
        _ranges.pop();
        delete _slotOf[rid];
        emit RangeClosed(rid);
    }

    function _indexOf(uint256 rid) internal view returns (uint256) {
        uint256 slot = _slotOf[rid];
        if (slot == 0) revert UnknownRange(rid);
        return slot - 1;
    }

    /// @dev Every action ends here: nothing stays loose in the clone.
    function _sweep(address t0, address t1) internal {
        _pushAll(t0);
        _pushAll(t1);
        if (potToken != address(0) && potToken != t0 && potToken != t1) _pushAll(potToken);
    }

    /// @dev Every token the clone can hold or move: both sides of each range, and the pot token.
    function _tokenSet() internal view returns (address[] memory set) {
        uint256 n = _ranges.length;
        address[] memory buf = new address[](2 * n + 1);
        uint256 used;
        for (uint256 i; i < n; ++i) {
            used = _addToken(buf, used, Currency.unwrap(_ranges[i].key.currency0));
            used = _addToken(buf, used, Currency.unwrap(_ranges[i].key.currency1));
        }
        if (potToken != address(0)) used = _addToken(buf, used, potToken);
        set = new address[](used);
        for (uint256 i; i < used; ++i) set[i] = buf[i];
    }

    function _addToken(address[] memory buf, uint256 used, address token) private pure returns (uint256) {
        for (uint256 i; i < used; ++i) {
            if (buf[i] == token) return used;
        }
        buf[used] = token;
        return used + 1;
    }

    function _balances(address[] memory tokens, address who) private view returns (uint256[] memory b) {
        b = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) b[i] = IERC20(tokens[i]).balanceOf(who);
    }

    function _deltas(address[] memory tokens, address who, uint256[] memory before)
        private
        view
        returns (Amount[] memory d)
    {
        d = new Amount[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 nowBal = IERC20(tokens[i]).balanceOf(who);
            d[i] = Amount(tokens[i], nowBal > before[i] ? nowBal - before[i] : 0);
        }
    }

    function _withPot(address t0, address t1) private view returns (address[] memory t) {
        if (potToken == address(0) || potToken == t0 || potToken == t1) return _tokens2(t0, t1);
        t = new address[](3);
        t[0] = t0;
        t[1] = t1;
        t[2] = potToken;
    }

    function _two(address a, uint256 amountA, address b, uint256 amountB) private pure returns (Amount[] memory x) {
        x = new Amount[](2);
        x[0] = Amount(a, amountA);
        x[1] = Amount(b, amountB);
    }

    /// @dev How far two sqrt prices are apart in PRICE terms, in basis points of `ref`. Anything beyond
    ///      4x in sqrt terms reads as type(uint256).max rather than overflowing.
    function _priceDeviationBps(uint160 sqrtP, uint160 ref) private pure returns (uint256) {
        if (uint256(sqrtP) >= uint256(ref) * 4) return type(uint256).max;
        uint256 rX96 = FullMath.mulDiv(sqrtP, 1 << 96, ref);
        uint256 pX96 = FullMath.mulDiv(rX96, rX96, 1 << 96);
        uint256 diff = pX96 > (1 << 96) ? pX96 - (1 << 96) : (1 << 96) - pX96;
        return FullMath.mulDiv(diff, 10_000, 1 << 96);
    }

    function _u128(uint256 x) private pure returns (uint128) {
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
