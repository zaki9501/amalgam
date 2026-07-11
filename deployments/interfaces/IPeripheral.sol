// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

interface IPeripheral {
    struct PositionParams {
        address pairAddress;
        address to;
        uint256 transferX;
        uint256 transferY;
        uint256 mintX;
        uint256 mintY;
        uint256 swapAmountInX;
        uint256 swapAmountInY;
        uint256 swapAmountOutX;
        uint256 swapAmountOutY;
        uint256 borrowLAssets;
    }

    function newPosition(
        PositionParams calldata params
    ) external;

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

    struct ClosePositionInputParams {
        address pairAddress;
        uint256 burnL;
        uint256 withdrawX;
        uint256 withdrawY;
    }

    function close(
        ClosePositionInputParams calldata params
    ) external;
}
