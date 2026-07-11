// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Q56, Q72, MAG2, BUFFER, BUFFER_NUMERATOR} from 'contracts/libraries/constants.sol';
import {ROUNDING_UP} from 'contracts/interfaces/tokens/ITokenController.sol';

library Convert {
    function toLiquidityAssets(
        uint256 liquidityShares,
        uint256 reservesAssets,
        uint256 activeLiquidityAssets,
        uint256 depositLiquidityAssets,
        uint256 depositLiquidityShares
    ) internal pure returns (uint256) {
        // This calculation is derived from the original formula:
        // amountAssets = amountShares * (depositLiquidityAssets / depositLiquidityShares) * reservesAssets / activeLiquidityAssets.
        return Convert.mulDiv(
            Convert.mulDiv(liquidityShares, reservesAssets, activeLiquidityAssets, false),
            depositLiquidityAssets,
            depositLiquidityShares,
            false
        );
    }

    function toAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares,
        bool roundingUp
    ) internal pure returns (uint256 _assets) {
        if (totalShares == 0) {
            return shares; // If no shares, assets are equal to shares.
        }
        return mulDiv(shares, totalAssets, totalShares, roundingUp);
    }

    function toShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares,
        bool roundingUp
    ) internal pure returns (uint256 _shares) {
        if (totalAssets == 0) {
            return assets; // If no assets, shares are equal to assets.
        }
        return mulDiv(assets, totalShares, totalAssets, roundingUp);
    }

    function mulDiv(uint256 x, uint256 y, uint256 z, bool roundingUp) internal pure returns (uint256 result) {
        result = x * y;
        result = roundingUp ? Math.ceilDiv(result, z) : result / z;
    }

    /**
     * @notice helper method to calculate balance adjustment for missing assets
     * @dev In the depleted case the adjusted reserve is `(reserve - missing) * bufferNumerator`,
     *      matching the `BUFFER_NUMERATOR` scaling applied by `calculateBalanceAfterFees` so the
     *      K comparison stays division-free.
     *      For updateObservation, different scaled `buffer` and `bufferNumerator` values
     *      are supplied so the adjusted reserve reflects observation-specific logic.
     * @param reserve the starting reserve
     * @param missing the missing assets, zero if deposits > borrows of X or Y
     * @param buffer  Scaling factor applied to the reserve for the depletion comparison.
     * @param bufferNumerator  Scaling factor applied to the missing amount for the comparison
     *                         and for computing the depleted-case adjusted reserve.
     * @return reserveAdjustment The adjusted reserve value used for swap or updateObservation
     *                           depends on the buffer, bufferNumerator to be passed in.
     */
    function calculateReserveAdjustmentsForMissingAssets(
        uint256 reserve,
        uint256 missing,
        uint256 buffer,
        uint256 bufferNumerator
    ) internal pure returns (uint256 reserveAdjustment) {
        reserveAdjustment = reserve * buffer < missing * bufferNumerator
            ? (reserve - missing) * bufferNumerator // depleted case
            : reserve; // not depleted case
    }

    /**
     * @notice Depletion-adjusted active liquidity, `sqrt` of the adjusted-reserve product using the
     *  swap K-check buffer. Shared by interest accrual and `TokenController.calculateActiveLiquidityAssets`
     *  so every active-liquidity reader uses one basis.
     * @param reserveXAssets reserve X used for the active-liquidity calculation.
     * @param reserveYAssets reserve Y used for the active-liquidity calculation.
     * @param missingXAssets missing X assets, zero if deposits > borrows of X.
     * @param missingYAssets missing Y assets, zero if deposits > borrows of Y.
     * @return The depletion-adjusted active liquidity.
     */
    function depletionAdjustedActiveLiquidity(
        uint256 reserveXAssets,
        uint256 reserveYAssets,
        uint256 missingXAssets,
        uint256 missingYAssets
    ) internal pure returns (uint256) {
        return Math.sqrt(
            calculateReserveAdjustmentsForMissingAssets(reserveXAssets, missingXAssets, BUFFER, BUFFER_NUMERATOR)
                * calculateReserveAdjustmentsForMissingAssets(reserveYAssets, missingYAssets, BUFFER, BUFFER_NUMERATOR)
        );
    }
}
