// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    INonfungiblePositionManager
} from "../../interfaces/external/uniswap/IUniswapV3.sol";
import {OraclePositionMath} from "./OraclePositionMath.sol";
import {GrowMath, IRouterHolder} from "./GrowMath.sol";

/**
 * @title  UniswapV3LiquidityAdapter
 * @notice Lets a Fund provide concentrated liquidity on Uniswap v3 through its NonfungiblePositionManager.
 *         The Fund's clone of this adapter owns the position NFTs and remembers their ids.
 *
 * @dev    ## Actions (`execute(abi.encode(uint8 id, ...))`, also listed in `describe()`)
 *         0 mint       new position in an existing pool, from tokens in the vault
 *         1 increase   add tokens from the vault to one of our positions
 *         2 decrease   remove liquidity; what comes out, fees included, goes to the vault
 *         3 collect    send a position's fees to the vault
 *         4 rebalance  remove all of a position, collect, and mint a new range in the same pool from what came
 *                      out; whatever does not fit goes to the vault
 *
 *         ## Valuation
 *         `positions` reports each NFT at the router's fair prices (see OraclePositionMath), never at the
 *         pool's current price, plus fees: what the NFT already owes us and what it has earned since, from
 *         the pool's fee growth counters. Those counters only grow with fees swappers actually paid, and
 *         moving the price does not change what has accrued inside a range, so reading them in a view is
 *         safe. A swap that crosses our range does pay us; that is real income.
 *
 *         ## Where the pool's price still matters, and why that is safe
 *         Adding liquidity pays tokens at the pool's current price. If someone has pushed the pool away
 *         from fair, the Fund pays more (at fair prices) than the position is then reported at; the
 *         controller sees that drop in NAV and charges it to the loss budget, and the manager's minimums
 *         bound it. Removing liquidity does not trade, so wherever the pool sits it returns at least what
 *         `positions` reported at fair prices. That is why `unwind` and `split` need no minimums and no
 *         manager.
 *
 *         ## Deposits into the existing mix
 *         `grow` adds the same fraction of liquidity to every position, in the same range, after collecting its
 *         fees to the vault. See `grow` and GrowMath.
 *
 *         ## Limits
 *         - At most `MAX_POSITIONS` NFTs per Fund, so the book stays affordable (`positions` runs under a gas
 *           cap in the controller).
 *         - Pools must already exist and be initialised. This adapter never creates a pool, because whoever
 *           creates one picks its starting price.
 *         - Tokens that charge a fee on transfer are not supported (the mint reverts).
 *         - NFTs sent to the clone by anyone else are ignored: only positions minted here are counted.
 *
 *         ## Per-Fund setting
 *         `config` is empty (any pool from the canonical factory) or `abi.encode(address[] pools)`: the only
 *         pools this Fund may open positions in. Fixed for the clone's life.
 */
