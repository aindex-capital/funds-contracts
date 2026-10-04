// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FundVault} from "./FundVault.sol";
import {FundController} from "./FundController.sol";
import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {IPriceRouter} from "../interfaces/IPriceRouter.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {Dial} from "../interfaces/IFundController.sol";

/// @notice Holds the controller's creation code so the factory stays under the contract size limit. Created by
///         the factory in its constructor; only that factory may use it.
contract ControllerDeployer {
    error NotFactory();

    address public immutable factory;

    constructor() {
        factory = msg.sender;
    }

    function deploy(
        IFundVault vault,
        IAdapterRegistry registry,
        IPriceRouter router,
        address guardian,
        address owner,
        address baseAsset,
        Dial calldata dial
    ) external returns (FundController) {
        if (msg.sender != factory) revert NotFactory();
        return new FundController(vault, registry, router, guardian, owner, baseAsset, dial);
    }
}

/**
 * @title  FundFactory
 * @notice Creates a Fund: its vault and its controller, wired to the shared registry, price router and
 *         guardian. Anyone may create a Fund and name its owner and teller.
 * @dev    The teller can mint and burn shares and pay holders, so it is the depositors' whole trust in a Fund
 *         besides the dial: pages and the MCP should list a Fund as investable only when its teller is an
 *         AINDEX teller. Indexers should take Funds from `isFund`, not from registry events, which anyone can
 *         produce with a fake vault.
 *         The guardian given to new Funds can be handed on (two steps), so a lost or rotated AINDEX key does
 *         not follow every future Fund; each existing Fund keeps its own guardian, which it can replace.
 */
contract FundFactory {
    IAdapterRegistry public immutable registry;
    IPriceRouter public immutable router;
    error NotGuardian();
    error ZeroAddress();

    /// @notice Guardian given to each new Fund.
    address public guardian;
    address public pendingGuardian;
    address public immutable baseAsset;
    ControllerDeployer public immutable controllerDeployer;

    address[] private _funds;
    mapping(address => bool) public isFund; // by vault

    event GuardianTransferStarted(address indexed guardian, address indexed pendingGuardian);
    event GuardianTransferred(address indexed previousGuardian, address indexed newGuardian);
    event FundCreated(address indexed vault, address indexed controller, address indexed owner, address teller, string name);

    constructor(IAdapterRegistry registry_, IPriceRouter router_, address guardian_, address baseAsset_) {
        registry = registry_;
        router = router_;
        guardian = guardian_;
        baseAsset = baseAsset_;
        controllerDeployer = new ControllerDeployer();
    }

    /// @param teller who issues and redeems shares for this Fund (the deposit and exit contract)
    function create(string calldata name, string calldata symbol, address owner, address teller, Dial calldata dial)
        external
        returns (FundVault vault, FundController controller)
    {
        if (owner == address(0) || teller == address(0)) revert ZeroAddress();
        vault = new FundVault(name, symbol);
        controller =
            controllerDeployer.deploy(IFundVault(address(vault)), registry, router, guardian, owner, baseAsset, dial);
        vault.wire(address(controller), teller);
        _funds.push(address(vault));
        isFund[address(vault)] = true;
        emit FundCreated(address(vault), address(controller), owner, teller, name);
    }

    function transferGuardian(address next) external {
        if (msg.sender != guardian) revert NotGuardian();
        pendingGuardian = next;
        emit GuardianTransferStarted(guardian, next);
    }

    function acceptGuardian() external {
        if (msg.sender != pendingGuardian) revert NotGuardian();
        emit GuardianTransferred(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
    }

    function funds() external view returns (address[] memory) {
        return _funds;
    }
}
