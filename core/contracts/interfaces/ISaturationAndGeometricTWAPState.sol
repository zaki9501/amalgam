// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';

interface ISaturationAndGeometricTWAPState {
    // errors

    error PairAlreadyExists();
    error PairDoesNotExist();
    error InvalidUserConfiguration();

    /**
     * @notice Exposes the public getter for the configured mid-term interval (in seconds)
     */
    function midTermIntervalConfig() external view returns (uint24);

    /**
     * @notice Exposes the public getter for the configured long-term interval (in seconds)
     */
    function longTermIntervalConfig() external view returns (uint24);

    /**
     * @notice  initializes the sat (allocating storage for all nodes) and twap structs
     */
    function init(uint256 reserveX, uint256 reserveY) external;

    // saturation external functions

    function setNewPositionSaturation(address pair, uint256 maxDesiredSaturationInMAG2) external;

    /**
     * @notice  get the details of a specific to the tree and leaf in the saturation state.
     * @param   pairAddress  the pair for which the tree is being queried
     * @param   netDebtX  whether to query the netDebtX or netDebtY side of the tree
     * @param   leaf  the leaf index to query, you can use zero if you don't need the leaf details
     * @return  saturation  the saturation details for the specified leaf
     * @return  currentPenaltyInBorrowLSharesPerSatInQ72  the current penalty per sat in borrowL
     *    shares for the specified leaf
     * @return  totalSatInLAssets  the total saturation in L assets for the specified tree
     * @return  highestSetLeaf  the highest set leaf index for the specified tree
     * @return  tranches  the list of tranches set in the specified leaf
     */
    function getTreeLeafDetails(
        address pairAddress,
        bool netDebtX,
        uint256 leaf
    )
        external
        view
        returns (
            Saturation.SaturationPair memory saturation,
            uint256 currentPenaltyInBorrowLSharesPerSatInQ72,
            uint128 totalSatInLAssets,
            uint16 highestSetLeaf,
            uint16[] memory tranches
        );

    function getTrancheDetails(
        address pairAddress,
        bool netDebtX,
        int16 tranche
    ) external view returns (uint16 leaf, Saturation.SaturationPair memory saturation);

    function getAccount(
        address pairAddress,
        bool netX,
        address accountAddress
    ) external view returns (Saturation.Account memory);

    /**
     * @notice Check if an account exists in either netX or netY saturation tree
     * @param pairAddress The address of the pair
     * @param accountAddress The address of the account to check
     * @return exists True if the account exists in either tree
     */
    function accountExistsInSaturation(
        address pairAddress,
        address accountAddress
    ) external view returns (bool exists);

    /**
     * @notice  update the borrow position of an account and potentially check (and revert) if the
     *   resulting sat is too high
     * @param   inputParams  contains the position and pair params, like account borrows/deposits,
     *   current price and active liquidity
     * @param   account  for which is position is being updated
     * @param   skipMinOrMaxTickCheck  whether to skip the min/max tick check during validation
     */
    function update(Validation.InputParams memory inputParams, address account, bool skipMinOrMaxTickCheck) external;

    /**
     * @notice  accrue penalties since last accrual based on all over saturated positions
     *
     * @param   externalLiquidity  Swap liquidity outside this pool
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     * @param   fragileLiquidityAssets  fragile liquidity removed from active liquidity so the penalty
     * threshold reads the same liquidity we use to measure risk capacity in update()
     */
    function accruePenalties(
        address account,
        uint256 externalLiquidity,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL,
        uint256 fragileLiquidityAssets
    ) external returns (uint112 penaltyInBorrowLShares, uint112 accountPenaltyInBorrowLShares);

