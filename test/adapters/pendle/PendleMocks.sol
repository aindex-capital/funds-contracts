// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../utils/Mocks.sol";
import {
    ApproxParams,
    LimitOrderData,
    TokenInput,
    TokenOutput
} from "../../../src/interfaces/external/pendle/IPendle.sol";

/// @notice An SY over one asset at a fixed exchange rate of 1: in and out in the asset only.
contract MockSY is MockERC20 {
    address public immutable asset;

    constructor(address asset_) MockERC20("SY", "SY", 6) {
        asset = asset_;
    }

    function assetInfo() external view returns (uint8, address, uint8) {
        return (0, asset, 6);
    }

    function getTokensIn() external view returns (address[] memory t) {
        t = new address[](1);
        t[0] = asset;
    }

    function getTokensOut() external view returns (address[] memory t) {
        t = new address[](1);
        t[0] = asset;
    }

    function isValidTokenIn(address t) external view returns (bool) {
        return t == asset;
    }

    function isValidTokenOut(address t) external view returns (bool) {
        return t == asset;
    }

    function exchangeRate() external pure returns (uint256) {
        return 1e18;
    }

    function previewRedeem(address, uint256 a) external pure returns (uint256) {
        return a;
    }

    function redeem(address receiver, uint256 a, address, uint256, bool) external returns (uint256) {
        _burn(msg.sender, a);
        MockERC20(asset).mint(receiver, a);
        return a;
    }
}

/// @notice A YT that pays `interest` SY to whoever claims, and one reward token.
contract MockYT is MockERC20 {
    MockSY public immutable sy;
    MockERC20 public immutable reward;
    bool public expired;
    uint256 public interest;

    constructor(MockSY sy_, MockERC20 reward_) MockERC20("YT", "YT", 6) {
        sy = sy_;
        reward = reward_;
    }

    function setInterest(uint256 a) external {
        interest = a;
    }

    function setExpired(bool e) external {
        expired = e;
    }

    function isExpired() external view returns (bool) {
        return expired;
    }

    function getRewardTokens() external view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(reward);
    }

    function redeemDueInterestAndRewards(address user, bool, bool) external returns (uint256, uint256[] memory r) {
        uint256 i = interest;
        interest = 0;
        sy.mint(user, i);
        reward.mint(user, 1e6);
        r = new uint256[](1);
        r[0] = 1e6;
        return (i, r);
    }
}

/// @notice A market: its own LP token, with PT, YT and SY.
contract MockMarket is MockERC20 {
    MockSY public immutable sy;
    MockERC20 public immutable pt;
    MockYT public immutable yt;
    MockERC20 public immutable reward;
    uint256 public expiry;

    constructor(MockSY sy_, MockERC20 pt_, MockYT yt_, MockERC20 reward_) MockERC20("LP", "LP", 6) {
        sy = sy_;
        pt = pt_;
        yt = yt_;
        reward = reward_;
        expiry = block.timestamp + 180 days;
    }

    function setExpiry(uint256 e) external {
        expiry = e;
    }

    function readTokens() external view returns (address, address, address) {
        return (address(sy), address(pt), address(yt));
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiry;
    }

    function getRewardTokens() external view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(reward);
    }

    function redeemRewards(address user) external returns (uint256[] memory r) {
        reward.mint(user, 2e6);
        r = new uint256[](1);
        r[0] = 2e6;
    }

    function increaseObservationsCardinalityNext(uint16) external {}
}

/// @notice Rates (asset per PT, YT, LP, 1e18) and readiness, set by hand.
contract MockPendleOracle {
    mapping(address => uint256[3]) public rates;
    mapping(address => bool) public notReady;

    function set(address m, uint256 pt, uint256 yt, uint256 lp) external {
        rates[m] = [pt, yt, lp];
    }

    function setReady(address m, bool r) external {
        notReady[m] = !r;
    }

    function getPtToAssetRate(address m, uint32) external view returns (uint256) {
        return rates[m][0];
    }

    function getYtToAssetRate(address m, uint32) external view returns (uint256) {
        return rates[m][1];
    }

    function getLpToAssetRate(address m, uint32) external view returns (uint256) {
        return rates[m][2];
    }

    function getOracleState(address m, uint32) external view returns (bool, uint16, bool) {
        return (notReady[m], 901, !notReady[m]);
    }
}

