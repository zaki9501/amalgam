// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {StorageSlot} from '@openzeppelin/contracts/utils/StorageSlot.sol';
import {BeaconProxy} from '@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol';
import {IBeacon} from '@openzeppelin/contracts/proxy/beacon/IBeacon.sol';
import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';

import {IAmmalgamFactory} from 'contracts/interfaces/factories/IAmmalgamFactory.sol';
import {ITokenController} from 'contracts/interfaces/tokens/ITokenController.sol';

interface IPairInitializable {
    function initialize() external;
    function reInitialize() external;
}

contract InitializablePair is IPairInitializable, Initializable {
    error AccessDenied();

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        _initialize();
    }

    function _initialize() internal virtual {
        // initialization logic
    }

    /**
     * @notice Allows only the proxy-controlled self-call used by beacon upgrade reinitialization.
     */
    modifier onlyProxySelfCall() {
        if (msg.sender != address(this)) revert AccessDenied();
        _;
    }

    /**
     * @notice Reinitializes the pair only when the proxy calls itself after a beacon implementation upgrade.
     */
    function reInitialize() external onlyProxySelfCall reinitializer(_getInitializedVersion() + 1) {
        _reInitialize();
    }

    function _reInitialize() internal virtual {
        // re-initialization logic
    }
}

/**
 * @title PairBeaconProxy
 * @notice Proxy contract for Ammalgam Pairs that uses a beacon for implementation management and
 *   self initialization and reinitialization.
 * @dev Inherits from OpenZeppelin's BeaconProxy and overrides the _fallback function to ensure
 *   the implementation is up-to-date with the beacon before delegating calls. If the
 *   implementation changes on the beacon, this proxy knows by storing the implementation at the
 *   time of construction. When a change is made, this proxy will call initialize during the
 *   _fallback call to ensure the new implementation is properly initialized. This reduces the
 *   need to manually upgrade each pair when the beacon changes the implementation.
 */
contract PairBeaconProxy is BeaconProxy {
    error EthTransferNotAllowed();
    error AccessDenied();

    /**
     * @dev Initializes the proxy with the beacon address from the factory and calls initialize
     *   on the implementation.
     */
    constructor()
        payable
        BeaconProxy(
            address(IAmmalgamFactory(msg.sender).pairBeacon()),
            abi.encodeWithSelector(IPairInitializable.initialize.selector)
        )
    {
        // also set the implementation here so we know when the beacon changes the implementation.
        _setImplementation(IBeacon(_getBeacon()).implementation());
    }

    /**
     * @dev Overrides the _fallback function to check if the implementation from the beacon
     *   has changed. If it has, it upgrades the implementation and calls initialize on the new
     *   implementation to ensure proper setup.
     */
    // slither-disable-next-line incorrect-return
    function _fallback() internal override {
        address beaconImplementation = _implementation();
        address currentImplementation = ERC1967Utils.getImplementation();

        bool upgrading = beaconImplementation != currentImplementation;

        if (upgrading) {
            try this._initialize(beaconImplementation) {
                currentImplementation = beaconImplementation;
            } catch {
                // maintain view functions during upgrade when initialization failed.
                // _staticCall returns or reverts and does not continue below.
                _staticCall(currentImplementation);
            }
        }

        // not upgrading OR upgrade succeeded
        _delegate(currentImplementation);
    }

    function _initialize(
        address beaconImplementation
    ) external {
        if (msg.sender != address(this)) revert AccessDenied();
        // slither-disable-next-line reentrancy-no-eth
        ERC1967Utils.upgradeToAndCall(
            beaconImplementation, abi.encodeWithSelector(IPairInitializable.reInitialize.selector)
        );
    }

    /**
     * @notice Adapted version of OZ Proxy._delegate()
     */
    function _staticCall(
        address implementation
    ) internal virtual {
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := staticcall(gas(), implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // staticcall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /**
     * @dev Adapted from ERC1967Utils. The original function is private, and we need
     *      to set the implementation on first deployment without invoking initialize()
     *      again, since initialization was already performed in the BeaconProxy constructor.
     */
    function _setImplementation(
        address newImplementation
    ) private {
        if (newImplementation.code.length == 0) {
            revert ERC1967Utils.ERC1967InvalidImplementation(newImplementation);
        }
        StorageSlot.getAddressSlot(ERC1967Utils.IMPLEMENTATION_SLOT).value = newImplementation;
    }

    receive() external payable {
        revert EthTransferNotAllowed();
    }
}
