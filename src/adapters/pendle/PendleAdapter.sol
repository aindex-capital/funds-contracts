// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount, IUnvalued} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {
    ApproxParams,
    FillOrderParams,
    IPendleMarket,
    IPendleMarketFactory,
    IPendlePYLpOracle,
    IPendleRouter,
    IPendleYieldToken,
    IStandardizedYield,
    LimitOrderData,
    SwapData,
    SwapType,
    TokenInput,
    TokenOutput
} from "../../interfaces/external/pendle/IPendle.sol";

/**
 * @title  PendleAdapter
 * @notice Lets a Fund trade yield on Pendle V2: fix a rate by buying PT, take a leveraged view on the floating rate
 *         by buying YT, earn fees and rewards as a liquidity provider, redeem at maturity, and collect interest and
 *         rewards. Any market made by Pendle's own market factory on the chain, so a carry trade on a meme token's
 *         yield is as available as one on USDG.
 *
 * @dev    ## What the clone holds
 *         PT, YT and LP tokens (the market contract is the LP token), at most `MAX_MARKETS` markets at a time; a
 *         market whose three balances reach zero is dropped from the list. Every token that comes out (USDG, a stock
 *         token, rewards) goes straight to the Fund's vault. Tokens in and out are limited to the SY's own
 *         `getTokensIn` and `getTokensOut`, so no external swap calldata ever passes through the adapter.
 *
 *         ## Valuation
 *         Never a pool's spot price. Each position is its balance times Pendle's oracle rate (PT, YT or LP to the
 *         SY's asset, a `TWAP` second time-weighted average of the market's implied rate), reported in the SY's
 *         asset, which the PriceRouter prices. One row per position: PT, YT and LP for every market held.
 *
 *         A market whose oracle is not ready (too few observations stored, or the oldest younger than `TWAP`) has
 *         no rate that resists a one-transaction move. Buying or adding there is refused (`OracleNotReady`), and
 *         anything held there is reported at zero and listed by `unvalued` (rule 8). Anyone can make a market ready:
 *         `increaseObservationsCardinalityNext(901)` on the market, then wait `TWAP` seconds.
 *
 *         If the PriceRouter does not price the SY's asset, the router counts the position at zero: buying it then
 *         costs the Fund the whole amount in NAV and in its daily loss budget, whatever the yield.
 *
 *         ## Exits
 *         `unwind` sells the fraction of each position for a token the router prices (the SY's asset when the SY
 *         pays it out, else its first output token), with a floor of the oracle value less `UNWIND_SLIPPAGE_BPS`.
 *         After maturity PT is redeemed instead of sold, and YT is worth only its unclaimed interest, which
 *         `grow(0)` collects. A market that cannot be sold is skipped with an event instead of blocking the others.
 *         `split` hands the leaver its slice of every PT, YT and LP token: they are ordinary ERC-20s.
 *
 *         `grow(0)` claims YT interest and every reward to the vault. Deposits enter Funds as cash since 2026-10-02,
 *         so `grow` above zero is refused (IAdapter allows a new adapter to do that).
 */
