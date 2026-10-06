// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A Uniswap v3 factory that knows the pools it is told about.
contract MockV3Factory {
    mapping(bytes32 => address) internal pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[keccak256(abi.encode(t0, t1, fee))];
    }
}

/// @notice A pool that only answers positions by key, and its identity. Liquidity it reports is backed by tokens the
///         test mints to it; the adapter never reads a price from it.
contract MockClmPool {
    struct P {
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    address public token0;
    address public token1;
    uint24 public fee = 3000;
    mapping(bytes32 => P) internal pos;

    constructor(address t0, address t1) {
        (token0, token1) = (t0, t1);
    }

    function setFee(uint24 f) external {
        fee = f;
    }

    function set(bytes32 key, uint128 liquidity, uint128 owed0, uint128 owed1) external {
        pos[key] = P(liquidity, owed0, owed1);
    }

    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128) {
        P memory p = pos[key];
        return (p.liquidity, 0, 0, p.owed0, p.owed1);
    }
}

/// @notice A CLM strategy: holds the vault's tokens idle (no live ranges unless the test sets some on the pool).
contract MockClmStrategy {
    address public vault;
    address public pool;
    address public factory;
    address public owner;
    address public lpToken0;
    address public lpToken1;
    uint256 public locked0;
    uint256 public locked1;
    int24 public lo = -600;
    int24 public hi = 600;
    int24 public altLo = -60;
    int24 public altHi = 60;

    constructor(address factory_, address owner_, address pool_, address t0, address t1) {
        (factory, owner, pool, lpToken0, lpToken1) = (factory_, owner_, pool_, t0, t1);
    }

    function setVault(address v) external {
        vault = v;
    }

    function setOwner(address o) external {
        owner = o;
    }

    function setLocked(uint256 l0, uint256 l1) external {
        (locked0, locked1) = (l0, l1);
    }

    function balancesOfThis() external view returns (uint256, uint256) {
        return (IERC20(lpToken0).balanceOf(address(this)), IERC20(lpToken1).balanceOf(address(this)));
    }

    function lockedProfit() external view returns (uint256, uint256) {
        return (locked0, locked1);
    }

    function getKeys() public view returns (bytes32, bytes32) {
        return (keccak256(abi.encodePacked(address(this), lo, hi)), keccak256(abi.encodePacked(address(this), altLo, altHi)));
    }

    function positionMain() external view returns (int24, int24) {
        return (lo, hi);
    }

    function positionAlt() external view returns (int24, int24) {
        return (altLo, altHi);
    }

    function pay(address to, uint256 a0, uint256 a1) external {
        require(msg.sender == vault, "only vault");
        if (a0 != 0) IERC20(lpToken0).transfer(to, a0);
        if (a1 != 0) IERC20(lpToken1).transfer(to, a1);
    }
}

/// @notice A CLM vault on the idle model: shares over the strategy's balances less locked profit, deposits taken in the
///         current ratio, an optional deposit fee and withdraw fee (basis points), and switches for calm and transfers.
contract MockClmVault is ERC20 {
    MockClmStrategy public strategy;
    address public owner;
    bool public isCalm = true;
    bool public blockTransfers;
    uint256 public depositFeeBps;
    uint256 public withdrawFee;
    uint256 public constant FEE_DENOMINATOR = 10_000;

    constructor(MockClmStrategy s, address owner_) ERC20("Cow vault", "cowMOCK") {
        strategy = s;
        owner = owner_;
    }

    function setCalm(bool c) external {
        isCalm = c;
    }

    function setBlockTransfers(bool b) external {
        blockTransfers = b;
    }

    function setFees(uint256 dep, uint256 wd) external {
        (depositFeeBps, withdrawFee) = (dep, wd);
    }

    function setOwner(address o) external {
        owner = o;
    }

    function wants() external view returns (address, address) {
        return (strategy.lpToken0(), strategy.lpToken1());
    }

    function balances() public view returns (uint256 b0, uint256 b1) {
        (b0, b1) = strategy.balancesOfThis();
        (uint256 l0, uint256 l1) = strategy.lockedProfit();
        b0 = b0 > l0 ? b0 - l0 : 0;
        b1 = b1 > l1 ? b1 - l1 : 0;
    }

    function previewDeposit(uint256 a0, uint256 a1) public view returns (uint256 shares, uint256 u0, uint256 u1, uint256 f0, uint256 f1) {
        uint256 s = totalSupply();
        (uint256 b0, uint256 b1) = balances();
        uint256 k;
        if (s == 0) {
            (k, u0, u1) = (a0 * 1e12 + a1, a0, a1);
        } else {
            uint256 k0 = b0 == 0 ? type(uint256).max : a0 * s / b0;
            uint256 k1 = b1 == 0 ? type(uint256).max : a1 * s / b1;
            k = k0 < k1 ? k0 : k1;
            u0 = Math.mulDiv(b0, k, s, Math.Rounding.Ceil);
            u1 = Math.mulDiv(b1, k, s, Math.Rounding.Ceil);
        }
        shares = k * (10_000 - depositFeeBps) / 10_000;
        (f0, f1) = (0, 0);
    }

    function previewWithdraw(uint256 shares) public view returns (uint256 a0, uint256 a1) {
        (uint256 b0, uint256 b1) = balances();
        uint256 s = totalSupply();
        a0 = b0 * shares / s * (10_000 - withdrawFee) / 10_000;
        a1 = b1 * shares / s * (10_000 - withdrawFee) / 10_000;
    }

    function deposit(uint256 a0, uint256 a1, uint256 minShares) external {
        require(isCalm, "not calm");
        (uint256 shares, uint256 u0, uint256 u1,,) = previewDeposit(a0, a1);
        require(shares >= minShares && shares != 0, "slippage");
        if (u0 != 0) IERC20(strategy.lpToken0()).transferFrom(msg.sender, address(strategy), u0);
        if (u1 != 0) IERC20(strategy.lpToken1()).transferFrom(msg.sender, address(strategy), u1);
        _mint(msg.sender, shares);
    }

    function withdraw(uint256 shares, uint256 min0, uint256 min1) external {
        require(isCalm, "not calm");
        (uint256 a0, uint256 a1) = previewWithdraw(shares);
        require(a0 >= min0 && a1 >= min1, "slippage");
        _burn(msg.sender, shares);
        strategy.pay(msg.sender, a0, a1);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blockTransfers || from == address(0) || to == address(0), "gated");
        super._update(from, to, value);
    }
}
