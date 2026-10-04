// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title  FundsConfig
 * @notice The entries of `script/funds-config.json`, shared by the deploy, apply and Fund scripts.
 * @dev    Field order is alphabetical: forge decodes a JSON object into a struct by its sorted keys, so every
 *         object in a section must carry exactly these keys.
 */
library FundsConfig {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct ChainlinkEntry {
        bool checkPause;
        uint256 closedHaircutBps;
        address feed;
        uint256 haircutBps;
        uint256 maxAge;
        address quoteToken;
        string symbol;
        address token;
        bool usSession;
        bool weekendClosed;
    }

    struct TwapEntry {
        bool checkPause;
        uint256 closedHaircutBps;
        uint256 haircutBps;
        address pool;
        address quoteToken;
        string symbol;
        bool thin; // class Thin instead of Pool (a shallow pool)
        address token;
        bool usSession;
        uint256 window;
    }

    struct IndexEntry {
        uint256 closedHaircutBps;
        uint256 haircutBps;
        string symbol;
        address token;
        bool usSession;
    }

    /// @notice A Morpho market AINDEX reviewed: its id (the hash of all five parameters) and, for the record,
    ///         its oracle.
    struct MarketEntry {
        bytes32 market;
        address oracle;
        string symbol;
    }

    /// @notice Worse-of pricing while a stock token's US market is closed: its deepest Uniswap v3 pools (any pair the
    ///         router prices), the band around the feed's last price, and the spread.
    struct WeekendEntry {
        uint256 clampBps;
        WeekendPool[] pools;
        uint256 spreadBps;
        string symbol;
        address token;
    }

    /// @notice One weekend pool, paired with any token the router prices, and the least liquidity at its current
    ///         tick for it to count.
    struct WeekendPool {
        uint256 minLiquidity;
        address pool;
    }

    function weekend(string memory json) internal pure returns (WeekendEntry[] memory) {
        return abi.decode(vm.parseJson(json, ".weekend"), (WeekendEntry[]));
    }

    function weekendInflowBps(string memory json) internal pure returns (uint256) {
        return vm.parseJsonUint(json, ".teller.weekendInflowBps");
    }

    function weekendOutflowBps(string memory json) internal pure returns (uint256) {
        return vm.parseJsonUint(json, ".teller.weekendOutflowBps");
    }

    function poolFlowBps(string memory json) internal pure returns (uint256) {
        return vm.parseJsonUint(json, ".teller.poolFlowBps");
    }

    /// @dev Whole USD in the file, USD 1e18 on chain.
    function poolFlowFloorUsd(string memory json) internal pure returns (uint256) {
        return vm.parseJsonUint(json, ".teller.poolFlowFloorUsd") * 1e18;
    }

    function chainlink(string memory json) internal pure returns (ChainlinkEntry[] memory) {
        return abi.decode(vm.parseJson(json, ".chainlink"), (ChainlinkEntry[]));
    }

    function twap(string memory json) internal pure returns (TwapEntry[] memory) {
        return abi.decode(vm.parseJson(json, ".twap"), (TwapEntry[]));
    }

    function indexes(string memory json) internal pure returns (IndexEntry[] memory) {
        return abi.decode(vm.parseJson(json, ".indexes"), (IndexEntry[]));
    }

    function morphoMarkets(string memory json) internal pure returns (MarketEntry[] memory) {
        return abi.decode(vm.parseJson(json, ".morphoMarkets"), (MarketEntry[]));
    }
}
