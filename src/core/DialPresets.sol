// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Dial} from "../interfaces/IFundController.sol";

/**
 * @title  DialPresets
 * @notice Ready-made risk dials for pages, scripts and agents: one click instead of eight numbers. The
 *         factory accepts any dial within bounds; these are suggestions, not rules.
 *
 * @dev    The manager chooses the risk (Ali, 2026-10-01). So the default a page offers is `open()`: no caps,
 *         borrowing to Morpho's own line, unreviewed adapters and markets allowed, and a 25% daily loss
 *         budget. A Fund that wants less risk picks a tighter preset or its own numbers, and can tighten at
 *         any time at once. What protects depositors in an open Fund is not the dial but the fixed guarantees:
 *         the manager can never withdraw, and what it can lose through bad trades is bounded by the daily loss
 *         budget it chose; prices are honest at entry and exit; and any later move to more risk waits the
 *         notice so holders can leave first. The loss budget is why `open()` stops at 25% a day rather than
 *         100%: a manager (or a stolen session key) with a 100% budget could empty the Fund in one
 *         transaction through a bad swap. A custom dial may still go up to 100%, as the manager's explicit
 *         choice, shown on the Fund's page.
 *
 *         These values are canonical: the website (apps/web/lib/funds.ts) and docs/ARCHITECTURE.md show the
 *         same numbers, so change all three together.
 *
 *         Internal pure functions: they are inlined where used, so nothing needs deploying or linking.
 */
library DialPresets {
    uint16 internal constant ALL = 10_000;
    /// @notice The open preset's daily loss budget: 25% of the Fund a day.
    uint16 internal constant OPEN_DAILY_LOSS = 2_500;

    /// @notice The fewest limits ("degen-friendly"): every cap at 100%, borrowing allowed down to a health of
    ///         1.0, anything AINDEX has not reviewed allowed, and a 25% daily loss budget. The default for new
    ///         Funds.
    function open() internal pure returns (Dial memory) {
        return Dial({
            maxNoMarketBps: ALL,
            maxThinBps: ALL,
            maxPoolBps: ALL,
            maxPerTokenBps: ALL,
            dailyLossBps: OPEN_DAILY_LOSS,
            allowBorrow: true,
            minHealthBps: ALL,
            allowUnreviewed: true
        });
    }

    /// @notice Priced assets, no borrowing, reviewed instruments only. Nothing without a market, nothing
    ///         thin, at most 20% pool-priced, at most 25% in any one token (cash is never capped), and the
    ///         manager's own actions may cost at most 3% a day. `minHealthBps` is 0: it only matters when
    ///         borrowing, which this preset forbids.
    function conservative() internal pure returns (Dial memory) {
        return Dial({
            maxNoMarketBps: 0,
            maxThinBps: 0,
            maxPoolBps: 2_000,
            maxPerTokenBps: 2_500,
            dailyLossBps: 300,
            allowBorrow: false,
            minHealthBps: 0,
            allowUnreviewed: false
        });
    }

    /// @notice Room to trade with guard rails: up to 10% thin and 50% pool-priced tokens, 40% in one token,
    ///         10% a day of losses, borrowing with a health of at least 1.5, reviewed instruments only, and
    ///         nothing without a market.
    function balanced() internal pure returns (Dial memory) {
        return Dial({
            maxNoMarketBps: 0,
            maxThinBps: 1_000,
            maxPoolBps: 5_000,
            maxPerTokenBps: 4_000,
            dailyLossBps: 1_000,
            allowBorrow: true,
            minHealthBps: 15_000,
            allowUnreviewed: false
        });
    }
}
