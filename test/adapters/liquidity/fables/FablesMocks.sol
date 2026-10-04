// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {FablesRangeState, FablesUserPosition} from "../../../../src/interfaces/external/fables/IFablesLedger.sol";
import {IFablesPoolRegistry} from "../../../../src/interfaces/external/fables/IFablesPoolRegistry.sol";
import {MockERC20} from "../../../utils/Mocks.sol";

/**
 * @notice The part of a Uniswap v4 PoolManager the adapter reads: storage through `extsload`, laid out exactly as
 *         v4 lays it out, so `StateLibrary` works unchanged. Prices, fee growth and tick crossings follow v4's
 *         rules (a tick's "outside" counters flip when the price crosses it), so fees inside a range behave like
 *         the real thing, including going quiet while the price is out of range.
 */
contract MockPoolManager {
    using StateLibrary for IPoolManager;

    mapping(bytes32 => bytes32) internal _s;
    mapping(bytes32 => int24[]) internal _initTicks; // by pool id
    mapping(bytes32 => mapping(int24 => bool)) internal _isInit;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _s[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; ++i) values[i] = _s[bytes32(uint256(startSlot) + i)];
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) values[i] = _s[slots[i]];
    }

    // ---- slots, as StateLibrary computes them
    function _state(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT));
    }

    function _tickSlot(PoolId id, int24 tick) internal pure returns (bytes32) {
        bytes32 ticks = bytes32(uint256(_state(id)) + StateLibrary.TICKS_OFFSET);
        return keccak256(abi.encodePacked(int256(tick), ticks));
    }

    function _posSlot(PoolId id, address owner, int24 tl, int24 tu) internal pure returns (bytes32) {
        bytes32 positions = bytes32(uint256(_state(id)) + StateLibrary.POSITIONS_OFFSET);
        return keccak256(abi.encodePacked(Position.calculatePositionKey(owner, tl, tu, bytes32(0)), positions));
    }

    // ---- reads
    function spot(PoolId id) public view returns (uint160 sqrtP, int24 tick) {
        (sqrtP, tick,,) = IPoolManager(address(this)).getSlot0(id);
    }

    function globals(PoolId id) public view returns (uint256 g0, uint256 g1) {
        bytes32 st = _state(id);
        g0 = uint256(_s[bytes32(uint256(st) + 1)]);
        g1 = uint256(_s[bytes32(uint256(st) + 2)]);
    }

    function inside(PoolId id, int24 tl, int24 tu) public view returns (uint256, uint256) {
        return IPoolManager(address(this)).getFeeGrowthInside(id, tl, tu);
    }

    function position(PoolId id, address owner, int24 tl, int24 tu)
        public
        view
        returns (uint128 liq, uint256 last0, uint256 last1)
    {
        return IPoolManager(address(this)).getPositionInfo(id, owner, tl, tu, bytes32(0));
    }

    // ---- writes (tests and the mock ledger)
    function initialize(PoolId id, uint160 sqrtP) external {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        _s[_state(id)] = _slot0(sqrtP, tick);
    }

    /// @dev Moves the price, crossing initialized ticks the way v4 does: outside = global - outside.
    function setSpot(PoolId id, uint160 sqrtP) external {
        (, int24 oldTick) = spot(id);
        int24 newTick = TickMath.getTickAtSqrtPrice(sqrtP);
        (uint256 g0, uint256 g1) = globals(id);
        int24[] memory ticks = _initTicks[PoolId.unwrap(id)];
        for (uint256 i; i < ticks.length; ++i) {
            int24 t = ticks[i];
            bool crossed = (oldTick < t && t <= newTick) || (newTick < t && t <= oldTick);
            if (crossed) {
                bytes32 ts = _tickSlot(id, t);
                _s[bytes32(uint256(ts) + 1)] = bytes32(g0 - uint256(_s[bytes32(uint256(ts) + 1)]));
                _s[bytes32(uint256(ts) + 2)] = bytes32(g1 - uint256(_s[bytes32(uint256(ts) + 2)]));
            }
        }
        _s[_state(id)] = _slot0(sqrtP, newTick);
    }

    function initTick(PoolId id, int24 tick) external {
        if (_isInit[PoolId.unwrap(id)][tick]) return;
        _isInit[PoolId.unwrap(id)][tick] = true;
        _initTicks[PoolId.unwrap(id)].push(tick);
        (, int24 cur) = spot(id);
        if (tick <= cur) {
            (uint256 g0, uint256 g1) = globals(id);
            bytes32 ts = _tickSlot(id, tick);
            _s[bytes32(uint256(ts) + 1)] = bytes32(g0);
            _s[bytes32(uint256(ts) + 2)] = bytes32(g1);
        }
    }

    function addGrowth(PoolId id, uint256 d0, uint256 d1) external {
        bytes32 st = _state(id);
        unchecked {
            _s[bytes32(uint256(st) + 1)] = bytes32(uint256(_s[bytes32(uint256(st) + 1)]) + d0);
            _s[bytes32(uint256(st) + 2)] = bytes32(uint256(_s[bytes32(uint256(st) + 2)]) + d1);
        }
    }

    function setPosition(PoolId id, address owner, int24 tl, int24 tu, uint128 liq, uint256 last0, uint256 last1)
        external
    {
        bytes32 ps = _posSlot(id, owner, tl, tu);
        _s[ps] = bytes32(uint256(liq));
        _s[bytes32(uint256(ps) + 1)] = bytes32(last0);
        _s[bytes32(uint256(ps) + 2)] = bytes32(last1);
    }

    function _slot0(uint160 sqrtP, int24 tick) internal pure returns (bytes32) {
        return bytes32(uint256(sqrtP) | (uint256(uint24(tick)) << 160));
    }
}

