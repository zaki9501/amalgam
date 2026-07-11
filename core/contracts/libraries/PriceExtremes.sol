// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';

/**
 * @notice Tracks intra-observation price extremes to mitigate TWAP lag attacks.
 * @dev Records max/min ticks per observation interval so arb-driven price signals are captured
 *      even if the attacker resets the price afterward.
 */
library PriceExtremes {
    /**
     * @notice State for tracking price extremes within an observation interval.
     */
    struct State {
        uint32 currentTimestamp;
        uint32 previousTimestamp;
        int16 currentMaxTick;
        int16 currentMinTick;
        int16 previousMaxTick;
        int16 previousMinTick;
        bool currentInitialized;
        bool previousInitialized;
    }

    /**
     * @notice Record a priceQ128 observation as inclusive min and exclusive max ticks.
     * @param state     The per-pair extreme tracking state
     * @param priceQ128 The current price as reserveX * Q128 / reserveY
     * @param interval  The observation interval (DEFAULT_MID_TERM_INTERVAL)
     */
    function record(State storage state, uint256 priceQ128, uint32 interval) internal {
        int16 minTick = TickMath.getTickAtPrice(priceQ128);
        int16 maxTick = minTick + 1;
        uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
        uint32 elapsed;
        unchecked {
            elapsed = currentTimestamp - state.currentTimestamp;
        }

        if (!state.currentInitialized || elapsed >= interval) {
            // Roll current → previous
            state.previousTimestamp = state.currentTimestamp;
            state.previousMaxTick = state.currentMaxTick;
            state.previousMinTick = state.currentMinTick;
            state.previousInitialized = state.currentInitialized;
            // Initialize new current
            state.currentTimestamp = currentTimestamp;
            state.currentMaxTick = maxTick;
            state.currentMinTick = minTick;
            state.currentInitialized = true;
        } else {
            if (maxTick > state.currentMaxTick) state.currentMaxTick = maxTick;
            if (minTick < state.currentMinTick) state.currentMinTick = minTick;
        }
    }

    /**
     * @notice Widen a [minTick, maxTick) range using fresh price extremes. Never narrows.
     * @param state    The per-pair extreme tracking state
     * @param minTick  Current minimum tick (from getTickRange)
     * @param maxTick  Current exclusive maximum tick (from getTickRange)
     * @param interval The observation interval (DEFAULT_MID_TERM_INTERVAL)
     * @return widenedMin  The potentially widened minimum tick
     * @return widenedMax  The potentially widened maximum tick
     */
    function widen(
        State storage state,
        int16 minTick,
        int16 maxTick,
        uint32 interval
    ) internal view returns (int16 widenedMin, int16 widenedMax) {
        widenedMin = minTick;
        widenedMax = maxTick;
        uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
        // previousTimestamp is set at rollover to the prior slot's start, which by the rollover
        // condition is already >= interval old. 2 * interval gives the previous slot one further
        // interval of freshness; tighter bounds would discard it immediately after every rollover.
        uint32 maxAge = 2 * interval;

        (widenedMin, widenedMax) = _widen(
            state.currentTimestamp,
            state.currentMinTick,
            state.currentMaxTick,
            state.currentInitialized,
            currentTimestamp,
            maxAge,
            widenedMin,
            widenedMax
        );
        (widenedMin, widenedMax) = _widen(
            state.previousTimestamp,
            state.previousMinTick,
            state.previousMaxTick,
            state.previousInitialized,
            currentTimestamp,
            maxAge,
            widenedMin,
            widenedMax
        );
    }

    function _widen(
        uint32 stateTimestamp,
        int16 slotMinTick,
        int16 slotMaxTick,
        bool initialized,
        uint32 currentTimestamp,
        uint32 maxAge,
        int16 widenMin,
        int16 widenMax
    ) private pure returns (int16, int16) {
        // Subtraction is unchecked so the freshness check stays correct across the 2^32 wrap.
        uint32 age;
        unchecked {
            age = currentTimestamp - stateTimestamp;
        }
        if (initialized && age < maxAge) {
            if (slotMaxTick > widenMax) widenMax = slotMaxTick;
            if (slotMinTick < widenMin) widenMin = slotMinTick;
        }
        return (widenMin, widenMax);
    }
}
