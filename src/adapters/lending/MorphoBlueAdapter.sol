// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount, IUnvalued} from "../../interfaces/IAdapter.sol";
import {IPockets, IPocketable} from "../../interfaces/IPockets.sol";
import {IPriceRouter, PriceClass} from "../../interfaces/IPriceRouter.sol";
import {IFundController} from "../../interfaces/IFundController.sol";
import {IMorpho, IMorphoOracle, MarketParams, MorphoMarket} from "../../interfaces/external/morpho/IMorpho.sol";
import {MorphoMath} from "./MorphoMath.sol";
import {MorphoMarketRegistry} from "./MorphoMarketRegistry.sol";

/// @dev FundController exposes its PriceRouter publicly; IFundController does not list it.
interface IControllerRouter {
    function router() external view returns (IPriceRouter);
}

/**
 * @title  MorphoBlueAdapter
 * @notice Lets a Fund lend, post collateral and borrow on any Morpho Blue market. Each Fund's clone is the
 *         Morpho position holder: Morpho positions cannot be moved between accounts, so the clone holds
 *         them for the Fund and reports them through `positions`.
 *
 * @dev    ## Markets
 *         A market is named by its five parameters (loan token, collateral token, oracle, rate model,
 *         LLTV) and can never change once created. The manager passes the parameters with each action and
 *         chooses the risk. The clone remembers every market it currently has a position in, so
 *         `positions`, `unwind` and `split` can find them; a market is forgotten again once the position
 *         in it is empty. At most `MAX_MARKETS` markets may be open at once, so valuing the Fund always
 *         fits in a block.
 *
 *         ## Which markets: reviewed markets are a badge, the Fund's dial decides
 *         Morpho market creation is permissionless and a market is any five parts. A manager could create a
 *         market whose oracle it controls, or one that pairs a sound oracle with a collateral token it mints at
 *         will, have the Fund lend into it, then borrow that loan against worthless collateral from outside the
 *         Fund (or price the Fund's collateral to zero and liquidate it). So AINDEX reviews whole markets, by
 *         id (the hash of all five parameters), and lists them in the `MorphoMarketRegistry` (adding one waits
 *         a day, removing one is instant). Before any action that adds exposure (supply, supplyCollateral,
 *         borrow) the adapter requires:
 *         1. the market is listed there, unless the Fund's dial has `allowUnreviewed` on. The manager chooses
 *            the risk; the dial tells depositors, and turning it on waits the notice;
 *         2. for a borrow, the loan token has a price class other than None (see below);
 *         3. if the owner gave a market list at enable time, the market is on it.
 *         Withdraw, repay, withdrawCollateral, `unwind` and `split` never check any of this: a Fund can
 *         always get out of a market, even one delisted after it went in.
 *
 *         Why only a borrow needs a priced token: the Fund's book already handles the rest. A None token
 *         lent or posted is worth zero, a known value, and the dial's `maxNoMarketBps` governs holding it.
 *         A debt in a None token is unpriceable (a zero would make it look free), so the book after such a
 *         borrow is incomplete and the controller would refuse it anyway; checking here gives the manager
 *         the real reason and keeps the adapter correct on its own.
 *
 *         ## Supply in a market that is not approved counts as nothing
 *         `positions` reports it with an amount of zero. Whoever made such a market may be able to borrow every
 *         unlent dollar against worthless collateral at any moment, and the free liquidity is no floor either:
 *         when the Fund is the only lender its own supply is the free liquidity, and another lender can leave
 *         just before the drain. Counting it as nothing is the one value a drain cannot push lower, so lending
 *         into such a market costs NAV at once, inside the manager's action, and is charged to the daily loss
 *         budget; a manager can never move more of the Fund this way than the budget it chose allows. Leavers
 *         still get their slice of it in kind (the zero row keeps the adapter in every exit). New holders would
 *         share the old supply's claim without paying for it, so the adapter reports it through `unvalued`
 *         (`IUnvalued`), and while any is above dust the teller mints no new shares until it is set aside for the
 *         holders of the moment: `pocket` (`IPocketable`, through the teller's `pocket`) moves every such supply
 *         in a loan token into a holders' pocket. From then on it is no longer the Fund's: `positions`, `unvalued`,
 *         `split`, `unwind` and the manager's withdrawals leave it alone, and `drain` (anyone) withdraws what the
 *         market can pay and pays it into the pocket, now and as borrowers repay. Supply in an approved market is
 *         counted in full, as below.
 *
 *         ## Only supply the clone put in itself counts
 *         Anyone may supply on behalf of any account on Morpho. Supply someone else put in for this clone is not the
 *         Fund's doing and must not change what the Fund reports: in a market AINDEX has not approved it would be an
 *         unvalued claim that holds every deposit until it is pocketed, and anyone could then mint snapshots for
 *         dust. So the clone counts only the supply shares it minted itself (`ownShares`); shares added on its
 *         behalf are ignored everywhere (`positions`, `unvalued`, exits, pockets, grows and withdrawals) and stay
 *         with Morpho.
 *
 *         ## A leaver's supply the market cannot pay yet stays the leaver's
 *         An exit in kind (`split`) pays the leaver its slice of each market's supply as far as the market's free
 *         liquidity allows. What it cannot pay today is not handed back to the Fund: those supply shares become the
 *         leaver's (`leaverShares`), leave the Fund's `positions`, keep earning the market's rate, and anyone may
 *         pay them out to the leaver as borrowers repay (`payLeaver`). So a borrower who takes the market's free
 *         liquidity for one transaction (a flash borrow) around a leaver's payout only delays it.
 *
 *         Config, fixed for the clone's life: `abi.encode(address marketRegistry, bytes32[] marketIds)`.
 *         An empty `marketIds` means any market the dial allows.
 *
 *         ## Tokens
 *         Every amount Morpho sends back (withdrawals, borrows) comes to the clone first and is then sent
 *         on to the vault (or to the leaver in `split`) in the same call, so the clone never ends a call
 *         holding loose tokens.
 *
 *         ## Valuation
 *         `positions` adds the interest each market has earned since it was last touched (MorphoMath), so
 *         the Fund's NAV is current without anyone sending a transaction. What the Fund is owed rounds
 *         down, what it owes rounds up. Supply in an approved market is counted in full even when the market
 *         is fully borrowed and cannot pay it back today: the money is owed to the Fund and will come back as
 *         borrowers repay or are liquidated. See `unwind` for what that means for exits.
 *
 *         ## Health
 *         The controller checks Fund-wide health (all assets over all debts, at its own prices) against the
 *         owner's dial. Morpho checks each market on its own, at that market's oracle, against its LLTV: a
 *         Fund with plenty of health overall can still be liquidated in one market. `marketHealth` shows
 *         the per-market picture (LTV, the oracle price at which liquidation starts) for agents and pages.
 *
 *         Because the dial cannot see one market on its own, the adapter keeps a fixed buffer itself: after
 *         a borrow or a collateral withdrawal, the market's LTV at its oracle must be at most
 *         `LLTV_BUFFER` (90%) of its LLTV. A manager could otherwise borrow to a hair under the LLTV, and the
 *         next small price move would liquidate the Fund and cost it Morpho's liquidation incentive (about
 *         12.7% of the debt at 62.5% LLTV). The buffer only limits new risk: repaying, adding collateral,
 *         `unwind`, `split` and `grow` are never blocked by it.
 *
 *         ## Deposits into the existing mix
 *         `grow` adds the same fraction to every market's supply, collateral and debt, so new money buys
 *         exactly the positions the Fund already holds at the LTV it already runs. See `grow` for which checks
 *         apply and which do not.
 */
