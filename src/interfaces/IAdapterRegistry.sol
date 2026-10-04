// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Where adapters live. Anyone may register one; AINDEX marks reviewed ones verified. A Fund enables
///         an adapter by asking the registry for its own clone of it.
interface IAdapterRegistry {
    struct Entry {
        address author; // who registered it
        bool verified; // reviewed and passed the adapter test suite
        bool retired; // no new instances (existing ones keep working)
        string metadataURI; // docs, audit, source
    }

    event Registered(address indexed implementation, address indexed author, string metadataURI);
    event Verified(address indexed implementation, bool verified);
    event Retired(address indexed implementation);
    event Instantiated(address indexed implementation, address indexed vault, address instance);
    event Reinstated(address indexed implementation);
    event AuthorSet(address indexed implementation, address indexed author);

    function register(address implementation, string calldata metadataURI) external;
    function setVerified(address implementation, bool verified) external;
    function retire(address implementation) external;

    /// @notice Reviewer: undo a retirement (for example one made by someone who registered another team's
    ///         implementation first and called themselves its author).
    function reinstate(address implementation) external;

    /// @notice Reviewer: correct who is recorded as an implementation's author.
    function setAuthor(address implementation, address author) external;

    function entry(address implementation) external view returns (Entry memory);
    function implementations() external view returns (address[] memory);

    /// @notice Clone `implementation` for one Fund and initialise it. Only that Fund's controller.
    function instantiate(address implementation, address vault, bytes calldata config) external returns (address);
    function implementationOf(address instance) external view returns (address);
}
