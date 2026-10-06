// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice The parts of Pendle V2 the AINDEX Pendle adapter calls, as Pendle's own interfaces define them
 *         (pendle-core-v2-public: IPAllActionTypeV3, IPActionSwapPTV3, IPActionSwapYTV3, IPActionAddRemoveLiqV3,
 *         IPActionMiscV3, IPMarket, IStandardizedYield, IPYieldToken, IPPYLpOracle, IPMarketFactoryV3). Struct layouts
 *         must match the router byte for byte: a wrong field order decodes as garbage and the call reverts. The fork
 *         tests (test/fork/adapters/pendle) check each one against the live router on Robinhood Chain.
 */

struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

enum SwapType {
    NONE,
    KYBERSWAP,
    ODOS,
    ETH_WETH,
    OKX,
    ONE_INCH,
    RESERVE_1,
    RESERVE_2,
    RESERVE_3
}

struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address pendleSwap;
    SwapData swapData;
}

struct TokenOutput {
    address tokenOut;
    uint256 minTokenOut;
    address tokenRedeemSy;
    address pendleSwap;
    SwapData swapData;
}

enum OrderType {
    SY_FOR_PT,
    PT_FOR_SY,
    SY_FOR_YT,
    YT_FOR_SY
}

struct Order {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    OrderType orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

struct FillOrderParams {
    Order order;
    bytes signature;
    uint256 makingAmount;
}

struct LimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    FillOrderParams[] normalFills;
    FillOrderParams[] flashFills;
    bytes optData;
}

interface IPendleRouter {
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactTokenForYt(
        address receiver,
        address market,
        uint256 minYtOut,
        ApproxParams calldata guessYtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netYtOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactYtForToken(
        address receiver,
        address market,
        uint256 exactYtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    function addLiquiditySingleToken(
        address receiver,
        address market,
        uint256 minLpOut,
        ApproxParams calldata guessPtReceivedFromSy,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netLpOut, uint256 netSyFee, uint256 netSyInterm);

    function removeLiquiditySingleToken(
        address receiver,
        address market,
        uint256 netLpToRemove,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    function redeemPyToToken(address receiver, address YT, uint256 netPyIn, TokenOutput calldata output)
        external
        returns (uint256 netTokenOut, uint256 netSyInterm);
}

interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256);
    function isExpired() external view returns (bool);
    function getRewardTokens() external view returns (address[] memory);
    function redeemRewards(address user) external returns (uint256[] memory);
    function increaseObservationsCardinalityNext(uint16 cardinalityNext) external;
}

interface IStandardizedYield {
    /// @dev 0 TOKEN, 1 LIQUIDITY.
    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);
    function getTokensIn() external view returns (address[] memory);
    function getTokensOut() external view returns (address[] memory);
    function isValidTokenIn(address token) external view returns (bool);
    function isValidTokenOut(address token) external view returns (bool);
    function exchangeRate() external view returns (uint256);
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem) external view returns (uint256);
    function redeem(address receiver, uint256 amountSharesToRedeem, address tokenOut, uint256 minTokenOut, bool burnFromInternalBalance)
        external
        returns (uint256 amountTokenOut);
}

interface IPendleYieldToken {
    function isExpired() external view returns (bool);
    function getRewardTokens() external view returns (address[] memory);
    function redeemDueInterestAndRewards(address user, bool redeemInterest, bool redeemRewards)
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut);
}

interface IPendlePYLpOracle {
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);
    function getYtToAssetRate(address market, uint32 duration) external view returns (uint256);
    function getLpToAssetRate(address market, uint32 duration) external view returns (uint256);
    function getOracleState(address market, uint32 duration)
        external
        view
        returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}

interface IPendleMarketFactory {
    function isValidMarket(address market) external view returns (bool);
}
