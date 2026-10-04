// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Amount} from "./IAdapter.sol";

/**
 * @title  ITeller
 * @notice The public deposit and exit desk of AINDEX Funds: one contract for every Fund, keyed by vault.
 *         Cash in at NAV: a deposit's USDG enters the Fund as cash and the depositor gets shares at the Fund's ask
 *         NAV per share; the manager invests the cash in its own actions. Requests queue until the Fund's next
 *         cut-off and settle in one batch after it, at prices read then. Inside a batch, entrants and cash leavers
 *         are matched first at fair NAV; only the net enters (minted at ask) or leaves (paid from the Fund's USDG
 *         at bid, and in kind for whatever USDG is short). Exits in kind work at any time.
 */
interface ITeller {
    enum Kind {
        None,
        Deposit,
        Redeem
    }

    /// @notice How a settlement now would treat new money (`depositHold`), and why deposits wait
    ///         (`DepositsWait`): 1 a market closed (informational: weekend pricing and the closure's inflow cap
    ///         apply, deposits still settle), 2 a holding valued at zero above dust (a pocket must run first,
    ///         `TellerOps.pocket`), 3 a price unavailable (`WAIT_NO_PRICE`), 4 over the closure's inflow cap
    ///         (`WAIT_INFLOW_CAP`), 5 over the pool-price flow cap of the 24-hour window (`WAIT_POOL_FLOW`).
    enum Hold {
        Open,
        MarketClosed, // a token the Fund holds (directly, inside a wrapper or through an adapter) is in a closed market
        NoMarket // the Fund holds a token with no market price (or a claim valued at zero) above dust
    }

    enum Status {
        Pending,
        Cancelled,
        Skipped, // its limit failed and it could not move on (the next batch was full, or it had moved once): paid back in full
        Claimed
    }

    struct Request {
        address vault;
        uint64 batch; // a request whose limit fails at settlement moves to the next batch, once
        Kind kind;
        Status status;
        uint16 round; // a deposit: the settlement round of its batch it went in at (0: not yet, or the last round)
        address owner; // the receiver: alone cancels while the batch is open; gets everything the request pays
        uint64 madeAt; // when it was made: `STALE_AFTER` later anyone may return it to its owner
        uint32 snap; // the Fund's snapshot id when its shares entered the teller's custody (a cash exit)
        uint128 amount; // USDG for a deposit, shares for a redemption
        uint128 min; // least shares for the whole deposit (a price, above zero) or least USDG (redemption)
    }

    /// @notice A batch's queue and the results of its first round (its leavers). A batch settles in rounds: the
    ///         first takes every request; deposits that must wait (a pocket to run, a price missing, the closure's
    ///         inflow cap) stay in the batch with their ids and limits, the batch takes the Fund's next cut-off, and
    ///         a later round takes them (oldest first under the cap). Each round's deposit results: `round`.
    struct Batch {
        uint64 cutoff; // requests are taken until this time; while deposits wait, the cut-off they wait for
        bool settled; // done: leavers paid and no deposit waiting
        uint16 count; // requests in this batch (a cancelled one frees its place)
        uint16 rounds; // settlements so far: leavers are paid at the first
        uint32 snap; // the Fund's snapshot id at the first round: leavers' shares leave the teller's custody then
        uint256 deposits; // USDG of the deposits still waiting in the batch, as requested
        uint256 redeems; // shares pending
        uint256 depTight; // the tightest deposit limit, shares per raw USDG (1e18): rounds that beat it skip the loop
        uint256 redTight; // the tightest cash-exit limit, raw USDG per share (1e18), and the smallest cash exit:
        uint256 redLow; // a first round that beats it by a unit on the smallest skips reading the leavers
        uint256 redIncluded; // shares of the cash exits the first round took
        uint256 matchedShares; // leavers' shares handed straight to entrants, at fair NAV
        uint256 matchedUsdg; // entrants' USDG handed straight to leavers for them
        uint256 navPerShare; // fair NAV per share (USD, 1e18) the matched part traded at; 0 if none matched
        uint256 usdgOut; // USDG for the leavers: matched USDG plus what the Fund paid from its cash at bid
        uint256 bidPerShare; // bid NAV per share (USD, 1e18) the net leavers were paid at; 0 if none
        uint256 sharesBack; // leavers' shares the Fund's USDG could not cover: handed back for an exit in kind
    }

    /// @notice One round's deposits: what went in (as requested) and the shares they got (matched at fair plus
    ///         minted at ask), or their USDG back on a wind-down.
    struct Round {
        uint256 dep;
        uint256 minted;
        uint256 askPerShare; // ask NAV per share (USD, 1e18) the net entrants were minted at; 0 if none
        bool refund; // a Fund winding down: every deposit in the round is paid back
        uint32 snap; // the Fund's snapshot id: the round's shares enter the teller's custody then
    }

