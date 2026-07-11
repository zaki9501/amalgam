// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

/**
 *  @title Interface for the AmmalgamFactory contract
 */
interface IAmmalgamFactory {
    /**
     * @notice Emitted when a new pair is created.
     * @param tokenX The first token in the pair.
     * @param tokenY The second token in the pair.
     * @param pair The address of the new pair.
     * @param allPairsLength The current total number of token pairs.
     */
    event PairCreated(address indexed tokenX, address indexed tokenY, address pair, uint256 allPairsLength);

    /**
     * @notice Emitted when new lending tokens are created.
     * @param pair The address of the pair.
     * @param depositL The address of the `DEPOSIT_L` lending token.
     * @param depositX The address of the `DEPOSIT_X` lending token.
     * @param depositY The address of the `DEPOSIT_Y` lending token.
     * @param borrowL The address of the `BORROW_L` lending token.
     * @param borrowX The address of the `BORROW_X` lending token.
     * @param borrowY The address of the `BORROW_Y` lending token.
     */
    event LendingTokensCreated(
        address indexed pair,
        address depositL,
        address depositX,
        address depositY,
        address borrowL,
        address borrowX,
        address borrowY
    );

    /**
     * @notice Returns the fee recipient address.
     * @return The address of the fee recipient.
     */
    function feeTo() external view returns (address);

    /**
     * @notice Returns the address that can change the fee recipient.
     * @return The address of the fee setter.
     */
    function feeToSetter() external view returns (address);

    /**
     * @notice Returns the pair address for two tokens.
     * @param tokenA The first token.
     * @param tokenB The second token.
     * @return pair The address of the pair for the two tokens.
     */
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /**
     * @notice Returns the pair address at a specific index.
     * @param index The index of the pair.
     * @return pair The address of the pair at the given index.
     */
    function allPairs(
        uint256 index
    ) external view returns (address pair);

    /**
     * @notice Returns the total number of token pairs.
     * @return The total number of token pairs.
     */
    function allPairsLength() external view returns (uint256);

    /**
     * @notice Creates a new pair for two tokens.
     * @param tokenA The first token.
     * @param tokenB The second token.
     * @return pair The address of the new pair.
     */
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /**
     * @notice Changes the fee recipient address.
     * @param newFeeTo The new fee recipient address.
     */
    function setFeeTo(
        address newFeeTo
    ) external;

    /**
     * @notice Changes the address that can change the fee recipient.
     * @param newFeeToSetter The new fee setter address.
     */
    function setFeeToSetter(
        address newFeeToSetter
    ) external;
}

/**
 * @title IPairFactory
 * @notice An interface to minimize code around the AmmalgamPair creation due to
 *         its large size.
 */
interface IPairFactory {
    function createPair(
        bytes32 salt
    ) external returns (address pair);
}
