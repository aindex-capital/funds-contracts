// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParams, MorphoMarket, IMorphoIrm, IMorphoOracle} from "../../../src/interfaces/external/morpho/IMorpho.sol";
import {MorphoMath} from "../../../src/adapters/lending/MorphoMath.sol";

/// @notice A fixed per-second borrow rate, settable by tests.
contract MockIrm is IMorphoIrm {
    uint256 public rate;

    function set(uint256 r) external {
        rate = r;
    }

    function borrowRateView(MarketParams memory, MorphoMarket memory) external view returns (uint256) {
        return rate;
    }

    /// @dev The real model has a state-changing twin; Morpho calls this one when accruing.
    function borrowRate(MarketParams memory, MorphoMarket memory) external view returns (uint256) {
        return rate;
    }
}

/// @notice A settable Morpho-style oracle (raw loan units per raw collateral unit, times 1e36).
contract MockMorphoOracle is IMorphoOracle {
    uint256 public price;

    function set(uint256 p) external {
        price = p;
    }
}

/**
 * @notice A small Morpho Blue look-alike for unit tests: markets, supply and borrow shares with the same
 *         virtual amounts, interest from a rate model, a protocol fee, per-market health at the oracle and
 *         LLTV, and the liquidity check on withdraw and borrow. Written for these tests; it skips Morpho's
 *         authorisation system (only the position holder may take money out), callbacks, liquidation and
 *         flash loans, which the adapter never uses.
 */
contract MockMorpho {
    using MorphoMath for uint256;

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    mapping(bytes32 => MorphoMarket) internal _market;
    mapping(bytes32 => mapping(address => Position)) public position;
    mapping(bytes32 => MarketParams) public idToMarketParams;

    function id(MarketParams memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function market(bytes32 i) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        MorphoMarket memory m = _market[i];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    function createMarket(MarketParams memory p) external {
        bytes32 i = id(p);
        require(_market[i].lastUpdate == 0, "exists");
        _market[i].lastUpdate = uint128(block.timestamp);
        idToMarketParams[i] = p;
    }

    function setFee(MarketParams memory p, uint256 fee) external {
        accrueInterest(p);
        _market[id(p)].fee = uint128(fee);
    }

    function accrueInterest(MarketParams memory p) public {
        bytes32 i = id(p);
        MorphoMarket storage m = _market[i];
        require(m.lastUpdate != 0, "market not created");
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;
        if (p.irm != address(0) && m.totalBorrowAssets != 0) {
            uint256 rate = IMorphoIrm(p.irm).borrowRateView(p, m);
            uint256 interest = uint256(m.totalBorrowAssets).mulDivDown(MorphoMath.compoundedGrowth(rate, elapsed), 1e18);
            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);
            if (m.fee != 0) {
                uint256 feeAssets = interest.mulDivDown(m.fee, 1e18);
                uint256 feeShares = feeAssets.toSharesDown(m.totalSupplyAssets - feeAssets, m.totalSupplyShares);
                m.totalSupplyShares += uint128(feeShares);
                position[i][address(0xFEE)].supplyShares += feeShares;
            }
        }
        m.lastUpdate = uint128(block.timestamp);
    }

    function supply(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        accrueInterest(p);
        bytes32 i = id(p);
        MorphoMarket storage m = _market[i];
        if (assets > 0) shares = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);
        position[i][onBehalf].supplyShares += shares;
        m.totalSupplyShares += uint128(shares);
        m.totalSupplyAssets += uint128(assets);
        IERC20(p.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function withdraw(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(p);
        bytes32 i = id(p);
        MorphoMarket storage m = _market[i];
        if (assets > 0) shares = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        position[i][onBehalf].supplyShares -= shares;
        m.totalSupplyShares -= uint128(shares);
        m.totalSupplyAssets -= uint128(assets);
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
        IERC20(p.loanToken).transfer(receiver, assets);
        return (assets, shares);
    }

    function borrow(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(p);
        bytes32 i = id(p);
        MorphoMarket storage m = _market[i];
        if (assets > 0) shares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsDown(m.totalBorrowAssets, m.totalBorrowShares);
        position[i][onBehalf].borrowShares += uint128(shares);
        m.totalBorrowShares += uint128(shares);
        m.totalBorrowAssets += uint128(assets);
        require(_healthy(p, i, onBehalf), "insufficient collateral");
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
        IERC20(p.loanToken).transfer(receiver, assets);
        return (assets, shares);
    }

    function repay(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        accrueInterest(p);
        bytes32 i = id(p);
        MorphoMarket storage m = _market[i];
        if (assets > 0) shares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        position[i][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = m.totalBorrowAssets > assets ? m.totalBorrowAssets - uint128(assets) : 0;
        IERC20(p.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf, bytes memory) external {
        bytes32 i = id(p);
        require(_market[i].lastUpdate != 0, "market not created");
        position[i][onBehalf].collateral += uint128(assets);
        IERC20(p.collateralToken).transferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory p, uint256 assets, address onBehalf, address receiver) external {
        require(msg.sender == onBehalf, "unauthorized");
        accrueInterest(p);
        bytes32 i = id(p);
        position[i][onBehalf].collateral -= uint128(assets);
        require(_healthy(p, i, onBehalf), "insufficient collateral");
        IERC20(p.collateralToken).transfer(receiver, assets);
    }

    function _healthy(MarketParams memory p, bytes32 i, address who) internal view returns (bool) {
        Position memory pos = position[i][who];
        if (pos.borrowShares == 0) return true;
        MorphoMarket memory m = _market[i];
        uint256 owed = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 maxBorrow = uint256(pos.collateral).mulDivDown(IMorphoOracle(p.oracle).price(), 1e36).mulDivDown(p.lltv, 1e18);
        return owed <= maxBorrow;
    }
}
