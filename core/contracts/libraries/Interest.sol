// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {MathLib, WAD} from '@morpho-org/morpho-blue/src/libraries/MathLib.sol';

import {TickMath} from 'contracts/libraries/TickMath.sol';

import {
    ITokenController,
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    FIRST_DEBT_TOKEN,
    TOKEN_COUNT,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {
    B_IN_Q72,
    Q72,
    Q128,
    LIQUIDITY_INTEREST_RATE_MAGNIFICATION,
    MAX_SATURATION_PERCENT_IN_WAD,
    MAX_UTILIZATION_PERCENT_IN_WAD,
    SECONDS_IN_YEAR
} from 'contracts/libraries/constants.sol';
import {Convert} from 'contracts/libraries/Convert.sol';

/**
 * @title Interest Library
 * @notice This library is used for calculating and accruing interest.
 * @dev many calculations are unchecked because we asset values are stored as uint112. We also limit
 *      the max amount amount of interest to ensure that it can not overflow when added to the
 *      current assets.
 *
 */
library Interest {
    using MathLib for uint256;
    using MathLib for uint112;

    struct AccrueInterestParams {
        uint256 duration;
        int16 lendingStateTick;
        uint112[6] shares;
        uint256 satPercentageInWads;
        uint256 reserveXAssets;
        uint256 reserveYAssets;
    }

    uint256 internal constant OPTIMAL_UTILIZATION = 0.8e18; //  80%
    uint256 internal constant DANGER_UTILIZATION = 0.925e18; // 92.5%
    uint256 internal constant SLOPE1 = 0.1e18;
    uint256 internal constant SLOPE2 = 2e18;
    uint256 internal constant SLOPE3 = 20e18;
    uint256 internal constant BASE_OPTIMAL_UTILIZATION = 0.08e18; // 8%
    uint256 internal constant BASE_DANGER_UTILIZATION = 0.33e18; // 33%

    uint256 internal constant LENDING_FEE_RATE = 10;
    uint256 private constant MAX_UINT112 = type(uint112).max;
    uint256 private constant LAST_DEPOSIT = 2; // FIRST_DEBT_TOKEN - 1;

    uint256 private constant NO_RESERVES_FOR_L = 0;

    /**
     * @dev Maximum percentage for the penalty saturation allowed.
     * This is used to prevent excessive penalties in case of high utilization.
     */
    uint256 private constant PENALTY_SATURATION_PERCENT_IN_WAD = 0.85e18; // 85%

    /**
     * @dev `MAX_SATURATION_PERCENT_IN_WAD` - `PENALTY_SATURATION_PERCENT_IN_WAD`
     */
    uint256 private constant SATURATION_PENALTY_BUFFER_IN_WAD = 0.1e18;

    function accrueInterestAndUpdateReservesWithAssets(
        uint112[6] storage assets,
        AccrueInterestParams memory accrueInterestParams
    ) external returns (uint256 interestXForLP, uint256 interestYForLP, uint256[3] memory protocolFeeAssets) {
        if (accrueInterestParams.duration > 0) {
            uint112[6] memory newAssets;
            (newAssets, interestXForLP, interestYForLP, protocolFeeAssets) =
                accrueInterestWithAssets(assets, accrueInterestParams);
            for (uint256 i = DEPOSIT_X; i < TOKEN_COUNT; i++) {
                assets[i] = newAssets[i];
            }
            emit ITokenController.InterestAccrued(
                accrueInterestParams.reserveXAssets + interestXForLP,
                accrueInterestParams.reserveYAssets + interestYForLP,
                newAssets[DEPOSIT_X],
                newAssets[DEPOSIT_Y],
                newAssets[BORROW_L],
                newAssets[BORROW_X],
                newAssets[BORROW_Y]
            );
        }
    }

    /**
     * @notice we approximate the reserves based on an average tick value since the last lending
     *         state update.
     * @dev this will never return values greater than uint112 max when used correctly. The reserve
     *      values are underestimated due to a tick being an approximate price. We use a smaller
     *      value when multiplying and a larger when dividing to ensure that we do not overflow.
     * @param activeLiquidityAssets active L where $\sqrt{reserveX\cdot reserveY}=L$
     * @param lendingStateTick Average tick value since last lending state update.
     * @return reserveXAssets approximate average reserve since last lending state update.
     * @return reserveYAssets approximate average reserve since last lending state update.
     */
    function getReservesAtTick(
        uint256 activeLiquidityAssets,
        int16 lendingStateTick
    ) internal pure returns (uint256 reserveXAssets, uint256 reserveYAssets) {
        // calculate reserves at lending state tick
        uint256 sqrtPriceAtLendingStateTickMinInQ72 = TickMath.getSqrtPriceAtTick(lendingStateTick);
        uint256 sqrtPriceAtLendingStateTickMaxInQ72 =
            Convert.mulDiv(sqrtPriceAtLendingStateTickMinInQ72, B_IN_Q72, Q72, true);

        unchecked {
            // x = L * sqrt(p)
            reserveXAssets = Convert.mulDiv(activeLiquidityAssets, sqrtPriceAtLendingStateTickMinInQ72, Q72, false);

            // y = L / sqrt(p)
            reserveYAssets = Convert.mulDiv(activeLiquidityAssets, Q72, sqrtPriceAtLendingStateTickMaxInQ72, false);
        }

        return (Math.max(reserveXAssets, 1), Math.max(reserveYAssets, 1));
    }

    /**
     * @notice Reserve tokens borrowed out beyond the single-sided deposit, i.e. `max(borrow, deposit) - deposit`.
     * @param startingAssets Asset balances indexed by token type.
     * @return missingXAssets Reserve X borrowed beyond the X deposit.
     * @return missingYAssets Reserve Y borrowed beyond the Y deposit.
     */
    function missingAssetsInReserve(
        uint112[6] memory startingAssets
    ) private pure returns (uint256 missingXAssets, uint256 missingYAssets) {
        missingXAssets = Math.max(startingAssets[BORROW_X], startingAssets[DEPOSIT_X]) - startingAssets[DEPOSIT_X];
        missingYAssets = Math.max(startingAssets[BORROW_Y], startingAssets[DEPOSIT_Y]) - startingAssets[DEPOSIT_Y];
    }

    function getUtilizationsInWads(
        uint112[6] memory startingAssets,
        uint256 reservesXAssets,
        uint256 reservesYAssets,
        uint256 satPercentageInWads
    ) internal pure returns (uint256[3] memory utilizationInWads) {
        uint256 missingAssetsXInL;
        uint256 missingAssetsYInL;

        unchecked {
            // Calculate missing assets in a block scope to reduce stack depth
            {
                uint256 activeLiquidity = startingAssets[DEPOSIT_L] - startingAssets[BORROW_L];
                (uint256 missingXAssets, uint256 missingYAssets) = missingAssetsInReserve(startingAssets);

                // overflow not possible on multiplication, and underflow caught by conditions
                if (missingXAssets > 0) {
                    missingAssetsXInL = Math.ceilDiv(missingXAssets * activeLiquidity, reservesXAssets);
                }
                if (missingYAssets > 0) {
                    missingAssetsYInL = Math.ceilDiv(missingYAssets * activeLiquidity, reservesYAssets);
                }
            }

            // Calculate utilizations in separate block scope
            {
                utilizationInWads = [
                    mutateUtilizationForSaturation(
                        getUtilizationInWads(
                            startingAssets[BORROW_L] + Math.max(missingAssetsXInL, missingAssetsYInL),
                            startingAssets[DEPOSIT_L]
                        ),
                        satPercentageInWads
                    ),
                    getUtilizationInWads(startingAssets[BORROW_X], startingAssets[DEPOSIT_X] + reservesXAssets),
                    getUtilizationInWads(startingAssets[BORROW_Y], startingAssets[DEPOSIT_Y] + reservesYAssets)
                ];
            }
        }
    }

    function accrueInterestWithAssets(
        uint112[6] memory assets,
        AccrueInterestParams memory params
    )
        public
        pure
        returns (
            uint112[6] memory newAssets,
            uint256 interestXPortionForLP,
            uint256 interestYPortionForLP,
            uint256[3] memory protocolFeeAssets
        )
    {
        uint112[6] memory startingAssets = assets;
        uint256[3] memory interestAssetSet;
        {
            uint256 activeLiquidityAssets;
            {
                (uint256 missingXAssets, uint256 missingYAssets) = missingAssetsInReserve(startingAssets);
                activeLiquidityAssets = Convert.depletionAdjustedActiveLiquidity(
                    params.reserveXAssets, params.reserveYAssets, missingXAssets, missingYAssets
                );
            }

            startingAssets[DEPOSIT_L] = uint112(activeLiquidityAssets + startingAssets[BORROW_L]);

            (uint256 averageReservesX, uint256 averageReservesY) =
                getReservesAtTick(activeLiquidityAssets, params.lendingStateTick);

            {
                uint256[3] memory utilizationsInWads = getUtilizationsInWads(
                    startingAssets, averageReservesX, averageReservesY, params.satPercentageInWads
                );

                // for loop overhead not worth it for three loops.
                interestAssetSet = [
                    // Magnify interest on liquidity by 5x what x and y rates for the same utilization.
                    LIQUIDITY_INTEREST_RATE_MAGNIFICATION
                        * computeInterestAssets(
                            params.duration,
                            utilizationsInWads[DEPOSIT_L],
                            NO_RESERVES_FOR_L,
                            startingAssets[BORROW_L],
                            startingAssets[DEPOSIT_L]
                        ),
                    computeInterestAssets(
                        params.duration,
                        utilizationsInWads[DEPOSIT_X],
                        params.reserveXAssets,
                        startingAssets[BORROW_X],
                        startingAssets[DEPOSIT_X]
                    ),
                    computeInterestAssets(
                        params.duration,
                        utilizationsInWads[DEPOSIT_Y],
                        params.reserveYAssets,
                        startingAssets[BORROW_Y],
                        startingAssets[DEPOSIT_Y]
                    )
                ];
            }

            unchecked {
                protocolFeeAssets = [
                    Convert.mulDiv(interestAssetSet[DEPOSIT_L], LENDING_FEE_RATE, 100, ROUNDING_UP),
                    Convert.mulDiv(interestAssetSet[DEPOSIT_X], LENDING_FEE_RATE, 100, ROUNDING_UP),
                    Convert.mulDiv(interestAssetSet[DEPOSIT_Y], LENDING_FEE_RATE, 100, ROUNDING_UP)
                ];

                interestAssetSet = [
                    interestAssetSet[DEPOSIT_L] - protocolFeeAssets[DEPOSIT_L],
                    interestAssetSet[DEPOSIT_X] - protocolFeeAssets[DEPOSIT_X],
                    interestAssetSet[DEPOSIT_Y] - protocolFeeAssets[DEPOSIT_Y]
                ];

                interestXPortionForLP = Convert.mulDiv(
                    interestAssetSet[DEPOSIT_X], averageReservesX, startingAssets[DEPOSIT_X] + averageReservesX, false
                );
                interestYPortionForLP = Convert.mulDiv(
                    interestAssetSet[DEPOSIT_Y], averageReservesY, startingAssets[DEPOSIT_Y] + averageReservesY, false
                );
            }
        }

        // Skip DEPOSIT_L in the loop - it will be calculated after based on new reserves and BORROW_L
        for (uint256 i = DEPOSIT_X; i < TOKEN_COUNT; i++) {
            uint256 interestPortionForLP;
            uint256 protocolFees;
            uint256 shortArrayIndex = i % FIRST_DEBT_TOKEN;

            if (i == DEPOSIT_X) {
                interestPortionForLP = interestXPortionForLP;
            } else if (i == DEPOSIT_Y) {
                interestPortionForLP = interestYPortionForLP;
            } else if (i > LAST_DEPOSIT) {
                // add protocol fees to all borrows.
                protocolFees = protocolFeeAssets[shortArrayIndex];
            }
            newAssets[i] = addInterestToAssets(
                startingAssets[i],
                interestAssetSet[shortArrayIndex]
                // Back out lp interest being attributed to reserves
                - interestPortionForLP
                // add protocol fees to all borrows.
                + protocolFees
            );
        }

        // Calculate DEPOSIT_L last from the depletion adjusted active liquidity assets.
        // newReserves include LP interest portions that will be added to reserves.
        uint256 newReserveX = params.reserveXAssets + interestXPortionForLP;
        uint256 newReserveY = params.reserveYAssets + interestYPortionForLP;
        {
            uint256 depositXWithFees = uint256(newAssets[DEPOSIT_X]) + protocolFeeAssets[DEPOSIT_X];
            uint256 depositYWithFees = uint256(newAssets[DEPOSIT_Y]) + protocolFeeAssets[DEPOSIT_Y];
            uint256 missingXAssets = Math.max(uint256(newAssets[BORROW_X]), depositXWithFees) - depositXWithFees;
            uint256 missingYAssets = Math.max(uint256(newAssets[BORROW_Y]), depositYWithFees) - depositYWithFees;

            newAssets[DEPOSIT_L] = uint112(
                Convert.depletionAdjustedActiveLiquidity(newReserveX, newReserveY, missingXAssets, missingYAssets)
                    + newAssets[BORROW_L]
            );
        }
    }

    function getUtilizationInWads(
        uint256 totalBorrowedAssets,
        uint256 totalDepositedAssets
    ) internal pure returns (uint256 utilization) {
        if (totalDepositedAssets > 0) {
            // assets are both 112 and will not overflow.
            unchecked {
                // assets are uint112, cant overflow.
                utilization = Math.ceilDiv(totalBorrowedAssets * WAD, totalDepositedAssets);
            }
        }
    }

    /**
     * @notice Adjusts utilization based on saturation to calculate interest penalties
     * @dev When saturation exceeds `PENALTY_SATURATION_PERCENT_IN_WAD`, utilization is increased
     *      to apply higher interest rates as a penalty for high saturation
     * @param utilization Current utilization of `L`, `X`, or `Y` assets
     * @param maxSatInWads Saturation utilization
     * @return The adjusted utilization value
     */
    function mutateUtilizationForSaturation(
        uint256 utilization,
        uint256 maxSatInWads
    ) internal pure returns (uint256) {
        // Early return, if saturation is above or below defined threshold, or utilization is greater than max utilization.
        if (utilization >= MAX_UTILIZATION_PERCENT_IN_WAD || maxSatInWads <= PENALTY_SATURATION_PERCENT_IN_WAD) {
            return utilization;
        } else if (maxSatInWads >= MAX_SATURATION_PERCENT_IN_WAD) {
            return MAX_UTILIZATION_PERCENT_IN_WAD;
        }

        // Calculate adjustment based on formula:
        // min(max((maxSatInWads - MAX_SATURATION_PERCENT) * (MAX_UTILIZATION - utilization) /
        //     (MAX_SATURATION_PERCENT - PENALTY_SATURATION_PERCENT) + MAX_UTILIZATION, utilization), MAX_UTILIZATION)
        uint256 adjustedUtilization = MAX_UTILIZATION_PERCENT_IN_WAD
            - Convert.mulDiv(
                MAX_SATURATION_PERCENT_IN_WAD - maxSatInWads,
                MAX_UTILIZATION_PERCENT_IN_WAD - utilization,
                SATURATION_PENALTY_BUFFER_IN_WAD,
                false
            );

        return Math.min(Math.max(adjustedUtilization, utilization), MAX_UTILIZATION_PERCENT_IN_WAD);
    }

    function computeInterestAssets(
        uint256 duration,
        uint256 utilization,
        uint256 reserveAssets,
        uint256 borrowedAssets,
        uint256 depositedAssets
    ) internal pure returns (uint256) {
        uint256 baseRateInWads = getAnnualInterestRatePerSecondInWads(utilization);

        return computeInterestAssetsGivenRate(
            duration, borrowedAssets, Math.max(depositedAssets, reserveAssets), baseRateInWads
        );
    }

    function computeInterestAssetsGivenRate(
        uint256 duration,
        uint256 borrowedAssets,
        uint256 maxDepositedOrReserveAssets,
        uint256 rateInWads
    ) internal pure returns (uint256) {
        // max amount of interest that can accrue is uint112 max to prevent overflows
        // this means that once an asset hits the max, interest will no longer accrue.
        unchecked {
            return Math.min(
                Convert.mulDiv(MathLib.wTaylorCompounded(rateInWads, duration), borrowedAssets, WAD, false),
                type(uint112).max - Math.max(maxDepositedOrReserveAssets, borrowedAssets)
            );
        }
    }

    function addInterestToAssets(uint256 prevAssets, uint256 interest) internal pure returns (uint112) {
        // safe down cast because interest <= type(uint112).max - max(depositedAssets, borrowedAssets) due to the check in computeInterestAssetsGivenRate
        unchecked {
            return uint112(prevAssets + interest);
        }
    }

    /**
     * @notice Gets the annual interest rate for a given utilization
     * @dev Same as getAnnualInterestRatePerSecondInWads but without dividing by SECONDS_IN_YEAR
     * @param utilizationInWads The utilization rate in WADs
     * @return interestRate The annual interest rate in WADs
     */
    function getAnnualInterestRatePerSecondInWads(
        uint256 utilizationInWads
    ) internal pure returns (uint256 interestRate) {
        if (utilizationInWads <= OPTIMAL_UTILIZATION) {
            interestRate = utilizationInWads.wMulDown(SLOPE1);
        } else if (utilizationInWads <= DANGER_UTILIZATION) {
            interestRate = (utilizationInWads - OPTIMAL_UTILIZATION).wMulDown(SLOPE2) + BASE_OPTIMAL_UTILIZATION;
        } else {
            interestRate = (utilizationInWads - DANGER_UTILIZATION).wMulDown(SLOPE3) + BASE_DANGER_UTILIZATION;
        }
        interestRate /= SECONDS_IN_YEAR;
    }
}
