// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  SourceAdmin
 * @notice Owner and configuration delay shared by the price sources.
 *
 * @dev    The PriceRouter makes any change that could raise a token's value wait a day. A source sits under
 *         the router, so if a source's owner could swap a token's feed or pool at once, that delay would be
 *         worth nothing. Each source therefore follows the same rule: a change that can only make a price
 *         unavailable (removing a token, tightening a limit) applies at once; anything else waits
 *         `CONFIG_DELAY` and anyone may apply it afterwards.
 *
 *         Configurations are kept as encoded bytes here so each source keeps its own typed struct.
 */
abstract contract SourceAdmin {
    error NotOwner();
    error NotReady();
    error BadConfig();

    uint64 public constant CONFIG_DELAY = 1 days;

    address public owner;
    address public pendingOwner;
    mapping(address => bytes) public pendingConfig;
    mapping(address => uint64) public pendingAt;

    event ConfigProposed(address indexed token, uint64 effectiveAt);
    event ConfigApplied(address indexed token);
    event ConfigCancelled(address indexed token);

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Anyone may apply a pending configuration once its delay has passed.
    function applyPending(address token) external {
        uint64 at = pendingAt[token];
        if (at == 0 || block.timestamp < at) revert NotReady();
        bytes memory c = pendingConfig[token];
        delete pendingAt[token];
        delete pendingConfig[token];
        _set(token, c);
        emit ConfigApplied(token);
    }

    function cancelPending(address token) external onlyOwner {
        delete pendingAt[token];
        delete pendingConfig[token];
        emit ConfigCancelled(token);
    }

    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @dev Apply at once when the change can only make prices unavailable, else queue it behind the delay.
    ///      A new proposal replaces any pending one for the same token.
    function _propose(address token, bytes memory encoded) internal {
        if (_lowersOnly(token, encoded)) {
            delete pendingAt[token];
            delete pendingConfig[token];
            _set(token, encoded);
            emit ConfigApplied(token);
            return;
        }
        uint64 at = uint64(block.timestamp) + CONFIG_DELAY;
        pendingConfig[token] = encoded;
        pendingAt[token] = at;
        emit ConfigProposed(token, at);
    }

    /// @dev True when `encoded` can only make the token's price unavailable compared with what is set now.
    function _lowersOnly(address token, bytes memory encoded) internal view virtual returns (bool);

    /// @dev Store a decoded configuration (already validated by the source's `propose`).
    function _set(address token, bytes memory encoded) internal virtual;
}
