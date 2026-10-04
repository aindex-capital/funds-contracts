// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMorpho, MarketParams} from "../../interfaces/external/morpho/IMorpho.sol";

/**
 * @title  MorphoMarketRegistry
 * @notice The Morpho markets AINDEX has reviewed and accepts: a review badge. A market is its five parameters
 *         (loan token, collateral token, oracle, rate model, LLTV), and its id is the hash of all five, so an
 *         approval covers exactly one market and nothing built from some of its parts. A Fund whose dial has
 *         `allowUnreviewed` off adds exposure (supply, collateral, borrow) only in approved markets; a Fund with
 *         it on may use any market, and the Morpho adapter counts its supply in a market that is not approved
 *         as worth nothing.
 *
 * @dev    ## Why markets, not oracles
 *         Anyone can create a Morpho market, from any parts. Approving an oracle is not enough: a manager can
 *         create a market that lends USDG against a token it mints at will, priced by a reviewed oracle meant for
 *         another token, have the Fund lend into it, and borrow everything back from outside the Fund. The
 *         oracle is sound; the market is not. What a review can vouch for is the whole market: that its
 *         collateral is the asset its oracle prices, that the oracle cannot be re-pointed, that the rate model
 *         is Morpho's and the LLTV is sane.
 *
 *         ## What gets listed
 *         Markets whose oracle nobody can re-point (no proxy, no storage writes in its code, reading official
 *         Chainlink feeds or a fixed rate) and prices the market's own collateral in its own loan token, on
 *         Morpho's own rate model. The deploy notes record how each was checked.
 *
 *         ## Delays
 *         Adding a market widens what every Fund's manager may do, so it waits `DELAY` after it is proposed, in
 *         public; anyone may apply it once the delay has passed. Removing one only narrows it, so it is instant
 *         (it can lower, never raise, what Funds count for supply in it). Removal never traps a Fund:
 *         withdrawing, repaying and exits do not consult this registry. The constructor's seed list applies at
 *         once, because no Fund can depend on a registry before it exists. Only markets that exist on Morpho can
 *         be listed.
 */
contract MorphoMarketRegistry {
    error NotOwner();
    error NotReady();
    error NotPending();
    error NoMarket(bytes32 id);
    error ZeroAddress();

    uint64 public constant DELAY = 1 days;

    IMorpho public immutable morpho;
    address public owner;
    address public pendingOwner;

    /// @notice True when Funds may add exposure in this market (id = keccak256(abi.encode(MarketParams))).
    mapping(bytes32 => bool) public isApproved;
    /// @notice When a proposed market may be applied; zero when nothing is pending.
    mapping(bytes32 => uint64) public pendingAt;

    event MarketProposed(bytes32 indexed id, uint64 effectiveAt);
    event MarketApproved(bytes32 indexed id);
    event MarketRemoved(bytes32 indexed id);
    event ProposalCancelled(bytes32 indexed id);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address owner_, IMorpho morpho_, bytes32[] memory seed) {
        if (owner_ == address(0) || address(morpho_) == address(0)) revert ZeroAddress();
        owner = owner_;
        morpho = morpho_;
        emit OwnershipTransferred(address(0), owner_);
        for (uint256 i; i < seed.length; ++i) {
            _exists(seed[i]);
            isApproved[seed[i]] = true;
            emit MarketApproved(seed[i]);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice A market's id, as Morpho and this registry name it.
    function marketId(MarketParams calldata p) external pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    /// @notice Whether the market with these exact parameters is approved.
    function isApprovedMarket(MarketParams calldata p) external view returns (bool) {
        return isApproved[keccak256(abi.encode(p))];
    }

    /// @notice Start the delay for listing market `id`.
    function propose(bytes32 id) external onlyOwner {
        _exists(id);
        uint64 at = uint64(block.timestamp) + DELAY;
        pendingAt[id] = at;
        emit MarketProposed(id, at);
    }

    /// @notice List a proposed market once its delay has passed. Anyone may call.
    function applyPending(bytes32 id) external {
        uint64 at = pendingAt[id];
        if (at == 0) revert NotPending();
        if (block.timestamp < at) revert NotReady();
        delete pendingAt[id];
        isApproved[id] = true;
        emit MarketApproved(id);
    }

    function cancel(bytes32 id) external onlyOwner {
        if (pendingAt[id] == 0) revert NotPending();
        delete pendingAt[id];
        emit ProposalCancelled(id);
    }

    /// @notice Delist a market (and drop any pending proposal for it) at once.
    function remove(bytes32 id) external onlyOwner {
        isApproved[id] = false;
        delete pendingAt[id];
        emit MarketRemoved(id);
    }

    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _exists(bytes32 id) private view {
        (,,,, uint128 lastUpdate,) = morpho.market(id);
        if (lastUpdate == 0) revert NoMarket(id);
    }
}