/**
 * @notice A Fables hook ledger for unit tests, following the verified source's rules that the adapter relies on:
 *         shares 1:1 with liquidity, fees collected from the v4 position on every touch and split per share after
 *         the claim-fee skim, `withdraw` never pausable, `deposit` and `claimFees` pausable, `claimFees` bounded by
 *         `maxFeeBps` and reverting `NothingToClaim` for a stranger. Principal moves at the pool's price with v4's
 *         rounding (up when paying in, down when paying out). The ledger holds token reserves itself, standing in
 *         for the rest of the pool.
 */
contract MockFablesLedger {
    using PoolIdLibrary for PoolKey;

    error LedgerPaused();
    error NothingToClaim();
    error ClaimFeeAboveMax();
    error PrincipalAboveMax();
    error PrincipalBelowMin();
    error InvalidSink();
    error Blocked();

    struct RK {
        PoolKey key;
        int24 tl;
        int24 tu;
        bool set;
    }

    MockPoolManager public immutable pm;
    uint16 public claimFeeBps;
    address public treasury;
    uint256 public pausedUntil;
    address public ballotGate;
    /// @notice A recipient that "blocklists": any payout to it reverts (stands in for a USDG freeze).
    address public blocked;

    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(uint256 => FablesRangeState) internal _ranges;
    mapping(uint256 => mapping(address => FablesUserPosition)) internal _pos;
    mapping(uint256 => RK) internal _keys;
    mapping(bytes32 => uint256[]) internal _poolRanges;
    mapping(PoolId => uint24) public maxFee;

    constructor(MockPoolManager pm_) {
        pm = pm_;
    }

    function poolManager() external view returns (address) {
        return address(pm);
    }

    // ---- admin (tests)
    function setClaimFee(uint16 bps, address to) external {
        claimFeeBps = bps;
        treasury = to;
    }

    function setPaused(uint256 duration) external {
        pausedUntil = duration == 0 ? 0 : block.timestamp + duration;
    }

    function setBlocked(address who) external {
        blocked = who;
    }

    function paused() public view returns (bool) {
        return pausedUntil > block.timestamp;
    }

    // ---- views
    function rangeId(PoolId poolId, int24 tl, int24 tu) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, tl, tu)));
    }

    function rangeState(uint256 id) external view returns (FablesRangeState memory) {
        return _ranges[id];
    }

    function userPosition(uint256 id, address owner) external view returns (FablesUserPosition memory) {
        return _pos[id][owner];
    }

    function effectiveClaimFee(uint256 id) external view returns (uint16) {
        return _ranges[id].totalShares == _ranges[id].totalStaked ? 0 : (treasury == address(0) ? 0 : claimFeeBps);
    }

    // ---- actions
    function deposit(
        PoolKey calldata key,
        int24 tl,
        int24 tu,
        uint128 liq,
        uint128 max0,
        uint128 max1,
        uint256 deadline
    ) external payable {
        if (paused()) revert LedgerPaused();
        require(msg.value == 0 && block.timestamp <= deadline && liq != 0, "bad deposit");
        require(address(key.hooks) == address(this), "PoolNotConfigured");
        uint256 id = rangeId(key.toId(), tl, tu);
        if (!_keys[id].set) {
            _keys[id] = RK(key, tl, tu, true);
            _poolRanges[PoolId.unwrap(key.toId())].push(id);
            pm.initTick(key.toId(), tl);
            pm.initTick(key.toId(), tu);
        }
        _sync(id);
        _settle(id, msg.sender);
        _payIn(key, tl, tu, liq, max0, max1);
        _ranges[id].totalShares += liq;
        balanceOf[msg.sender][id] += liq;
        _grow(key, tl, tu, liq);
    }

    function _payIn(PoolKey calldata key, int24 tl, int24 tu, uint128 liq, uint128 max0, uint128 max1) internal {
        (uint256 a0, uint256 a1) = _amounts(key, tl, tu, liq, true);
        if (a0 > max0 || a1 > max1) revert PrincipalAboveMax();
        if (a0 != 0) IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), a0);
        if (a1 != 0) IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), a1);
    }

    function _grow(PoolKey calldata key, int24 tl, int24 tu, uint128 liq) internal {
        (uint128 pl,,) = pm.position(key.toId(), address(this), tl, tu);
        (uint256 g0, uint256 g1) = pm.inside(key.toId(), tl, tu);
        pm.setPosition(key.toId(), address(this), tl, tu, pl + liq, g0, g1);
    }

    function withdraw(
        PoolKey calldata key,
        int24 tl,
        int24 tu,
        uint128 liq,
        address to,
        uint128 min0,
        uint128 min1,
        uint256 deadline
    ) external {
        // No pause check: Fables' withdraw cannot be paused.
        require(block.timestamp <= deadline && liq != 0 && to != address(0), "bad withdraw");
        if (to == address(this) || to == address(pm)) revert InvalidSink();
        uint256 id = rangeId(key.toId(), tl, tu);
        _sync(id);
        _settle(id, msg.sender);
        balanceOf[msg.sender][id] -= liq; // reverts when over-withdrawing
        _ranges[id].totalShares -= liq;
        _shrink(key, tl, tu, liq);
        (uint256 a0, uint256 a1) = _amounts(key, tl, tu, liq, false);
        if (a0 < min0 || a1 < min1) revert PrincipalBelowMin();
        _pay(Currency.unwrap(key.currency0), to, a0);
        _pay(Currency.unwrap(key.currency1), to, a1);
    }

    function _shrink(PoolKey calldata key, int24 tl, int24 tu, uint128 liq) internal {
        (uint128 pl, uint256 l0, uint256 l1) = pm.position(key.toId(), address(this), tl, tu);
        pm.setPosition(key.toId(), address(this), tl, tu, pl - liq, l0, l1);
    }

    function claimFees(PoolKey calldata key, int24 tl, int24 tu, address to, uint16 maxFeeBps) external {
        if (paused()) revert LedgerPaused();
        if (to == address(0) || to == address(this) || to == address(pm)) revert InvalidSink();
        uint256 id = rangeId(key.toId(), tl, tu);
        if (this.effectiveClaimFee(id) > maxFeeBps) revert ClaimFeeAboveMax();
        FablesUserPosition storage p = _pos[id][msg.sender];
        if (balanceOf[msg.sender][id] == 0 && p.owed0 == 0 && p.owed1 == 0) revert NothingToClaim();
        _sync(id);
        _settle(id, msg.sender);
        (uint256 a0, uint256 a1) = (p.owed0, p.owed1);
        if (a0 == 0 && a1 == 0) return;
        (p.owed0, p.owed1) = (0, 0);
        _pay(Currency.unwrap(key.currency0), to, a0);
        _pay(Currency.unwrap(key.currency1), to, a1);
    }

    /// @notice Test helper: swappers paid `fee0`/`fee1` to the in-range liquidity of this pool.
    function accrue(PoolKey calldata key, uint256 fee0, uint256 fee1) external {
        PoolId pid = key.toId();
        (, int24 tick) = pm.spot(pid);
        uint256[] memory ids = _poolRanges[PoolId.unwrap(pid)];
        uint256 active;
        for (uint256 i; i < ids.length; ++i) {
            RK memory k = _keys[ids[i]];
            if (k.tl <= tick && tick < k.tu) {
                (uint128 l,,) = pm.position(pid, address(this), k.tl, k.tu);
                active += l;
            }
        }
        require(active != 0, "no active liquidity");
        pm.addGrowth(pid, FullMath.mulDiv(fee0, 1 << 128, active), FullMath.mulDiv(fee1, 1 << 128, active));
        MockERC20(Currency.unwrap(key.currency0)).mint(address(this), fee0);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(this), fee1);
    }

    // ---- internals
    function _sync(uint256 id) internal {
        RK memory k = _keys[id];
        FablesRangeState storage r = _ranges[id];
        if (!k.set || r.totalShares == 0) return;
        PoolId pid = k.key.toId();
        (uint128 liq, uint256 l0, uint256 l1) = pm.position(pid, address(this), k.tl, k.tu);
        (uint256 g0, uint256 g1) = pm.inside(pid, k.tl, k.tu);
        uint256 f0;
        uint256 f1;
        unchecked {
            f0 = FullMath.mulDiv(g0 - l0, liq, 1 << 128);
            f1 = FullMath.mulDiv(g1 - l1, liq, 1 << 128);
        }
        pm.setPosition(pid, address(this), k.tl, k.tu, liq, g0, g1);
        if (f0 == 0 && f1 == 0) return;
        if (treasury != address(0) && claimFeeBps != 0) {
            uint256 c0 = f0 * claimFeeBps / 10_000;
            uint256 c1 = f1 * claimFeeBps / 10_000;
            _pay(Currency.unwrap(k.key.currency0), treasury, c0);
            _pay(Currency.unwrap(k.key.currency1), treasury, c1);
            f0 -= c0;
            f1 -= c1;
        }
        r.accFee0X128 += FullMath.mulDiv(f0, 1 << 128, r.totalShares);
        r.accFee1X128 += FullMath.mulDiv(f1, 1 << 128, r.totalShares);
    }

    function _settle(uint256 id, address owner) internal {
        FablesRangeState storage r = _ranges[id];
        FablesUserPosition storage p = _pos[id][owner];
        uint256 bal = balanceOf[owner][id];
        if (bal != 0) {
            p.owed0 += uint128(FullMath.mulDiv(bal, r.accFee0X128 - p.checkpoint0X128, 1 << 128));
            p.owed1 += uint128(FullMath.mulDiv(bal, r.accFee1X128 - p.checkpoint1X128, 1 << 128));
        }
        p.checkpoint0X128 = r.accFee0X128;
        p.checkpoint1X128 = r.accFee1X128;
    }

    function _amounts(PoolKey calldata key, int24 tl, int24 tu, uint128 liq, bool up)
        internal
        view
        returns (uint256 a0, uint256 a1)
    {
        (uint160 p,) = pm.spot(key.toId());
        uint160 a = TickMath.getSqrtPriceAtTick(tl);
        uint160 b = TickMath.getSqrtPriceAtTick(tu);
        if (p <= a) {
            a0 = SqrtPriceMath.getAmount0Delta(a, b, liq, up);
        } else if (p < b) {
            a0 = SqrtPriceMath.getAmount0Delta(p, b, liq, up);
            a1 = SqrtPriceMath.getAmount1Delta(a, p, liq, up);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(a, b, liq, up);
        }
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == blocked) revert Blocked();
        IERC20(token).transfer(to, amount);
    }
}

