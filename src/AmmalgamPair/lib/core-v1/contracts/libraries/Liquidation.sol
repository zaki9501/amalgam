// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {
    BIPS,
    MAG1,
    MAG2,
    ALLOWED_LIQUIDITY_LEVERAGE,
    ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE
} from 'contracts/libraries/constants.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {PartialLiquidations} from 'contracts/libraries/PartialLiquidations.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';
import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {ROUNDING_UP} from 'contracts/interfaces/tokens/ITokenController.sol';

library Liquidation {
    // constants

    uint256 internal constant START_NEGATIVE_PREMIUM_LTV_BIPS = 6000; // == 0.6
    uint256 private constant START_PREMIUM_LTV_BIPS = 7500; // == 0.75
    uint256 private constant NEGATIVE_PREMIUM_SLOPE_IN_BIPS = 66_667; // 20/3
    uint256 private constant NEGATIVE_PREMIUM_INTERCEPT_IN_BIPS = 40_000; // == -4 (subtracted since stored positively)
    uint256 private constant POSITIVE_PREMIUM_SLOPE_IN_BIPS = 7408; // == 20/27
    uint256 private constant POSITIVE_PREMIUM_INTERCEPT_IN_BIPS = 4444; // == 4/9

    /**
     * @notice This factor brings a leveraged position just below the leverage liquidation threshold
     */
    uint256 internal constant LEVERAGE_LIQUIDATION_BREAK_EVEN_FACTOR_MAG2 = 10; // 0.1 MAG2 version

    /**
     * @notice Leverage liquidation factor derived from max allowed leverage scaled by the break-even factor
     */
    uint256 internal constant LEVERAGE_LIQUIDATION_FACTOR =
        ALLOWED_LIQUIDITY_LEVERAGE * MAG2 / LEVERAGE_LIQUIDATION_BREAK_EVEN_FACTOR_MAG2;
    uint256 internal constant MAX_PREMIUM_IN_BIPS = 11_111; // == 10 * BIPS / 9

    uint256 internal constant HARD = 0;
    uint256 internal constant SATURATION = 1;
    uint256 internal constant LEVERAGE = 2;

    // errors

    error LiquidationPremiumTooHigh();
    error LiquidationZeroPremium();
    error NotEnoughRepaidForLiquidation();
    error TooMuchDepositToTransferForLeverageLiquidation();
    error LiquidationMutation();

    function verifyHardLiquidation(
        ISaturationAndGeometricTWAPState saturationState,
        address pairAddress,
        Validation.InputParams memory inputParams,
        uint256[6] memory proposedLiquidation,
        uint256 fragileLiquidityAssets,
        address borrower
    ) external view returns (uint256[6] memory partialLiquidation, bool badDebt) {
        {
            (uint256 netRepaidLAssets, uint256 netSeizedLAssets, bool netDebtX) = calculateNetDebtAndSeizedDeposits(
                proposedLiquidation, inputParams.sqrtPriceMinInQ72, inputParams.sqrtPriceMaxInQ72
            );

            Saturation.Account memory account = saturationState.getAccount(pairAddress, netDebtX, borrower);

            partialLiquidation = PartialLiquidations.calculatePartialLiquidation(
                account.satPairPerTranche,
                account.lastTranche,
                inputParams.userAssets,
                inputParams.activeLiquidityAssets - fragileLiquidityAssets,
                netRepaidLAssets,
                netSeizedLAssets,
                netDebtX
            );
        }

        uint256 maxAllowedPremiumBips = calcHardMaxPremiumInBips(
            partialLiquidation,
            inputParams.activeLiquidityAssets,
            inputParams.sqrtPriceMinInQ72,
            inputParams.sqrtPriceMaxInQ72
        );

        // Premium exceeds max before bad debt and all assets seized.
        badDebt = maxAllowedPremiumBips > MAX_PREMIUM_IN_BIPS
            && (
                partialLiquidation[DEPOSIT_L] == inputParams.userAssets[DEPOSIT_L]
                    && partialLiquidation[DEPOSIT_X] == inputParams.userAssets[DEPOSIT_X]
                    && partialLiquidation[DEPOSIT_Y] == inputParams.userAssets[DEPOSIT_Y]
            );

        if (!badDebt) {
            // Not bad debt.
            // Debt repaid must be equal to or greater than the partial liquidation amount.
            // Deposits seized will be less than or equal the partial liquidation amount.
            // Verifies the repaid amount of each asset to cover the partial liquidation.
            if (
                proposedLiquidation[BORROW_L] < partialLiquidation[BORROW_L]
                    || proposedLiquidation[BORROW_X] < partialLiquidation[BORROW_X]
                    || proposedLiquidation[BORROW_Y] < partialLiquidation[BORROW_Y]
            ) {
                revert NotEnoughRepaidForLiquidation();
            }
            // Verified that proposed deposits do not exceed partial liquidation allowance.
            if (
                proposedLiquidation[DEPOSIT_L] > partialLiquidation[DEPOSIT_L]
                    || proposedLiquidation[DEPOSIT_X] > partialLiquidation[DEPOSIT_X]
                    || proposedLiquidation[DEPOSIT_Y] > partialLiquidation[DEPOSIT_Y]
            ) {
                revert LiquidationMutation();
            }
            // keep the repaid amounts from the partial liquidation and use the proposed deposits.
            partialLiquidation[DEPOSIT_L] = proposedLiquidation[DEPOSIT_L];
            partialLiquidation[DEPOSIT_X] = proposedLiquidation[DEPOSIT_X];
            partialLiquidation[DEPOSIT_Y] = proposedLiquidation[DEPOSIT_Y];
        } else {
            // potential bad debt case.
            // Debt repaid will be less than the partial liquidation amount, deposits will be equal
            // to the partial liquidation amount.
            // Verify that liquidator does not mutate by not seizing enough of one asset and more
            // of another.
            // Do not allow a liquidator to skip any borrow leg held by the borrower.
            // Bad debt burns the borrower's full token balance after this validation.
            if (
                (
                    proposedLiquidation[BORROW_L] > partialLiquidation[BORROW_L]
                        || proposedLiquidation[BORROW_X] > partialLiquidation[BORROW_X]
                        || proposedLiquidation[BORROW_Y] > partialLiquidation[BORROW_Y]
                ) || (proposedLiquidation[BORROW_L] == 0 && partialLiquidation[BORROW_L] > 0)
                    || (proposedLiquidation[BORROW_X] == 0 && partialLiquidation[BORROW_X] > 0)
                    || (proposedLiquidation[BORROW_Y] == 0 && partialLiquidation[BORROW_Y] > 0)
            ) {
                revert LiquidationMutation();
            }
            // keep the deposit amount from the partial liquidation and use the proposed repaid amounts.
            partialLiquidation[BORROW_L] = proposedLiquidation[BORROW_L];
            partialLiquidation[BORROW_X] = proposedLiquidation[BORROW_X];
            partialLiquidation[BORROW_Y] = proposedLiquidation[BORROW_Y];
        }

        (uint256 netDebtRepaidInLAssets, uint256 netDepositsSeizedInLAssets,) = calculateNetDebtAndSeizedDeposits(
            partialLiquidation, inputParams.sqrtPriceMinInQ72, inputParams.sqrtPriceMaxInQ72
        );

        checkHardPremiums(netDebtRepaidInLAssets, netDepositsSeizedInLAssets, maxAllowedPremiumBips);
    }

    function checkHardPremiums(
        uint256 repaidDebtInL,
        uint256 seizedCollateralValueInL,
        uint256 maxAllowedPremiumBips
    ) internal pure {
        uint256 premiumInBips = calcHardPremiumInBips(repaidDebtInL, seizedCollateralValueInL);

        if (maxAllowedPremiumBips < premiumInBips) revert LiquidationPremiumTooHigh();
    }

    function calculateNetDebtAndSeizedDeposits(
        uint256[6] memory proposedLiquidation,
        uint256 sqrtPriceMinInQ72,
        uint256 sqrtPriceMaxInQ72
    ) internal pure returns (uint256 netDebtInLAssets, uint256 netCollateralInLAssets, bool netDebtX) {
        // swap min and max
        Validation.CheckLtvParams memory checkLtvParams =
            Validation.getCheckLtvParams(proposedLiquidation, sqrtPriceMaxInQ72, sqrtPriceMinInQ72);
        (netDebtInLAssets, netCollateralInLAssets, netDebtX) = Validation.calcDebtAndCollateral(checkLtvParams);
    }

    function checkSaturationPremiums(
        ISaturationAndGeometricTWAPState saturationAndGeometricTWAPState,
        Validation.InputParams memory inputParams,
        address borrower
    ) external view returns (uint256 seizeLAssets, uint256 seizeXAssets, uint256 seizeYAssets) {
        uint256 premiumInBips = calcSaturationMaxPremiumInBips(saturationAndGeometricTWAPState, inputParams, borrower);

        if (premiumInBips == 0) {
            revert LiquidationZeroPremium();
        }

        (seizeLAssets, seizeXAssets, seizeYAssets) = calcSaturationSeizedAssets(
            inputParams.userAssets[DEPOSIT_L],
            inputParams.userAssets[DEPOSIT_X],
            inputParams.userAssets[DEPOSIT_Y],
            premiumInBips
        );
    }

    /**
     * @notice Calculate weighted leverage liquidation repayments and seized deposits.
     * @dev The first three return indices are seized deposits, the last three are required
     *   repayments, and all values are in each token's native units. The formula for the premium
     *   is calculated with the average net borrow of X and Y $$B$$ and the net deposit of X and Y
     *   $$D$$ and a scaler $$S$$ that sets the pace at which the premium increased, in code we
     *   call this `LEVERAGE_LIQUIDATION_BREAK_EVEN_FACTOR_MAG2`, and allowed leverage $$AL$$,
     *   `ALLOWED_LIQUIDITY_LEVERAGE`:
     *   ```math
     *   premium = \begin{cases}
     *     S \left(
     *       \frac{B}{D}
     *       - \frac{AL - 1}{AL}
     *     \right)
     *     \text { if } \frac{B}{D} >
     *       \frac{AL - 1}{AL} \\
     *     0 \text { otherwise }
     *   \end{cases}
     *   ```
     *
     *   This can be visualized [here](https://www.desmos.com/calculator/1cd55f1yhz).
     *
     *   The premium is a percentage of the total deposit. If the premium is low enough, then we
     *   we attempt to deleverage the position such that the premium and closed part of the
     *   position leaves it under the leveraged threshold. If this is not possible, then all of the
     *   users deposit will be transferred to the liquidator and there will be bad debt.
     *
     *   Note that the de leveraging relies on the min and max tick to be equal, so the result may
     *   not be a valid amount of leverage using a min and max price as is done in the Validation
     *   library.
     *
     * @param inputParams The params representing the position of the borrower.
     * @return leveragedLiquidationParams Array indexed by DEPOSIT_L, DEPOSIT_X, DEPOSIT_Y,
     *   BORROW_L, BORROW_X, BORROW_Y.
     * @return badDebt Whether the leverage liquidation leaves bad debt to burn.
     */
    function liquidateLeverageCalcDeltaAndPremium(
        Validation.InputParams memory inputParams
    ) external pure returns (uint256[6] memory leveragedLiquidationParams, bool badDebt) {
        uint256 netDepositInLAssets;
        uint256 netBorrowInLAssets;

        // we use the averageSqrtPrice for conversion between L and X/Y assets
        uint256 averageSqrtPrice = Math.sqrt(inputParams.sqrtPriceMinInQ72 * inputParams.sqrtPriceMaxInQ72);

        // overestimates borrow and underestimates deposit as we do in validation
        Validation.CheckLtvParams memory checkLtvParams =
            Validation.getCheckLtvParams(inputParams.userAssets, averageSqrtPrice, averageSqrtPrice);

        {
            // We average the two since both are in L assets.
            netDepositInLAssets = (checkLtvParams.netDepositedXinLAssets + checkLtvParams.netDepositedYinLAssets) / 2;
            netBorrowInLAssets = (checkLtvParams.netBorrowedXinLAssets + checkLtvParams.netBorrowedYinLAssets) / 2;
        }

        if (
            // guarantee that premium > 0;
            ALLOWED_LIQUIDITY_LEVERAGE * netBorrowInLAssets
                > ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE * netDepositInLAssets + LEVERAGE_LIQUIDATION_FACTOR
        ) {
            uint256 premiumValueInLAssets = (
                ALLOWED_LIQUIDITY_LEVERAGE * netBorrowInLAssets
                    - ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE * netDepositInLAssets
            ) / LEVERAGE_LIQUIDATION_FACTOR;

            uint256 totalRepayInLAssets;
            uint256 remainingDepositAfterPremium;
            if (netDepositInLAssets < premiumValueInLAssets) {
                // extreme, unlikely, case when the premium is greater than all deposits
                premiumValueInLAssets = netDepositInLAssets;
            } else {
                // start close assets as the remaining deposits after premium.
                remainingDepositAfterPremium = netDepositInLAssets - premiumValueInLAssets;
            }

            if (netBorrowInLAssets < remainingDepositAfterPremium) {
                // the position can be de leveraged to meet leverage requirements.
                totalRepayInLAssets = remainingDepositAfterPremium
                    - ALLOWED_LIQUIDITY_LEVERAGE * (remainingDepositAfterPremium - netBorrowInLAssets);
            } else {
                totalRepayInLAssets = remainingDepositAfterPremium;
                badDebt = true;
            }

            uint256 totalSeizedInLAssets = totalRepayInLAssets + premiumValueInLAssets;

            leveragedLiquidationParams[DEPOSIT_L] = calculateLeverageLiquidationAsset(
                inputParams.userAssets[DEPOSIT_L], totalSeizedInLAssets, netDepositInLAssets, !ROUNDING_UP
            );
            leveragedLiquidationParams[DEPOSIT_X] = calculateLeverageLiquidationAsset(
                inputParams.userAssets[DEPOSIT_X], totalSeizedInLAssets, netDepositInLAssets, !ROUNDING_UP
            );
            leveragedLiquidationParams[DEPOSIT_Y] = calculateLeverageLiquidationAsset(
                inputParams.userAssets[DEPOSIT_Y], totalSeizedInLAssets, netDepositInLAssets, !ROUNDING_UP
            );
            leveragedLiquidationParams[BORROW_L] = calculateLeverageLiquidationAsset(
                inputParams.userAssets[BORROW_L], totalRepayInLAssets, netBorrowInLAssets, ROUNDING_UP
            );
            leveragedLiquidationParams[BORROW_X] = calculateLeverageLiquidationAsset(
                inputParams.userAssets[BORROW_X], totalRepayInLAssets, netBorrowInLAssets, ROUNDING_UP
            );
            leveragedLiquidationParams[BORROW_Y] = calculateLeverageLiquidationAsset(
                inputParams.userAssets[BORROW_Y], totalRepayInLAssets, netBorrowInLAssets, ROUNDING_UP
            );
        } else {
            revert LiquidationZeroPremium();
        }
    }

    /**
     * @notice Calculate the amount of an asset to be liquidated in a leverage liquidation.
     * @dev we use the min so amounts don't exceed balances
     * @param userAsset The amount of the asset held by the user.
     * @param totalShareLAsset The portion getting seized or repaid in L assets, or fraction of the total borrowed l or deposited l respectively.
     * @param totalLAsset The total borrowed l or deposited l respectively.
     * @param rounding Whether to round up the result, we round up for the borrow legs to make sure enough is repaid to cover the seized deposits.
     */
    function calculateLeverageLiquidationAsset(
        uint256 userAsset,
        uint256 totalShareLAsset,
        uint256 totalLAsset,
        bool rounding
    ) internal pure returns (uint256) {
        return Math.min(
            userAsset,
            Math.mulDiv(userAsset, totalShareLAsset, totalLAsset, rounding ? Math.Rounding.Ceil : Math.Rounding.Floor)
        );
    }

    /**
     * @notice Calculate the maximum premium the liquidator may receive given the LTV of the borrower.
     * @dev We min the result to favor the borrower.
     * @return maxPremiumInBips The max premium allowed to be received by the liquidator.
     */
    function calcHardMaxPremiumInBips(
        uint256[6] memory validatedLiquidation,
        uint256 activeLiquidityAssets,
        uint256 sqrtPriceMinInQ72,
        uint256 sqrtPriceMaxInQ72
    ) internal pure returns (uint256 maxPremiumInBips) {
        // Calculate max premium before repay, swap min and max
        Validation.CheckLtvParams memory checkLtvParams =
            Validation.getCheckLtvParams(validatedLiquidation, sqrtPriceMaxInQ72, sqrtPriceMinInQ72);

        (uint256 netDebtInLAssets, uint256 netCollateralInLAssets,) = Validation.calcDebtAndCollateral(checkLtvParams);

        netDebtInLAssets = Validation.increaseForSlippage(netDebtInLAssets, activeLiquidityAssets);

        maxPremiumInBips = convertLtvToPremium(
            0 < netCollateralInLAssets ? Convert.mulDiv(netDebtInLAssets, BIPS, netCollateralInLAssets, false) : 0
        );
    }

    /**
     * @notice Calculate the premium being afforded to the liquidator given the repay and depositToTransfer amounts.
     * @dev We use prices to maximize the `premiumInBips` to favor the borrower
     * @param repaidDebtInL The amount of debt being repaid in L assets.
     * @param seizedCollateralValueInL The value of the collateral being seized in L assets.
     * @return premiumInBips The premium being received by the liquidator.
     */
    function calcHardPremiumInBips(
        uint256 repaidDebtInL,
        uint256 seizedCollateralValueInL
    ) internal pure returns (uint256 premiumInBips) {
        // If nothing is being or can be liquidated, premium is infinite, we will revert
        if (repaidDebtInL == 0) {
            return type(uint256).max;
        }

        // Calculate premium in bips
        unchecked {
            premiumInBips = Convert.mulDiv(seizedCollateralValueInL, BIPS, repaidDebtInL, ROUNDING_UP);
        }
    }

    /**
     * @notice Calculates the maximum premium the liquidator should receive based on borrower LTV.
     *   `ltvBips` and the returned premium are both denominated in bips. Let `l` be
     *   `ltvBips`, `a` and `b` be the two LTV thresholds, `m` be a slope, and `c` be an
     *   intercept. The negative-premium segment uses `m_-` and `c_-`; the positive-premium
     *   segment uses `m_+` and `c_+`.
     *
     *   ```math
     *   P(l)=
     *   \begin{cases}
     *     0
     *       & l \le a \\
     *     \left\lfloor\frac{m_{-}\cdot l}{BIPS}\right\rfloor-c_{-}
     *       & a < l < b \\
     *     \left\lfloor\frac{m_{+}\cdot l}{BIPS}\right\rfloor+c_{+}
     *       & b \le l
     *   \end{cases}
     *   ```
     * @dev internal for testing only
     * @param ltvBips LTV of the borrower.
     * @return maxPremiumInBips The maximum premium for the liquidator.
     */
    function convertLtvToPremium(
        uint256 ltvBips
    ) internal pure returns (uint256 maxPremiumInBips) {
        if (ltvBips > START_NEGATIVE_PREMIUM_LTV_BIPS) {
            if (ltvBips < START_PREMIUM_LTV_BIPS) {
                // negative premium <=> maxPremiumInBips < 1
                // linear function going thru (START_NEGATIVE_PREMIUM_LTV_BIPS, 0) and (START_PREMIUM_LTV_BIPS, 1)
                maxPremiumInBips = Convert.mulDiv(NEGATIVE_PREMIUM_SLOPE_IN_BIPS, ltvBips, BIPS, false)
                    - NEGATIVE_PREMIUM_INTERCEPT_IN_BIPS;
            } else {
                // positive premium <=> 1 <= maxPremiumInBips
                // linear function going thru (START_PREMIUM_LTV_BIPS, 1) and (0.9, 1/0.9)
                maxPremiumInBips = Convert.mulDiv(POSITIVE_PREMIUM_SLOPE_IN_BIPS, ltvBips, BIPS, false)
                    + POSITIVE_PREMIUM_INTERCEPT_IN_BIPS;
            }
        }
    }

    // saturation liquidation

    function calcSaturationSeizedAssets(
        uint256 depositedLAssets,
        uint256 depositedXAssets,
        uint256 depositedYAssets,
        uint256 premiumInBips
    ) internal pure returns (uint256 seizedLAssets, uint256 seizedXAssets, uint256 seizedYAssets) {
        seizedLAssets = depositedLAssets * premiumInBips / BIPS;
        seizedXAssets = depositedXAssets * premiumInBips / BIPS;
        seizedYAssets = depositedYAssets * premiumInBips / BIPS;
    }

    /**
     * @notice Calculate the max premium the saturation liquidator can receive given position of
     *         `account`.
     * @param saturationAndGeometricTWAPState The contract containing the saturation state.
     * @param inputParams The params containing the position of `account`.
     * @param account The account of the borrower.
     * @return maxPremiumBips The max premium for the liquidator.
     */
    function calcSaturationMaxPremiumInBips(
        ISaturationAndGeometricTWAPState saturationAndGeometricTWAPState,
        Validation.InputParams memory inputParams,
        address account
    ) internal view returns (uint256 maxPremiumBips) {
        // calculate ratio of new sat vs old sat
        (uint256 netXLiqSqrtPriceInXInQ72, uint256 netYLiqSqrtPriceInXInQ72) =
            Saturation.calcLiqSqrtPriceQ72(inputParams.userAssets);

        // use max of netX vs netY
        uint256 ratioBips;
        if (0 < netXLiqSqrtPriceInXInQ72 || 0 < netYLiqSqrtPriceInXInQ72) {
            ratioBips = saturationAndGeometricTWAPState.calcSatChangeRatioBips(
                inputParams, netXLiqSqrtPriceInXInQ72, netYLiqSqrtPriceInXInQ72, address(this), account
            );
        }

        // if the saturation has decreased, no saturation liquidation (maxPremium == 0)
        if (ratioBips < BIPS) return 0;

        // calculate premium
        unchecked {
            maxPremiumBips = (ratioBips - BIPS) / MAG1;
        }
    }
}
