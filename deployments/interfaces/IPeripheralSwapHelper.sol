// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

interface IPeripheralSwapHelper {
    struct SwapSingleParams {
        address to;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    function swapHelper(
        SwapSingleParams calldata params
    ) external;

    function swapFromNative(
        SwapSingleParams calldata params
    ) external payable;

    function swapToNative(
        SwapSingleParams calldata params
    ) external;

    function computeExpectedSwapAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 referenceReserveIn,
        uint256 reserveOut,
        uint256 missingIn,
        uint256 missingOut
    ) external pure returns (uint256);

    function computeExpectedSwapAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 referenceReserveIn,
        uint256 reserveOut,
        uint256 missingIn,
        uint256 missingOut
    ) external pure returns (uint256);
}
