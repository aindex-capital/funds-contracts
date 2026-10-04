// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  FreshFeed
 * @notice Rehearsal only, never deployed to a live chain. A fork cannot see Chainlink publish: after the
 *         rehearsal warps a day past the router's delay, every feed on the fork is a day older than it would
 *         be on mainnet, and the 26-hour age rule would call most of them stale. `rehearse-funds.sh` puts this
 *         code at each feed proxy's address on the anvil fork, with the feed's last answer and decimals in
 *         storage, so the feed answers its real last price as if Chainlink had just confirmed it.
 * @dev    Storage: slot 0 the answer, slot 1 the decimals. Same answer, fresh timestamp: prices are real, only
 *         the clock is faked.
 */
contract FreshFeed {
    int256 internal answer;
    uint8 internal decimals_;

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
