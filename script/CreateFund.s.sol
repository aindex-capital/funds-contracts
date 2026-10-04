// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {FundController} from "../src/core/FundController.sol";
import {Teller} from "../src/core/Teller.sol";
import {FundFees} from "../src/core/Fees.sol";
import {DialPresets} from "../src/core/DialPresets.sol";
import {Dial} from "../src/interfaces/IFundController.sol";
import {AggregatorSwapAdapter} from "../src/adapters/swap/AggregatorSwapAdapter.sol";
import {IFablesPoolRegistry} from "../src/interfaces/external/fables/IFablesPoolRegistry.sol";

/**
 * @title  CreateFund
 * @notice Creates one Fund through the public teller and readies it for its manager: the teller's `createFund`
 *         makes the vault and controller and opens the Fund with the owner's stake in one transaction, then the
 *         chosen adapters are enabled and the manager named. The broadcaster is the Fund's owner and pays the
 *         stake, so it must hold the USDG. The Fund takes public deposits from its first cut-off on.
 *
 * @dev    Environment:
 *         - FUND_NAME, FUND_SYMBOL: the share token's name and symbol (required);
 *         - FUND_MANAGER: who trades, an agent's session key or a person (required);
 *         - FUND_MANAGEMENT_BPS, FUND_PERFORMANCE_BPS: fee rates (required; at most 200 and 2000). Until someone
 *           other than the owner holds a share the owner may change them at once; after that a raise waits 30
 *           days;
 *         - FUND_DIAL: `open` (default: no caps, at most 25% lost a day), `balanced` or `conservative` (src/core/DialPresets.sol);
 *         - FUND_STAKE_USDG: the opening stake, raw USDG (6 decimals); default the teller's minimum (10 USDG);
 *         - FUND_ADAPTERS: comma-separated labels from the deployment record, default one of every kind (a Fund may list 12)
 *           (swap,erc4626,index,morpho,uniswapV3,uniswapV4,fables);
 *         - FUND_MANAGER_DAYS: the manager's term (default `fund.managerDays`, 90);
 *         - FUND_FEE_RECIPIENT: who receives the manager's 70% of fees (default the owner; never a session key);
 *         - FUND_OWNER: if set, the broadcaster must be this address;
 *         - FUND_STRATEGY: the strategy in words. It lives off chain (pages, the agent's prompt); it is only
 *           copied into the record here;
 *         - FUNDS_DEPLOYMENT (default deployments/4663.json), FUND_OUT (default deployments/fund-<symbol>.json).
 *
 *         While the owner holds every share, adding an adapter applies at once, so the Fund is ready to act in
 *         this one script. Prices must already be applied (ApplyPending): opening needs none, but the first
 *         action needs every holding priced.
 */
