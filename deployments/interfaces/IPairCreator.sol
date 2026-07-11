// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

/**
 * @title IPairCreator
 * @notice Creates an Ammalgam pair and seeds its initial liquidity in a single call.
 */
interface IPairCreator {
    /**
     * @notice Creates the pair for the two tokens and mints the initial liquidity to the caller.
     * @dev Tokens are sorted internally, so `tokenA`/`tokenB` may be passed in either order. The
     *   caller must approve this contract for `amountA` of `tokenA` and `amountB` of `tokenB`; both
     *   are pulled via `transferFrom` directly into the new pair before minting.
     * @param tokenA One of the pair's underlying tokens.
     * @param tokenB The other underlying token.
     * @param amountA Amount of `tokenA` to seed as initial liquidity.
     * @param amountB Amount of `tokenB` to seed as initial liquidity.
     * @return pair The address of the newly created pair.
     */
    function createPair(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) external returns (address pair);
}
