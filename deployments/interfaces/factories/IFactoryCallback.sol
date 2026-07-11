// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {IAmmalgamERC20} from 'interfaces/tokens/IAmmalgamERC20.sol';

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
        address factory;
    }

    /**
     * @notice Returns the current token factory configuration.
     * @return A TokenFactoryConfig struct representing the current token factory config.
     */
    function generateTokensWithinFactory() external returns (IERC20, IERC20, IAmmalgamERC20[6] memory);
}