contract CreateFund is Script {
    // Alphabetical, for forge's JSON decoding.
    struct SwapTarget {
        uint256 approval;
        string name;
        address target;
    }

    // One of every kind (seven; a Fund may list up to FundController.MAX_ADAPTERS, 12).
    string internal constant ALL_ADAPTERS = "swap,erc4626,index,morpho,uniswapV3,uniswapV4,fables";

    string internal json;
    string internal dep;
    address internal vault;
    FundController internal controller;
    string[] internal names;
    address[] internal instances;
    string internal symbol;
    string internal dialName;
    address internal owner;
    address internal manager;
    address internal recipient;
    uint256 internal stake;
    uint16 internal mgmt;
    uint16 internal perf;

    function run() external {
        json = vm.readFile("script/funds-config.json");
        dep = vm.readFile(vm.envOr("FUNDS_DEPLOYMENT", string("deployments/4663.json")));
        symbol = vm.envString("FUND_SYMBOL");
        manager = vm.envAddress("FUND_MANAGER");
        mgmt = uint16(vm.envUint("FUND_MANAGEMENT_BPS"));
        perf = uint16(vm.envUint("FUND_PERFORMANCE_BPS"));
        dialName = vm.envOr("FUND_DIAL", string("open"));
        Dial memory dial = _dial(dialName);
        uint256 days_ = vm.envOr("FUND_MANAGER_DAYS", vm.parseJsonUint(json, ".fund.managerDays"));
        string[] memory labels = vm.split(vm.envOr("FUND_ADAPTERS", string(ALL_ADAPTERS)), ",");
        address usdg = vm.parseJsonAddress(dep, ".baseAsset");
        Teller teller = Teller(vm.parseJsonAddress(dep, ".teller"));
        stake = vm.envOr("FUND_STAKE_USDG", teller.minOpeningStake());

        vm.startBroadcast();
        (, owner,) = vm.readCallers();
        require(vm.envOr("FUND_OWNER", owner) == owner, "the broadcaster is not FUND_OWNER");
        require(IERC20(usdg).balanceOf(owner) >= stake, "the owner does not hold the stake USDG");
        IERC20(usdg).approve(address(teller), stake);
        address c;
        (vault, c) = teller.createFund(vm.envString("FUND_NAME"), symbol, dial, stake, mgmt, perf);
        controller = FundController(c);
        for (uint256 i; i < labels.length; ++i) _enable(labels[i]);
        controller.setManager(manager, uint64(block.timestamp + days_ * 1 days));
        recipient = vm.envOr("FUND_FEE_RECIPIENT", owner);
        if (recipient != owner) teller.fees().setRecipient(vault, recipient);
        vm.stopBroadcast();

        _record();
    }

    function _dial(string memory n) internal pure returns (Dial memory) {
        bytes32 h = keccak256(bytes(n));
        if (h == keccak256("open")) return DialPresets.open();
        if (h == keccak256("balanced")) return DialPresets.balanced();
        if (h == keccak256("conservative")) return DialPresets.conservative();
        revert("FUND_DIAL must be open, balanced or conservative");
    }

    function _enable(string memory label) internal {
        bytes32 h = keccak256(bytes(label));
        bytes memory config;
        if (h == keccak256("swap")) {
            SwapTarget[] memory st = abi.decode(vm.parseJson(json, ".fund.swapTargets"), (SwapTarget[]));
            AggregatorSwapAdapter.Target[] memory targets = new AggregatorSwapAdapter.Target[](st.length);
            for (uint256 i; i < st.length; ++i) {
                targets[i] =
                    AggregatorSwapAdapter.Target(st[i].target, AggregatorSwapAdapter.Approval(uint8(st[i].approval)));
            }
            config = abi.encode(targets);
        } else if (h == keccak256("erc4626")) {
            config = abi.encode(vm.parseJsonAddressArray(json, ".fund.erc4626Vaults"));
        } else if (h == keccak256("index")) {
            config = abi.encode(vm.parseJsonAddress(json, ".fund.indexZap"), new address[](0));
        } else if (h == keccak256("morpho")) {
            // Any market the dial allows: reviewed markets only with allowUnreviewed off; with it on, supply in a
            // market the registry has not approved counts as nothing (see MorphoBlueAdapter).
            config = abi.encode(vm.parseJsonAddress(dep, ".morphoMarketRegistry"), new bytes32[](0));
        } else if (h == keccak256("fables")) {
            (address[] memory hooks, bytes32[] memory witness) = _fablesHooks();
            config = abi.encode(hooks, witness, uint16(vm.parseJsonUint(json, ".fund.fablesMaxSpotDeviationBps")));
        } else if (h != keccak256("uniswapV3") && h != keccak256("uniswapV4")) {
            revert(string.concat("unknown adapter label: ", label));
        }
        address impl = vm.parseJsonAddress(dep, string.concat(".adapters.", label));
        names.push(label);
        instances.push(controller.addAdapter(impl, config));
    }

    /// @dev Every hook of an active, ERC-20-only Fables pool, each with one of its pools as the witness the
    ///      adapter checks against Fables' registry.
    function _fablesHooks() internal view returns (address[] memory hooks, bytes32[] memory witness) {
        IFablesPoolRegistry reg = IFablesPoolRegistry(vm.parseJsonAddress(json, ".external.fablesRegistry"));
        uint256 n = reg.poolCount();
        hooks = new address[](n);
        witness = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            IFablesPoolRegistry.PoolInfo memory p = reg.poolAt(i);
            if (!p.active || Currency.unwrap(p.key.currency0) == address(0)) continue;
            address h = address(p.key.hooks);
            bool seen;
            for (uint256 j; j < k; ++j) {
                if (hooks[j] == h) seen = true;
            }
            if (seen) continue;
            hooks[k] = h;
            witness[k] = PoolId.unwrap(p.id);
            ++k;
        }
        assembly ("memory-safe") {
            mstore(hooks, k)
            mstore(witness, k)
        }
    }

    function _record() internal {
        string memory a = "instances";
        string memory list;
        for (uint256 i; i < instances.length; ++i) list = vm.serializeAddress(a, names[i], instances[i]);
        string memory k = "fund";
        vm.serializeAddress(k, "vault", vault);
        vm.serializeAddress(k, "controller", address(controller));
        vm.serializeAddress(k, "teller", vm.parseJsonAddress(dep, ".teller"));
        vm.serializeAddress(k, "owner", owner);
        vm.serializeAddress(k, "manager", manager);
        vm.serializeAddress(k, "feeRecipient", recipient);
        vm.serializeString(k, "dial", dialName);
        vm.serializeUint(k, "stakeUsdg", stake);
        vm.serializeUint(k, "managementBps", mgmt);
        vm.serializeUint(k, "performanceBps", perf);
        vm.serializeString(k, "strategy", vm.envOr("FUND_STRATEGY", string("")));
        vm.serializeUint(k, "createdAt", block.timestamp);
        string memory out = vm.serializeString(k, "adapters", list);
        string memory path = vm.envOr("FUND_OUT", string.concat("deployments/fund-", symbol, ".json"));
        vm.writeJson(out, path);
        console.log("Fund", symbol, "vault", vault);
        console.log("controller", address(controller), "record", path);
    }
}
