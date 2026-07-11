// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';

uint256 constant DEPOSIT_L = 0;
uint256 constant DEPOSIT_X = 1;
uint256 constant DEPOSIT_Y = 2;
uint256 constant BORROW_L = 3;
uint256 constant BORROW_X = 4;
uint256 constant BORROW_Y = 5;
uint256 constant FIRST_DEBT_TOKEN = 3;
uint256 constant TOKEN_COUNT = 6;

bool constant ROUNDING_UP = true;

/**
 * @title ITokenController Interface
 * @notice The interface of a ERC20 facade for multiple token types with functionality similar to ERC1155.
 * @dev The TokenController provides support to the AmmalgamPair contract for token management.
 */
interface ITokenController {
    /**
     * @notice Reverts when fragile liquidity exceeds active liquidity available for risk checks.
     */
    error FragileLiquidityExceedsActiveLiquidity();

    /**
     * @dev Emitted when reserves are synchronized
     * @param reserveXAssets The updated reserve for token X
     * @param reserveYAssets The updated reserve for token Y
     */
    event Sync(uint256 reserveXAssets, uint256 reserveYAssets);

    /**
     * @dev Emitted when external liquidity is updated
     * @param externalLiquidity The updated value for external liquidity
     */
    event UpdateExternalLiquidity(uint112 externalLiquidity);

    /**
     * @dev Emitted when bad debt is burned
     * @param borrower The address of the borrower
     * @param tokenType The type of token being burned
     * @param badDebtAssets The amount of bad debt assets being burned
     * @param badDebtShares The amount of bad debt shares being burned
     */
    event BurnBadDebt(
        address indexed borrower, uint256 indexed tokenType, uint256 badDebtAssets, uint256 badDebtShares
    );

    /**
     * @dev Emitted when Interest gets accrued
     * @param reserveXAssets The amount reserve X assets in the pool after interest accrual
     * @param reserveYAssets The amount reserve Y assets in the pool after interest accrual
     * @param depositXAssets The amount of total `DEPOSIT_X` assets in the pool after interest accrual
     * @param depositYAssets The amount of total `DEPOSIT_Y` assets in the pool after interest accrual
     * @param borrowLAssets The amount of total `BORROW_L` assets in the pool after interest accrual
     * @param borrowXAssets The amount of total `BORROW_X` assets in the pool after interest accrual
     * @param borrowYAssets The amount of total `BORROW_Y` assets in the pool after interest accrual
     */
    event InterestAccrued(
        uint256 reserveXAssets,
        uint256 reserveYAssets,
        uint112 depositXAssets,
        uint112 depositYAssets,
        uint112 borrowLAssets,
        uint112 borrowXAssets,
        uint112 borrowYAssets
    );

    /**
     * @notice Get the underlying tokens for the AmmalgamERC20Controller.
     * @return The addresses of the underlying tokens.
     */
    function underlyingTokens() external view returns (IERC20, IERC20);

    /**
     * @notice Fetches the current reserves and the last update timestamp.
     * @return reserveXAssets The raw reserveX or reserveX plus unaccrued interest.
     * @return reserveYAssets The raw reserveY or reserveY plus unaccrued interest.
     * @return lastTimestamp The timestamp of the last operation.
     */
    function getReserves()
        external
        view
        returns (uint112 reserveXAssets, uint112 reserveYAssets, uint32 lastTimestamp);

    function externalLiquidity() external view returns (uint112);

    function fragileLiquidityShares() external view returns (uint112);

    /**
     * @notice Updates the external liquidity value.
     * @dev This function sets the external liquidity to a new value and emits an event with the new value. It can only be called by the fee setter.
     * @param _externalLiquidity The new external liquidity value.
     */
    function updateExternalLiquidity(
        uint112 _externalLiquidity
    ) external;

    /**
     * @notice Returns the reference reserves for the block, these represent a snapshot of the
     *   reserves at the start of the block weighted for mints, burns, borrow and repayment of
     *   liquidity. These amounts are critical to calculating the correct fees for any swap.
     * @return referenceReserveX The reference reserve for asset X.
     * @return referenceReserveY The reference reserve for asset Y.
     */
    function referenceReserves() external view returns (uint112 referenceReserveX, uint112 referenceReserveY);

    /**
     * @notice Return the IAmmalgamERC20 token corresponding to the token type
     * @param tokenType The type of token for which the scaler is being computed.
     *                  Can be one of BORROW_X, DEPOSIT_X, BORROW_Y, DEPOSIT_Y, BORROW_L, or DEPOSIT_L.
     * @return The IAmmalgamERC20 token
     */
    function tokens(
        uint256 tokenType
    ) external view returns (IAmmalgamERC20);

    /**
     *  @notice Computes current total assets and shares.
     *
     * @dev Behavior depends on the `withInterest` flag:
     *       1. If `withInterest` is `false`: Returns stored values (`allAssets`, `allShares`) without adjustments.
     *      2. If `withInterest` is `true`:
     *         - First calls `computeAssetsState()` to recalculate assets and shares (accounts for elapsed time, interest, and lending state).
     *         - Converts protocol fees to shares for DEPOSIT_L/X/Y and adds them to `_allShares`.
     *         - Adds protocol fees to DEPOSIT_L/X/Y in `_allAssets` (updated after shares to avoid double-counting).
     *      3. If `computeAssetsState()` detects no elapsed lending time, it returns stored values without recalculation.
     *
     * @param withInterest Toggle to enable/disable interest accrual, reserve adjustments, and protocol fee application.
     *
     * @return _allAssets Array of six `uint128` values: Total assets for each of the 6 Amalgam token types.
     *         If `withInterest` is `true`, includes protocol fees for DEPOSIT_L/X/Y.
     * @return _allShares Array of six `uint112` values: Total shares for each of the 6 Amalgam token types.
     *         If `withInterest` is `true`, includes shares converted from protocol fees for DEPOSIT_L/X/Y.
     */
    function totalAssetsAndShares(
        bool withInterest
    ) external view returns (uint112[6] memory _allAssets, uint112[6] memory _allShares);
}
