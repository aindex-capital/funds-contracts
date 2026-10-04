// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Optional for price sources of assets that trade in sessions (US stocks and ETFs). While the market is
 *         closed for a holiday, the source's own staleness rule rightly calls the last price stale; the router
 *         then asks for that last reading and decides itself whether it is still the market's last word.
 */
interface ISessionSource {
    /// @notice The latest reading with every check the source makes except its age (answer above zero, round
    ///         complete, token not paused, sequencer up). `ok` false when any of those fail.
    function lastPrice(address token) external view returns (uint256 usd, uint64 updatedAt, bool ok);
}