contract MorphoBlueAdapter is BaseAdapter, IUnvalued, IPocketable {
    using MorphoMath for uint256;

    error UnknownAction(uint8 id);
    error MarketNotAllowed(bytes32 id);
    error MarketNotApproved(bytes32 id);
    error TokenNotPriced(address token);
    error MarketNotCreated(bytes32 id);
    error TooManyMarkets();
    error BadFraction();
    error TooCloseToLiquidation(uint256 ltv, uint256 limit);
    error SplitUnfunded(address token, uint256 needed, uint256 available);
    error PocketBusy(bytes32 id);
    error PocketedSupply(bytes32 id);
    error BadPockets();
    /// @notice A tolerated Morpho call failed because the transaction ran short of gas, not because the market
    ///         refused: retry with more gas. Without this a low gas estimate would turn a payable slice into owed supply.
    error ShortGas();

    uint8 internal constant SUPPLY = 0;
    uint8 internal constant WITHDRAW = 1;
    uint8 internal constant SUPPLY_COLLATERAL = 2;
    uint8 internal constant WITHDRAW_COLLATERAL = 3;
    uint8 internal constant BORROW = 4;
    uint8 internal constant REPAY = 5;
    uint8 internal constant REPAY_SHARES = 6;

    /// @notice Upper bound on markets with an open position, so `positions` stays cheap and an exit in kind (which
    ///         repays and withdraws in every market) fits a transaction (docs/DEPOSITS-AND-EXITS.md, "Gas").
    uint256 public constant MAX_MARKETS = 13;
    uint256 internal constant WAD = 1e18;
    /// @notice Pass as the amount to mean "all of it" (withdraw, withdrawCollateral, repayShares).
    uint256 public constant ALL = type(uint256).max;
    /// @notice After a borrow or collateral withdrawal, a market's LTV may be at most this share of its LLTV.
    uint256 public constant LLTV_BUFFER = 0.9e18;

    IMorpho public immutable morpho;

    /// @notice The Morpho markets AINDEX has reviewed. A badge: other markets are open to Funds whose dial has
    ///         `allowUnreviewed` on, and supply in them counts as nothing.
    MorphoMarketRegistry public marketRegistry;
    /// @notice True when the Fund's owner limited this clone to a fixed list of markets at enable time.
    bool public restricted;
    mapping(bytes32 => bool) public allowedMarket;

    bytes32[] private _open;
    mapping(bytes32 => uint256) private _slot; // index in _open plus one; zero means not open
    /// @dev A market's parameters with the clone's own supply shares packed in (one read gives `positions` both).
    struct Market {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint64 lltv; // Morpho's LLTVs are at most 1e18
        uint192 own; // `ownShares`
    }

    mapping(bytes32 => Market) private _markets;

    /// @notice Supply shares in a market that belong to a holders' pocket, not to the Fund (see the header).
    mapping(bytes32 => uint256) public pocketedShares;
    /// @notice The pocket (snapshot id) a market's pocketed supply pays into.
    mapping(bytes32 => uint256) public pocketIdOf;
    /// @notice Where pocketed supply pays (set by the first `pocket`).
    IPockets public pockets;
    /// @notice Markets with pocketed supply; while zero, nothing else here is read.
    uint256 public pocketedMarkets;
    /// @notice Supply shares owed to a leaver whose slice the market could not pay in full, per market and leaver.
    mapping(bytes32 => mapping(address => uint256)) public leaverShares;
    /// @notice All leavers' supply shares in a market (no longer the Fund's).
    mapping(bytes32 => uint256) public leaverTotal;
    /// @notice Markets with leavers' shares; while zero, `leaverTotal` is not read.
    uint256 public leaverMarkets;

    event SupplyPocketed(bytes32 indexed id, uint256 indexed pocketId, uint256 shares);
    event Drained(bytes32 indexed id, uint256 indexed pocketId, uint256 assets);
    event LeaverOwed(bytes32 indexed id, address indexed leaver, uint256 shares);
    event LeaverPaid(bytes32 indexed id, address indexed leaver, uint256 assets);

    /// @notice One market's position, as agents and pages want to see it.
    struct MarketHealth {
        bytes32 id;
        uint256 supplied; // loan token, what the Fund is owed, interest included
        uint256 borrowed; // loan token, what the Fund owes, interest included
        uint256 collateral; // collateral token
        uint256 liquidity; // loan token the market could pay out right now
        uint256 oraclePrice; // Morpho oracle: raw loan units per raw collateral unit, times 1e36 (0 if it failed)
        uint256 lltv; // 1e18 = 100%
        uint256 ltv; // borrowed over collateral value at the oracle, 1e18 = 100% (0 with no debt)
        uint256 maxBorrow; // loan token the collateral supports at the LLTV
        uint256 liquidationPrice; // oracle price (same scale) at which this position becomes liquidatable
    }

    constructor(IMorpho morpho_) {
        if (address(morpho_) == address(0)) revert ZeroAddress();
        morpho = morpho_;
    }

    function _configure(bytes calldata config) internal override {
        (address registry_, bytes32[] memory ids) = abi.decode(config, (address, bytes32[]));
        if (registry_ == address(0)) revert ZeroAddress();
        marketRegistry = MorphoMarketRegistry(registry_);
        if (ids.length == 0) return;
        restricted = true;
        for (uint256 i; i < ids.length; ++i) {
            allowedMarket[ids[i]] = true;
        }
    }

    // ---------------------------------------------------------------- description

    function name() external pure returns (string memory) {
        return "Morpho Blue v1";
    }

    function describe() external pure returns (string memory) {
        return string.concat(
            '{"adapter":"Morpho Blue v1",',
            '"about":"Lend, post collateral and borrow on any Morpho Blue market. market is the MarketParams tuple',
            " (loanToken, collateralToken, oracle, irm, lltv); its id is keccak256(abi.encode(market)). Amounts are",
            " raw token units. Pass 2^256-1 as amount to mean all of it where noted. Supply in a fully borrowed",
            " market is owed but cannot be withdrawn until borrowers repay. Each market is liquidated on its own",
            ' oracle at its LLTV: read marketHealth(market) before borrowing.",',
            '"encoding":"abi.encode(uint8 id, (address,address,address,address,uint256) market, uint256 amount)",',
            '"actions":[',
            '{"id":0,"name":"supply","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"loan token to lend"}]},',
            '{"id":1,"name":"withdraw","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"loan token to take back; all = every supply share"}]},',
            '{"id":2,"name":"supplyCollateral","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"collateral token to post"}]},',
            '{"id":3,"name":"withdrawCollateral","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"collateral to take back; all = everything; must leave LTV at most 90% of the LLTV"}]},',
            '{"id":4,"name":"borrow","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"loan token to borrow; needs allowBorrow and minHealth on the dial, and LTV at most 90% of the LLTV after"}]},',
            '{"id":5,"name":"repay","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"loan token to repay; must not exceed the debt"}]},',
            '{"id":6,"name":"repayShares","params":[{"name":"market","type":"tuple"},{"name":"amount","type":"uint256","about":"borrow shares to repay; all = clear the debt exactly"}]}',
            "],",
            '"rules":"supply, supplyCollateral and borrow need the market (all five parameters, by id) approved in marketRegistry() (AINDEX reviewed) unless the Fund dial has allowUnreviewed on; borrow needs the loan token priced by the Fund router; supply in a market that is not approved counts as zero in NAV, so lending into one is charged to the daily loss budget in full; exits are never restricted",',
            '"views":["markets()","marketId(market)","marketHealth(market)","marketRegistry()","restricted()","allowedMarket(id)"]}'
        );
    }

    // ---------------------------------------------------------------- actions

    function inputs(bytes calldata action) external view returns (Amount[] memory) {
        (uint8 id, MarketParams memory p, uint256 amount) = _decode(action);
        if (id == SUPPLY || id == REPAY) return _one(p.loanToken, amount);
        if (id == SUPPLY_COLLATERAL) return _one(p.collateralToken, amount);
        if (id == REPAY_SHARES) {
            bytes32 mid = marketId(p);
            (uint256 shares, uint256 assets) = _repaySharesCost(p, mid, amount);
            shares;
            return _one(p.loanToken, assets);
        }
        if (id > REPAY_SHARES) revert UnknownAction(id);
        return _none();
    }

    function outputs(bytes calldata action) external pure returns (address[] memory) {
        (uint8 id, MarketParams memory p,) = _decode(action);
        if (id == SUPPLY_COLLATERAL || id == WITHDRAW_COLLATERAL) return _tokens1(p.collateralToken);
        if (id > REPAY_SHARES) revert UnknownAction(id);
        return _tokens1(p.loanToken);
    }

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 id, MarketParams memory p, uint256 amount) = _decode(action);
        if (id == SUPPLY || id == SUPPLY_COLLATERAL || id == BORROW) _checkNewExposure(p, id);
        bytes32 mid = _enter(p);
        uint256 a;
        uint256 s;
        address self = address(this);

        if (id == SUPPLY) {
            _pull(p.loanToken, amount);
            _approve(p.loanToken, address(morpho), amount);
            (a, s) = morpho.supply(p, amount, 0, self, "");
            _markets[mid].own += uint192(s);
            _approve(p.loanToken, address(morpho), 0);
        } else if (id == WITHDRAW) {
            uint256 mine = _fundShares(mid);
            if (amount == ALL) {
                (a, s) = morpho.withdraw(p, 0, mine, self, self);
            } else {
                (a, s) = morpho.withdraw(p, amount, 0, self, self);
                if (s > mine) revert PocketedSupply(mid); // only the Fund's own supply
            }
            _markets[mid].own -= uint192(s);
            _pushAll(p.loanToken);
        } else if (id == SUPPLY_COLLATERAL) {
            _pull(p.collateralToken, amount);
            _approve(p.collateralToken, address(morpho), amount);
            morpho.supplyCollateral(p, amount, self, "");
            _approve(p.collateralToken, address(morpho), 0);
            a = amount;
        } else if (id == WITHDRAW_COLLATERAL) {
            if (amount == ALL) {
                (,, uint128 c) = morpho.position(mid, self);
                amount = c;
            }
            morpho.withdrawCollateral(p, amount, self, self);
            _checkBuffer(p, mid);
            _pushAll(p.collateralToken);
            a = amount;
        } else if (id == BORROW) {
            (a, s) = morpho.borrow(p, amount, 0, self, self);
            _checkBuffer(p, mid);
            _pushAll(p.loanToken);
        } else if (id == REPAY) {
            _pull(p.loanToken, amount);
            _approve(p.loanToken, address(morpho), amount);
            (a, s) = morpho.repay(p, amount, 0, self, "");
            _approve(p.loanToken, address(morpho), 0);
            _pushAll(p.loanToken);
        } else if (id == REPAY_SHARES) {
            // Same block, same state as `inputs`, so this is exactly what the vault approved.
            (uint256 shares, uint256 cost) = _repaySharesCost(p, mid, amount);
            _pull(p.loanToken, cost);
            _approve(p.loanToken, address(morpho), cost);
            (a, s) = morpho.repay(p, 0, shares, self, "");
            _approve(p.loanToken, address(morpho), 0);
            _pushAll(p.loanToken);
        } else {
            revert UnknownAction(id);
        }
        _forgetIfEmpty(mid);
        return abi.encode(a, s);
    }

    // ---------------------------------------------------------------- positions

    function positions(IPriceRouter) external view returns (Amount[] memory assets, Amount[] memory debts) {
        uint256 n = _open.length;
        assets = new Amount[](2 * n);
        debts = new Amount[](n);
        uint256 na;
        uint256 nd;
        for (uint256 i; i < n; ++i) {
            bytes32 mid = _open[i];
            MarketParams memory p = _paramsOf(mid);
            (, uint256 borrowShares, uint256 collateral) = _position(mid);
            uint256 supplyShares = _fundShares(mid);
            MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
            if (supplyShares != 0) {
                // A market AINDEX has not approved: a row of zero, so the supply is worth nothing to NAV but the
                // adapter still takes part in exits (see the header).
                uint256 sup = _approved(mid) ? supplyShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares) : 0;
                if (sup != 0 || !_approved(mid)) assets[na++] = Amount(p.loanToken, sup);
            }
            if (collateral != 0) assets[na++] = Amount(p.collateralToken, collateral);
            if (borrowShares != 0) {
                debts[nd++] = Amount(p.loanToken, borrowShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares));
            }
        }
        assembly ("memory-safe") {
            mstore(assets, na)
            mstore(debts, nd)
        }
    }

    /// @notice Supply in markets that are not approved, at what it would be worth if counted (`IUnvalued`). The
    ///         teller takes no new deposits while any is above dust: new shares would share it without paying.
    function unvalued() external view returns (Amount[] memory out) {
        uint256 n = _open.length;
        out = new Amount[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            bytes32 mid = _open[i];
            if (_approved(mid)) continue;
            uint256 supplyShares = _fundShares(mid);
            if (supplyShares == 0) continue;
            MarketParams memory p = _paramsOf(mid);
            MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
            out[k++] = Amount(p.loanToken, supplyShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares));
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    // ---------------------------------------------------------------- exits

    /**
     * @notice Loan tokens `unwind(f)` and `split(f, to)` need from the vault: the cost of repaying the
     *         fraction `f` of every borrow, interest included, one entry per loan token.
     * @dev    Borrow shares are sliced rounding up, so the remaining holders never keep more than their
     *         share of the debt.
     */
    function unwindInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        if (fractionWad > WAD) revert BadFraction();
        uint256 n = _open.length;
        needs = new Amount[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            bytes32 mid = _open[i];
            (uint256 cost,) = _repaySlice(mid, fractionWad);
            if (cost == 0) continue;
            address t = _markets[mid].loanToken;
            bool merged;
            for (uint256 j; j < k; ++j) {
                if (needs[j].token == t) {
                    needs[j].amount += cost;
                    merged = true;
                    break;
                }
            }
            if (!merged) needs[k++] = Amount(t, cost);
        }
        assembly ("memory-safe") {
            mstore(needs, k)
        }
    }

    /**
     * @notice Turns `fractionWad` of every Morpho position back into tokens in the vault.
     * @dev    Per market, in this order:
     *         1. Repay the fraction of the borrow, with loan tokens pulled from the vault (declared by
     *            `unwindInputs`; the caller approves them). If the vault holds less, what it has is used.
     *         2. Withdraw the same fraction of collateral (rounded down). Morpho refuses if what is left
     *            would be unhealthy, for example when step 1 could not be paid in full; then this market's
     *            collateral stays put.
     *         3. Withdraw the fraction of supply, as far as the market's free liquidity allows.
     *
     *         Nothing here reverts because one market cannot pay: Morpho stock-collateral markets sit near
     *         100% utilisation, so supply in them may only come back in part, or not at all, until
     *         borrowers repay. The rest stays a position of the Fund (still in `positions`), and the caller
     *         compares `received` with what it expected. Unused loan tokens go back to the vault.
     * @return received tokens that came out of Morpho (collateral and supply), not counting unused repay money.
     */
    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        return _exit(fractionWad, vault, false);
    }

    /**
     * @notice In-kind exit for one leaver. Morpho positions cannot be transferred, so the leaver's slice is
     *         paid in the underlying tokens: its share of collateral and of supply, sent to `to`.
     * @dev    A borrowing position must be repaid before its collateral can be freed, so the leaver's slice
     *         of every debt is repaid first with loan tokens from the vault (the same `unwindInputs`, which
     *         the caller approves). The caller (the teller) must therefore take that repayment out of the
     *         leaver's slice of the vault's own tokens, otherwise the remaining holders pay the leaver's
     *         debt.
     *
     *         Unlike `unwind`, the debt side is all or nothing: if the vault cannot fund the whole repayment
     *         (`SplitUnfunded`), or Morpho refuses the repayment or the collateral release, the split reverts.
     *         It never hands out a leaver's collateral while leaving the leaver's debt behind, nor keeps
     *         collateral behind a debt that should have been cleared. The leaver's claim on this adapter then
     *         waits (`Teller.claimInKind` reverts for it) and its other adapters still pay. Supply is paid as far as
     *         the market's free liquidity allows: what it cannot pay today becomes the leaver's own supply shares
     *         (`leaverShares`, `LeaverOwed`), out of the Fund's positions, paid out by anyone as borrowers repay
     *         (`payLeaver`). `sent` says what the leaver got now.
     * @return sent tokens sent to `to`.
     */
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (to == address(0)) revert ZeroAddress();
        return _exit(fractionWad, to, true);
    }

    // ---------------------------------------------------------------- deposits into the existing mix

    /// @dev What growing one market by a fraction takes: supply shares to mint and what they cost, and collateral
    ///      to post. The borrow is sized in `grow`, per loan token across markets (`_growDebt`).
    struct GrowPlan {
        uint256 supplyShares;
        uint256 supplyCost;
        uint256 collateral;
    }

    /// @dev Per loan token, the debt `positions` reported before a grow (each market rounded up, summed) and after
    ///      it, so far.
    struct DebtTally {
        address[] tokens;
        uint256[] before;
        uint256[] grown;
        uint256 n;
    }

    /**
     * @notice What `grow(fractionWad)` pulls from the vault: per market, the loan token that buys the extra
     *         supply shares and the extra collateral, one entry per token. Not netted against the borrow (see
     *         `grow`).
     */
    function growInputs(uint256 fractionWad) public view returns (Amount[] memory needs) {
        (needs,) = _growAll(fractionWad);
    }

    /// @dev Every market's grow and the inputs they sum to, worked out once for `growInputs` and `grow` (growing
    ///      one market moves no other market's totals).
    function _growAll(uint256 fractionWad) internal view returns (Amount[] memory needs, GrowPlan[] memory plans) {
        uint256 n = _open.length;
        needs = new Amount[](2 * n);
        plans = new GrowPlan[](n);
        uint256 rows;
        for (uint256 i; i < n; ++i) {
            bytes32 mid = _open[i];
            MarketParams memory p = _paramsOf(mid);
            GrowPlan memory g = _growPlan(p, mid, fractionWad);
            plans[i] = g;
            if (g.supplyCost != 0) rows = _tally(needs, rows, p.loanToken, g.supplyCost);
            if (g.collateral != 0) rows = _tally(needs, rows, p.collateralToken, g.collateral);
        }
        needs = _trim(needs, rows);
    }

    /**
     * @notice Grows every Morpho position by `fractionWad` (1e18 = double): per market, supply, collateral and
     *         debt each by the same fraction, so the market's LTV stays where it was. Supply and collateral are
     *         paid from the vault (`growInputs`); the borrowed loan tokens go to the vault.
     * @dev    Per market, in this order:
     *         1. Supply: mint the fraction of our supply shares, rounded up, plus the shares one raw unit is
     *            worth. Morpho charges a share's assets rounded up, so the share price never falls on our
     *            supply, and the margin covers `positions` rounding the result down.
     *         2. Collateral: post the fraction of what is posted, rounded up.
     *         3. Debt: borrow so that the debt `positions` reports per loan token, summed over every market that
     *            lends it, goes from `D` to `ceil(D * (1 + f))`, worked out with Morpho's own rounding (one more raw
     *            unit when the rounding of the new shares would leave it a unit short). Markets are taken in turn,
     *            each aiming at what the running total still needs and read back after its borrow, so the units
     *            each market's rounding adds do not pile up: the reported total lands in
     *            `[D * (1 + f), D * (1 + f) + 2)` however many markets lend the token. Never less, so the new money
     *            is as levered as the old, and never more than the teller's two-unit slack, so the old holders
     *            carry no new debt. (Sized market by market, each market's debt is an integer that must reach
     *            `d * (1 + f)`, so each could land up to two units over and seven USDG borrows read 4 to 12 units
     *            over the slack on the fork.)
     *         Supply comes first so a market the Fund both lends to and borrows from has the liquidity for the
     *         borrow; collateral comes before the borrow so Morpho's health check sees it.
     *
     *         Why the borrow is not netted against the inputs: the borrowed tokens exist only after collateral
     *         is posted, and a Fund's collateral may be another market's loan token, so funding inputs from
     *         borrows would make the order of markets decide whether the call works. Gross inputs always work.
     *         The borrowed tokens land in the vault in this call; the teller treats them as the batch's money
     *         (they are the batch's share of the leverage), measuring the vault's balances before and after.
     *
     *         What is not checked, and why:
     *         - Market approval, the dial's `allowUnreviewed`, the market list and the borrow-token price class
     *           are rules for NEW exposure. Growing collateral and debt by the same fraction keeps the Fund's mix
     *           as its holders already hold it, in any market. The one exception is supply in a market that is
     *           not approved: it counts as nothing, so new money does not buy more of it, and while it is above
     *           dust the teller takes no new money at all (`unvalued`). A market AINDEX has since delisted is
     *           treated the same; the manager's job is to leave it (withdraw and repay are never blocked).
     *         - The LLTV buffer limits new risk taken by the manager. Growing proportionally keeps a market's LTV
     *           where it is, so a market above the buffer (prices moved) still grows. Morpho's own health check
     *           still applies to the borrow: a market at or past its LLTV refuses, and the whole grow, and the
     *           deposit batch, reverts until the manager repairs the position. Adding new money to a position
     *           that is being liquidated would hand depositors' money to liquidators.
     *         - Liquidity: a borrow from a market with too little free liquidity reverts, likewise.
     * @return used what was pulled from the vault (always `growInputs(fractionWad)`); borrowed tokens are
     *         not subtracted.
     */
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        GrowPlan[] memory plans;
        (used, plans) = _growAll(fractionWad);
        _pullAll(used);
        // Morpho is approved once per token for what every market is to take of it (`used` sums them) and cleared
        // once at the end; it pulls only inside `supply` and `supplyCollateral`, exactly what each call is for.
        for (uint256 i; i < used.length; ++i) _approve(used[i].token, address(morpho), used[i].amount);
        bytes32[] memory list = _open;
        address self = address(this);
        DebtTally memory t = DebtTally(new address[](list.length), new uint256[](list.length), new uint256[](list.length), 0);
        for (uint256 i; i < list.length; ++i) {
            bytes32 mid = list[i];
            MarketParams memory p = _paramsOf(mid);
            GrowPlan memory g = plans[i];
            if (g.supplyShares != 0) {
                morpho.supply(p, 0, g.supplyShares, self, "");
                _markets[mid].own += uint192(g.supplyShares);
            }
            if (g.collateral != 0) morpho.supplyCollateral(p, g.collateral, self, "");
            if (fractionWad != 0) _growDebt(t, p, mid, fractionWad);
        }
        // Every input was spent exactly (same block, same totals as `growInputs`); anything else goes home.
        for (uint256 i; i < used.length; ++i) {
            _approve(used[i].token, address(morpho), 0);
            _pushAll(used[i].token);
        }
    }

    /// @dev See `grow` for the rounding of each leg.
    function _growPlan(MarketParams memory p, bytes32 mid, uint256 fractionWad)
        internal
        view
        returns (GrowPlan memory g)
    {
        if (fractionWad == 0) return g;
        (,, uint256 collateral) = _position(mid);
        uint256 supplyShares = _fundShares(mid);
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
        // Supply in a market that is not approved counts as nothing, so new money does not buy more of it.
        if (supplyShares != 0 && _approved(mid)) {
            g.supplyShares = MorphoMath.mulDivUp(supplyShares, fractionWad, WAD)
                + MorphoMath.toSharesUp(1, m.totalSupplyAssets, m.totalSupplyShares);
            g.supplyCost = g.supplyShares.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);
        }
        if (collateral != 0) g.collateral = MorphoMath.mulDivUp(collateral, fractionWad, WAD);
    }

    /**
     * @dev One market's share of growing its loan token's debt (see `grow`, step 3). `t` keeps, per loan token,
     *      the debt read before over the markets taken so far and what they report now. This market borrows what
     *      takes the running total to `ceil(before * (1 + f))`, or nothing when the markets before it already
     *      did (a unit their rounding added). Its own debt is then read back from Morpho, rounded up as
     *      `positions` rounds it.
     */
    function _growDebt(DebtTally memory t, MarketParams memory p, bytes32 mid, uint256 fractionWad) internal {
        (, uint256 shares,) = _position(mid);
        if (shares == 0) return;
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
        uint256 debt = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 k;
        while (k < t.n && t.tokens[k] != p.loanToken) ++k;
        if (k == t.n) t.tokens[t.n++] = p.loanToken;
        t.before[k] += debt;
        uint256 total = t.before[k] + MorphoMath.mulDivUp(t.before[k], fractionWad, WAD);
        uint256 target = total > t.grown[k] ? total - t.grown[k] : 0;
        if (target > debt) {
            (uint256 got,) = morpho.borrow(p, _borrowFor(shares, m, debt, target), 0, address(this), address(this));
            _push(p.loanToken, vault, got);
            (, shares,) = _position(mid);
            (,, uint128 tb, uint128 tbs,,) = morpho.market(mid);
            debt = shares.toAssetsUp(tb, tbs);
        }
        t.grown[k] += debt;
    }

    /// @dev The loan assets that take a market's reported debt (`debt`, of `shares`) to at least `target` under
    ///      Morpho's rounding: a borrow of `a` adds `toSharesUp(a)` shares and `a` assets to the market's totals.
    function _borrowFor(uint256 shares, MorphoMarket memory m, uint256 debt, uint256 target)
        internal
        pure
        returns (uint256 a)
    {
        uint256 ta = m.totalBorrowAssets;
        uint256 ts = m.totalBorrowShares;
        a = target - debt;
        for (uint256 k; k < 3; ++k) {
            uint256 sh = a.toSharesUp(ta, ts);
            if ((shares + sh).toAssetsUp(ta + a, ts + sh) >= target) return a;
            ++a;
        }
    }

    // ---------------------------------------------------------------- holders' pockets (IPocketable)

    /**
     * @notice Controller only (the teller's `pocket`): every supply this clone holds in a market AINDEX has not
     *         approved and whose loan token is `token` (what `unvalued` reports) stops being the Fund's and belongs to
     *         pocket `id`: what the market can pay now is withdrawn and paid in, the rest by `drain` later. A market
     *         whose supply already pays into another pocket refuses a second one until it is drained.
     * @return paid what was paid into the pocket now.
     */
    function pocket(address token, IPockets pockets_, uint256 id)
        external
        onlyController
        nonReentrant
        returns (uint256 paid)
    {
        if (address(pockets_) == address(0) || (address(pockets) != address(0) && pockets_ != pockets)) {
            revert BadPockets();
        }
        pockets = pockets_;
        bytes32[] memory list = _open;
        for (uint256 i; i < list.length; ++i) {
            bytes32 mid = list[i];
            if (_markets[mid].loanToken != token || _approved(mid)) continue;
            uint256 supplyShares = _markets[mid].own - (leaverMarkets == 0 ? 0 : leaverTotal[mid]); // pocketed or not
            uint256 cur = pocketedShares[mid];
            if (supplyShares <= cur) continue;
            if (cur != 0 && pocketIdOf[mid] != id) revert PocketBusy(mid);
            if (cur == 0) ++pocketedMarkets;
            pocketedShares[mid] = supplyShares;
            pocketIdOf[mid] = id;
            emit SupplyPocketed(mid, id, supplyShares - cur);
        }
        paid = _drainAll();
    }

    /// @notice Anyone: withdraw what every market with pocketed supply can pay now and pay it into its pocket.
    function drain() external nonReentrant returns (uint256 paid) {
        return _drainAll();
    }

    function _drainAll() internal returns (uint256 paid) {
        if (pocketedMarkets == 0) return 0;
        bytes32[] memory list = _open;
        for (uint256 i; i < list.length; ++i) {
            if (pocketedShares[list[i]] != 0) paid += _drain(list[i]);
        }
        for (uint256 i; i < list.length; ++i) {
            _forgetIfEmpty(list[i]);
        }
    }

    /// @dev Withdraw as much of one market's pocketed supply as its free liquidity allows and pay it in.
    function _drain(bytes32 mid) internal returns (uint256 got) {
        MarketParams memory p = _paramsOf(mid);
        uint256 shares = pocketedShares[mid];
        uint256 pid = pocketIdOf[mid];
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
        uint256 want = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        uint256 free = _liquidity(p, m);
        uint256 burned;
        if (want <= free) {
            (got, burned) = morpho.withdraw(p, 0, shares, address(this), address(this));
        } else if (free != 0) {
            (got, burned) = morpho.withdraw(p, free, 0, address(this), address(this));
        }
        if (burned > shares) burned = shares;
        _markets[mid].own -= uint192(burned);
        uint256 left = shares - burned;
        pocketedShares[mid] = left;
        if (left == 0) {
            --pocketedMarkets;
            delete pocketIdOf[mid];
        }
        if (got != 0) {
            _approve(p.loanToken, address(pockets), got);
            pockets.topUp(vault, pid, got);
            _approve(p.loanToken, address(pockets), 0);
            emit Drained(mid, pid, got);
        }
    }

    // ---------------------------------------------------------------- views for agents

    function marketId(MarketParams memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    /// @notice Every market this clone has an open position in.
    function markets() external view returns (MarketParams[] memory list) {
        uint256 n = _open.length;
        list = new MarketParams[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = _paramsOf(_open[i]);
        }
    }

    /**
     * @notice This clone's position in one market, with the numbers that decide liquidation.
     * @dev    Liquidation starts when borrowed > collateral x oracle price x LLTV, so the liquidation price is
     *         borrowed x 1e36 / (collateral x LLTV), rounded up, in the oracle's scale. To read it in USD per
     *         whole collateral token for a dollar loan token: price x 10^collateralDecimals / 10^loanDecimals
     *         / 1e36. Uses the market's oracle, not the Fund's router, because Morpho liquidates on its own
     *         oracle.
     */
    function marketHealth(MarketParams memory p) external view returns (MarketHealth memory h) {
        bytes32 mid = marketId(p);
        h.id = mid;
        h.lltv = p.lltv;
        (, uint256 borrowShares, uint256 collateral) = _position(mid);
        uint256 supplyShares = _fundShares(mid);
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
        h.supplied = supplyShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        h.borrowed = borrowShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        h.collateral = collateral;
        h.liquidity = _liquidity(p, m);
        if (p.oracle != address(0) && p.oracle.code.length != 0) {
            try IMorphoOracle(p.oracle).price() returns (uint256 px) {
                h.oraclePrice = px;
            } catch {}
        }
        if (h.oraclePrice != 0 && collateral != 0) {
            uint256 value = Math.mulDiv(collateral, h.oraclePrice, MorphoMath.ORACLE_SCALE);
            h.maxBorrow = MorphoMath.mulDivDown(value, p.lltv, WAD);
            if (h.borrowed != 0) h.ltv = value == 0 ? type(uint256).max : MorphoMath.mulDivUp(h.borrowed, WAD, value);
        }
        if (h.borrowed != 0 && collateral != 0 && p.lltv != 0) {
            uint256 perUnit = Math.mulDiv(h.borrowed, MorphoMath.ORACLE_SCALE, collateral, Math.Rounding.Ceil);
            h.liquidationPrice = Math.mulDiv(perUnit, WAD, p.lltv, Math.Rounding.Ceil);
        }
    }

    // ---------------------------------------------------------------- internals

    function _decode(bytes calldata action) internal pure returns (uint8 id, MarketParams memory p, uint256 amount) {
        (id, p, amount) = abi.decode(action, (uint8, MarketParams, uint256));
    }

    function _position(bytes32 mid) internal view returns (uint256 supplyShares, uint256 borrowShares, uint256 collateral) {
        (uint256 s, uint128 b, uint128 c) = morpho.position(mid, address(this));
        return (s, b, c);
    }

    /// @dev The three conditions for adding exposure (see the header).
    function _checkNewExposure(MarketParams memory p, uint8 id) internal view {
        bytes32 mid = marketId(p);
        if (!_approved(mid) && !IFundController(controller).dial().allowUnreviewed) revert MarketNotApproved(mid);
        if (id == BORROW && IControllerRouter(controller).router().classOf(p.loanToken) == PriceClass.None) {
            revert TokenNotPriced(p.loanToken);
        }
        if (restricted && !allowedMarket[mid]) revert MarketNotAllowed(mid);
    }

    /// @dev True when AINDEX lists the market (all five parameters) as reviewed. A registry that cannot answer
    ///      counts as not approved, the cautious side for both the gate and the valuation.
    function _approved(bytes32 mid) internal view returns (bool) {
        try marketRegistry.isApproved(mid) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @dev Records the market as open (it must exist on Morpho).
    function _enter(MarketParams memory p) internal returns (bytes32 mid) {
        mid = marketId(p);
        if (_slot[mid] != 0) return mid;
        (,,,, uint128 lastUpdate,) = morpho.market(mid);
        if (lastUpdate == 0) revert MarketNotCreated(mid);
        if (_open.length >= MAX_MARKETS) revert TooManyMarkets();
        _open.push(mid);
        _slot[mid] = _open.length;
        if (p.lltv > type(uint64).max) revert MarketNotCreated(mid); // no Morpho LLTV is above 1e18
        _markets[mid] = Market(p.loanToken, p.collateralToken, p.oracle, p.irm, uint64(p.lltv), 0);
    }

    /// @dev Called right after Morpho accrued this market, so its stored totals are current.
    function _checkBuffer(MarketParams memory p, bytes32 mid) internal view {
        (, uint256 borrowShares, uint256 collateral) = _position(mid);
        if (borrowShares == 0) return;
        (,, uint128 tb, uint128 tbs,,) = morpho.market(mid);
        uint256 borrowed = borrowShares.toAssetsUp(tb, tbs);
        uint256 value = Math.mulDiv(collateral, IMorphoOracle(p.oracle).price(), MorphoMath.ORACLE_SCALE);
        uint256 limit = Math.mulDiv(p.lltv, LLTV_BUFFER, WAD);
        uint256 ltv = value == 0 ? type(uint256).max : Math.mulDiv(borrowed, WAD, value, Math.Rounding.Ceil);
        if (ltv > limit) revert TooCloseToLiquidation(ltv, limit);
    }

    function _forgetIfEmpty(bytes32 mid) internal {
        uint256 slot = _slot[mid];
        if (slot == 0) return;
        (, uint256 b, uint256 c) = _position(mid);
        if (_markets[mid].own != 0 || b != 0 || c != 0) return; // supply put in on its behalf is not its own
        uint256 last = _open.length;
        if (slot != last) {
            bytes32 moved = _open[last - 1];
            _open[slot - 1] = moved;
            _slot[moved] = slot;
        }
        _open.pop();
        delete _slot[mid];
    }

    /// @dev Shares to repay (ALL = the whole debt) and the loan tokens that costs in this block.
    function _repaySharesCost(MarketParams memory p, bytes32 mid, uint256 amount)
        internal
        view
        returns (uint256 shares, uint256 assets)
    {
        shares = amount;
        if (amount == ALL) (, shares,) = _position(mid);
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
        assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    /**
     * @dev The borrow shares an exit of `fractionWad` repays in a market, and their cost now: the fraction rounded
     *      up, plus the shares one raw unit of debt is worth (the leaver's slice rounds against the leaver, by at
     *      most a unit). What `positions` then reports for the remaining holders, rounded up, is at most
     *      `(1 - f)` times what it reported before in this market, so the teller's check holds however many
     *      markets owe the same token: each market keeps its own rounding instead of passing it to the slack.
     */
    function _repaySlice(bytes32 mid, uint256 fractionWad) internal view returns (uint256 cost, uint256 shares) {
        (, uint256 borrowShares,) = _position(mid);
        if (borrowShares == 0 || fractionWad == 0) return (0, 0);
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, _paramsOf(mid), mid);
        shares = MorphoMath.mulDivUp(borrowShares, fractionWad, WAD);
        if (fractionWad < WAD) shares += MorphoMath.toSharesUp(1, m.totalBorrowAssets, m.totalBorrowShares);
        if (shares > borrowShares) shares = borrowShares;
        cost = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @dev Loan tokens the market can pay out now: what is supplied and not lent, never more than Morpho holds.
    function _liquidity(MarketParams memory p, MorphoMarket memory m) internal view returns (uint256 free) {
        free = m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
        uint256 held = IERC20(p.loanToken).balanceOf(address(morpho));
        if (held < free) free = held;
    }

    /// @dev Shared body of `unwind` (to = vault) and `split` (to = the leaver).
    /// @dev `strict` (split): the debt slice must be repaid and the collateral slice freed, or the call reverts.
    function _exit(uint256 fractionWad, address to, bool strict) internal returns (Amount[] memory out) {
        if (fractionWad > WAD) revert BadFraction();
        bytes32[] memory list = _open; // copy: markets may be forgotten as we go
        uint256 n = list.length;
        out = new Amount[](2 * n);
        if (fractionWad == 0 || n == 0) {
            assembly ("memory-safe") {
                mstore(out, 0)
            }
            return out;
        }

        // 1. Pull the repay money once per loan token, as much as the vault can give of what was declared.
        Amount[] memory needs = _pullRepayMoney(fractionWad, strict);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            k = _exitMarket(out, k, list[i], fractionWad, strict, to);
        }

        // 2. Send what came out to its destination; unused repay money goes back to the vault.
        for (uint256 i; i < k; ++i) {
            _push(out[i].token, to, out[i].amount);
        }
        for (uint256 i; i < needs.length; ++i) {
            _approve(needs[i].token, address(morpho), 0);
            _pushAll(needs[i].token);
        }
        for (uint256 i; i < n; ++i) {
            _forgetIfEmpty(list[i]);
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    function _pullRepayMoney(uint256 fractionWad, bool strict) internal returns (Amount[] memory needs) {
        needs = unwindInputs(fractionWad);
        for (uint256 i; i < needs.length; ++i) {
            uint256 can = needs[i].amount;
            uint256 bal = IERC20(needs[i].token).balanceOf(vault);
            uint256 allowed = IERC20(needs[i].token).allowance(vault, address(this));
            if (bal < can) can = bal;
            if (allowed < can) can = allowed;
            if (strict && can < needs[i].amount) revert SplitUnfunded(needs[i].token, needs[i].amount, can);
            _pull(needs[i].token, can);
        }
    }

    function _exitMarket(Amount[] memory out, uint256 k, bytes32 mid, uint256 fractionWad, bool strict, address to)
        internal
        returns (uint256)
    {
        MarketParams memory p = _paramsOf(mid);
        _repayPart(p, mid, fractionWad, strict);
        k = _record(out, k, p.collateralToken, _withdrawCollateralPart(p, mid, fractionWad, strict));
        return _record(out, k, p.loanToken, _withdrawSupplyPart(p, mid, fractionWad, strict ? to : address(0)));
    }

    function _repayPart(MarketParams memory p, bytes32 mid, uint256 fractionWad, bool strict) internal {
        (uint256 cost, uint256 shares) = _repaySlice(mid, fractionWad);
        if (shares == 0) return;
        uint256 have = IERC20(p.loanToken).balanceOf(address(this));
        if (strict) {
            // Funded in full by `_pullRepayMoney`; any failure must stop the split.
            _approve(p.loanToken, address(morpho), cost);
            morpho.repay(p, 0, shares, address(this), "");
            return;
        }
        if (have == 0) return;
        _approve(p.loanToken, address(morpho), have);
        if (have >= cost) {
            uint256 g = gasleft();
            try morpho.repay(p, 0, shares, address(this), "") {} catch { _notShortOfGas(g); }
        } else {
            // Not enough to clear the slice: repay what we have, which lowers the debt anyway.
            uint256 g = gasleft();
            try morpho.repay(p, have, 0, address(this), "") {} catch { _notShortOfGas(g); }
        }
    }

    function _withdrawCollateralPart(MarketParams memory p, bytes32 mid, uint256 fractionWad, bool strict)
        internal
        returns (uint256 got)
    {
        (,, uint256 collateral) = _position(mid);
        uint256 amount = MorphoMath.mulDivDown(collateral, fractionWad, WAD);
        if (amount == 0) return 0;
        if (strict) {
            morpho.withdrawCollateral(p, amount, address(this), address(this));
            return amount;
        }
        uint256 g = gasleft();
        try morpho.withdrawCollateral(p, amount, address(this), address(this)) {
            got = amount;
        } catch {
            _notShortOfGas(g);
        }
    }

    /// @dev The fraction of the Fund's supply shares, rounded down, less the shares one raw unit is worth (the mirror
    ///      of `_repaySlice`): what `positions` reports for the remaining holders, rounded down, stays at least
    ///      `(1 - f)` times what it reported before in this market. Withdrawn as far as the market's free liquidity
    ///      allows. For a leaver (`leaver` set, a split) what the market cannot pay now becomes the leaver's shares
    ///      (`leaverShares`), paid out later by `payLeaver`; for an unwind it stays the Fund's.
    function _withdrawSupplyPart(MarketParams memory p, bytes32 mid, uint256 fractionWad, address leaver)
        internal
        returns (uint256 got)
    {
        uint256 shares = MorphoMath.mulDivDown(_fundShares(mid), fractionWad, WAD);
        if (shares == 0) return 0;
        MorphoMarket memory m = MorphoMath.expectedMarket(morpho, p, mid);
        if (fractionWad < WAD) {
            uint256 unit = MorphoMath.toSharesUp(1, m.totalSupplyAssets, m.totalSupplyShares);
            if (shares <= unit) return 0;
            shares -= unit;
        }
        uint256 burned;
        (got, burned) = _withdrawUpTo(p, m, shares);
        _markets[mid].own -= uint192(burned);
        if (leaver != address(0) && burned < shares) {
            uint256 owedShares = shares - burned;
            leaverShares[mid][leaver] += owedShares;
            if (leaverTotal[mid] == 0) ++leaverMarkets;
            leaverTotal[mid] += owedShares;
            emit LeaverOwed(mid, leaver, owedShares);
        }
    }

    /// @dev Withdraw `shares` of supply, or as much as the market's free liquidity pays (never more shares).
    function _withdrawUpTo(MarketParams memory p, MorphoMarket memory m, uint256 shares)
        internal
        returns (uint256 got, uint256 burned)
    {
        uint256 want = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        uint256 free = _liquidity(p, m);
        uint256 g = gasleft();
        if (want <= free) {
            try morpho.withdraw(p, 0, shares, address(this), address(this)) returns (uint256 a, uint256 b) {
                (got, burned) = (a, b);
            } catch {
                _notShortOfGas(g);
            }
        } else if (free != 0) {
            try morpho.withdraw(p, free, 0, address(this), address(this)) returns (uint256 a, uint256 b) {
                (got, burned) = (a, b);
            } catch {
                _notShortOfGas(g);
            }
        }
        if (burned > shares) burned = shares; // cannot happen: `free` assets are worth less than `shares`
    }

    /// @dev After a tolerated Morpho call failed: when something inside it ran out of gas, each call level kept back
    ///      1/64 of its gas, so the caller gets back only a small share of what it had (about 1/32 two levels deep,
    ///      under 1/16 at four, as with a proxied token). A market that refuses does so early and leaves far more.
    ///      Under 1/8 left counts as gas, so a low estimate fails loudly instead of paying nothing; erring this way
    ///      only asks for a retry with more gas.
    function _notShortOfGas(uint256 before) private view {
        if (gasleft() < before / 8) revert ShortGas();
    }

    /// @notice Anyone: pay `leaver` what the market can pay now of its supply shares in market `mid` (`leaverShares`).
    function payLeaver(bytes32 mid, address leaver) external nonReentrant returns (uint256 got) {
        uint256 shares = leaverShares[mid][leaver];
        if (shares == 0) return 0;
        MarketParams memory p = _paramsOf(mid);
        uint256 burned;
        (got, burned) = _withdrawUpTo(p, MorphoMath.expectedMarket(morpho, p, mid), shares);
        if (burned == 0) return 0;
        leaverShares[mid][leaver] = shares - burned;
        leaverTotal[mid] -= burned;
        if (leaverTotal[mid] == 0) --leaverMarkets;
        _markets[mid].own -= uint192(burned);
        if (got != 0) _push(p.loanToken, leaver, got);
        emit LeaverPaid(mid, leaver, got);
        _forgetIfEmpty(mid);
    }

    /// @notice Supply shares this clone minted itself in market `id` (pocketed and leavers' shares included). Shares
    ///         anyone else supplied on its behalf are not counted anywhere (see the header).
    function ownShares(bytes32 id) external view returns (uint256) {
        return _markets[id].own;
    }

    function _paramsOf(bytes32 mid) internal view returns (MarketParams memory) {
        Market storage m = _markets[mid];
        return MarketParams(m.loanToken, m.collateralToken, m.oracle, m.irm, m.lltv);
    }

    /// @dev The Fund's supply shares in a market: what the clone minted itself, less pocketed and leavers' shares.
    function _fundShares(bytes32 mid) internal view returns (uint256 s) {
        s = _markets[mid].own;
        if (pocketedMarkets != 0) s -= pocketedShares[mid];
        if (leaverMarkets != 0) s -= leaverTotal[mid];
    }

    function _record(Amount[] memory out, uint256 k, address token, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return k;
        for (uint256 j; j < k; ++j) {
            if (out[j].token == token) {
                out[j].amount += amount;
                return k;
            }
        }
        out[k] = Amount(token, amount);
        return k + 1;
    }
}
