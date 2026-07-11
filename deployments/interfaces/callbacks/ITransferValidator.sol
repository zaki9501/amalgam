// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

/**
 * @title Transfer Validator Interface
 *
 * @notice This interface is intended for validating the solvency of an account when transfers occur.
 */
interface ITransferValidator {
    /**
     * @notice Validates the solvency of an account for a given token transfer operation.
     *
     * @dev Implementation should properly protect against any creation of new debt or transfer
     * of existing debt or collateral that would leave any individual address with insufficient collateral to cover all debts.
     * @param validate The address of the account being checked for solvency and having its saturation updated
     * @param update The address of the account having its saturation updated
     */
    function validateOnUpdate(address validate, address update) external;
}