contract UniswapV3LiquidityAdapter is BaseAdapter {
    error UnknownAction(uint8 id);
    error UnknownPosition(uint256 tokenId);
    error UnsortedTokens();
    error PoolNotFound();
    error PoolNotAllowed(address pool);
    error PoolNotInitialized(address pool);
    error TooManyPositions();
    error NothingToMint();
    error GrewTooLittle(uint256 tokenId, uint128 added, uint128 wanted);

    event PositionOpened(uint256 indexed tokenId, address indexed pool, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PositionClosed(uint256 indexed tokenId);
    /// @notice An exit could not take its share of this position (it reverted); the position stays as it was.
    event PositionSkipped(uint256 indexed tokenId);

    uint8 internal constant MINT = 0;
    uint8 internal constant INCREASE = 1;
    uint8 internal constant DECREASE = 2;
    uint8 internal constant COLLECT = 3;
    uint8 internal constant REBALANCE = 4;

    /// @notice Most positions one Fund holds here. `positions` runs on every action and settlement, and an exit in
    ///         kind splits every position, so this bounds both (sized on a fork: docs/DEPOSITS-AND-EXITS.md, "Gas").
    uint256 public constant MAX_POSITIONS = 10;
    uint256 private constant WAD = 1e18;
    uint128 private constant ALL = type(uint128).max;

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;

    struct Position {
        uint256 tokenId;
        address pool;
        address token0;
        address token1;
    }

    /// @dev The NPM's per-position record, decoded as one struct to keep the stack small.
    struct NpmPosition {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @dev Action parameters after the id. All static, so `abi.decode(action[32:], (MintArgs))` reads them.
    struct MintArgs {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 min0;
        uint256 min1;
    }

    struct RebalanceArgs {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint256 outMin0;
        uint256 outMin1;
        uint256 inMin0;
        uint256 inMin1;
    }

    Position[] internal _positions;
    bool public restricted;
    mapping(address => bool) public poolAllowed;

    constructor(INonfungiblePositionManager positionManager_) {
        positionManager = positionManager_;
        // The NPM only ever mints into its own factory's pools, so we read the factory from it.
        factory = IUniswapV3Factory(positionManager_.factory());
    }

    function _configure(bytes calldata config) internal override {
        if (config.length == 0) return;
        address[] memory pools = abi.decode(config, (address[]));
        restricted = true;
        for (uint256 i; i < pools.length; ++i) poolAllowed[pools[i]] = true;
    }

    // ---------------------------------------------------------------- descriptions

    function name() external pure returns (string memory) {
        return "Uniswap v3 liquidity v1";
    }

    function describe() external pure returns (string memory) {
        return string.concat(
            string.concat(
                '{"adapter":"Uniswap v3 liquidity v1","actions":[',
                '{"id":0,"name":"mint","about":"open a position in an existing pool; tokens must be sorted (token0 < token1)","params":[',
                '{"name":"token0","type":"address"},{"name":"token1","type":"address"},{"name":"fee","type":"uint24","about":"pool fee in hundredths of a bip"},',
                '{"name":"tickLower","type":"int24"},{"name":"tickUpper","type":"int24","about":"multiples of the pool tick spacing"},'
            ),
            string.concat(
                '{"name":"amount0","type":"uint256","about":"most token0 to add, raw units"},{"name":"amount1","type":"uint256"},',
                '{"name":"min0","type":"uint256","about":"least token0 actually added (price protection)"},{"name":"min1","type":"uint256"}],',
                '"encoding":"abi.encode(uint8 0, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1)"},',
                '{"id":1,"name":"increase","params":[{"name":"tokenId","type":"uint256"},{"name":"amount0","type":"uint256"},{"name":"amount1","type":"uint256"},{"name":"min0","type":"uint256"},{"name":"min1","type":"uint256"}],'
            ),
            string.concat(
                '"encoding":"abi.encode(uint8 1, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1)"},',
                '{"id":2,"name":"decrease","about":"remove liquidity and send it, with all fees, to the vault; the NFT is burned when empty","params":[{"name":"tokenId","type":"uint256"},{"name":"liquidity","type":"uint128"},{"name":"min0","type":"uint256","about":"least token0 from the liquidity, fees excluded"},{"name":"min1","type":"uint256"}],',
                '"encoding":"abi.encode(uint8 2, uint256 tokenId, uint128 liquidity, uint256 min0, uint256 min1)"},',
                '{"id":3,"name":"collect","params":[{"name":"tokenId","type":"uint256"}],"encoding":"abi.encode(uint8 3, uint256 tokenId)"},'
            ),
            string.concat(
                '{"id":4,"name":"rebalance","about":"remove everything, collect, mint a new range in the same pool from what came out; leftovers to the vault","params":[',
                '{"name":"tokenId","type":"uint256"},{"name":"tickLower","type":"int24"},{"name":"tickUpper","type":"int24"},',
                '{"name":"outMin0","type":"uint256","about":"least token0 from the old liquidity"},{"name":"outMin1","type":"uint256"},',
                '{"name":"inMin0","type":"uint256","about":"least token0 into the new range"},{"name":"inMin1","type":"uint256"}],'
            ),
            string.concat(
                '"encoding":"abi.encode(uint8 4, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 outMin0, uint256 outMin1, uint256 inMin0, uint256 inMin1)"}',
                "]}"
            )
        );
    }

    /// @notice The NFTs this Fund holds through the adapter.
    function positionIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](_positions.length);
        for (uint256 i; i < ids.length; ++i) ids[i] = _positions[i].tokenId;
    }

    // ---------------------------------------------------------------- what an action needs and returns

    function inputs(bytes calldata action) external view returns (Amount[] memory a) {
        uint8 id = abi.decode(action[:32], (uint8));
        if (id == MINT) {
            (, address t0, address t1,,,, uint256 a0, uint256 a1) =
                abi.decode(action, (uint8, address, address, uint24, int24, int24, uint256, uint256));
            return _pair(t0, a0, t1, a1);
        }
        if (id == INCREASE) {
            (, uint256 tokenId, uint256 a0, uint256 a1) = abi.decode(action, (uint8, uint256, uint256, uint256));
            Position memory p = _positions[_indexOf(tokenId)];
            return _pair(p.token0, a0, p.token1, a1);
        }
        if (id > REBALANCE) revert UnknownAction(id);
        return _none();
    }

    function outputs(bytes calldata action) external view returns (address[] memory) {
        uint8 id = abi.decode(action[:32], (uint8));
        if (id == MINT) {
            (, address t0, address t1) = abi.decode(action, (uint8, address, address));
            return _tokens2(t0, t1);
        }
        if (id > REBALANCE) revert UnknownAction(id);
        (, uint256 tokenId) = abi.decode(action, (uint8, uint256));
        Position memory p = _positions[_indexOf(tokenId)];
        return _tokens2(p.token0, p.token1);
    }

    // ---------------------------------------------------------------- actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        uint8 id = abi.decode(action[:32], (uint8));
        if (id == MINT) return _mintAction(action);
        if (id == INCREASE) return _increaseAction(action);
        if (id == DECREASE) return _decreaseAction(action);
        if (id == COLLECT) {
            (, uint256 tokenId) = abi.decode(action, (uint8, uint256));
            _indexOf(tokenId);
            (uint256 c0, uint256 c1) = _collect(tokenId, vault, ALL, ALL);
            return abi.encode(c0, c1);
        }
        if (id == REBALANCE) return _rebalanceAction(action);
        revert UnknownAction(id);
    }

    function _mintAction(bytes calldata action) internal returns (bytes memory) {
        MintArgs memory m = abi.decode(action[32:], (MintArgs));
        address pool = _checkPool(m.token0, m.token1, m.fee);
        _pull(m.token0, m.amount0);
        _pull(m.token1, m.amount1);
        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) = _mint(pool, m);
        _pushAll(m.token0);
        _pushAll(m.token1);
        return abi.encode(tokenId, liquidity, used0, used1);
    }

    function _increaseAction(bytes calldata action) internal returns (bytes memory) {
        (, uint256 tokenId, uint256 a0, uint256 a1, uint256 m0, uint256 m1) =
            abi.decode(action, (uint8, uint256, uint256, uint256, uint256, uint256));
        Position memory p = _positions[_indexOf(tokenId)];
        _pull(p.token0, a0);
        _pull(p.token1, a1);
        _approve(p.token0, address(positionManager), a0);
        _approve(p.token1, address(positionManager), a1);
        (uint128 liquidity, uint256 used0, uint256 used1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(tokenId, a0, a1, m0, m1, block.timestamp)
        );
        _approve(p.token0, address(positionManager), 0);
        _approve(p.token1, address(positionManager), 0);
        _pushAll(p.token0);
        _pushAll(p.token1);
        return abi.encode(liquidity, used0, used1);
    }

    function _decreaseAction(bytes calldata action) internal returns (bytes memory) {
        (, uint256 tokenId, uint128 liquidity, uint256 m0, uint256 m1) =
            abi.decode(action, (uint8, uint256, uint128, uint256, uint256));
        uint256 index = _indexOf(tokenId);
        if (liquidity != 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, m0, m1, block.timestamp)
            );
        }
        (uint256 c0, uint256 c1) = _collect(tokenId, vault, ALL, ALL);
        _burnIfEmpty(index);
        return abi.encode(c0, c1);
    }

    function _rebalanceAction(bytes calldata action) internal returns (bytes memory) {
        RebalanceArgs memory r = abi.decode(action[32:], (RebalanceArgs));
        uint256 index = _indexOf(r.tokenId);
        Position memory p = _positions[index];
        NpmPosition memory info = _npmPosition(r.tokenId);
        if (info.liquidity != 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(r.tokenId, info.liquidity, r.outMin0, r.outMin1, block.timestamp)
            );
        }
        (uint256 a0, uint256 a1) = _collect(r.tokenId, address(this), ALL, ALL);
        positionManager.burn(r.tokenId);
        _remove(index);
        emit PositionClosed(r.tokenId);
        MintArgs memory m = MintArgs(p.token0, p.token1, info.fee, r.tickLower, r.tickUpper, a0, a1, r.inMin0, r.inMin1);
        (uint256 newId, uint128 liquidity,,) = _mint(p.pool, m);
        _pushAll(p.token0);
        _pushAll(p.token1);
        return abi.encode(newId, liquidity);
    }

    // ---------------------------------------------------------------- exits

    /// @notice Remove `fractionWad` of every position and send it, with the same share of fees, to the vault.
    /// @dev    No minimums: removing liquidity does not trade, so wherever the pool sits it returns at least
    ///         what `positions` reported at fair prices (see the header).
    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        return _exit(fractionWad, vault);
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return new Amount[](0);
    }

    /// @notice In-kind exit. An NFT cannot be split, so `to` receives its share as the underlying tokens:
    ///         `fractionWad` of each position's liquidity and of its fees.
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (to == address(0)) revert ZeroAddress();
        return _exit(fractionWad, to);
    }

    /// @dev Each position on its own: one that reverts (a token refusing the recipient, a broken pool) is
    ///      skipped and stays whole, so it never blocks the exit from every other position.
    function _exit(uint256 fractionWad, address to) internal returns (Amount[] memory out) {
        if (fractionWad > WAD) fractionWad = WAD;
        uint256 n = _positions.length;
        out = new Amount[](2 * n);
        uint256 rows;
        // Walk backwards: closing a position moves the last one into its slot.
        for (uint256 i = n; i > 0; --i) {
            Position memory p = _positions[i - 1];
            try this.exitOne(i - 1, fractionWad, to) returns (uint256 got0, uint256 got1) {
                rows = _gather(out, rows, p.token0, got0);
                rows = _gather(out, rows, p.token1, got1);
            } catch {
                emit PositionSkipped(p.tokenId);
            }
        }
        assembly {
            mstore(out, rows)
        }
    }

    /// @notice This adapter only (a self-call, so one position's failure can be caught): one position's exit.
    function exitOne(uint256 index, uint256 fractionWad, address to) external returns (uint256, uint256) {
        if (msg.sender != address(this)) revert NotController();
        return _exitOne(index, _positions[index], fractionWad, to);
    }

    function _exitOne(uint256 index, Position memory p, uint256 fractionWad, address to)
        internal
        returns (uint256 got0, uint256 got1)
    {
        NpmPosition memory info = _npmPosition(p.tokenId);
        if (fractionWad == WAD) {
            if (info.liquidity != 0) {
                positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(p.tokenId, info.liquidity, 0, 0, block.timestamp)
                );
            }
            (got0, got1) = _collect(p.tokenId, to, ALL, ALL);
            _burnIfEmpty(index);
            return (got0, got1);
        }
        // Our share of fees, measured before the decrease folds principal into what the NFT owes.
        (uint256 fee0, uint256 fee1) = _fees(p.pool, info);
        uint128 take = _taken(p, info, fractionWad);
        uint256 principal0;
        uint256 principal1;
        if (take != 0) {
            (principal0, principal1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(p.tokenId, take, 0, 0, block.timestamp)
            );
        }
        uint256 max0 = principal0 + fee0 * fractionWad / WAD;
        uint256 max1 = principal1 + fee1 * fractionWad / WAD;
        if (max0 == 0 && max1 == 0) return (0, 0);
        return _collect(p.tokenId, to, _u128(max0), _u128(max1));
    }

    /// @dev The liquidity an exit of `fractionWad` takes: the fraction less a unit's worth of each token at fair
    ///      prices (GrowMath.taken), so what stays reads at least `(1 - f)` of what this position read and
    ///      rounding never adds up across positions.
    function _taken(Position memory p, NpmPosition memory info, uint256 fractionWad) internal view returns (uint128) {
        (uint256 fair0, uint256 fair1) = OraclePositionMath.fairAmounts(
            IRouterHolder(controller).router(), p.token0, p.token1, info.tickLower, info.tickUpper, info.liquidity
        );
        return GrowMath.taken(info.liquidity, fractionWad, fair0, fair1);
    }

    // ---------------------------------------------------------------- deposits into the existing mix

    /**
     * @notice What `grow(fractionWad)` pulls: for every position, the tokens that add its share of liquidity at
     *         the pool's current price, rounded up (see GrowMath), one entry per token. A little more than the
     *         pool will take, because the position manager sizes liquidity from amounts and rounds down; what is
     *         not taken goes back to the vault in the same call.
     */
    function growInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        (needs,) = _growAll(fractionWad);
    }

    /// @dev One position's grow: the liquidity to add and the tokens offered for it.
    struct GrowStep {
        uint128 add;
        uint256 a0;
        uint256 a1;
    }

    /// @dev Every position's grow and the inputs they sum to, worked out once for `growInputs` and `grow` (growing
    ///      one position moves no other position's plan: adding liquidity never moves a pool's price).
    function _growAll(uint256 fractionWad) internal view returns (Amount[] memory needs, GrowStep[] memory steps) {
        uint256 n = _positions.length;
        needs = new Amount[](2 * n);
        steps = new GrowStep[](n);
        uint256 rows;
        if (fractionWad != 0) {
            IPriceRouter router = IRouterHolder(controller).router();
            for (uint256 i; i < n; ++i) {
                Position memory p = _positions[i];
                GrowStep memory g = steps[i];
                (g.add, g.a0, g.a1) = _growPlan(router, p, _npmPosition(p.tokenId), fractionWad);
                if (g.a0 != 0) rows = _tally(needs, rows, p.token0, g.a0);
                if (g.a1 != 0) rows = _tally(needs, rows, p.token1, g.a1);
            }
        }
        needs = _trim(needs, rows);
    }

    /**
     * @notice Grows every position by `fractionWad` (1e18 = double): the same range gets that fraction more
     *         liquidity, paid with tokens the teller bought into the vault. `grow(0)` only sends every
     *         position's uncollected fees to the vault.
     * @dev    Why fees are collected: `positions` reports principal plus fees, and only principal can be grown
     *         (fees are not liquidity). Left in place, fees would make a position look as if it grew by less
     *         than the fraction. Collected, they become ordinary vault tokens that the teller grows like any
     *         other holding, and the position is principal only. So the teller calls `grow(0)` (collect only)
     *         on every adapter before it takes its "before" snapshot, then `grow(f)`. `grow(f)` does not collect
     *         again: what a position earned in between (from the batch's own swaps) stays in it as owed fees,
     *         which only makes it read more than the fraction requires. A grow without the collect before it
     *         fails the teller's measurement instead (the old fees did not grow), so it can never pass short.
     *
     *         Each position checks that the position manager added at least the planned liquidity, so a
     *         rounding surprise reverts here instead of failing the teller's measurement later.
     * @return used tokens the pool actually took, per token (at most `growInputs`).
     */
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        (Amount[] memory needs, GrowStep[] memory steps) = _growAll(fractionWad);
        Amount[] memory pulled = _pullAll(needs);
        // The position manager is approved once per token for what every position is offered of it (`needs`
        // sums them), and cleared once after the last; it pulls only inside `increaseLiquidity`, at most what each
        // call is offered.
        for (uint256 i; i < needs.length; ++i) _approve(needs[i].token, address(positionManager), needs[i].amount);
        uint256 n = _positions.length;
        for (uint256 i; i < n; ++i) {
            Position memory p = _positions[i];
            // Fees are collected by `grow(0)`, which the teller calls before its "before" reading. A real grow
            // leaves what the position earned since (the batch's own swaps through the pool) in the position:
            // the position manager books it as owed when liquidity is added, `positions` counts it, and the
            // position then reads more than the fraction requires, never less.
            if (fractionWad == 0) {
                NpmPosition memory info = _npmPosition(p.tokenId);
                if (info.liquidity != 0 || info.tokensOwed0 != 0 || info.tokensOwed1 != 0) {
                    _collect(p.tokenId, vault, ALL, ALL);
                }
            }
            (uint128 add, uint256 a0, uint256 a1) = (steps[i].add, steps[i].a0, steps[i].a1);
            if (add == 0) continue;
            (uint128 got,,) = positionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(p.tokenId, a0, a1, 0, 0, block.timestamp)
            );
            if (got < add) revert GrewTooLittle(p.tokenId, got, add);
        }
        for (uint256 i; i < needs.length; ++i) _approve(needs[i].token, address(positionManager), 0);
        used = _settleGrow(pulled);
    }

    /// @dev Liquidity to add to one position and the tokens to offer for it: the cost of two units more than
    ///      planned, rounded up, so the position manager's own rounding down still adds at least the plan.
    function _growPlan(IPriceRouter router, Position memory p, NpmPosition memory info, uint256 fractionWad)
        internal
        view
        returns (uint128 add, uint256 a0, uint256 a1)
    {
        if (info.liquidity == 0) return (0, 0, 0);
        (uint256 fair0, uint256 fair1) =
            OraclePositionMath.fairAmounts(router, p.token0, p.token1, info.tickLower, info.tickUpper, info.liquidity);
        add = GrowMath.added(info.liquidity, fractionWad, fair0, fair1);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(p.pool).slot0();
        (a0, a1) = GrowMath.cost(sqrtP, info.tickLower, info.tickUpper, add + 2);
    }

    // ---------------------------------------------------------------- valuation

    /// @notice Each position at the router's fair prices plus its fees, one row per position and token. Owes nothing.
    function positions(IPriceRouter router) external view returns (Amount[] memory assets, Amount[] memory debts) {
        uint256 n = _positions.length;
        assets = new Amount[](2 * n);
        uint256 rows;
        for (uint256 i; i < n; ++i) {
            Position memory p = _positions[i];
            NpmPosition memory info = _npmPosition(p.tokenId);
            (uint256 a0, uint256 a1) =
                OraclePositionMath.fairAmounts(router, p.token0, p.token1, info.tickLower, info.tickUpper, info.liquidity);
            (uint256 f0, uint256 f1) = _fees(p.pool, info);
            // One row per position and token, not summed: the teller allows each row its own rounding slack.
            assets[rows++] = Amount(p.token0, a0 + f0);
            assets[rows++] = Amount(p.token1, a1 + f1);
        }
        assembly {
            mstore(assets, rows)
        }
        debts = new Amount[](0);
    }

    /// @notice What a position's fees come to now: what the NFT already owes plus what it has earned since it
    ///         last settled with the pool.
    function _fees(address pool, NpmPosition memory info) internal view returns (uint256 fee0, uint256 fee1) {
        fee0 = info.tokensOwed0;
        fee1 = info.tokensOwed1;
        if (info.liquidity == 0) return (fee0, fee1);
        (uint256 inside0, uint256 inside1) = _feeGrowthInside(IUniswapV3Pool(pool), info.tickLower, info.tickUpper);
        fee0 += OraclePositionMath.feesEarned(inside0, info.feeGrowthInside0LastX128, info.liquidity);
        fee1 += OraclePositionMath.feesEarned(inside1, info.feeGrowthInside1LastX128, info.liquidity);
    }

    /// @dev Fee growth inside a range, the way the pool itself computes it: global growth less what accrued
    ///      below the lower tick and above the upper one. The pool's tick only decides which side of each
    ///      boundary counts as outside; the tick's own record flips when the price crosses it, so the result
    ///      is the same wherever the price sits.
    function _feeGrowthInside(IUniswapV3Pool pool, int24 lo, int24 hi)
        internal
        view
        returns (uint256 inside0, uint256 inside1)
    {
        (, int24 tick,,,,,) = pool.slot0();
        (,, uint256 lo0, uint256 lo1,,,,) = pool.ticks(lo);
        (,, uint256 hi0, uint256 hi1,,,,) = pool.ticks(hi);
        uint256 g0 = pool.feeGrowthGlobal0X128();
        uint256 g1 = pool.feeGrowthGlobal1X128();
        unchecked {
            if (tick < lo) {
                inside0 = lo0 - hi0;
                inside1 = lo1 - hi1;
            } else if (tick < hi) {
                inside0 = g0 - lo0 - hi0;
                inside1 = g1 - lo1 - hi1;
            } else {
                inside0 = hi0 - lo0;
                inside1 = hi1 - lo1;
            }
        }
    }

    // ---------------------------------------------------------------- internals

    function _mint(address pool, MintArgs memory m)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)
    {
        if (_positions.length >= MAX_POSITIONS) revert TooManyPositions();
        if (m.amount0 == 0 && m.amount1 == 0) revert NothingToMint();
        _approve(m.token0, address(positionManager), m.amount0);
        _approve(m.token1, address(positionManager), m.amount1);
        (tokenId, liquidity, used0, used1) = positionManager.mint(
            INonfungiblePositionManager.MintParams(
                m.token0, m.token1, m.fee, m.tickLower, m.tickUpper, m.amount0, m.amount1, m.min0, m.min1,
                address(this), block.timestamp
            )
        );
        _approve(m.token0, address(positionManager), 0);
        _approve(m.token1, address(positionManager), 0);
        _positions.push(Position(tokenId, pool, m.token0, m.token1));
        emit PositionOpened(tokenId, pool, m.tickLower, m.tickUpper, liquidity);
    }

    function _collect(uint256 tokenId, address to, uint128 max0, uint128 max1) internal returns (uint256, uint256) {
        return positionManager.collect(INonfungiblePositionManager.CollectParams(tokenId, to, max0, max1));
    }

    /// @dev Burn and forget a position once it holds no liquidity and owes nothing.
    function _burnIfEmpty(uint256 index) internal {
        uint256 tokenId = _positions[index].tokenId;
        NpmPosition memory info = _npmPosition(tokenId);
        if (info.liquidity != 0 || info.tokensOwed0 != 0 || info.tokensOwed1 != 0) return;
        positionManager.burn(tokenId);
        _remove(index);
        emit PositionClosed(tokenId);
    }

    function _remove(uint256 index) internal {
        uint256 last = _positions.length - 1;
        if (index != last) _positions[index] = _positions[last];
        _positions.pop();
    }

    function _checkPool(address t0, address t1, uint24 fee) internal view returns (address pool) {
        if (t0 >= t1) revert UnsortedTokens();
        pool = factory.getPool(t0, t1, fee);
        if (pool == address(0)) revert PoolNotFound();
        if (restricted && !poolAllowed[pool]) revert PoolNotAllowed(pool);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(pool);
        // Valuation needs both tokens' decimals; refuse a token it could not handle before holding it.
        OraclePositionMath.decimalsOf(t0);
        OraclePositionMath.decimalsOf(t1);
    }

    function _npmPosition(uint256 tokenId) internal view returns (NpmPosition memory info) {
        (bool ok, bytes memory data) =
            address(positionManager).staticcall(abi.encodeCall(INonfungiblePositionManager.positions, (tokenId)));
        if (!ok) revert UnknownPosition(tokenId);
        info = abi.decode(data, (NpmPosition));
    }

    function _indexOf(uint256 tokenId) internal view returns (uint256) {
        uint256 n = _positions.length;
        for (uint256 i; i < n; ++i) {
            if (_positions[i].tokenId == tokenId) return i;
        }
        revert UnknownPosition(tokenId);
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

    function _u128(uint256 x) internal pure returns (uint128) {
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }
}