    /**
     * @notice Calculate the ratio by which the saturation has changed for `account`.
     * @param inputParams The params containing the position of `account`.
     * @param liqSqrtPriceInXInQ72 The liquidation sqrt price for netX in Q72; pass 0 if not applicable.
     * @param liqSqrtPriceInYInQ72 The liquidation sqrt price for netY in Q72; pass 0 if not applicable.
     * @param pairAddress The address of the pair
     * @param account The account for which we are calculating the saturation change ratio.
     * @return ratioBips The ratio representing the change in saturation for account.
     */
    function calcSatChangeRatioBips(
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 liqSqrtPriceInYInQ72,
        address pairAddress,
        address account
    ) external view returns (uint256 ratioBips);

    // price extremes external functions

    /**
     * @notice Record a price extreme observation for the calling pair.
     */
    function recordPriceExtreme(
        uint256 priceQ128
    ) external;

    // twap external functions

    /**
     * @notice Configures the interval of long-term observations.
     * @dev This function is used to set the long-term interval between observations for the long-term buffer.
     * @param pairAddress The address of the pair for which the long-term interval is being configured.
     * @param longTermIntervalConfigFactor The desired duration for each long-term period.
     *      The size is set as a factor of the mid-term interval to ensure a sufficient buffer, requiring
     *      at least 16 * 12 = 192 seconds per period, resulting in a total of ~25 minutes (192 * 8 = 1536 seconds)
     *      for the long-term buffer.
     */
    function configLongTermInterval(address pairAddress, uint24 longTermIntervalConfigFactor) external;

    /**
     * @notice Records a new observation tick value and updates the observation data.
     * @dev This function is used to record new observation data for the contract. It ensures that
     *      the provided tick value is stored appropriately in both mid-term and long-term
     *      observations, updates interval counters, and handles tick cumulative values based
     *      on the current interval configuration. Ensures that this function is called in
     *      chronological order, with increasing timestamps. Returns in case the
     *      provided block timestamp is less than or equal to the last recorded timestamp.
     * @param newTick The new tick value to be recorded, representing the most recent update of
     *      reserveXAssets and reserveYAssets.
     * @param timeElapsed The time elapsed since the last observation.
     */
    function recordObservation(int16 newTick, uint32 timeElapsed) external returns (bool);

    /**
     * @notice Gets the min and max range of tick values from the stored oracle observations.
     * @dev This function calculates the minimum and maximum tick values among three observed ticks:
     *          long-term tick, mid-term tick, and current tick.
     * @param pair The address of the pair for which the tick range is being queried.
     * @param reserveXAssets The current pair reserves of asset X.
     * @param reserveYAssets The current pair reserves of asset Y.
     * @param includeLongTermTick Boolean value indicating whether to include the long-term tick in the range.
     * @return minTick The minimum tick value among the three observed ticks.
     * @return maxTick The maximum tick value among the three observed ticks.
     */
    function getTickRange(
        address pair,
        uint256 reserveXAssets,
        uint256 reserveYAssets,
        bool includeLongTermTick
    ) external view returns (int16, int16);

    /**
     * @notice Gets the tick value representing the TWAP since the last
     *         lending update and checkpoints the current lending cumulative sum
     *         as `self.lendingCumulativeSum` and the current block timestamp as `self.lastLendingTimestamp`.
     * @dev See `getLendingStateTick` for implementation details which was
     *      separated to allow view access without any state updates.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     */
    function getLendingStateTickAndCheckpoint(
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) external returns (int16, uint256);

    /**
     * @dev Retrieves the mid-term tick value based on the stored observations.
     * @return midTermTick The mid-term tick value.
     */
    function getObservedMidTermTick() external view returns (int16 midTermTick);

    /**
     * @notice Gets the tick value representing the TWAP since the last lending update.
     * @param newTick The current tick value.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     * @return currentCumulativeSum The current cumulative sum for the last updated timestamp.
     */
    function getLendingStateTick(
        int56 newTick,
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) external view returns (int16, uint256);

    function getObservations(
        address pair
    ) external view returns (GeometricTWAP.Observations memory);
}
