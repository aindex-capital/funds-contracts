// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {MockERC20} from "../../../utils/Mocks.sol";

/// @notice WETH9 that really holds ether, so unwrapping pays out.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/**
 * @notice A third party on a v4 pool: adds liquidity and swaps, paying from its own balance. Tests fund it
 *         with tokens (mint or deal) and ether.
 */
contract V4Helper is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    /// @notice Add as much liquidity as `amount0` and `amount1` allow at the current price.
    function addAmounts(PoolKey memory key, int24 lo, int24 hi, uint256 amount0, uint256 amount1)
        external
        returns (uint128 liquidity)
    {
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amount0, amount1
        );
        pm.unlock(abi.encode(uint8(0), key, abi.encode(lo, hi, liquidity)));
    }

    /// @notice Swap exactly `amountIn` (or until the price reaches `limit`).
    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) external {
        pm.unlock(abi.encode(uint8(1), key, abi.encode(zeroForOne, amountIn, limit)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (uint8 kind, PoolKey memory key, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        if (kind == 0) {
            (int24 lo, int24 hi, uint128 liquidity) = abi.decode(args, (int24, int24, uint128));
            pm.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, int256(uint256(liquidity)), bytes32(0)), "");
        } else {
            (bool zeroForOne, uint256 amountIn, uint160 limit) = abi.decode(args, (bool, uint256, uint160));
            pm.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        }
        _close(key.currency0);
        _close(key.currency1);
        return "";
    }

    function _close(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            if (c.isAddressZero()) {
                pm.settle{value: uint256(-d)}();
            } else {
                pm.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-d));
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}

/// @notice Acts on swaps only, like the Pons and AINDEX share-market hooks: liquidity providers are untouched.
contract AfterSwapHook {
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (AfterSwapHook.afterSwap.selector, 0);
    }
}

/// @notice Admits no outside liquidity.
contract RefuseAddHook {
    error OnlyOurLiquidity();

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert OnlyOurLiquidity();
    }
}

/// @notice Watches removals: harmless here, but it could block one, so the adapter refuses it.
contract RemoveHook {
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return RemoveHook.beforeRemoveLiquidity.selector;
    }
}

// ------------------------------------------------------------------ Uniswap v3, mocked

contract MockV3Factory {
    mapping(bytes32 => address) public pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[keccak256(abi.encode(t0, t1, fee))];
    }
}

/**
 * @notice A v3 pool's state, set by the test: price, fee growth and tick records. It holds no tokens (the
 *         mock NPM does) and does not swap; `setPrice` moves it as a swap would.
 */
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    uint128 public liquidity;

    constructor(address t0, address t1, uint24 fee_, int24 spacing, uint160 sqrtP) {
        token0 = t0;
        token1 = t1;
        fee = fee_;
        tickSpacing = spacing;
        setPrice(sqrtP);
    }

    function setPrice(uint160 sqrtP) public {
        sqrtPriceX96 = sqrtP;
        tick = TickMath.getTickAtSqrtPrice(sqrtP);
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    /// @notice Fees earned by every unit of in-range liquidity.
    function growFees(uint256 g0, uint256 g1) external {
        unchecked {
            feeGrowthGlobal0X128 += g0;
            feeGrowthGlobal1X128 += g1;
        }
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 1, 1, 0, true);
    }

    /// @dev Every tick record reads as zero growth outside, so all growth counts as inside while in range.
    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (1, 0, 0, 0, 0, 0, 0, true);
    }
}

/**
 * @notice A NonfungiblePositionManager with v3's math and bookkeeping, holding the tokens itself. Tokens it
 *         lacks when paying out (because the test moved the price, as swappers would have paid) are minted.
 */
