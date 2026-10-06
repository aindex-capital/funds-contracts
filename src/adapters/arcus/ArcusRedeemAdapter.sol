// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "../BaseAdapter.sol";
import {Amount} from "../../interfaces/IAdapter.sol";
import {IPriceRouter} from "../../interfaces/IPriceRouter.sol";
import {IArcusPToken, IArcusPTokenFactory} from "../../interfaces/external/arcus/IArcusPToken.sol";

/**
 * @title  ArcusRedeemAdapter
 * @notice Lets a Fund leave an Arcus pToken at the value Arcus posts for it, instead of selling into the pToken's
 *         Uniswap v4 pool (0.425% or 0.85% fee, thin): it files an ERC-7540 redeem request for the Fund, and once
 *         Arcus' keeper fulfils it (about a minute) claims the USDG to the Fund's vault.
 *
 * @dev    ## Where things are
 *         The Fund holds pTokens in its vault (bought through the swap adapter, priced by `VaultShareSource`). A
 *         request moves shares from the vault into the pToken with this clone as owner and controller, so only this
 *         clone can claim them, and every claim pays the vault. Between calls the clone holds no loose tokens: its
 *         positions are its open requests.
 *
 *         ## Which pTokens
 *         Only tokens Arcus' factory reports as pTokens (`isPToken`), checked at each request. The factory is a proxy
 *         Arcus controls; a token it lists still has to be priced by the Fund's router for a Fund to hold it.
 *
 *         ## Valuation (`positions`)
 *         Per pToken with open requests, in its asset (USDG): what fulfilled requests pay now (`maxWithdraw`, fixed
 *         at fulfilment) plus pending shares at `convertToAssets` (the value Arcus posts, the same number the router
 *         prices the pToken by); and, in the pToken itself, shares Arcus rejected or that expired and wait to come
 *         back. A request that is never fulfilled can be cancelled after its 7 days, and its shares return.
 *
 *         ## Exits
 *         `grow(0)`, `unwind` and the `claim` action pay everything claimable to the vault and take back rejected or
 *         expired shares. A pending request cannot be split (ERC-7540 requests belong to one controller), so `split`
 *         reverts `RequestPending` while one is open rather than pay a leaver less than its slice: requests fill in
 *         about a minute and the teller's exit can run again after. At most `MAX_OPEN` requests at once keeps that
 *         window, and the position rows, small.
 */
