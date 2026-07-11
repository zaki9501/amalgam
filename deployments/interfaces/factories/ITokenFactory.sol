// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {IAmmalgamERC20} from 'interfaces/tokens/IAmmalgamERC20.sol';
import {ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';

/**
 *  @title Interface for
 *      AmmalgamERC4626TokenFactory,
 *      AmmalgamERC4626LiquidityTokenFactory
 *      ERC4626DebtTokenTokenFactory,
 *      ERC4626DebtTokenLiquidityTokenFactory
 */
interface ITokenFactory {
    function createToken(ERC20BaseConfig memory config, address _asset) external returns (IAmmalgamERC20);
}