contract PendleAdapter is BaseAdapter, IUnvalued {
    using Strings for address;
    using Strings for uint256;

    error BadConfig();
    error UnknownAction(uint8 id);
    error NotPendleMarket(address market);
    error NotHeld(address market);
    error TooManyMarkets();
    error OracleNotReady(address market);
    error BadToken(address token);
    error ZeroAmount();
    error TooLittle(uint256 got, uint256 minOut);
    error Expired(address market);
    error BadFraction();
    error NoGrow();

    event Traded(address indexed market, uint8 indexed action, address token, uint256 amountIn, uint256 amountOut);
    event Claimed(address indexed market, uint256 interestSy);
    event UnwindSkipped(address indexed market, address position, uint256 amount);

    uint8 public constant BUY_PT = 0;
    uint8 public constant SELL_PT = 1;
    uint8 public constant BUY_YT = 2;
    uint8 public constant SELL_YT = 3;
    uint8 public constant ADD_LIQUIDITY = 4;
    uint8 public constant REMOVE_LIQUIDITY = 5;
    uint8 public constant REDEEM_PY = 6;
    uint8 public constant CLAIM = 7;

    /// @notice The oracle window: 15 minutes, Pendle's own recommendation for its PT oracle.
    uint32 public constant TWAP = 900;
    /// @notice Most markets held at once. Three rows each (PT, YT, LP), all in the SY's asset, so twelve rows of one
    ///         token at most: under the teller's slack cap (`TellerMath.MAX_SLACK_ROWS`, 13).
    uint256 public constant MAX_MARKETS = 4;
    /// @notice How far under the oracle value an unwind may sell: Pendle's books are thin.
    uint256 public constant UNWIND_SLIPPAGE_BPS = 300;
    uint256 private constant WAD = 1e18;

    IPendleRouter public immutable pendleRouter;
    IPendlePYLpOracle public immutable oracle;
    IPendleMarketFactory public immutable factory;
    /// @notice A second Pendle market factory (zero when the chain has one).
    IPendleMarketFactory public immutable factory2;

    struct MarketInfo {
        address sy;
        address pt;
        address yt;
        address asset;
    }

    address[] private _markets;
    mapping(address => MarketInfo) private _info;

    constructor(IPendleRouter router_, IPendlePYLpOracle oracle_, IPendleMarketFactory factory_, IPendleMarketFactory factory2_) {
        if (address(router_) == address(0) || address(oracle_) == address(0) || address(factory_) == address(0)) revert BadConfig();
        pendleRouter = router_;
        oracle = oracle_;
        factory = factory_;
        factory2 = factory2_;
    }

    /// @param config empty: every market of Pendle's factory is allowed; the Fund's dial decides how much.
    function _configure(bytes calldata config) internal pure override {
        if (config.length != 0) revert BadConfig();
    }

    // ---------------------------------------------------------------- reads

    function name() external pure returns (string memory) {
        return "Pendle v1";
    }

    function markets() external view returns (address[] memory) {
        return _markets;
    }

    function marketInfo(address market) external view returns (MarketInfo memory) {
        return _info[market];
    }

    /// @notice Whether `market`'s oracle gives a rate a single transaction cannot move: what buying and adding need.
    function oracleReady(address market) public view returns (bool) {
        try oracle.getOracleState(market, TWAP) returns (bool increase, uint16, bool oldestOk) {
            return !increase && oldestOk;
        } catch {
            return false;
        }
    }

    function _isPendleMarket(address market) private view returns (bool) {
        if (market.code.length == 0) return false;
        if (_valid(factory, market)) return true;
        return address(factory2) != address(0) && _valid(factory2, market);
    }

    function describe() external view returns (string memory) {
        return string.concat(
            '{"adapter":"Pendle v1","kind":"yield","positions":true,',
            '"about":"Pendle V2 yield trading, any market of Pendle\'s factory. PT: bought under par, redeemed 1:1 in the asset at expiry, a fixed-yield carry trade. ',
            "YT: all floating interest until expiry, then nothing; a leveraged bet the floating rate beats the implied one. LP: fees and rewards. ",
            "Valued at Pendle's 15-minute oracle in the SY asset. token: an SY getTokensIn (buy, add) or getTokensOut (sell, remove, redeem, claim) token. ",
            "Buy or add needs oracleReady(market); else call increaseObservationsCardinalityNext(901) on the market and wait 15 minutes. ",
            "An SY asset AINDEX does not price counts as zero (a full loss in NAV). After expiry: redeem PT (6), claim YT interest (7). Max 4 markets.\",",
            '"held":[', _heldJson(), '],',
            '"actions":[', _actionsJson(), "]}"
        );
    }

    /// @dev The markets held, by address; `marketInfo(market)` and `oracleReady(market)` give the rest.
    function _heldJson() private view returns (string memory list) {
        for (uint256 i; i < _markets.length; ++i) list = string.concat(list, i == 0 ? '"' : ',"', _markets[i].toHexString(), '"');
    }

    function _actionsJson() private pure returns (string memory) {
        string memory a = string.concat(
            _action(0, "buyPt", "an SY input token", "raw units of token to spend", "least PT to receive", "ptOut"), ",",
            _action(1, "sellPt", "an SY output token", "PT to sell; max uint for all", "least token to receive", "tokenOut"), ",",
            _action(2, "buyYt", "an SY input token", "raw units of token to spend", "least YT to receive", "ytOut"), ","
        );
        a = string.concat(
            a,
            _action(3, "sellYt", "an SY output token", "YT to sell; max uint for all", "least token to receive", "tokenOut"), ",",
            _action(4, "addLiquidity", "an SY input token", "raw units of token to add", "least LP to receive", "lpOut"), ",",
            _action(5, "removeLiquidity", "an SY output token", "LP to remove; max uint for all", "least token to receive", "tokenOut"), ","
        );
        return string.concat(
            a,
            _action(6, "redeemPy", "an SY output token", "PT to redeem (plus as much YT before expiry); max uint for all", "least token to receive", "tokenOut"), ",",
            _action(7, "claim", "SY output token for YT interest", "0", "0", "interestOut")
        );
    }

    /// @dev One action's entry: its params are always (market, token, amount, minOut).
    function _action(uint8 id, string memory name_, string memory token, string memory amount, string memory minOut, string memory ret)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            string.concat('{"id":', uint256(id).toString(), ',"name":"', name_, '","params":[{"name":"market","type":"address","about":"a Pendle market (its LP token)"},'),
            string.concat('{"name":"token","type":"address","about":"', token, '"},{"name":"amount","type":"uint256","about":"', amount, '"},'),
            string.concat('{"name":"minOut","type":"uint256","about":"', minOut, '"}],"encoding":"abi.encode(uint8 id, address market, address token, uint256 amount, uint256 minOut)","returns":"abi.encode(uint256 ', ret, ')"}')
        );
    }

    function inputs(bytes calldata action) external pure returns (Amount[] memory) {
        (uint8 id,, address token, uint256 amount,) = abi.decode(action, (uint8, address, address, uint256, uint256));
        if (id == BUY_PT || id == BUY_YT || id == ADD_LIQUIDITY) return _one(token, amount);
        return _none();
    }

    function outputs(bytes calldata action) external view returns (address[] memory out) {
        (uint8 id, address market, address token,,) = abi.decode(action, (uint8, address, address, uint256, uint256));
        if (id != CLAIM) return _tokens1(token);
        address[] memory a = _rewardTokens(market);
        out = new address[](a.length + 1);
        out[0] = token;
        for (uint256 i; i < a.length; ++i) out[i + 1] = a[i];
    }

    // ---------------------------------------------------------------- actions

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 id, address market, address token, uint256 amount, uint256 minOut) =
            abi.decode(action, (uint8, address, address, uint256, uint256));
        if (id == BUY_PT || id == BUY_YT || id == ADD_LIQUIDITY) return abi.encode(_enter(id, market, token, amount, minOut));
        if (id > CLAIM) revert UnknownAction(id);
        MarketInfo memory x = _info[market];
        if (x.sy == address(0)) revert NotHeld(market);
        uint256 out;
        if (id == CLAIM) {
            if (!IStandardizedYield(x.sy).isValidTokenOut(token)) revert BadToken(token);
            out = _claim(market, x, token);
        } else {
            if (!IStandardizedYield(x.sy).isValidTokenOut(token)) revert BadToken(token);
            out = _exit(id, market, x, token, amount, minOut);
        }
        _prune(market);
        return abi.encode(out);
    }

    /// @dev Buy PT, buy YT or add liquidity with `amount` of `token` pulled from the vault.
    function _enter(uint8 id, address market, address token, uint256 amount, uint256 minOut) private returns (uint256 got) {
        if (amount == 0) revert ZeroAmount();
        MarketInfo memory x = _track(market);
        if (IPendleMarket(market).isExpired()) revert Expired(market);
        if (!oracleReady(market)) revert OracleNotReady(market);
        if (!IStandardizedYield(x.sy).isValidTokenIn(token)) revert BadToken(token);
        _pull(token, amount);
        _approve(token, address(pendleRouter), amount);
        TokenInput memory input = TokenInput(token, amount, token, address(0), SwapData(SwapType.NONE, address(0), "", false));
        address held = id == BUY_PT ? x.pt : id == BUY_YT ? x.yt : market;
        uint256 before = IERC20(held).balanceOf(address(this));
        // The three share one argument layout, so one encoding with the selector chosen.
        bytes4 sel = id == BUY_PT ? IPendleRouter.swapExactTokenForPt.selector
            : id == BUY_YT ? IPendleRouter.swapExactTokenForYt.selector : IPendleRouter.addLiquiditySingleToken.selector;
        (bool ok, bytes memory ret) =
            address(pendleRouter).call(abi.encodeWithSelector(sel, address(this), market, minOut, _approx(), input, _noLimit()));
        _bubble(ok, ret);
        _approve(token, address(pendleRouter), 0);
        got = IERC20(held).balanceOf(address(this)) - before;
        if (got < minOut) revert TooLittle(got, minOut);
        _pushAll(token); // what the router did not take
        emit Traded(market, id, token, amount, got);
    }

    /// @dev Sell PT or YT, remove liquidity, or redeem PT (and YT before maturity), paying `token` to the vault.
    function _exit(uint8 id, address market, MarketInfo memory x, address token, uint256 amount, uint256 minOut)
        private
        returns (uint256 got)
    {
        amount = _amountOf(id, market, x, amount);
        bool expired = IPendleMarket(market).isExpired();
        if (expired && id != REMOVE_LIQUIDITY && id != REDEEM_PY) revert Expired(market);
        uint256 before = IERC20(token).balanceOf(vault);
        // Exit kinds: 0 PT (sold, or redeemed after maturity), 1 YT, 2 LP, 3 PT and YT redeemed together.
        (bool ok, bytes memory ret) =
            _callExit(id == SELL_PT ? 0 : id == SELL_YT ? 1 : id == REMOVE_LIQUIDITY ? 2 : expired ? 0 : 3, market, x, amount, _output(token, minOut), expired);
        _bubble(ok, ret);
        got = IERC20(token).balanceOf(vault) - before;
        if (got < minOut) revert TooLittle(got, minOut);
        emit Traded(market, id, token, amount, got);
    }

    /// @dev The amount an exit takes: all held for max uint, never zero.
    function _amountOf(uint8 id, address market, MarketInfo memory x, uint256 amount) private view returns (uint256) {
        address held = id == SELL_PT || id == REDEEM_PY ? x.pt : id == SELL_YT ? x.yt : market;
        if (amount == type(uint256).max) amount = IERC20(held).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        return amount;
    }

    /// @dev Revert with what the router reverted with.
    function _bubble(bool ok, bytes memory ret) private pure {
        if (ok) return;
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }

    /// @dev YT interest (paid in SY, redeemed to `token`) and every reward of the market and its YT, to the vault.
    function _claim(address market, MarketInfo memory x, address token) private returns (uint256 out) {
        if (IERC20(x.yt).balanceOf(address(this)) != 0 || IPendleMarket(market).isExpired()) {
            try IPendleYieldToken(x.yt).redeemDueInterestAndRewards(address(this), true, true) {} catch {}
        }
        if (IERC20(market).balanceOf(address(this)) != 0) {
            try IPendleMarket(market).redeemRewards(address(this)) {} catch {}
        }
        uint256 sy = IERC20(x.sy).balanceOf(address(this));
        if (sy != 0) {
            uint256 before = IERC20(token).balanceOf(vault);
            IStandardizedYield(x.sy).redeem(vault, sy, token, 0, false);
            out = IERC20(token).balanceOf(vault) - before;
            emit Claimed(market, sy);
        }
        address[] memory r = _rewardTokens(market);
        for (uint256 i; i < r.length; ++i) {
            if (r[i] == x.pt || r[i] == x.yt || r[i] == market || r[i] == x.sy) continue;
            _pushAll(r[i]);
        }
    }

    // ---------------------------------------------------------------- positions and exits

    /// @notice Every market's PT, YT and LP, in the SY's asset at Pendle's oracle rate. Zero where the oracle is not
    ///         ready (see `unvalued`).
    function positions(IPriceRouter) external view returns (Amount[] memory assets, Amount[] memory debts) {
        uint256 n = _markets.length;
        assets = new Amount[](n * 3);
        for (uint256 i; i < n; ++i) {
            address m = _markets[i];
            MarketInfo memory x = _info[m];
            bool ready = oracleReady(m);
            assets[i * 3] = Amount(x.asset, ready ? _value(m, IERC20(x.pt).balanceOf(address(this)), 0) : 0);
            assets[i * 3 + 1] = Amount(x.asset, ready ? _value(m, IERC20(x.yt).balanceOf(address(this)), 1) : 0);
            assets[i * 3 + 2] = Amount(x.asset, ready ? _value(m, IERC20(m).balanceOf(address(this)), 2) : 0);
        }
        debts = new Amount[](0);
    }

    /// @notice What `positions` counts as zero: PT, YT and LP held in a market whose oracle is not ready, as tokens.
    function unvalued() external view returns (Amount[] memory out) {
        uint256 n = _markets.length;
        out = new Amount[](n * 3);
        uint256 rows;
        for (uint256 i; i < n; ++i) {
            address m = _markets[i];
            if (oracleReady(m)) continue;
            MarketInfo memory x = _info[m];
            address[3] memory t = [x.pt, x.yt, m];
            for (uint256 k; k < 3; ++k) {
                uint256 b = IERC20(t[k]).balanceOf(address(this));
                if (b != 0) out[rows++] = Amount(t[k], b);
            }
        }
        out = _trim(out, rows);
    }

    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        address[] memory list = _markets;
        received = new Amount[](list.length);
        for (uint256 i; i < list.length; ++i) {
            address m = list[i];
            MarketInfo memory x = _info[m];
            address out = _exitToken(x);
            received[i].token = out;
            uint256 before = IERC20(out).balanceOf(vault);
            Exit memory e = Exit(m, out, IPendleMarket(m).isExpired(), oracleReady(m));
            _unwindOne(e, x, x.pt, _slice(IERC20(x.pt).balanceOf(address(this)), fractionWad), 0);
            if (!e.expired) _unwindOne(e, x, x.yt, _slice(IERC20(x.yt).balanceOf(address(this)), fractionWad), 1);
            _unwindOne(e, x, m, _slice(IERC20(m).balanceOf(address(this)), fractionWad), 2);
            received[i].amount = IERC20(out).balanceOf(vault) - before;
        }
        for (uint256 i; i < list.length; ++i) _prune(list[i]);
    }

    /// @dev Sell (or after maturity redeem) one position's slice for `out`, at no less than its oracle value less the
    ///      slippage bound; skipped with an event when the market will not take it or the oracle cannot value it.
    /// @dev One market's unwind: where to sell, and whether it is past maturity and its oracle ready.
    struct Exit {
        address market;
        address out;
        bool expired;
        bool ready;
    }

    /// @dev Sell (or after maturity redeem) one position's slice for `e.out`, at no less than its oracle value less
    ///      the slippage bound; skipped with an event when the market will not take it or the oracle cannot value it.
    function _unwindOne(Exit memory e, MarketInfo memory x, address held, uint256 amount, uint8 kind) private {
        if (amount == 0) return;
        if (!e.ready) {
            emit UnwindSkipped(e.market, held, amount);
            return;
        }
        (bool ok,) = _callExit(kind, e.market, x, amount, _output(e.out, _floor(e.market, x, e.out, amount, kind)), e.expired);
        if (!ok) emit UnwindSkipped(e.market, held, amount);
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        if (to == address(0)) revert ZeroAddress();
        address[] memory list = _markets;
        sent = new Amount[](list.length * 3);
        for (uint256 i; i < list.length; ++i) {
            MarketInfo memory x = _info[list[i]];
            address[3] memory t = [x.pt, x.yt, list[i]];
            for (uint256 k; k < 3; ++k) {
                uint256 amount = _slice(IERC20(t[k]).balanceOf(address(this)), fractionWad);
                sent[i * 3 + k] = Amount(t[k], amount);
                _push(t[k], to, amount);
            }
        }
        for (uint256 i; i < list.length; ++i) _prune(list[i]);
    }

    /// @notice `grow(0)` claims YT interest and rewards for every market to the vault. Above zero: refused.
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        if (fractionWad != 0) revert NoGrow();
        address[] memory list = _markets;
        for (uint256 i; i < list.length; ++i) {
            MarketInfo memory x = _info[list[i]];
            _claim(list[i], x, _exitToken(x));
        }
        used = _none();
    }

    function growInputs(uint256 fractionWad) external pure returns (Amount[] memory) {
        if (fractionWad != 0) revert NoGrow();
        return _none();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Approve and make one exit call to Pendle's router, paying the vault: kind 0 sells PT (redeems it after
    ///      maturity), 1 sells YT, 2 removes liquidity, 3 redeems PT and YT together. One encoder for every exit, from
    ///      `execute` (which bubbles a failure) and `unwind` (which skips it).
    function _callExit(uint8 kind, address market, MarketInfo memory x, uint256 amount, TokenOutput memory output, bool expired)
        private
        returns (bool ok, bytes memory ret)
    {
        bytes memory data;
        address held = kind == 1 ? x.yt : kind == 2 ? market : x.pt;
        if (kind == 3 || (kind == 0 && expired)) {
            data = abi.encodeCall(IPendleRouter.redeemPyToToken, (vault, x.yt, amount, output));
        } else {
            // Selling PT or YT and removing liquidity share one argument layout.
            bytes4 sel = kind == 0 ? IPendleRouter.swapExactPtForToken.selector
                : kind == 1 ? IPendleRouter.swapExactYtForToken.selector : IPendleRouter.removeLiquiditySingleToken.selector;
            data = abi.encodeWithSelector(sel, vault, market, amount, output, _noLimit());
        }
        _approve(held, address(pendleRouter), amount);
        if (kind == 3) _approve(x.yt, address(pendleRouter), amount);
        (ok, ret) = address(pendleRouter).call(data);
        _approve(held, address(pendleRouter), 0);
        if (kind == 3) _approve(x.yt, address(pendleRouter), 0);
    }

    function _valid(IPendleMarketFactory f, address market) private view returns (bool) {
        try f.isValidMarket(market) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _track(address market) private returns (MarketInfo memory x) {
        x = _info[market];
        if (x.sy != address(0)) return x;
        if (!_isPendleMarket(market)) revert NotPendleMarket(market);
        if (_markets.length >= MAX_MARKETS) revert TooManyMarkets();
        (address sy, address pt, address yt) = IPendleMarket(market).readTokens();
        (, address asset,) = IStandardizedYield(sy).assetInfo();
        if (asset == address(0)) revert NotPendleMarket(market);
        x = MarketInfo(sy, pt, yt, asset);
        _info[market] = x;
        _markets.push(market);
    }

    /// @dev Drop a market once nothing is held in it, so the four slots free up.
    function _prune(address market) private {
        MarketInfo memory x = _info[market];
        if (x.sy == address(0)) return;
        if (IERC20(x.pt).balanceOf(address(this)) != 0 || IERC20(x.yt).balanceOf(address(this)) != 0 || IERC20(market).balanceOf(address(this)) != 0) return;
        uint256 n = _markets.length;
        for (uint256 i; i < n; ++i) {
            if (_markets[i] == market) {
                _markets[i] = _markets[n - 1];
                _markets.pop();
                break;
            }
        }
        delete _info[market];
    }

    /// @dev `amount` of PT (kind 0), YT (1) or LP (2) in the SY's asset at the oracle rate.
    function _value(address market, uint256 amount, uint8 kind) private view returns (uint256) {
        if (amount == 0) return 0;
        uint256 rate;
        if (kind == 0) rate = oracle.getPtToAssetRate(market, TWAP);
        else if (kind == 1) rate = oracle.getYtToAssetRate(market, TWAP);
        else rate = oracle.getLpToAssetRate(market, TWAP);
        return amount * rate / WAD;
    }

    /// @dev The least an unwind accepts for `amount` of a position: its oracle value in `out`, less the slippage bound.
    function _floor(address market, MarketInfo memory x, address out, uint256 amount, uint8 kind) private view returns (uint256) {
        uint256 assets = _value(market, amount, kind) * (10_000 - UNWIND_SLIPPAGE_BPS) / 10_000;
        if (out == x.asset) return assets;
        // In another output token: the asset amount as SY, then what the SY pays out in `out`.
        try IStandardizedYield(x.sy).exchangeRate() returns (uint256 rate) {
            if (rate == 0) return 0;
            try IStandardizedYield(x.sy).previewRedeem(out, assets * WAD / rate) returns (uint256 o) {
                return o;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev Where an unwind sells to: the SY's asset when the SY pays it out, else the SY's first output token.
    function _exitToken(MarketInfo memory x) private view returns (address) {
        if (IStandardizedYield(x.sy).isValidTokenOut(x.asset)) return x.asset;
        return IStandardizedYield(x.sy).getTokensOut()[0];
    }

    /// @dev The market's reward tokens and its YT's (a market is only claimed once held, so its YT is known). A token
    ///      both pay appears twice, which the vault counts once.
    function _rewardTokens(address market) private view returns (address[] memory out) {
        address[] memory a;
        address[] memory b;
        try IPendleMarket(market).getRewardTokens() returns (address[] memory r) { a = r; } catch {}
        address yt = _info[market].yt;
        if (yt != address(0)) {
            try IPendleYieldToken(yt).getRewardTokens() returns (address[] memory r) { b = r; } catch {}
        }
        out = new address[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) out[i] = a[i];
        for (uint256 i; i < b.length; ++i) out[a.length + i] = b[i];
    }

    function _slice(uint256 held, uint256 fractionWad) private pure returns (uint256) {
        return fractionWad == WAD ? held : held * fractionWad / WAD;
    }

    function _output(address token, uint256 minOut) private pure returns (TokenOutput memory) {
        return TokenOutput(token, minOut, token, address(0), SwapData(SwapType.NONE, address(0), "", false));
    }

    /// @dev Pendle's default search for the swap size: the whole range, its usual iteration cap and precision.
    function _approx() private pure returns (ApproxParams memory) {
        return ApproxParams(0, type(uint256).max, 0, 256, 1e14);
    }

    function _noLimit() private pure returns (LimitOrderData memory l) {
        l.normalFills = new FillOrderParams[](0);
        l.flashFills = new FillOrderParams[](0);
    }
}