contract MockNPM {
    struct P {
        address owner;
        address pool;
        int24 lo;
        int24 hi;
        uint128 liquidity;
        uint256 last0;
        uint256 last1;
        uint128 owed0;
        uint128 owed1;
    }

    address public factory;
    address public WETH9;
    uint256 public nextId = 1;
    mapping(uint256 => P) public ps;

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH9 = weth_;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(ps[id].owner != address(0), "Invalid token ID");
        return ps[id].owner;
    }

    function positions(uint256 id)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        P memory p = ps[id];
        require(p.owner != address(0), "Invalid token ID");
        MockV3Pool pool = MockV3Pool(p.pool);
        return (0, address(0), pool.token0(), pool.token1(), pool.fee(), p.lo, p.hi, p.liquidity, p.last0, p.last1, p.owed0, p.owed1);
    }

    function mint(MintParams calldata m) external returns (uint256 id, uint128 liquidity, uint256 a0, uint256 a1) {
        address pool = MockV3Factory(factory).getPool(m.token0, m.token1, m.fee);
        require(pool != address(0), "no pool");
        id = nextId++;
        ps[id].owner = m.recipient;
        ps[id].pool = pool;
        ps[id].lo = m.tickLower;
        ps[id].hi = m.tickUpper;
        (ps[id].last0, ps[id].last1) = _inside(ps[id]);
        (liquidity, a0, a1) = _add(id, m.amount0Desired, m.amount1Desired, m.amount0Min, m.amount1Min);
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external
        returns (uint128 liquidity, uint256 a0, uint256 a1)
    {
        require(ps[p.tokenId].owner == msg.sender, "not owner");
        _accrue(p.tokenId);
        return _add(p.tokenId, p.amount0Desired, p.amount1Desired, p.amount0Min, p.amount1Min);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint256 a0, uint256 a1) {
        P storage s = ps[p.tokenId];
        require(s.owner == msg.sender, "not owner");
        require(p.liquidity > 0 && p.liquidity <= s.liquidity, "bad liquidity");
        _accrue(p.tokenId);
        (uint160 sqrtP, uint160 sa, uint160 sb) = _prices(s);
        (a0, a1) = _amounts(sqrtP, sa, sb, p.liquidity, false);
        require(a0 >= p.amount0Min && a1 >= p.amount1Min, "Price slippage check");
        s.liquidity -= p.liquidity;
        s.owed0 += uint128(a0);
        s.owed1 += uint128(a1);
    }

    function collect(CollectParams calldata p) external returns (uint256 a0, uint256 a1) {
        P storage s = ps[p.tokenId];
        require(s.owner == msg.sender, "not owner");
        if (s.liquidity > 0) _accrue(p.tokenId);
        a0 = s.owed0 < p.amount0Max ? s.owed0 : p.amount0Max;
        a1 = s.owed1 < p.amount1Max ? s.owed1 : p.amount1Max;
        s.owed0 -= uint128(a0);
        s.owed1 -= uint128(a1);
        MockV3Pool pool = MockV3Pool(s.pool);
        _pay(pool.token0(), p.recipient, a0);
        _pay(pool.token1(), p.recipient, a1);
    }

    function burn(uint256 id) external {
        P storage s = ps[id];
        require(s.owner == msg.sender, "not owner");
        require(s.liquidity == 0 && s.owed0 == 0 && s.owed1 == 0, "Not cleared");
        delete ps[id];
    }

    function _add(uint256 id, uint256 d0, uint256 d1, uint256 m0, uint256 m1)
        internal
        returns (uint128 liquidity, uint256 a0, uint256 a1)
    {
        P storage s = ps[id];
        (uint160 sqrtP, uint160 sa, uint160 sb) = _prices(s);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sa, sb, d0, d1);
        require(liquidity > 0, "zero liquidity");
        (a0, a1) = _amounts(sqrtP, sa, sb, liquidity, true);
        require(a0 >= m0 && a1 >= m1, "Price slippage check");
        s.liquidity += liquidity;
        MockV3Pool pool = MockV3Pool(s.pool);
        if (a0 > 0) IERC20(pool.token0()).transferFrom(msg.sender, address(this), a0);
        if (a1 > 0) IERC20(pool.token1()).transferFrom(msg.sender, address(this), a1);
    }

    function _accrue(uint256 id) internal {
        P storage s = ps[id];
        (uint256 g0, uint256 g1) = _inside(s);
        unchecked {
            s.owed0 += uint128(FullMath.mulDiv(g0 - s.last0, s.liquidity, 1 << 128));
            s.owed1 += uint128(FullMath.mulDiv(g1 - s.last1, s.liquidity, 1 << 128));
        }
        s.last0 = g0;
        s.last1 = g1;
    }

    function _inside(P storage s) internal view returns (uint256, uint256) {
        MockV3Pool pool = MockV3Pool(s.pool);
        int24 t = pool.tick();
        if (t < s.lo || t >= s.hi) return (0, 0);
        return (pool.feeGrowthGlobal0X128(), pool.feeGrowthGlobal1X128());
    }

    function _prices(P storage s) internal view returns (uint160, uint160, uint160) {
        return (MockV3Pool(s.pool).sqrtPriceX96(), TickMath.getSqrtPriceAtTick(s.lo), TickMath.getSqrtPriceAtTick(s.hi));
    }

    function _amounts(uint160 sqrtP, uint160 sa, uint160 sb, uint128 l, bool up) internal pure returns (uint256 a0, uint256 a1) {
        if (sqrtP <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, l, up);
        } else if (sqrtP < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtP, sb, l, up);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sqrtP, l, up);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, l, up);
        }
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) MockERC20(token).mint(address(this), amount - bal);
        IERC20(token).transfer(to, amount);
    }
}