contract MockPendleFactory {
    mapping(address => bool) public isValidMarket;

    function add(address m) external {
        isValidMarket[m] = true;
    }
}

/// @notice Trades at the oracle's rates, less `feeBps`, and sends to the receiver as Pendle's router does.
contract MockPendleRouter {
    MockPendleOracle public immutable oracle;
    uint256 public feeBps = 10;
    bool public broken;

    constructor(MockPendleOracle o) {
        oracle = o;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function _in(MockMarket m, TokenInput calldata input, uint8 kind) private returns (uint256 out) {
        require(!broken, "router down");
        require(!m.isExpired(), "expired");
        IERC20(input.tokenIn).transferFrom(msg.sender, address(this), input.netTokenIn);
        uint256 rate = oracle.rates(address(m), kind);
        out = input.netTokenIn * 1e18 / rate * (10_000 - feeBps) / 10_000;
    }

    function _out(address receiver, MockMarket m, address held, uint256 amount, TokenOutput calldata output, uint8 kind)
        private
        returns (uint256 out)
    {
        require(!broken, "router down");
        IERC20(held).transferFrom(msg.sender, address(this), amount);
        out = amount * oracle.rates(address(m), kind) / 1e18 * (10_000 - feeBps) / 10_000;
        require(out >= output.minTokenOut, "slippage");
        MockERC20(output.tokenOut).mint(receiver, out);
    }

    function swapExactTokenForPt(address receiver, address market, uint256 minOut, ApproxParams calldata, TokenInput calldata input, LimitOrderData calldata)
        external
        returns (uint256 out, uint256, uint256)
    {
        MockMarket m = MockMarket(market);
        out = _in(m, input, 0);
        require(out >= minOut, "slippage");
        m.pt().mint(receiver, out);
    }

    function swapExactTokenForYt(address receiver, address market, uint256 minOut, ApproxParams calldata, TokenInput calldata input, LimitOrderData calldata)
        external
        returns (uint256 out, uint256, uint256)
    {
        MockMarket m = MockMarket(market);
        out = _in(m, input, 1);
        require(out >= minOut, "slippage");
        m.yt().mint(receiver, out);
    }

    function addLiquiditySingleToken(address receiver, address market, uint256 minOut, ApproxParams calldata, TokenInput calldata input, LimitOrderData calldata)
        external
        returns (uint256 out, uint256, uint256)
    {
        MockMarket m = MockMarket(market);
        out = _in(m, input, 2);
        require(out >= minOut, "slippage");
        m.mint(receiver, out);
    }

    function swapExactPtForToken(address receiver, address market, uint256 amount, TokenOutput calldata output, LimitOrderData calldata)
        external
        returns (uint256 out, uint256, uint256)
    {
        MockMarket m = MockMarket(market);
        require(!m.isExpired(), "expired");
        out = _out(receiver, m, address(m.pt()), amount, output, 0);
    }

    function swapExactYtForToken(address receiver, address market, uint256 amount, TokenOutput calldata output, LimitOrderData calldata)
        external
        returns (uint256 out, uint256, uint256)
    {
        MockMarket m = MockMarket(market);
        require(!m.isExpired(), "expired");
        out = _out(receiver, m, address(m.yt()), amount, output, 1);
    }

    function removeLiquiditySingleToken(address receiver, address market, uint256 amount, TokenOutput calldata output, LimitOrderData calldata)
        external
        returns (uint256 out, uint256, uint256)
    {
        out = _out(receiver, MockMarket(market), market, amount, output, 2);
    }

    /// @dev After maturity PT alone redeems one for one; before it, PT and YT together.
    function redeemPyToToken(address receiver, address yt, uint256 amount, TokenOutput calldata output) external returns (uint256 out, uint256) {
        require(!broken, "router down");
        MockYT y = MockYT(yt);
        MockMarket m = MockMarket(_marketOf[yt]);
        IERC20(address(m.pt())).transferFrom(msg.sender, address(this), amount);
        if (!m.isExpired()) IERC20(yt).transferFrom(msg.sender, address(this), amount);
        out = amount;
        require(out >= output.minTokenOut, "slippage");
        MockERC20(output.tokenOut).mint(receiver, out);
        y;
        return (out, 0);
    }

    mapping(address => address) internal _marketOf;

    function link(address yt, address market) external {
        _marketOf[yt] = market;
    }
}
