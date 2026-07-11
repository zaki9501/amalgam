// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';

/**
 * @title IFactoryCallback Interface
 * @notice This interface provides methods for getting the token factory configuration.
 */
interface IFactoryCallback {
    /**
     * @notice This struct represents the configuration of the token factory, which includes
     * the addresses of tokenX, tokenY, and the factory itself.
     */
    struct TokenFactoryConfig {
        address tokenX;
        address tokenY;
    }

    /**
     * @notice Returns the current token factory configuration.
     * @return A TokenFactoryConfig struct representing the current token factory config.
     */
    function generateTokensWithinFactory() external returns (IERC20, IERC20, IAmmalgamERC20[6] memory);

    /**
     * @notice Returns the fee recipient address.
     * @return The address of the fee recipient.
     */
    function feeTo() external view returns (address);

    /**
     * @notice Returns the address that can change the fee recipient.
     * @return The address of the fee setter.
     */
    function feeToSetter() external view returns (address);

    /**
     * @notice Returns the address of the saturation state contract
     */
    function saturationAndGeometricTWAPState() external view returns (ISaturationAndGeometricTWAPState);
}
