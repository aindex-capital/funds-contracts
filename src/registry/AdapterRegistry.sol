// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundController} from "../interfaces/IFundController.sol";

/**
 * @title  AdapterRegistry
 * @notice The catalogue of adapters. Anyone can register an implementation (a protocol team, an outside
 *         developer, AINDEX); AINDEX's reviewer marks the ones that passed review and the shared test suite as
 *         verified. Funds pick from it, and each Fund gets its own clone of every adapter it enables.
 * @dev    Verification is a label, not a gate: a Fund's owner may enable an unverified adapter, and the Fund
 *         page says so. Retiring stops new clones; existing clones keep working, because a Fund's positions
 *         must always be reachable. Anyone may register any address, so the first registrant becomes its
 *         recorded author; the reviewer can correct the author and undo a retirement, so registering someone
 *         else's adapter first gains nothing lasting.
 *         `instantiate` checks that the caller is the vault's controller and that the controller names the
 *         vault back. A contract posing as both can still get a clone bound to itself, which reaches nothing
 *         but itself; indexers take Funds from the factory, not from `Instantiated` events.
 */
contract AdapterRegistry is IAdapterRegistry {
    error NotReviewer();
    error AlreadyRegistered();
    error UnknownImplementation();
    error RetiredImplementation();
    error NotFundController();
    error NoCode();

    address public reviewer;
    address public pendingReviewer;

    mapping(address => Entry) private _entries;
    mapping(address => bool) private _known;
    address[] private _implementations;
    mapping(address => address) public implementationOf;

    constructor(address reviewer_) {
        reviewer = reviewer_;
    }

    modifier onlyReviewer() {
        if (msg.sender != reviewer) revert NotReviewer();
        _;
    }

    function register(address implementation, string calldata metadataURI) external {
        if (implementation.code.length == 0) revert NoCode();
        if (_known[implementation]) revert AlreadyRegistered();
        _known[implementation] = true;
        _entries[implementation] = Entry({author: msg.sender, verified: false, retired: false, metadataURI: metadataURI});
        _implementations.push(implementation);
        emit Registered(implementation, msg.sender, metadataURI);
    }

    function setVerified(address implementation, bool verified) external onlyReviewer {
        if (!_known[implementation]) revert UnknownImplementation();
        _entries[implementation].verified = verified;
        emit Verified(implementation, verified);
    }

    /// @notice The author or the reviewer may retire an adapter (no new clones).
    function retire(address implementation) external {
        if (!_known[implementation]) revert UnknownImplementation();
        if (msg.sender != reviewer && msg.sender != _entries[implementation].author) revert NotReviewer();
        _entries[implementation].retired = true;
        emit Retired(implementation);
    }

    function reinstate(address implementation) external onlyReviewer {
        if (!_known[implementation]) revert UnknownImplementation();
        _entries[implementation].retired = false;
        emit Reinstated(implementation);
    }

    function setAuthor(address implementation, address author) external onlyReviewer {
        if (!_known[implementation]) revert UnknownImplementation();
        _entries[implementation].author = author;
        emit AuthorSet(implementation, author);
    }

    function entry(address implementation) external view returns (Entry memory) {
        return _entries[implementation];
    }

    function implementations() external view returns (address[] memory) {
        return _implementations;
    }

    function instantiate(address implementation, address vault, bytes calldata config) external returns (address instance) {
        if (!_known[implementation]) revert UnknownImplementation();
        if (_entries[implementation].retired) revert RetiredImplementation();
        // Only the Fund's own controller may add adapters to it.
        if (IFundVault(vault).controller() != msg.sender || IFundController(msg.sender).vault() != vault) {
            revert NotFundController();
        }
        instance = Clones.clone(implementation);
        implementationOf[instance] = implementation;
        IAdapter(instance).initialize(vault, msg.sender, config);
        emit Instantiated(implementation, vault, instance);
    }

    event ReviewerTransferStarted(address indexed reviewer, address indexed pendingReviewer);
    event ReviewerTransferred(address indexed previousReviewer, address indexed newReviewer);

    function transferReviewer(address next) external onlyReviewer {
        pendingReviewer = next;
        emit ReviewerTransferStarted(reviewer, next);
    }

    function acceptReviewer() external {
        if (msg.sender != pendingReviewer) revert NotReviewer();
        emit ReviewerTransferred(reviewer, msg.sender);
        reviewer = pendingReviewer;
        pendingReviewer = address(0);
    }
}