contract ArcusRedeemAdapter is BaseAdapter {
    uint256 internal constant WAD = 1e18;
    /// @notice Most redeem requests open at once (two rows each in `positions`, under the teller's 13-row slack).
    uint256 public constant MAX_OPEN = 6;

    error BadAction();
    error NotPToken(address token);
    error ZeroShares();
    error TooManyRequests();
    error RequestPending(address pToken, uint256 requestId);
    error NoGrow();
    error BadFraction();

    event RedeemRequested(address indexed pToken, uint256 indexed requestId, uint256 shares);
    event Claimed(address indexed pToken, uint256 assets);
    event SharesReturned(address indexed pToken, uint256 indexed requestId, uint256 shares);
    event Cancelled(address indexed pToken, uint256 indexed requestId);

    struct Request {
        address pToken;
        uint256 id;
    }

    IArcusPTokenFactory public immutable factory;
    Request[] internal _open;

    constructor(IArcusPTokenFactory factory_) {
        factory = factory_;
    }

    function name() external pure returns (string memory) {
        return "Arcus pToken redeem v1";
    }

    function describe() external pure returns (string memory) {
        return string.concat(
            '{"adapter":"Arcus pToken redeem v1","venue":"Arcus pTokens (ERC-7540), Robinhood Chain",',
            '"notes":"Leave an Arcus pToken at the value Arcus posts for it, without the 0.425% or 0.85% fee of its Uniswap v4 pool. ',
            "request files a redeem request for shares the Fund holds; Arcus' keeper fulfils it in about a minute, and claim then pays the USDG to the Fund. ",
            "The keeper may reject a request: claim then returns the shares. A request not fulfilled within 7 days can be cancelled by claim, and its shares return. ",
            "While a request is pending the Fund counts it at the pToken's value. At most 6 requests open at once; claim before filing more. ",
            'Buying pTokens is done through the swap adapter (their pools); minting is restricted by Arcus.",',
            '"actions":[',
            '{"id":0,"name":"request","params":[',
            '{"name":"pToken","type":"address","about":"an Arcus pToken the Fund holds"},',
            '{"name":"shares","type":"uint256","about":"pToken shares to redeem, raw units (18 decimals)"}],',
            '"encoding":"abi.encode(uint8 0, address pToken, uint256 shares)"},',
            '{"id":1,"name":"claim","params":[],',
            '"encoding":"abi.encode(uint8 1, address(0), uint256 0)",',
            '"about":"pay every fulfilled request to the Fund in USDG, return rejected shares, cancel and return expired requests"}]}'
        );
    }

    // ---------------------------------------------------------------- actions

    function inputs(bytes calldata action) external pure returns (Amount[] memory) {
        (uint8 id, address pToken, uint256 shares) = abi.decode(action, (uint8, address, uint256));
        if (id == 0) return _one(pToken, shares);
        return _none();
    }

    function outputs(bytes calldata action) external view returns (address[] memory out) {
        (uint8 id,,) = abi.decode(action, (uint8, address, uint256));
        if (id == 0) return new address[](0);
        return _claimTokens();
    }

    function execute(bytes calldata action) external onlyController nonReentrant returns (bytes memory) {
        (uint8 id, address pToken, uint256 shares) = abi.decode(action, (uint8, address, uint256));
        if (id == 0) return abi.encode(_request(pToken, shares));
        if (id == 1) {
            _claimAll();
            return "";
        }
        revert BadAction();
    }

    function _request(address pToken, uint256 shares) internal returns (uint256 requestId) {
        if (shares == 0) revert ZeroShares();
        if (!factory.isPToken(pToken)) revert NotPToken(pToken);
        if (_open.length >= MAX_OPEN) revert TooManyRequests();
        _pull(pToken, shares);
        requestId = IArcusPToken(pToken).requestRedeem(shares, address(this), address(this));
        _open.push(Request(pToken, requestId));
        emit RedeemRequested(pToken, requestId, shares);
    }

    /// @dev Pays every claimable request to the vault, returns rejected or cancelled shares, cancels expired requests,
    ///      and forgets requests with nothing left.
    function _claimAll() internal {
        address[] memory tokens = _distinctTokens();
        for (uint256 t; t < tokens.length; ++t) {
            IArcusPToken p = IArcusPToken(tokens[t]);
            uint256 claimable = p.maxRedeem(address(this));
            if (claimable != 0) emit Claimed(tokens[t], p.redeem(claimable, vault, address(this)));
        }
        for (uint256 i = _open.length; i > 0; --i) {
            Request memory r = _open[i - 1];
            IArcusPToken p = IArcusPToken(r.pToken);
            uint256 pending = p.pendingRedeemRequest(r.id, address(this));
            if (pending != 0 && _expired(p, r.id)) {
                try p.cancelRedeemRequest(r.id, address(this)) {
                    emit Cancelled(r.pToken, r.id);
                } catch {}
                pending = p.pendingRedeemRequest(r.id, address(this));
            }
            uint256 back = p.claimableCancelRedeemRequest(r.id, address(this));
            if (back != 0) emit SharesReturned(r.pToken, r.id, p.claimCancelRedeemRequest(r.id, vault, address(this)));
            if (pending == 0 && p.claimableRedeemRequest(r.id, address(this)) == 0) _remove(i - 1);
        }
    }

    function _expired(IArcusPToken p, uint256 requestId) internal view returns (bool) {
        try p.redemption(requestId) returns (address, uint8, uint64 expiry, uint256, uint256) {
            return expiry != 0 && block.timestamp > expiry;
        } catch {
            return false;
        }
    }

    // ---------------------------------------------------------------- valuation

    function positions(IPriceRouter) external view returns (Amount[] memory assets, Amount[] memory debts) {
        address[] memory tokens = _distinctTokens();
        assets = new Amount[](tokens.length * 2);
        uint256 k;
        for (uint256 t; t < tokens.length; ++t) {
            IArcusPToken p = IArcusPToken(tokens[t]);
            uint256 pendingShares;
            uint256 returning;
            for (uint256 i; i < _open.length; ++i) {
                if (_open[i].pToken != tokens[t]) continue;
                pendingShares += p.pendingRedeemRequest(_open[i].id, address(this));
                returning += p.claimableCancelRedeemRequest(_open[i].id, address(this));
            }
            uint256 owed = p.maxWithdraw(address(this));
            if (pendingShares != 0) owed += p.convertToAssets(pendingShares);
            if (owed != 0) assets[k++] = Amount(p.asset(), owed);
            if (returning != 0) assets[k++] = Amount(tokens[t], returning);
        }
        assets = _trim(assets, k);
        debts = new Amount[](0);
    }

    /// @notice The open requests, for pages and agents: each pToken, request id, pending and claimable shares.
    function requests()
        external
        view
        returns (address[] memory pTokens, uint256[] memory ids, uint256[] memory pending, uint256[] memory claimable)
    {
        uint256 n = _open.length;
        pTokens = new address[](n);
        ids = new uint256[](n);
        pending = new uint256[](n);
        claimable = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            IArcusPToken p = IArcusPToken(_open[i].pToken);
            pTokens[i] = _open[i].pToken;
            ids[i] = _open[i].id;
            pending[i] = p.pendingRedeemRequest(_open[i].id, address(this));
            claimable[i] = p.claimableRedeemRequest(_open[i].id, address(this));
        }
    }

    // ---------------------------------------------------------------- exits

    /// @notice Pays what is claimable to the vault (all of it: it is the Fund's either way). Pending requests stay and
    ///         stay counted; they fill in about a minute.
    function unwind(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory received) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        address[] memory tokens = _claimTokens();
        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) before[i] = IERC20(tokens[i]).balanceOf(vault);
        _claimAll();
        received = new Amount[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            received[i] = Amount(tokens[i], IERC20(tokens[i]).balanceOf(vault) - before[i]);
        }
    }

    function unwindInputs(uint256) external pure returns (Amount[] memory) {
        return _none();
    }

    /// @notice Hands `to` its slice of what is claimable and of shares coming back; reverts `RequestPending` while a
    ///         request is still pending, since an ERC-7540 request cannot be split between controllers.
    function split(uint256 fractionWad, address to) external onlyController nonReentrant returns (Amount[] memory sent) {
        if (fractionWad == 0 || fractionWad > WAD) revert BadFraction();
        if (to == address(0)) revert ZeroAddress();
        for (uint256 i; i < _open.length; ++i) {
            if (IArcusPToken(_open[i].pToken).pendingRedeemRequest(_open[i].id, address(this)) != 0) {
                revert RequestPending(_open[i].pToken, _open[i].id);
            }
        }
        address[] memory tokens = _distinctTokens();
        sent = new Amount[](tokens.length * 2);
        uint256 k;
        for (uint256 t; t < tokens.length; ++t) {
            IArcusPToken p = IArcusPToken(tokens[t]);
            uint256 slice = p.maxRedeem(address(this)) * fractionWad / WAD;
            if (slice != 0) sent[k++] = Amount(p.asset(), p.redeem(slice, to, address(this)));
            uint256 back;
            for (uint256 i; i < _open.length; ++i) {
                if (_open[i].pToken != tokens[t]) continue;
                uint256 c = p.claimableCancelRedeemRequest(_open[i].id, address(this));
                if (c != 0) back += p.claimCancelRedeemRequest(_open[i].id, address(this), address(this));
            }
            if (back != 0) {
                uint256 mine = back * fractionWad / WAD;
                _push(tokens[t], to, mine);
                _pushAll(tokens[t]);
                if (mine != 0) sent[k++] = Amount(tokens[t], mine);
            }
        }
        sent = _trim(sent, k);
        for (uint256 i = _open.length; i > 0; --i) {
            IArcusPToken p = IArcusPToken(_open[i - 1].pToken);
            uint256 id = _open[i - 1].id;
            if (p.pendingRedeemRequest(id, address(this)) == 0 && p.claimableRedeemRequest(id, address(this)) == 0
                    && p.claimableCancelRedeemRequest(id, address(this)) == 0) {
                _remove(i - 1);
            }
        }
    }

    /// @notice `grow(0)` claims everything claimable into the vault; a Fund grows pTokens by buying them, not here.
    function grow(uint256 fractionWad) external onlyController nonReentrant returns (Amount[] memory used) {
        if (fractionWad != 0) revert NoGrow();
        _claimAll();
        return _none();
    }

    function growInputs(uint256 fractionWad) external pure returns (Amount[] memory) {
        if (fractionWad != 0) revert NoGrow();
        return _none();
    }

    // ---------------------------------------------------------------- helpers

    function _distinctTokens() internal view returns (address[] memory out) {
        out = new address[](_open.length);
        uint256 n;
        for (uint256 i; i < _open.length; ++i) {
            address t = _open[i].pToken;
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (out[j] == t) seen = true;
            }
            if (!seen) out[n++] = t;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    /// @dev Every token a claim can send the vault: each open pToken's asset and the pToken itself.
    function _claimTokens() internal view returns (address[] memory out) {
        address[] memory tokens = _distinctTokens();
        out = new address[](tokens.length * 2);
        uint256 n;
        for (uint256 t; t < tokens.length; ++t) {
            address a = IArcusPToken(tokens[t]).asset();
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (out[j] == a) seen = true;
            }
            if (!seen) out[n++] = a;
            out[n++] = tokens[t];
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _remove(uint256 i) internal {
        _open[i] = _open[_open.length - 1];
        _open.pop();
    }
}
