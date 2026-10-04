// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {IWETH9} from "../../interfaces/external/uniswap/IWETH9.sol";
import {OraclePositionMath} from "./OraclePositionMath.sol";
import {GrowMath, IRouterHolder} from "./GrowMath.sol";

/**
 * @title  UniswapV4LiquidityAdapter
 * @notice Lets a Fund provide concentrated liquidity on Uniswap v4, in hookless pools and in pools whose
 *         hook leaves liquidity providers alone (Pons pools, AINDEX share markets). The Fund's clone owns
 *         its positions in the PoolManager directly.
 *
 * @dev    ## Why the PoolManager and not the PositionManager
 *         Both reach the same pools. We talk to the PoolManager through its unlock callback because:
 *         - Nothing sits between the Fund and the contract that holds the money. The PositionManager adds
 *           a second contract and Permit2 allowances to every add, and each is something to trust and to
 *           leave approved by mistake. Here every token goes straight to the PoolManager in the same call.
 *         - Valuation reads the very storage the actions write (the PoolManager's position record), not a
 *           copy kept by a periphery.
 *         - It is the pattern our LiquidityLocker already uses and that was reviewed.
 *         What we give up: positions are not NFTs, so they do not show in wallets, and a hook that only
 *         admits the PositionManager as a liquidity provider refuses us (cleanly, see below).
 *
 *         Each position is the clone's own position in the PoolManager, keyed by its range and a salt; the
 *         salt is the position's id here (1, 2, 3, ...).
 *
 *         ## Actions (`execute(abi.encode(uint8 id, ...))`, also listed in `describe()`)
 *         0 mint       new position in an initialised pool, from tokens in the vault
 *         1 increase   add tokens from the vault to one of our positions
 *         2 decrease   remove liquidity; what comes out, fees included, goes to the vault
 *         3 collect    send a position's fees to the vault
 *         4 rebalance  in one unlock: remove all of a position and add a new range in the same pool from what
 *                      came out; whatever does not fit goes to the vault
 *
 *         ## Hooks
 *         A hook runs code around every pool operation. We refuse a pool at mint if its hook can touch an
 *         exit or take a cut of liquidity: the before or after remove-liquidity permissions, or either
 *         liquidity "returns delta" permission. Those could block an unwind or make it return less than
 *         `positions` reported, and an exit must always work at the reported value. Hooks that act only on
 *         swaps, initialisation, donations or adds are accepted. A hook that refuses our add reverts the
 *         mint with `HookRefusedLiquidity` instead of an opaque error.
 *
 *         ## Native ether
 *         The Fund keeps ether as WETH. For a pool whose currency0 is native ether, the adapter unwraps
 *         exactly what it pulled for the call, pays the pool in ether, and wraps everything that comes back
 *         before sending it to the vault. `positions` reports native ether as WETH, which is what unwinding
 *         delivers.
 *
 *         ## Valuation, and where the pool's price still matters
 *         As in the v3 adapter: positions at the router's fair prices (OraclePositionMath) plus fees earned,
 *         read from the PoolManager's fee growth counters. Adding liquidity pays at the pool's price, which
 *         the controller's loss budget and the manager's minimums bound; removing it never trades, so
 *         `unwind` and `split` need no minimums.
 *
 *         ## Deposits into the existing mix
 *         `grow` adds the same fraction of liquidity to every position, in the same range, with its fees going
 *         to the vault. See `grow` and GrowMath.
 *
 *         ## Limits
 *         - At most `MAX_POSITIONS` positions per Fund (the controller reads `positions` under a gas cap).
 *         - No pool creation: whoever initialises a pool picks its price.
 *         - Hook data is always empty.
 *         - Tokens that charge a fee on transfer are not supported (settling reverts).
 *
 *         ## Per-Fund setting
 *         `config` is empty (any pool that passes the hook check) or `abi.encode(bytes32[] poolIds)`: the only
 *         pools this Fund may open positions in. Fixed for the clone's life.
 */
