// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockERC20} from "../../utils/Mocks.sol";

/// @dev A pToken as measured on Robinhood Chain on 2026-10-06: requests take the owner's shares, the keeper fulfils
///      (shares become claimable at a fixed USDG amount) or rejects (shares claimable-cancelled), the controller may
///      cancel only after the 7-day TTL, and only the controller claims.
contract MockPToken is MockERC20 {
    struct Req { address controller; uint8 status; uint64 expiry; uint256 shares; uint256 claimableShares; uint256 assets; uint256 cancelled; }
    MockERC20 public immutable usdg;
    uint256 public perShare; // USDG raw per 1e18 shares
    uint256 public next = 1;
    mapping(uint256 => Req) public reqs;
    uint256 public constant TTL = 7 days;

    constructor(MockERC20 usdg_) MockERC20("Arcus HOOD 3x long", "pHOOD3x", 18) { usdg = usdg_; }

    function setPerShare(uint256 v) external { perShare = v; }
    function asset() external view returns (address) { return address(usdg); }
    function convertToAssets(uint256 shares) public view returns (uint256) { return shares * perShare / 1e18; }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 id) {
        require(owner == msg.sender, "owner");
        _transfer(owner, address(this), shares);
        id = next++;
        reqs[id] = Req(controller, 1, uint64(block.timestamp + TTL), shares, 0, 0, 0);
    }

    function fulfil(uint256 id) external {
        Req storage r = reqs[id];
        uint256 a = convertToAssets(r.shares);
        usdg.mint(address(this), a);
        _burn(address(this), r.shares);
        r.claimableShares = r.shares; r.assets = a; r.status = 2;
    }

    function reject(uint256 id) external {
        Req storage r = reqs[id];
        r.cancelled = r.shares; r.status = 2;
    }

    function pendingRedeemRequest(uint256 id, address c) public view returns (uint256) {
        Req storage r = reqs[id];
        return r.controller == c && r.status == 1 ? r.shares : 0;
    }
    function claimableRedeemRequest(uint256 id, address c) public view returns (uint256) {
        Req storage r = reqs[id];
        return r.controller == c ? r.claimableShares : 0;
    }
    function claimableCancelRedeemRequest(uint256 id, address c) public view returns (uint256) {
        Req storage r = reqs[id];
        return r.controller == c ? r.cancelled : 0;
    }
    function maxRedeem(address c) public view returns (uint256 s) {
        for (uint256 i = 1; i < next; ++i) if (reqs[i].controller == c) s += reqs[i].claimableShares;
    }
    function maxWithdraw(address c) public view returns (uint256 a) {
        for (uint256 i = 1; i < next; ++i) if (reqs[i].controller == c) a += reqs[i].assets;
    }
    /// @dev Pays claimable requests oldest first; a partial amount takes a pro-rata part of one request.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        require(msg.sender == controller, "controller");
        for (uint256 i = 1; i < next && shares > 0; ++i) {
            Req storage r = reqs[i];
            if (r.controller != controller || r.claimableShares == 0) continue;
            uint256 take = shares < r.claimableShares ? shares : r.claimableShares;
            uint256 a = r.assets * take / r.claimableShares;
            r.claimableShares -= take; r.assets -= a; shares -= take; assets += a;
        }
        usdg.transfer(receiver, assets);
    }
    function cancelRedeemRequest(uint256 id, address controller) external {
        Req storage r = reqs[id];
        require(msg.sender == controller && r.controller == controller, "controller");
        require(block.timestamp > r.expiry, "not expired");
        r.cancelled = r.shares; r.status = 3;
    }
    function claimCancelRedeemRequest(uint256 id, address receiver, address controller) external returns (uint256 s) {
        Req storage r = reqs[id];
        require(msg.sender == controller && r.controller == controller, "controller");
        s = r.cancelled; r.cancelled = 0; r.shares = 0;
        _transfer(address(this), receiver, s);
    }
    function redemption(uint256 id) external view returns (address, uint8, uint64, uint256, uint256) {
        Req storage r = reqs[id];
        return (r.controller, r.status, r.expiry, r.shares, r.claimableShares);
    }
}

contract MockPTokenFactory {
    mapping(address => bool) public isPToken;
    function set(address t, bool v) external { isPToken[t] = v; }
}
