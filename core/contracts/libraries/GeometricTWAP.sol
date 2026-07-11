// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {Convert} from 'contracts/libraries/Convert.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {DEFAULT_TICK_DELTA_FACTOR, MAX_TICK_DELTA, Q32} from 'contracts/libraries/constants.sol';

/**
 * @title GeometricTWAP: Library for Geometric TWAP calculation and observations.
 */
library GeometricTWAP {
    uint256 internal constant MID_TERM_ARRAY_LENGTH = 51;
    uint256 internal constant LONG_TERM_ARRAY_LENGTH = 9;
    uint256 internal constant LOG_BASE_OF_ROOT_TWO = 178;
    uint256 internal constant MID_TERM_ARRAY_LAST_INDEX = MID_TERM_ARRAY_LENGTH - 1;
    uint256 internal constant LONG_TERM_ARRAY_LAST_INDEX = LONG_TERM_ARRAY_LENGTH - 1;
    /**
     * @notice Minimum long-term interval factor is used to verify the long-term interval
     *      is at least 14 times the mid-term interval. This ensures that the long term
     *      interval is required to be at least 14 times the mid-term interval, this is
     *      ```math
     *      \left \lceil \frac{2 * MID\_TERM\_ARRAY\_LAST\_INDEX}{LONG\_TERM\_ARRAY\_LAST\_INDEX} \right \rceil.
     *      ```
     */
    uint256 internal constant MINIMUM_LONG_TERM_INTERVAL_FACTOR = 14;

    /**
     * @notice Struct for storing observations related to the Geometric TWAP calculation.
     * @dev This struct holds various data points used in the Time-Weighted Average Price (TWAP)
     *      calculation.
     * @member midTermIndex: The index representing the total duration observed for the
     *      short-term period. Its initial value is 0.
     * @member longTermIndex: The index representing the total duration observed for the
     *      long-term period. Its initial value is 0.
     * @member lastTick: The latest recorded tick, bounded to avoid outliers.
     * @member midTermIntervalConfig: The configurable interval for each period of the mid-term buffer.
     * @member longTermIntervalConfig: The time required to pass before the long term twap is updated.
     * @member lendingCumulativeSum: The cumulative sum of mid-term values for lending state.
     * @member midTermTimeInterval: An array tracking timestamp at which each mid-term observation is recorded.
     * @member longTermTimeInterval: An array tracking timestamp at which each long-term observation is recorded.
     * @member midTerm: An array of mid-term observations. Each element stores cumulative tick value.
     *      The array size is 51 for it observes 50 price changes for last 10 minutes (12 * 50 = 600 seconds).
     * @member longTerm: An array of long-term observations. Each element stores cumulative tick
     *      value of a buffer. The buffer size is configured by `longTermIntervalConfig`. The term is
     *      observed every `longTermIntervalConfig` duration.
     */
    struct Observations {
        bool isMidTermBufferInitialized;
        bool isLongTermBufferInitialized;
        uint8 midTermIndex;
        uint8 longTermIndex;
        int16 lastTick;
        uint24 midTermIntervalConfig;
        uint24 longTermIntervalConfig;
        int56 lendingCumulativeSum;
        int56[MID_TERM_ARRAY_LENGTH] midTermCumulativeSum;
        int56[LONG_TERM_ARRAY_LENGTH] longTermCumulativeSum;
        uint32[MID_TERM_ARRAY_LENGTH] midTermTimeInterval;
        uint32[LONG_TERM_ARRAY_LENGTH] longTermTimeInterval;
    }

    error InvalidIntervalConfig();

    /**
     * @notice Initializes the observation struct with the specified interval configurations.
     * @dev This function sets the initial values for the mid-term and long-term interval configurations.
     *
     *      This forces the time to to go through the long term is twice as long as it takes to go
     *      through the mid-term interval.
     * @param self The storage reference to the Observations struct.
     * @param midTermTimePerUpdate The time required to pass before the mid-term twap is updated.
     * @param longTermTimePerUpdate The time required to pass before the long-term twap is updated.
     */
    function initializeObservationStruct(
        Observations storage self,
        uint24 midTermTimePerUpdate,
        uint24 longTermTimePerUpdate
    ) internal {
        if (
            midTermTimePerUpdate == 0
                || longTermTimePerUpdate < MINIMUM_LONG_TERM_INTERVAL_FACTOR * midTermTimePerUpdate
        ) {
            revert InvalidIntervalConfig();
        }
        self.midTermIntervalConfig = midTermTimePerUpdate;
        self.longTermIntervalConfig = longTermTimePerUpdate;
    }

    function addObservationAndSetLendingState(Observations storage self, int16 firstTick) internal {
        // Update the mid-term & long-term states with first tick value.
        setObservationData(self, firstTick, 0, 0, true);
    }

    /**
     * @notice Configures the interval of long-term observations.
     * @dev This function is used to set the long-term interval between observations for the long-term buffer.
     * @param self The storage reference to the Observations struct.
     * @param longTermTimePerUpdate the time required to pass before the long term twap is update.
     */
    function configLongTermInterval(Observations storage self, uint24 longTermTimePerUpdate) internal {
        uint256 midTermIntervalConfig = self.midTermIntervalConfig;
        if (
            longTermTimePerUpdate < MINIMUM_LONG_TERM_INTERVAL_FACTOR * midTermIntervalConfig
                || midTermIntervalConfig == 0 // make sure the library is initialized
        ) {
            revert InvalidIntervalConfig();
        }
        self.longTermIntervalConfig = longTermTimePerUpdate;
    }

    /**
     * @notice Records a new observation tick value and updates the observation data.
     * @dev This function is used to record new observation data for the contract. It ensures that
     *      the provided tick value is stored appropriately in both mid-term and long-term
     *      observations, updates interval counters, and handles tick cumulative values based
     *      on the current interval configuration. Ensures that this function is called in
     *      chronological order, with increasing timestamps. Returns in case the
     *      provided block timestamp is less than or equal to the last recorded timestamp.
     * @param self The storage structure containing observation data.
     * @param newTick The new tick value to be recorded, representing the most recent update of
     *      reserveXAssets and reserveYAssets.
     * @param timeElapsed The time elapsed since the last observation.
     * @return updated A boolean indicating whether the observation was updated.
     */
    function recordObservation(
        Observations storage self,
        int16 newTick,
        uint32 timeElapsed
    ) internal returns (bool updated) {
        // Record observation only if the time elapsed is greater than the configured mid-term interval.
        if (timeElapsed >= self.midTermIntervalConfig) {
            uint256 currentMidTermIndex = self.midTermIndex;

            newTick = boundTick(self, newTick);

            // Update state for mid-term range observations.
            int56 currentCumulativeTick = getMidTermAtLastIndex(self, currentMidTermIndex);
            unchecked {
                currentCumulativeTick += int56(newTick) * int56(uint56(timeElapsed));
            }

            setObservationData(self, newTick, currentCumulativeTick, currentMidTermIndex, false);
            updated = true;
        }
    }

    /**
     * @notice Gets the min and max range of tick values from the stored oracle observations.
     * @dev This function calculates the minimum and maximum tick values among three observed ticks:
     *          long-term tick, mid-term tick, and current tick.
     * @param self The observation struct where stored oracle array containing the tick observations.
     * @param currentTick The current (most recent) tick based on the current reserves.
     * @return minTick The minimum tick value among the three observed ticks.
     * @return maxTick The maximum tick value among the three observed ticks.
     */
    function getTickRange(Observations storage self, int16 currentTick) internal view returns (int16, int16) {
        bool isLongTermBufferInitialized = self.isLongTermBufferInitialized;
        (int16 longTermTick, int16 midTermTick, int16 blockTick) = getObservedTicks(self, isLongTermBufferInitialized);
        uint256 factor = getLongTermBufferFactor(self, isLongTermBufferInitialized);
        return getTickRangeInternal(longTermTick, midTermTick, blockTick, currentTick, factor);
    }

    /**
     * @notice Gets the min and max range of tick values from the stored oracle observations.
     * @dev This function calculates the minimum and maximum tick values among the mid-term tick and current tick.
     * @param self The observation struct where stored oracle array containing the tick observations.
     * @return minTick The minimum tick value.
     * @return maxTick The maximum tick value.
     */
    function getTickRangeWithoutLongTerm(
        Observations storage self
    ) internal view returns (int16 minTick, int16 maxTick) {
        int16 midTermTick = getObservedMidTermTick(self);
        int16 blockTick = self.lastTick;

        // we do not include the current tick to avoid manipulation to increase liquidation payout.
        (minTick, maxTick) = getMinAndMaxOfThree(midTermTick, blockTick, blockTick);
        maxTick += 1;
    }

    /**
     * @dev Retrieves the long-term, mid-term, and current tick values based on the stored observations.
     * @dev visibility is only `internal` for testing purposes
     * @param self The observation struct.
     * @param isLongTermBufferInitialized Boolean value which represents whether long-term buffer is filled or not.
     * @return The long-term, mid-term, and last tick values.
     */
    function getObservedTicks(
        Observations storage self,
        bool isLongTermBufferInitialized
    ) internal view returns (int16, int16, int16) {
        return (getObservedLongTermTick(self, isLongTermBufferInitialized), getObservedMidTermTick(self), self.lastTick);
    }

    /**
     * @dev Retrieves the mid-term tick value based on the stored observations.
     * @param self The observation struct.
     * @return midTermTick The mid-term tick value.
     */
    function getObservedMidTermTick(
        Observations storage self
    ) internal view returns (int16 midTermTick) {
        uint256 currentMidTermIndex = self.midTermIndex; // gas savings
        uint256 lastMidTermInterval = getLastIndex(currentMidTermIndex, MID_TERM_ARRAY_LAST_INDEX);
        bool isMidTermBufferInitialized = self.isMidTermBufferInitialized;

        if (!isMidTermBufferInitialized && lastMidTermInterval == 0) {
            midTermTick = self.lastTick;
        } else {
            unchecked {
                // Timestamp can overflow after 136 years, this is safe as long as
                // there is an update every 2.67 years on average for a cycle through
                // the mid-term array.
                midTermTick = calculateTickAverage(
                    self.midTermCumulativeSum[lastMidTermInterval],
                    (isMidTermBufferInitialized ? self.midTermCumulativeSum[currentMidTermIndex] : int56(0)),
                    uint256(
                        self.midTermTimeInterval[lastMidTermInterval]
                            - (
                                isMidTermBufferInitialized
                                    ? self.midTermTimeInterval[currentMidTermIndex]
                                    : self.midTermTimeInterval[0]
                            )
                    )
                );
            }
        }
    }

    /**
     * @dev Retrieves the long-term tick value based on the stored observations.
     * @param self The observation struct.
     * @param isLongTermBufferInitialized Boolean value which represents whether long-term buffer is filled or not.
     * @return longTermTick The long-term tick value.
     */
    function getObservedLongTermTick(
        Observations storage self,
        bool isLongTermBufferInitialized
    ) private view returns (int16 longTermTick) {
        uint256 currentLongTermIndex = self.longTermIndex;
        uint256 lastLongTermInterval = getLastIndex(currentLongTermIndex, LONG_TERM_ARRAY_LAST_INDEX);

        if (!isLongTermBufferInitialized && lastLongTermInterval == 0) {
            longTermTick = self.lastTick;
        } else {
            unchecked {
                // we allow the timestamp to overflow every 136 years.
                longTermTick = calculateTickAverage(
                    self.longTermCumulativeSum[lastLongTermInterval],
                    isLongTermBufferInitialized ? self.longTermCumulativeSum[currentLongTermIndex] : int56(0),
                    uint256(
                        self.longTermTimeInterval[lastLongTermInterval]
                            - (
                                isLongTermBufferInitialized
                                    ? self.longTermTimeInterval[currentLongTermIndex]
                                    : self.longTermTimeInterval[0]
                            )
                    )
                );
            }
        }
    }

    // visibility is only `internal` for testing purposes
    function getTickRangeInternal(
        int16 longTermTick,
        int16 midTermTick,
        int16 blockTick,
        int16 currentTick,
        uint256 factor
    ) internal pure returns (int16 minTick, int16 maxTick) {
        (minTick, maxTick) = getMinAndMaxOfFour(longTermTick, midTermTick, blockTick, currentTick);

        // `minTick` & `maxTick` bound check to be within the range of `MIN_TICK` and `MAX_TICK`.
        unchecked {
            // 0 <= delta <= MAX_TICK-MIN_TICK
            uint256 delta = uint256(int256(maxTick) - minTick);

            int256 buffer = int256(
                delta
                    + Convert.mulDiv(
                        LOG_BASE_OF_ROOT_TWO, LONG_TERM_ARRAY_LAST_INDEX - factor, LONG_TERM_ARRAY_LAST_INDEX, false
                    )
            );

            // `minTick` & `maxTick` bound check to be within the range of `MIN_TICK` and `MAX_TICK`.
            // safe from under flow
            minTick =
                int256(blockTick) - buffer > int256(TickMath.MIN_TICK) ? int16(blockTick - buffer) : TickMath.MIN_TICK;
            maxTick = int256(blockTick) + buffer + 1 < int256(TickMath.MAX_TICK)
                ? int16(blockTick + buffer + 1)
                : TickMath.MAX_TICK;
        }
    }

    function getMinAndMaxOfFour(int16 a, int16 b, int16 c, int16 d) private pure returns (int16 min, int16 max) {
        (min, max) = getMinAndMaxOfThree(b, c, d);
        (min, max) = getMinAndMaxOfThree(a, min, max);
    }

    function getMinAndMaxOfThree(int16 a, int16 b, int16 c) private pure returns (int16 min, int16 max) {
        (min, max) = c < b ? (c, b) : (b, c);
        if (a < min) {
            min = a;
        } else if (max < a) {
            max = a;
        }
    }

    function getMidTermAtLastIndex(Observations storage self, uint256 index) private view returns (int56) {
        return self.midTermCumulativeSum[getLastIndex(index, MID_TERM_ARRAY_LAST_INDEX)];
    }

    function getLastIndex(uint256 index, uint256 lastIndex) private pure returns (uint256) {
        unchecked {
            return index == 0 ? lastIndex : index - 1;
        }
    }

    function getNextIndex(uint256 currentIndex, uint256 indexLength) private pure returns (uint8) {
        unchecked {
            return uint8((currentIndex + 1) % indexLength);
        }
    }

    /**
     * @notice Gets the tick value representing the TWAP since the last
     *         lending update and checkpoints the current lending cumulative sum
     *         as `self.lendingCumulativeSum` and the current block timestamp as `self.lastLendingTimestamp`.
     * @dev See `getLendingStateTick` for implementation details which was
     *      separated to allow view access without any state updates.
     * @param self Observations storage struct
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     */
    function getLendingStateTickAndCheckpoint(
        Observations storage self,
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) internal returns (int16) {
        (int16 lendingStateTick, int56 currentCumulativeSum) =
            getLendingStateTick(self, 0, timeElapsedSinceUpdate, timeElapsedSinceLendingUpdate, false);

        self.lendingCumulativeSum = currentCumulativeSum;
        return lendingStateTick;
    }

    /**
     * @notice Gets the tick value representing the TWAP since the last lending update.
     * @param self Observations storage struct
     * @param newTick The current tick value.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     * @return currentCumulativeSum The current cumulative sum for the last updated timestamp.
     */
    function getLendingStateTick(
        Observations storage self,
        int56 newTick,
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate,
        bool tickAvailable
    ) internal view returns (int16, int56) {
        uint24 midTermIntervalConfig = self.midTermIntervalConfig; // gas savings
        int56 currentCumulativeSum = getMidTermAtLastIndex(self, self.midTermIndex);

        if (tickAvailable && timeElapsedSinceUpdate >= midTermIntervalConfig) {
            unchecked {
                // add currentTimeStamp * tick to cumulativeSum
                currentCumulativeSum += int56(boundTick(self, int16(newTick))) * int56(uint56(timeElapsedSinceUpdate));
            }
        }

        return (
            (timeElapsedSinceLendingUpdate < midTermIntervalConfig)
                ? self.lastTick
                : calculateTickAverage(currentCumulativeSum, self.lendingCumulativeSum, timeElapsedSinceLendingUpdate),
            currentCumulativeSum
        );
    }

    /**
     * @notice Updates the observation data with the new tick value and current timestamp.
     * @dev This function updates both mid-term and long-term observation states based on the provided
     *      new tick value and the current timestamp. It also updates the last recorded observation state.
     * @param self The storage reference to the Observations struct.
     * @param newTick The new tick value to be recorded.
     * @param currentCumulativeTick The current cumulative tick sum.
     */
    function setObservationData(
        Observations storage self,
        int16 newTick,
        int56 currentCumulativeTick,
        uint256 currentMidTermIndex,
        bool firstUpdate
    ) private {
        uint32 currentTimestamp = getCurrentTimestamp();
        // Update the mid-term interval state.
        self.midTermCumulativeSum[currentMidTermIndex] = currentCumulativeTick;
        self.midTermTimeInterval[currentMidTermIndex] = currentTimestamp;

        // set storage and memory to save gas.
        uint256 nextIndex = self.midTermIndex = getNextIndex(currentMidTermIndex, MID_TERM_ARRAY_LENGTH);

        if (!self.isMidTermBufferInitialized && nextIndex == 0) {
            self.isMidTermBufferInitialized = true;
        }

        {
            // Check if long-term interval should be updated.
            uint24 currentLongTermConfig = self.longTermIntervalConfig;

            uint32 duration;
            unchecked {
                duration = currentTimestamp
                    - self.longTermTimeInterval[getLastIndex(self.longTermIndex, LONG_TERM_ARRAY_LAST_INDEX)];
            }
            if (duration >= currentLongTermConfig || firstUpdate) {
                uint256 currentLongTermIndex = self.longTermIndex;

                // Update the long-term interval state.
                self.longTermCumulativeSum[currentLongTermIndex] = currentCumulativeTick;
                self.longTermTimeInterval[currentLongTermIndex] = currentTimestamp;
                // set to storage and memory to save gas.
                nextIndex = self.longTermIndex = getNextIndex(currentLongTermIndex, LONG_TERM_ARRAY_LENGTH);

                if (!self.isLongTermBufferInitialized && nextIndex == 0) {
                    self.isLongTermBufferInitialized = true;
                }
            }
        }

        // update last recorded observation state.
        self.lastTick = newTick;
    }

    /**
     * @notice Computes the tick average based on the cumulative sum and duration.
     * @param currentCumulativeSum The current cumulative sum of mid-term/long-term values.
     * @param previousCumulativeSum The previous cumulative sum recorded for mid-term/long-term.
     * @param bufferLength If the mid-term/long-term buffer is fully recorded, then the buffer length
     *         equals the duration passed between the first and last recorded ticks, else it's same as
     *         the mid-term/long-term buffer.
     * @return tick The computed tick average for mid-term/long-term.
     */
    function calculateTickAverage(
        int56 currentCumulativeSum,
        int56 previousCumulativeSum,
        uint256 bufferLength
    ) private pure returns (int16 tick) {
        unchecked {
            // under flows desired
            tick = int16((currentCumulativeSum - previousCumulativeSum) / int256(bufferLength));
        }
    }

    /**
     * @dev Gets the long-term buffer factor based on the available data in long-term array.
     * @param self The observation struct where stored oracle array containing the tick observations.
     * @param isLongTermBufferInitialized Boolean value which represents whether long-term buffer is filled or not.
     * @return factor The amount of information we have in the long-term array.
     */
    function getLongTermBufferFactor(
        Observations storage self,
        bool isLongTermBufferInitialized
    ) private view returns (uint256 factor) {
        /**
         * Factor, `F` is the amount of information we have in the long-term array.
         * It's represented by the last filled index count in the long-term array.
         */
        factor = LONG_TERM_ARRAY_LAST_INDEX;
        if (!isLongTermBufferInitialized) {
            factor = self.longTermIndex - 1;
        }
    }

    /**
     * @notice Adjusts the new tick value to ensure it stays within valid bounds. When we have less data, the outlier
     *         factor is greater to allow for more flexibility to find the true price.
     * @dev The function ensures that `newTick` stays within the bounds
     *      determined by `lastTick` and a dynamically calculated factor.
     * @param self The storage reference to `Observations`, which holds historical tick data.
     * @param newTick The proposed new tick value to be adjusted within valid bounds.
     * @return The adjusted tick value constrained within the allowable range.
     */
    function boundTick(Observations storage self, int16 newTick) internal view returns (int16) {
        int256 outlierFactor = DEFAULT_TICK_DELTA_FACTOR;

        bool isLongTermBufferInitialized = self.isLongTermBufferInitialized;

        if (!isLongTermBufferInitialized) {
            outlierFactor =
                int256(LONG_TERM_ARRAY_LAST_INDEX - getLongTermBufferFactor(self, isLongTermBufferInitialized));
        }
        int16 lastTick = self.lastTick;
        unchecked {
            int256 maxTickDelta = outlierFactor * MAX_TICK_DELTA;
            int256 minTickBound = lastTick - maxTickDelta;
            int256 maxTickBound = lastTick + maxTickDelta;

            if (newTick > maxTickBound) {
                newTick = int16(maxTickBound);
            } else if (newTick < minTickBound) {
                newTick = int16(minTickBound);
            }
        }

        return newTick;
    }

    /**
     * @dev Returns the current block timestamp casted to uint32.
     * @return The current block timestamp as a uint32 value.
     */
    function getCurrentTimestamp() internal view returns (uint32) {
        unchecked {
            // slither-disable-next-line weak-prng
            return uint32(block.timestamp % Q32);
        }
    }

    /**
     * @dev Average the mid-term tick and the new tick, rounding towards the `midTermTick`.
     * @param midTermTick The midterm tick value
     * @param newTick The new tick value
     * @return The calculated average tick value
     */
    function calculateTickAverageTowardsMidTerm(int256 midTermTick, int256 newTick) internal pure returns (int16) {
        int256 sum = midTermTick + newTick;

        // If sum is even, the average is an integer
        // If sum is odd, the average is a half-integer, so round towards `midTermTick`
        return int16(sum % 2 == 0 ? sum / 2 : midTermTick > newTick ? (sum + 1) / 2 : (sum - 1) / 2);
    }
}