/// @notice Fables' pool registry: an admin-written list of full pool keys.
contract MockFablesRegistry {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => IFablesPoolRegistry.PoolInfo) internal _info;
    mapping(bytes32 => bool) public registered;

    function register(PoolKey calldata key) external returns (bytes32 id) {
        id = PoolId.unwrap(key.toId());
        _info[id] = IFablesPoolRegistry.PoolInfo(key, key.toId(), true);
        registered[id] = true;
    }

    function setActive(bytes32 id, bool active) external {
        _info[id].active = active;
    }

    function isRegistered(PoolId id) external view returns (bool) {
        return registered[PoolId.unwrap(id)];
    }

    function poolById(PoolId id) external view returns (IFablesPoolRegistry.PoolInfo memory) {
        require(registered[PoolId.unwrap(id)], "NotRegistered");
        return _info[PoolId.unwrap(id)];
    }
}

/// @notice The weekly USDG pot: a cumulative Merkle distributor with the same leaf encoding as Fables'.
contract MockPotDistributor {
    address public immutable token;
    bytes32 public root;
    mapping(address => uint256) public claimed;

    error NothingToClaim();
    error InvalidProof();

    constructor(address token_) {
        token = token_;
    }

    function setRoot(bytes32 r) external {
        root = r;
    }

    function leaf(address account, uint256 cumulative) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function claim(address account, uint256 cumulative, bytes32[] calldata proof) external {
        if (!MerkleProof.verifyCalldata(proof, root, leaf(account, cumulative))) revert InvalidProof();
        uint256 already = claimed[account];
        if (cumulative <= already) revert NothingToClaim();
        claimed[account] = cumulative;
        IERC20(token).transfer(account, cumulative - already);
    }
}