contract UniswapV4LiquidityAdapter is BaseAdapter, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error UnknownAction(uint8 id);
    error UnknownPosition(uint256 id);
    error PoolNotAllowed(bytes32 poolId);
    error PoolNotInitialized(bytes32 poolId);
    error HookNotSupported(address hooks);
    error HookRefusedLiquidity(address hooks, bytes reason);
    error TooManyPositions();
    error ZeroLiquidity();
    error BelowMinimum(uint256 amount0, uint256 amount1);
    error UnauthorizedCallback();
    error UnexpectedEther();

    event PositionOpened(uint256 indexed id, bytes32 indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionClosed(uint256 indexed id);
    /// @notice An exit could not take its share of this position (it reverted); the position stays as it was.
    event PositionSkipped(uint256 indexed id);

    uint8 internal constant MINT = 0;
    uint8 internal constant INCREASE = 1;
    uint8 internal constant DECREASE = 2;
    uint8 internal constant COLLECT = 3;
    uint8 internal constant REBALANCE = 4;

    // What the unlock callback is asked to do.
    uint8 private constant OP_ADD = 0;
    uint8 private constant OP_REMOVE = 1;
    uint8 private constant OP_MOVE = 2;
    uint8 private constant OP_GROW = 3;

    /// @notice Most positions one Fund holds here. `positions` runs on every action and settlement, and an exit in
    ///         kind splits every position, so this bounds both (docs/DEPOSITS-AND-EXITS.md, "Gas").
    uint256 public constant MAX_POSITIONS = 10;
    uint256 private constant WAD = 1e18;

    /// @notice Hook permissions that could block an exit or skim liquidity: refused.
    uint160 public constant UNSAFE_HOOK_FLAGS = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    IPoolManager public immutable poolManager;
    IWETH9 public immutable weth;

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 id; // also the salt in the PoolManager
    }

    /// @dev Action parameters after the id. All static, so `abi.decode(action[32:], (MintArgs))` reads them.
    struct MintArgs {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 min0;
        uint256 min1;
    }

    struct RebalanceArgs {
        uint256 id;
        int24 tickLower;
        int24 tickUpper;
        uint256 outMin0;
        uint256 outMin1;
        uint256 inMin0;
        uint256 inMin1;
    }

    /// @dev What one unlock did. `out` is liquidity taken out, `in_` liquidity put in, both fees excluded.
    struct Result {
        uint128 liquidity; // added
        uint256 out0;
        uint256 out1;
        uint256 fees0;
        uint256 fees1;
        uint256 in0;
        uint256 in1;
    }

    struct Op {
        uint8 kind;
        PoolKey key;
        int24 lower; // the range removed from (REMOVE, MOVE) or added to (ADD)
        int24 upper;
        bytes32 salt;
        uint128 removeLiquidity; // REMOVE, MOVE; for GROW, the exact liquidity to add
        uint256 max0; // ADD
        uint256 max1;
        int24 newLower; // MOVE
        int24 newUpper;
        bytes32 newSalt;
    }

    Position[] internal _positions;
    uint256 public lastId;
    bool public restricted;
    mapping(bytes32 => bool) public poolAllowed;

    /// @dev Set only for the length of our own `unlock`, so the callback answers nothing else.
    bool private transient _unlocking;

    constructor(IPoolManager poolManager_, IWETH9 weth_) {
        poolManager = poolManager_;
        weth = weth_;
    }

    function _configure(bytes calldata config) internal override {
        if (config.length == 0) return;
        bytes32[] memory ids = abi.decode(config, (bytes32[]));
        restricted = true;
        for (uint256 i; i < ids.length; ++i) poolAllowed[ids[i]] = true;
    }

    /// @dev Ether arrives only from WETH (unwrapping) and the PoolManager (taking native ether).
    receive() external payable {
        if (msg.sender != address(weth) && msg.sender != address(poolManager)) revert UnexpectedEther();
    }

    // ---------------------------------------------------------------- descriptions

    function name() external pure returns (string memory) {
        return "Uniswap v4 liquidity v1";
    }

    function describe() external pure returns (string memory) {
        return string.concat(
            string.concat(
                '{"adapter":"Uniswap v4 liquidity v1","notes":"key is the v4 PoolKey (currency0, currency1, fee, tickSpacing, hooks); native ether is address(0) in the key and WETH in the vault; position ids are uint256","actions":[',
                '{"id":0,"name":"mint","about":"open a position in an initialised pool whose hook does not touch removals","params":[',
                '{"name":"key","type":"tuple(address,address,uint24,int24,address)"},{"name":"tickLower","type":"int24"},{"name":"tickUpper","type":"int24"},',
                '{"name":"amount0","type":"uint256","about":"most currency0 to add, raw units"},{"name":"amount1","type":"uint256"},'
            ),
            string.concat(
                '{"name":"min0","type":"uint256","about":"least currency0 actually added (price protection)"},{"name":"min1","type":"uint256"}],',
                '"encoding":"abi.encode(uint8 0, PoolKey key, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1)"},',
                '{"id":1,"name":"increase","params":[{"name":"id","type":"uint256"},{"name":"amount0","type":"uint256"},{"name":"amount1","type":"uint256"},{"name":"min0","type":"uint256"},{"name":"min1","type":"uint256"}],',
                '"encoding":"abi.encode(uint8 1, uint256 id, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1)"},'
            ),
            string.concat(
                '{"id":2,"name":"decrease","about":"remove liquidity and send it, with all fees, to the vault","params":[{"name":"id","type":"uint256"},{"name":"liquidity","type":"uint128"},{"name":"min0","type":"uint256","about":"least currency0 from the liquidity, fees excluded"},{"name":"min1","type":"uint256"}],',
                '"encoding":"abi.encode(uint8 2, uint256 id, uint128 liquidity, uint256 min0, uint256 min1)"},',
                '{"id":3,"name":"collect","params":[{"name":"id","type":"uint256"}],"encoding":"abi.encode(uint8 3, uint256 id)"},',
                '{"id":4,"name":"rebalance","about":"remove everything and add a new range in the same pool from what came out, in one unlock; leftovers to the vault","params":['
            ),
            string.concat(
                '{"name":"id","type":"uint256"},{"name":"tickLower","type":"int24"},{"name":"tickUpper","type":"int24"},',
                '{"name":"outMin0","type":"uint256","about":"least currency0 from the old liquidity"},{"name":"outMin1","type":"uint256"},',
                '{"name":"inMin0","type":"uint256","about":"least currency0 into the new range"},{"name":"inMin1","type":"uint256"}],',
                '"encoding":"abi.encode(uint8 4, uint256 id, int24 tickLower, int24 tickUpper, uint256 outMin0, uint256 outMin1, uint256 inMin0, uint256 inMin1)"}]}'
            )
        );
    }

    /// @notice The positions this Fund holds through the adapter.
    function positionList() external view returns (Position[] memory) {
        return _positions;
    }

    /// @notice Why a pool would be refused at mint, or an empty string when it would be accepted.
    function poolProblem(PoolKey calldata key) external view returns (string memory) {
        bytes32 pid = PoolId.unwrap(key.toId());
        if (restricted && !poolAllowed[pid]) return "pool not allowed for this Fund";
        if (uint160(address(key.hooks)) & UNSAFE_HOOK_FLAGS != 0) return "hook can act on liquidity removal";
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return "pool not initialised";
        return "";
    }

    // ---------------------------------------------------------------- what an action needs and returns

    function inputs(bytes calldata action) external view returns (Amount[] memory a) {
        uint8 kind = abi.decode(action[:32], (uint8));
        if (kind == MINT) {
            MintArgs memory m = abi.decode(action[32:], (MintArgs));
            return _pair(_asset(m.key.currency0), m.amount0, _asset(m.key.currency1), m.amount1);
        }
        if (kind == INCREASE) {
            (, uint256 id, uint256 a0, uint256 a1) = abi.decode(action, (uint8, uint256, uint256, uint256));
            PoolKey memory key = _positions[_indexOf(id)].key;
            return _pair(_asset(key.currency0), a0, _asset(key.currency1), a1);
        }
        if (kind > REBALANCE) revert UnknownAction(kind);
        return _none();
    }

    function outputs(bytes calldata action) external view returns (address[] memory) {
        uint8 kind = abi.decode(action[:32], (uint8));
        PoolKey memory key;
        if (kind == MINT) {
            key = abi.decode(action[32:], (MintArgs)).key;
        } else if (kind <= REBALANCE) {
            (, uint256 id) = abi.decode(action, (uint8, uint256));
            key = _positions[_indexOf(id)].key;
        } else {
            revert UnknownAction(kind);
        }
        return _tokens2(_asset(key.currency0), _asset(key.currency1));
    }

    // ---------------------------------------------------------------- actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        uint8 kind = abi.decode(action[:32], (uint8));
        if (kind == MINT) return _mintAction(abi.decode(action[32:], (MintArgs)));
        if (kind == INCREASE) return _increaseAction(action);
        if (kind == DECREASE) return _decreaseAction(action);
        if (kind == COLLECT) {
            (, uint256 id) = abi.decode(action, (uint8, uint256));
            Position memory p = _positions[_indexOf(id)];
            Result memory r = _remove(p, 0);
            _flush(p.key, vault);
            return abi.encode(r.fees0, r.fees1);
        }
        if (kind == REBALANCE) return _rebalanceAction(abi.decode(action[32:], (RebalanceArgs)));
        revert UnknownAction(kind);
    }

    function _mintAction(MintArgs memory m) internal returns (bytes memory) {
        if (_positions.length >= MAX_POSITIONS) revert TooManyPositions();
        _checkPool(m.key);
        uint256 id = ++lastId;
        Result memory r = _addFromVault(m.key, m.tickLower, m.tickUpper, bytes32(id), m.amount0, m.amount1);
        if (r.in0 < m.min0 || r.in1 < m.min1) revert BelowMinimum(r.in0, r.in1);
        _positions.push(Position(m.key, m.tickLower, m.tickUpper, id));
        emit PositionOpened(id, PoolId.unwrap(m.key.toId()), m.tickLower, m.tickUpper, r.liquidity);
        return abi.encode(id, r.liquidity, r.in0, r.in1);
    }

    function _increaseAction(bytes calldata action) internal returns (bytes memory) {
        (, uint256 id, uint256 a0, uint256 a1, uint256 m0, uint256 m1) =
            abi.decode(action, (uint8, uint256, uint256, uint256, uint256, uint256));
        Position memory p = _positions[_indexOf(id)];
        Result memory r = _addFromVault(p.key, p.tickLower, p.tickUpper, bytes32(id), a0, a1);
        if (r.in0 < m0 || r.in1 < m1) revert BelowMinimum(r.in0, r.in1);
        return abi.encode(r.liquidity, r.in0, r.in1);
    }

    function _decreaseAction(bytes calldata action) internal returns (bytes memory) {
        (, uint256 id, uint128 liquidity, uint256 m0, uint256 m1) =
            abi.decode(action, (uint8, uint256, uint128, uint256, uint256));
        uint256 index = _indexOf(id);
        Position memory p = _positions[index];
        Result memory r = _remove(p, liquidity);
        if (r.out0 < m0 || r.out1 < m1) revert BelowMinimum(r.out0, r.out1);
        _flush(p.key, vault);
        _forgetIfEmpty(index);
        return abi.encode(r.out0 + r.fees0, r.out1 + r.fees1);
    }

    function _rebalanceAction(RebalanceArgs memory a) internal returns (bytes memory) {
        uint256 index = _indexOf(a.id);
        Position memory p = _positions[index];
        uint256 newId = ++lastId;
        Op memory op;
        op.kind = OP_MOVE;
        op.key = p.key;
        op.lower = p.tickLower;
        op.upper = p.tickUpper;
        op.salt = bytes32(p.id);
        op.removeLiquidity = _liquidityOf(p);
        op.newLower = a.tickLower;
        op.newUpper = a.tickUpper;
        op.newSalt = bytes32(newId);
        Result memory r = _run(op);
        if (r.out0 < a.outMin0 || r.out1 < a.outMin1) revert BelowMinimum(r.out0, r.out1);
        if (r.in0 < a.inMin0 || r.in1 < a.inMin1) revert BelowMinimum(r.in0, r.in1);
        _drop(index);
        emit PositionClosed(p.id);
        _positions.push(Position(p.key, a.tickLower, a.tickUpper, newId));
        emit PositionOpened(newId, PoolId.unwrap(p.key.toId()), a.tickLower, a.tickUpper, r.liquidity);
        _flush(p.key, vault);
        return abi.encode(newId, r.liquidity);
    }

    // ---------------------------------------------------------------- exits

    /// @notice Remove `fractionWad` of every position and send it to the vault. The PoolManager pays out all
    ///         of a position's fees whenever its liquidity changes, so all fees come back too.
    /// @dev    No minimums: removing liquidity does not trade (see the header).
    /// @dev Each position on its own: one that reverts (a hook refusing, a token refusing the recipient) is
    ///      skipped and stays whole, so it never blocks the exit from every other position.
    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        return _exitAll(fractionWad, vault, false);
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }

    /// @notice In-kind exit as tokens: `to` gets `fractionWad` of each position's liquidity and of its fees.
    ///         The fees that belong to everyone else come out with them (see `unwind`) and go to the vault.
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (to == address(0)) revert ZeroAddress();
        return _exitAll(fractionWad, to, true);
    }

    function _exitAll(uint256 fractionWad, address to, bool isSplit) internal returns (Amount[] memory out) {
        if (fractionWad > WAD) fractionWad = WAD;
        uint256 n = _positions.length;
        out = new Amount[](2 * n);
        uint256 rows;
        for (uint256 i = n; i > 0; --i) {
            Position memory p = _positions[i - 1];
            try this.exitOne(i - 1, fractionWad, to, isSplit) returns (uint256 s0, uint256 s1) {
                rows = _gather(out, rows, _asset(p.key.currency0), s0);
                rows = _gather(out, rows, _asset(p.key.currency1), s1);
            } catch {
                emit PositionSkipped(p.id);
            }
        }
        assembly {
            mstore(out, rows)
        }
    }

    /**
     * @notice This adapter only (a self-call, so one position's failure can be caught): one position's exit.
     *         `isSplit`: the leaver `to` gets the fraction of liquidity and of fees, the rest of the fees go to the
     *         vault; otherwise everything that came out goes to the vault. Returns what went to `to`.
     */
    function exitOne(uint256 index, uint256 fractionWad, address to, bool isSplit)
        external
        returns (uint256 s0, uint256 s1)
    {
        if (msg.sender != address(this)) revert UnauthorizedCallback();
        Position memory p = _positions[index];
        uint128 liquidity = _liquidityOf(p);
        // The fraction less a unit's worth of each token at fair prices (GrowMath.taken): what stays reads at
        // least `(1 - f)` of what this position read, so rounding never adds up across positions.
        (uint256 fair0, uint256 fair1) = OraclePositionMath.fairAmounts(
            IRouterHolder(controller).router(),
            _asset(p.key.currency0),
            _asset(p.key.currency1),
            p.tickLower,
            p.tickUpper,
            liquidity
        );
        uint128 take = GrowMath.taken(liquidity, fractionWad, fair0, fair1);
        if (take == 0) return (0, 0);
        Result memory r = _remove(p, take);
        if (isSplit) {
            s0 = r.out0 + r.fees0 * fractionWad / WAD;
            s1 = r.out1 + r.fees1 * fractionWad / WAD;
            _wrapIfNative(p.key);
            _push(_asset(p.key.currency0), to, s0);
            _push(_asset(p.key.currency1), to, s1);
        } else {
            s0 = r.out0 + r.fees0;
            s1 = r.out1 + r.fees1;
        }
        _flush(p.key, vault);
        _forgetIfEmpty(index);
    }

    // ---------------------------------------------------------------- deposits into the existing mix

    /**
     * @notice What `grow(fractionWad)` pulls: for every position, the tokens that add its share of liquidity at
     *         the pool's current price, rounded up exactly as the PoolManager charges them (see GrowMath), one
     *         entry per token (WETH for native ether).
     */
    function growInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        uint256 n = _positions.length;
        needs = new Amount[](2 * n);
        uint256 rows;
        if (fractionWad == 0) return _trim(needs, 0);
        IPriceRouter router = IRouterHolder(controller).router();
        for (uint256 i; i < n; ++i) {
            Position memory p = _positions[i];
            (, uint256 a0, uint256 a1) = _growPlan(router, p, fractionWad);
            if (a0 != 0) rows = _tally(needs, rows, _asset(p.key.currency0), a0);
            if (a1 != 0) rows = _tally(needs, rows, _asset(p.key.currency1), a1);
        }
        return _trim(needs, rows);
    }

    /**
     * @notice Grows every position by `fractionWad` (1e18 = double): the same range gets that fraction more
     *         liquidity, paid with tokens the teller bought into the vault. Every position's fees go to the vault
     *         in the same call (the PoolManager pays them out on any change of liquidity).
     * @dev    The add names its liquidity exactly, so the pool takes exactly what `growInputs` declared and
     *         nothing is left over but the fees. Why fees leave the position: see the v3 adapter's `grow`. The
     *         teller calls `grow(0)` (collect only) before its "before" snapshot, so the measured position is
     *         principal only.
     * @return used tokens the pool took, per token.
     */
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        uint256 n = _positions.length;
        used = new Amount[](2 * n);
        uint256 rows;
        IPriceRouter router = fractionWad == 0 ? IPriceRouter(address(0)) : IRouterHolder(controller).router();
        for (uint256 i; i < n; ++i) {
            Position memory p = _positions[i];
            uint128 add;
            uint256 a0;
            uint256 a1;
            if (fractionWad != 0) (add, a0, a1) = _growPlan(router, p, fractionWad);
            if (add == 0) {
                // Collect only: a zero change pays out the fees.
                if (_liquidityOf(p) != 0) _remove(p, 0);
                _flush(p.key, vault);
                continue;
            }
            address t0 = _asset(p.key.currency0);
            address t1 = _asset(p.key.currency1);
            _pull(t0, a0);
            _pull(t1, a1);
            if (p.key.currency0.isAddressZero() && a0 != 0) weth.withdraw(a0);
            Op memory op;
            op.kind = OP_GROW;
            op.key = p.key;
            op.lower = p.tickLower;
            op.upper = p.tickUpper;
            op.salt = bytes32(p.id);
            op.removeLiquidity = add;
            Result memory r = _run(op);
            _flush(p.key, vault);
            rows = _gather(used, rows, t0, r.in0);
            rows = _gather(used, rows, t1, r.in1);
        }
        assembly {
            mstore(used, rows)
        }
    }

    /// @dev Liquidity to add to one position and what the PoolManager will charge for it now.
    function _growPlan(IPriceRouter router, Position memory p, uint256 fractionWad)
        internal
        view
        returns (uint128 add, uint256 a0, uint256 a1)
    {
        uint128 liquidity = _liquidityOf(p);
        if (liquidity == 0) return (0, 0, 0);
        (uint256 fair0, uint256 fair1) = OraclePositionMath.fairAmounts(
            router, _asset(p.key.currency0), _asset(p.key.currency1), p.tickLower, p.tickUpper, liquidity
        );
        add = GrowMath.added(liquidity, fractionWad, fair0, fair1);
        (uint160 sqrtP,,,) = poolManager.getSlot0(p.key.toId());
        (a0, a1) = GrowMath.cost(sqrtP, p.tickLower, p.tickUpper, add);
    }

    // ---------------------------------------------------------------- valuation

    /// @notice Each position at the router's fair prices plus its fees, one row per position and token. Owes nothing.
    function positions(IPriceRouter router) external view returns (Amount[] memory assets, Amount[] memory debts) {
        uint256 n = _positions.length;
        assets = new Amount[](2 * n);
        uint256 rows;
        for (uint256 i; i < n; ++i) {
            Position memory p = _positions[i];
            (uint256 h0, uint256 h1) = _holding(router, p);
            // One row per position and token, not summed: the teller allows each row its own rounding slack.
            assets[rows++] = Amount(_asset(p.key.currency0), h0);
            assets[rows++] = Amount(_asset(p.key.currency1), h1);
        }
        assembly {
            mstore(assets, rows)
        }
        debts = new Amount[](0);
    }

    /// @dev One position at fair prices plus the fees it has earned since its last change.
    function _holding(IPriceRouter router, Position memory p) internal view returns (uint256 h0, uint256 h1) {
        PoolId pid = p.key.toId();
        (uint128 liquidity, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(pid, address(this), p.tickLower, p.tickUpper, bytes32(p.id));
        (h0, h1) = OraclePositionMath.fairAmounts(
            router, _asset(p.key.currency0), _asset(p.key.currency1), p.tickLower, p.tickUpper, liquidity
        );
        if (liquidity != 0) {
            (uint256 g0, uint256 g1) = poolManager.getFeeGrowthInside(pid, p.tickLower, p.tickUpper);
            h0 += OraclePositionMath.feesEarned(g0, last0, liquidity);
            h1 += OraclePositionMath.feesEarned(g1, last1, liquidity);
        }
    }

    // ---------------------------------------------------------------- the unlock

    /// @dev Pull from the vault, unwrap for a native pool, add in one unlock, send the rest back.
    function _addFromVault(PoolKey memory key, int24 lower, int24 upper, bytes32 salt, uint256 a0, uint256 a1)
        internal
        returns (Result memory r)
    {
        address t0 = _asset(key.currency0);
        _pull(t0, a0);
        _pull(_asset(key.currency1), a1);
        if (key.currency0.isAddressZero() && a0 != 0) weth.withdraw(a0);
        Op memory op;
        op.kind = OP_ADD;
        op.key = key;
        op.lower = lower;
        op.upper = upper;
        op.salt = salt;
        op.max0 = a0;
        op.max1 = a1;
        r = _run(op);
        _flush(key, vault);
    }

    function _remove(Position memory p, uint128 liquidity) internal returns (Result memory) {
        Op memory op;
        op.kind = OP_REMOVE;
        op.key = p.key;
        op.lower = p.tickLower;
        op.upper = p.tickUpper;
        op.salt = bytes32(p.id);
        op.removeLiquidity = liquidity;
        return _run(op);
    }

    /// @dev Runs one operation inside the PoolManager's lock. A refusal by the pool's hook surfaces as
    ///      `HookRefusedLiquidity`; anything else bubbles up unchanged.
    function _run(Op memory op) internal returns (Result memory r) {
        _unlocking = true;
        try poolManager.unlock(abi.encode(op)) returns (bytes memory out) {
            _unlocking = false;
            r = abi.decode(out, (Result));
        } catch (bytes memory reason) {
            address hooks = address(op.key.hooks);
            if (hooks != address(0) && reason.length >= 36) {
                bytes4 selector;
                address target;
                assembly {
                    selector := mload(add(reason, 32))
                    target := mload(add(reason, 36))
                }
                if (selector == CustomRevert.WrappedError.selector && target == hooks) {
                    revert HookRefusedLiquidity(hooks, reason);
                }
            }
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert UnauthorizedCallback();
        Op memory op = abi.decode(data, (Op));
        Result memory r;
        if (op.kind == OP_ADD) {
            _modifyAdd(op.key, op.lower, op.upper, op.salt, op.max0, op.max1, r);
        } else if (op.kind == OP_GROW) {
            _modifyGrow(op.key, op.lower, op.upper, op.salt, op.removeLiquidity, r);
        } else {
            _modifyRemove(op.key, op.lower, op.upper, op.salt, op.removeLiquidity, r);
            if (op.kind == OP_MOVE) {
                // Everything that came out, fees included, is what the new range may use.
                _modifyAdd(op.key, op.newLower, op.newUpper, op.newSalt, r.out0 + r.fees0, r.out1 + r.fees1, r);
            }
        }
        _close(op.key.currency0);
        _close(op.key.currency1);
        return abi.encode(r);
    }

    /// @dev Add as much liquidity as `max0` and `max1` allow at the pool's current price. One unit of each is
    ///      held back so rounding in the pool's favour can never ask for more than we have.
    function _modifyAdd(
        PoolKey memory key,
        int24 lower,
        int24 upper,
        bytes32 salt,
        uint256 max0,
        uint256 max1,
        Result memory r
    ) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            max0 > 0 ? max0 - 1 : 0,
            max1 > 0 ? max1 - 1 : 0
        );
        if (liquidity == 0) revert ZeroLiquidity();
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), salt), ""
        );
        // An add to an existing position also pays out its fees; principal is what the add itself cost.
        BalanceDelta principal = callerDelta - fees;
        r.liquidity = liquidity;
        r.in0 = uint256(uint128(-principal.amount0()));
        r.in1 = uint256(uint128(-principal.amount1()));
        r.fees0 += uint256(uint128(fees.amount0()));
        r.fees1 += uint256(uint128(fees.amount1()));
    }

    /// @dev Add exactly `liquidity` to an existing position. The PoolManager charges it rounded up, which is what
    ///      `growInputs` paid for; it also pays out the position's fees, which go to the vault with the rest.
    function _modifyGrow(PoolKey memory key, int24 lower, int24 upper, bytes32 salt, uint128 liquidity, Result memory r)
        internal
    {
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), salt), ""
        );
        BalanceDelta principal = callerDelta - fees;
        r.liquidity = liquidity;
        r.in0 = uint256(uint128(-principal.amount0()));
        r.in1 = uint256(uint128(-principal.amount1()));
        r.fees0 = uint256(uint128(fees.amount0()));
        r.fees1 = uint256(uint128(fees.amount1()));
    }

    function _modifyRemove(PoolKey memory key, int24 lower, int24 upper, bytes32 salt, uint128 liquidity, Result memory r)
        internal
    {
        (BalanceDelta callerDelta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, -int256(uint256(liquidity)), salt), ""
        );
        BalanceDelta principal = callerDelta - fees;
        r.out0 = uint256(uint128(principal.amount0()));
        r.out1 = uint256(uint128(principal.amount1()));
        r.fees0 = uint256(uint128(fees.amount0()));
        r.fees1 = uint256(uint128(fees.amount1()));
    }

    /// @dev Settle what we owe the PoolManager in `currency`, or take what it owes us, so the unlock closes.
    function _close(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }

    // ---------------------------------------------------------------- internals

    function _checkPool(PoolKey memory key) internal view {
        bytes32 pid = PoolId.unwrap(key.toId());
        if (restricted && !poolAllowed[pid]) revert PoolNotAllowed(pid);
        if (uint160(address(key.hooks)) & UNSAFE_HOOK_FLAGS != 0) revert HookNotSupported(address(key.hooks));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(pid);
        // Valuation needs both tokens' decimals; refuse a token it could not handle before holding it.
        OraclePositionMath.decimalsOf(_asset(key.currency0));
        OraclePositionMath.decimalsOf(_asset(key.currency1));
    }

    /// @dev The token the vault holds for a pool currency: WETH for native ether.
    function _asset(Currency c) internal view returns (address) {
        return c.isAddressZero() ? address(weth) : Currency.unwrap(c);
    }

    function _wrapIfNative(PoolKey memory key) internal {
        if (!key.currency0.isAddressZero()) return;
        uint256 bal = address(this).balance;
        if (bal != 0) weth.deposit{value: bal}();
    }

    /// @dev Send everything left of a pool's two tokens to `to`, wrapping ether first.
    function _flush(PoolKey memory key, address to) internal {
        _wrapIfNative(key);
        address a0 = _asset(key.currency0);
        address a1 = _asset(key.currency1);
        _push(a0, to, IERC20(a0).balanceOf(address(this)));
        _push(a1, to, IERC20(a1).balanceOf(address(this)));
    }

    function _liquidityOf(Position memory p) internal view returns (uint128 liquidity) {
        (liquidity,,) = poolManager.getPositionInfo(p.key.toId(), address(this), p.tickLower, p.tickUpper, bytes32(p.id));
    }

    /// @dev Forget a position once it holds no liquidity. Its fees were paid out with the last removal.
    function _forgetIfEmpty(uint256 index) internal {
        Position memory p = _positions[index];
        if (_liquidityOf(p) != 0) return;
        _drop(index);
        emit PositionClosed(p.id);
    }

    function _drop(uint256 index) internal {
        uint256 last = _positions.length - 1;
        if (index != last) _positions[index] = _positions[last];
        _positions.pop();
    }

    function _indexOf(uint256 id) internal view returns (uint256) {
        uint256 n = _positions.length;
        for (uint256 i; i < n; ++i) {
            if (_positions[i].id == id) return i;
        }
        revert UnknownPosition(id);
    }

    function _pair(address t0, uint256 a0, address t1, uint256 a1) internal pure returns (Amount[] memory a) {
        a = new Amount[](2);
        a[0] = Amount(t0, a0);
        a[1] = Amount(t1, a1);
    }

    function _gather(Amount[] memory list, uint256 rows, address token, uint256 amount) internal pure returns (uint256) {
        for (uint256 k; k < rows; ++k) {
            if (list[k].token == token) {
                list[k].amount += amount;
                return rows;
            }
        }
        list[rows] = Amount(token, amount);
        return rows + 1;
    }
}
