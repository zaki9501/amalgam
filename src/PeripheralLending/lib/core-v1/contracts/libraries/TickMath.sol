// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {Convert} from 'contracts/libraries/Convert.sol';
import {Q128} from 'contracts/libraries/constants.sol';

/**
 * @title Math library for computing sqrt prices from ticks and vice versa
 * @notice Computes sqrt price for ticks of size $B=(1-2^{-9})^{-1}$ as fixed point Q72 numbers.
 * Supports prices between $2^{-112}$ and $2^{112}-1$.
 */
library TickMath {
    error PriceOutOfBounds();
    error TickOutOfBounds();

    // big(2)^64 / log2(B) - 1; / 2 since the input is price but ticks map to sqrt price; -1 since without is an odd number
    int256 private constant BASE_CHANGE_CONSTANT_IN_Q128 = 0xb145b7be86780ae93f;
    int256 private constant TICK_LOW_ERROR_CORRECTION_IN_Q128 = 0x1f6d22eefc342687357a94df44b0dbf;
    int256 private constant TICK_HI_ERROR_CORRECTION_IN_Q128 = 0xb33c8bdbc23c5eaf1cd8140681512562;

    uint256 internal constant MIN_PRICE_IN_Q128 = 0x10000;
    uint256 internal constant MAX_PRICE_IN_Q128 = 0xffffffffffffffffffffffffffff00000000000000000000000000000000;

    // getSqrtPriceAtTick(MIN_TICK) == MIN_SQRT_PRICE_IN_Q72 < getSqrtPriceAtTick(MIN_TICK + 1)
    // getSqrtPriceAtTick(MAX_TICK - 1) < MAX_SQRT_PRICE_IN_Q72 == getSqrtPriceAtTick(MAX_TICK)
    int16 internal constant MIN_TICK = -0x4d8f; // -19855
    int16 internal constant MAX_TICK = 0x4d8e; // -MIN_TICK - 1; // 19854
    uint256 internal constant MIN_SQRT_PRICE_IN_Q72 = 0xffc0;
    uint256 internal constant MAX_SQRT_PRICE_IN_Q72 = 0xffc00ffc00ffc00ffc00ffc00ffc00ff;

    // sqrtPrice = B^tick
    function getSqrtPriceAtTick(
        int16 tick
    ) internal pure returns (uint256 sqrtPriceInQ72) {
        // Handle edge case where we round up tick by 1.
        if (tick == MAX_TICK + 1) return MAX_SQRT_PRICE_IN_Q72;
        if (tick < MIN_TICK || MAX_TICK + 1 < tick) revert TickOutOfBounds();

        int256 intTick = int256(tick);
        uint256 absTick = uint256(intTick < 0 ? -intTick : intTick);

        sqrtPriceInQ72 = applyMultiplications(absTick) >> 56; // 72 == 128 - 56
        if (0 < tick) sqrtPriceInQ72 = type(uint144).max / sqrtPriceInQ72; // 2 * 72 == 144
    }

    // tick = log in basis B of priceInQ128
    function getTickAtPrice(
        uint256 priceInQ128
    ) internal pure returns (int16) {
        if (priceInQ128 < MIN_PRICE_IN_Q128 || MAX_PRICE_IN_Q128 < priceInQ128) revert PriceOutOfBounds();

        uint256 p = priceInQ128;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(p, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := shl(6, gt(p, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := shl(5, gt(p, 0xFFFFFFFF))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := shl(4, gt(p, 0xFFFF))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := shl(3, gt(p, 0xFF))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := shl(2, gt(p, 0xF))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := shl(1, gt(p, 0x3))
            msb := or(msb, f)
            p := shr(f, p)
        }
        assembly {
            let f := gt(p, 0x1)
            msb := or(msb, f)
        }

        int256 logBase2;
        unchecked {
            if (msb >= 128) p = priceInQ128 >> (msb - 127);
            else p = priceInQ128 << (127 - msb);
            logBase2 = (int256(msb) - 128) << 64;
        }

        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(63, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(62, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(61, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(60, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(59, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(58, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(57, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(56, f))
            p := shr(f, p)
        }
        assembly {
            p := shr(127, mul(p, p))
            let f := shr(128, p)
            logBase2 := or(logBase2, shl(55, f))
            p := shr(f, p)
        }

        unchecked {
            int256 logB = BASE_CHANGE_CONSTANT_IN_Q128 * logBase2;
            int16 tickLow = int16((logB - TICK_LOW_ERROR_CORRECTION_IN_Q128) >> 128);
            int16 tickHi = int16((logB + TICK_HI_ERROR_CORRECTION_IN_Q128) >> 128);
            if (tickLow == tickHi) return tickLow;
            if (getPriceAtTick(tickHi) <= priceInQ128) return tickHi;
            return tickLow;
        }
    }

    function getPriceAtTick(
        int16 tick
    ) internal pure returns (uint256 priceInQ128) {
        if (tick == MAX_TICK + 1) return MAX_PRICE_IN_Q128;
        if (tick < MIN_TICK || MAX_TICK + 1 < tick) revert TickOutOfBounds();

        int256 intTick = tick;
        uint256 absTick = uint256(intTick < 0 ? -intTick : intTick);

        // apply the same algorithm as in getSqrtPriceAtTick using tick * 2 and adding a round.
        absTick *= 2;
        priceInQ128 = applyMultiplications(absTick);
        if (absTick & 0x8000 != 0) priceInQ128 = (priceInQ128 * 0xbef94ed7e) >> 128;

        if (0 < tick) priceInQ128 = type(uint256).max / priceInQ128;
    }

    function applyMultiplications(
        uint256 absTick
    ) private pure returns (uint256 valueInQ128) {
        unchecked {
            valueInQ128 = absTick & 0x1 != 0 ? 0xff800000000000000000000000000000 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) valueInQ128 = (valueInQ128 * 0xff004000000000000000000000000000) >> 128;
            if (absTick & 0x4 != 0) valueInQ128 = (valueInQ128 * 0xfe017f80100000000000000000000000) >> 128;
            if (absTick & 0x8 != 0) valueInQ128 = (valueInQ128 * 0xfc06f9045e406ff00100000000000000) >> 128;
            if (absTick & 0x10 != 0) {
                valueInQ128 = (valueInQ128 * 0xf81dba7137fcc6d22fafcfde71ae81e0) >> 128;
            }
            if (absTick & 0x20 != 0) {
                valueInQ128 = (valueInQ128 * 0xf0799caf21e927ea1252fa7400a1d886) >> 128;
            }
            if (absTick & 0x40 != 0) {
                valueInQ128 = (valueInQ128 * 0xe1e43f8ddd0922622788b108788fc191) >> 128;
            }
            if (absTick & 0x80 != 0) {
                valueInQ128 = (valueInQ128 * 0xc7530338a302e81d8229a7f1f67fa265) >> 128;
            }
            if (absTick & 0x100 != 0) {
                valueInQ128 = (valueInQ128 * 0x9b3229ed2432991a2e021bb106f5feb6) >> 128;
            }
            if (absTick & 0x200 != 0) {
                valueInQ128 = (valueInQ128 * 0x5e15c89991553a6dc1c8a8a0931572d2) >> 128;
            }
            if (absTick & 0x400 != 0) {
                valueInQ128 = (valueInQ128 * 0x2294012b4d1cbe1865fe254cef6e40bc) >> 128;
            }
            if (absTick & 0x800 != 0) {
                valueInQ128 = (valueInQ128 * 0x4aba5e0da8e29a77fabca56a012ae25) >> 128;
            }
            if (absTick & 0x1000 != 0) {
                valueInQ128 = (valueInQ128 * 0x15d0460cb40a7356d32b6966397c03) >> 128;
            }
            if (absTick & 0x2000 != 0) valueInQ128 = (valueInQ128 * 0x1dbd4effd593afec2694414e4f6) >> 128;
            if (absTick & 0x4000 != 0) valueInQ128 = (valueInQ128 * 0x3746fe3b485b7be710a06) >> 128;
        }
    }

    /**
     * @dev Get the new tick based on the current reserves.
     * @param reserveXAssets The current reserve X assets.
     * @param reserveYAssets The current reserve Y assets.
     * @return newTick The current tick.
     */
    function getTickFromReserves(uint256 reserveXAssets, uint256 reserveYAssets) internal pure returns (int16) {
        return getTickAtPrice(Convert.mulDiv(reserveXAssets, Q128, reserveYAssets, false));
    }
}