    /// @notice An exit in kind in parts: the leaver's slice of each adapter waits, set aside in the adapter's units
    ///         (`unitsOf`), until anyone pays it out (`claimInKind`).
    struct Exit {
        address vault;
        address to;
        address owner; // who began the exit (the caller); its slices are paid to `to`
        uint64 madeAt;
        uint16 pending; // adapters whose slice is still to be paid out
        uint64 fraction; // of the Fund when it began (1e18 = all): a small one may be paid out by anyone at once
    }

    event Opened(address indexed vault, address indexed owner, uint256 usdg, uint256 shares);
    event DepositRequested(
        address indexed vault, uint256 indexed id, address indexed owner, uint64 batch, uint256 usdg, uint256 minShares
    );
    event RedeemRequested(
        address indexed vault, uint256 indexed id, address indexed owner, uint64 batch, uint256 shares, uint256 minUsdg
    );
    /// @notice Deposit `id` was referred by `referrer` (an address or a partner code): attribution for payouts made
    ///         off chain. Emitted only when it is not zero; it changes nothing on chain.
    event Referred(address indexed vault, uint256 indexed id, bytes32 indexed referrer);
    event Cancelled(address indexed vault, uint256 indexed id);
    event Skipped(address indexed vault, uint256 indexed id);
    event Moved(address indexed vault, uint256 indexed id, uint64 toBatch);
    /// @notice Under a cap, `amount` USDG of waiting deposit `id` went in this round as request `part` (same owner,
    ///         its limit scaled to the part); the rest of `id` keeps waiting with its id, limit and clock.
    event DepositSplit(address indexed vault, uint256 indexed id, uint256 indexed part, uint256 amount);
    /// @notice Entrants and leavers met inside the batch: `shares` changed hands for `usdg` at `navPerShare`.
    event Matched(address indexed vault, uint64 indexed batch, uint256 shares, uint256 usdg, uint256 navPerShare);
    /// @notice The net entrants' USDG went into the Fund as cash; `shares` were minted at `askPerShare`.
    event Minted(address indexed vault, uint64 indexed batch, uint256 usdg, uint256 shares, uint256 askPerShare);
    /// @notice The net leavers' `shares` were paid `usdg` from the Fund's cash at `bidPerShare`; `sharesBack` the cash
    ///         could not cover go back to them for an exit in kind.
    event Paid(
        address indexed vault,
        uint64 indexed batch,
        uint256 shares,
        uint256 usdg,
        uint256 bidPerShare,
        uint256 sharesBack
    );
    /// @notice `usdg` of the batch's deposits did not go in this round and waits for the cut-off of batch `toBatch`
    ///         (each request keeps its id, limit and 7-day clock; its owner can take it back until then). `reason`:
    ///         2 a holding valued at zero (a pocket must run first), 3 a price unavailable, 4 over the closure's
    ///         inflow cap; `token` is the one why, when there is one.
    event DepositsWait(
        address indexed vault, uint64 indexed fromBatch, uint64 toBatch, uint256 usdg, uint8 reason, address token
    );
    event Settled(
        address indexed vault,
        uint64 indexed batch,
        address indexed keeper,
        uint16 round,
        uint256 depIncluded,
        uint256 redIncluded,
        uint256 minted,
        uint256 usdgOut,
        uint256 sharesBack
    );
    /// @notice An exit in kind began in parts: its slices of every adapter that holds or owes anything wait in the
    ///         adapters' units (`adapters` of them; 0: the exit is complete).
    event ExitStarted(uint256 indexed exitId, address indexed vault, address indexed owner, address to, uint16 adapters);
    /// @notice One adapter's slice of exit `exitId` was paid out (or, `released`, given back to the Fund).
    event ExitClaimed(uint256 indexed exitId, address indexed adapter, bool released);
    event Claimed(address indexed vault, uint256 indexed id, address indexed owner, uint256 shares, uint256 usdg);
    event RedeemedInKind(
        address indexed vault, address indexed from, address indexed to, uint256 shares, uint256 fractionWad
    );
    event SlicePaid(address indexed vault, address indexed to, address indexed token, uint256 amount);
    event SliceFunded(address indexed vault, address indexed from, address indexed token, uint256 amount);
    event Left(address indexed vault, address indexed what); // an adapter or token a leaver chose to leave behind
    event WrittenOff(address indexed vault, address indexed token, uint256 amount);
    /// @notice A holding valued at zero went to the holders' pocket `id` (`Pockets`).
    event Pocketed(address indexed vault, uint256 indexed id, address indexed token, uint256 amount);
    event ScheduleSet(address indexed vault, uint64 interval, uint64 offset);
    event WindDown(address indexed vault, uint64 stakeFreeAt);
    event StakeReleased(address indexed vault, address indexed owner, uint256 shares);
    event FeesAccrued(address indexed vault, uint256 sharesMinted, uint256 lockedShares, uint256 burnedLocked);

