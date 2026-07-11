// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IPeripheralLending
 * @notice Interface for the Ammalgam pair lending actions - deposit / withdraw / repay helper methods.
 */
interface IPeripheralLending {
    struct HelperParams {
        address to;
        address pairAddress;
        uint256 amountX;
        uint256 amountY;
    }

    function depositLiquidityHelper(
        HelperParams calldata helperParams
    ) external;

    function depositHelper(
        HelperParams calldata helperParams
    ) external;

    function repayHelper(
        HelperParams calldata helperParams
    ) external;

    function repayFullHelper(
        HelperParams calldata helperParams
    ) external;

    function repayLiquidityHelper(
        HelperParams calldata helperParams
    ) external;

    function repayLiquidityFullHelper(
        HelperParams calldata helperParams
    ) external;

    function withdrawHelper(
        HelperParams calldata helperParams
    ) external;

    function withdrawLiquidityHelper(address to, address pairAddress, uint256 amount) external;
}
