// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

/**
 * @title ICallback Interface
 * @dev This interface should be implemented by anyone wishing to use callbacks in the
 * `swap`, `borrow`, and `borrowLiquidity` functions in the  IAmmalgamPair interface.
 */
interface ICallback {
    /**
     * @notice Handles a swap call in the Ammalgam protocol.
     * @dev Callback passed as calldata to `swap` functions in `IAmmalgamPair`.
     * @param sender The address of the sender initiating the swap call.
     * @param amountXAssets The amount of token X involved in the swap.
     * @param amountYAssets The amount of token Y involved in the swap.
     * @param data The calldata provided to the swap function.
     */
    function swapCall(address sender, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;

    /**
     * @notice Handles a borrow call in the Ammalgam protocol.
     * @dev Callback passed as calldata to `borrow` and `borrowLiquidity` functions in `IAmmalgamPair`.
     * @param sender The address of the sender initiating the borrow call.
     * @param amountXAssets The amount of token X involved in the borrow.
     * @param amountYAssets The amount of token Y involved in the borrow.
     * @param amountLAssets The amount of liquidity involved in the borrow.
     * @param data The calldata provided to the borrow function.
     */
    function borrowCall(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 amountLAssets,
        bytes calldata data
    ) external;
}
