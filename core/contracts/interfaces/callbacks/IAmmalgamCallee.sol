// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title ICallback Interface
 * @dev This interface should be implemented by anyone wishing to use callbacks in the
 * `swap`, `borrow`, and `borrowLiquidity` functions in the  IAmmalgamPair interface.
 */
interface ISwapCallback {
    /**
     * @notice Handles a swap call in the Ammalgam protocol.
     * @dev Callback passed as calldata to `swap` functions in `IAmmalgamPair`.
     * @param sender The address of the sender initiating the swap call.
     * @param amountXAssets The amount of token X involved in the swap.
     * @param amountYAssets The amount of token Y involved in the swap.
     * @param data The calldata provided to the swap function.
     */
    function ammalgamSwapCallV1(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        bytes calldata data
    ) external;
}

interface IBorrowCallback {
    /**
     * @notice The callback in the `AmmalgamPair.borrow()` function transfers borrowed `amountXAssets` and `amountYAssets`
     *         to the borrower which doesn't include the initial lending fee. The `amountXShares` and `amountYShares`
     *         minted debt shares for the `borrower` include the initial lending fee.
     * @param sender The address of the sender initiating the borrow call.
     * @param amountXAssets The amount of token X involved in the borrow.
     * @param amountYAssets The amount of token Y involved in the borrow.
     * @param amountXShares The shares of token X involved in the borrow including the initial lending fee.
     * @param amountYShares The shares of token Y involved in the borrow including the initial lending fee.
     * @param data The calldata provided to the borrow function.
     */
    function ammalgamBorrowCallV1(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 amountXShares,
        uint256 amountYShares,
        bytes calldata data
    ) external;

    /**
     * @notice The callback in the `AmmalgamPair.borrowLiquidity()` function transfers borrowed
     *         `amountXAssets` and `amountYAssets` to the borrower which doesn't include the initial lending fee.
     *         The `amountLShares` minted debt shares for the `borrower` include the initial lending fee.
     * @param sender The address of the sender initiating the borrow liquidity call.
     * @param amountXAssets The amount of token X involved in the borrow liquidity.
     * @param amountYAssets The amount of token Y involved in the borrow liquidity.
     * @param amountLShares The shares of liquidity involved in the borrow liquidity including the initial lending fee.
     * @param data The calldata provided to the borrow liquidity function.
     */
    function ammalgamBorrowLiquidityCallV1(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 amountLShares,
        bytes calldata data
    ) external;
}

interface ICallback is ISwapCallback, IBorrowCallback {}