    // ---------------------------------------------------------------- opening

    function open(address vault, uint256 usdg, uint16 managementBps, uint16 performanceBps)
        external
        returns (uint256 shares);

    // ---------------------------------------------------------------- requests

    /// @notice Deposit for the caller (receiver = caller, no referrer).
    function requestDeposit(address vault, uint256 usdg, uint256 minShares) external returns (uint256 id);
    /// @notice Deposit paid by the caller for `receiver`, who owns the request (its shares, refunds, cancel and
    ///         stale return); `referrer` (0: none) is only emitted in `Referred`.
    function requestDeposit(address vault, uint256 usdg, uint256 minShares, address receiver, bytes32 referrer)
        external
        returns (uint256 id);
    /// @notice Cash exit of the caller's shares for the caller.
    function requestRedeem(address vault, uint256 shares, uint256 minUsdg) external returns (uint256 id);
    /// @notice Cash exit of the caller's own shares for `receiver`, who owns the request (the USDG, shares handed
    ///         back, cancel and stale return).
    function requestRedeem(address vault, uint256 shares, uint256 minUsdg, address receiver)
        external
        returns (uint256 id);
    function cancel(uint256 id) external;
    function claim(uint256 id) external returns (uint256 shares, uint256 usdg);

    // ---------------------------------------------------------------- settlement (listed keepers)

    /// @notice Settle a closed batch: fees, then match entrants with leavers at fair NAV, mint the net entrants
    ///         at ask NAV (their USDG goes into the Fund as cash) or pay the net leavers from the Fund's USDG at bid
    ///         NAV (the rest of their shares back for an exit in kind). No swaps. `skip` lists requests whose limit
    ///         the result cannot meet.
    function settle(address vault, uint64 batch, uint256[] calldata skip) external;

    // ---------------------------------------------------------------- exits in kind (any time)

    function redeemInKind(address vault, uint256 shares, address to) external;
    function redeemInKindLeaving(address vault, uint256 shares, address to, address[] calldata leave) external;
    /// @notice An exit in kind in parts, for a Fund too large to leave in one transaction: the shares burn and the
    ///         vault tokens are paid now; each adapter's slice is set aside and paid out by `claimInKind`.
    function startInKind(address vault, uint256 shares, address to, address[] calldata leave)
        external
        returns (uint256 exitId);
    /// @notice Pay out exit `exitId`'s slices of `adapters` to its recipient: its owner or recipient at once, anyone
    ///         a day after it began.
    function claimInKind(uint256 exitId, address[] calldata adapters) external;

    // ---------------------------------------------------------------- holders' pockets

    /// @notice Anyone: set aside a holding NAV values at zero (`token` with no market price, or an adapter's claim
    ///         in `token` valued at zero) above dust for the holders of this moment (`Pockets`). `adapters` names
    ///         the adapters that hold it; `into` adds to a pocket opened for it within a day (0: a new one).
    ///         Settlements take no new money while one is above dust, so a keeper runs this first.
    function pocket(address vault, address token, address[] calldata adapters, uint256 into)
        external
        returns (uint256 id);

    // ---------------------------------------------------------------- views for keepers, pages and the MCP

    function request(uint256 id) external view returns (Request memory);
    /// @notice What request `id` would pay its owner now: shares and USDG. `waiting` is true until its batch has
    ///         settled.
    function due(uint256 id) external view returns (uint256 shares, uint256 usdg, bool waiting);
    function batch(address vault, uint64 id) external view returns (Batch memory);
    function round(address vault, uint64 batch, uint16 round) external view returns (Round memory);
    function batchRequests(address vault, uint64 id) external view returns (uint256[] memory);
    function currentBatch(address vault) external view returns (uint64 id, uint64 cutoff);
    /// @notice Whether a settlement now would take new money (`Hold.Open`), or not and why (see `Hold`).
    function depositHold(address vault) external view returns (Hold why, address token);
    /// @notice Cheap figures for the manager and pages: the Fund's cash (its USDG), what is queued in and out, and
    ///         its fair NAV and cash at the last settlement (invested is roughly NAV less cash).
    function cash(address vault)
        external
        view
        returns (uint256 usdg, uint256 queuedUsdg, uint256 queuedShares, uint256 lastNav, uint256 lastCash, uint64 lastAt);
    function inKindNeeds(address vault, uint256 shares) external view returns (Amount[] memory);
    function inKindSteps(address vault, uint256 shares) external view returns (address[] memory);
    function exit(uint256 exitId) external view returns (Exit memory);
}
