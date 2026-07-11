// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {IAmmalgamERC20} from 'interfaces/tokens/IAmmalgamERC20.sol';

/**
 * @title INewTokensFactory
 * @notice Interface for the NewTokensFactory contract, which is responsible for creating new instances of AmmalgamERC20 tokens.
 */
interface INewTokensFactory {
    /**
     * @notice Creates new instances of AmmalgamERC20 tokens for the given token addresses.
     * @param tokenX The address of tokenX.
     * @param tokenY The address of tokenY.
     * @return An array of IAmmalgamERC20 tokens consisting of [liquidityToken, depositXToken, depositYToken, borrowXToken, borrowYToken, borrowLToken].
     */
    function createAllTokens(
        address pair,
        address pluginRegistry,
        address tokenX,
        address tokenY
    ) external returns (IAmmalgamERC20[6] memory);
}
