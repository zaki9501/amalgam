// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {
    BIPS,
    EXPECTED_SATURATION_LTV_MAG2,
    MAG2,
    MAX_SATURATION_RATIO_IN_MAG2,
    TRANCHE_B_IN_Q72,
    TRANCHE_B_MINUS_ONE_IN_Q72,
    Q72,
    Q144
} from 'contracts/libraries/constants.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';
import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {Validation} from 'contracts/libraries/Validation.sol';

/**
 * @title PartialLiquidations
 * @notice We allow liquidations to happen in parts when the position is spread across more than
 *   one tranche. These partial liquidations allow the liquidator to specify how many tranches they
 *   are liquidating based on how much they are repaying. Smaller slices start with the tranche range
 *   closest to the current price and move outward, so the slice reaches expected LTV before the full
 *   position on the same debt side does. In most cases, one tranche will be liquidated at one time,
 *   but in some cases, a sliver of liquidity in the first tranche may not be worth the cost to
 *   liquidate until it and the next tranche have become profitable to liquidate.
 *
 *   Once we determine the number of tranches to liquidate, we build the liquidated slice from the
 *   debt side first. L uses a weight because both deposit and borrow L can be included together;
 *   the opposing side is then solved directly so the slice lands on the expected liquidation LTV.
 *
 *   A partial liquidation splits the signed position into the liquidated slice and the remaining
 *   position:
 *
 *  ```math
 *   P_0=P_\Delta+P_1,
 *   \qquad
 *   P_0=[L_0,X_0,Y_0],
 *   \qquad
 *   P_\Delta=[L_\Delta,X_\Delta,Y_\Delta]
 *   ```
 *
 *   The slice must preserve component signs, must not exceed the original component magnitudes, and
 *   must have exact expected liquidation LTV at the slice square-root price `s_delta`. The whole
 *   position and the remaining position do not need to have the same LTV as the liquidated slice.
 *
 *   Signed components are net deposits minus borrows:
 *
 *   ```math
 *   \begin{align}
 *     L_0 &= depositL - borrowL \\
 *     X_0 &= depositX - borrowX \\
 *     Y_0 &= depositY - borrowY
 *   \end{align}
 *   ```
 *
 *   The slice is constructed from the debt-side component first. Throughout this library, `s` is
 *   a square-root price, not a price. At square-root price `s`, X is measured in L as `X / s` and
 *   Y is measured in L as `Y * s`.
 *
 *   Let `k` be the unscaled expected liquidation LTV:
 *
 *   ```math
 *   k=EXPECTED\_SATURATION\_LTV
 *   ```
 *
 *   In code, `k` is represented by `EXPECTED_SATURATION_LTV_MAG2 / MAG2`.
 *
 *   In signed slice notation, repaid debt components are negative and seized collateral components
 *   are positive. For net debt X, the exact-LTV slice condition is:
 *
 *   ```math
 *   k=\dfrac{-X_\Delta/s_\Delta-L_\Delta}{L_\Delta+Y_\Delta s_\Delta}
 *   ```
 *
 *   The net debt Y equations are symmetric:
 *
 *   ```math
 *   k=\dfrac{-Y_\Delta s_\Delta-L_\Delta}{L_\Delta+X_\Delta/s_\Delta}
 *   ```
 *
 */
library PartialLiquidations {
    int256 internal constant MAG2_INT = int256(MAG2);

    struct LoopMemoryState {
        uint256 satArrayLength;
        uint256 partialSatInLAssets;
        uint256 includedTranches;
        uint256 partialSatLimit;
    }

    /**
     * @notice Calculates the partial liquidation slice for the tranches covered by the repayment.
     * @dev Returns the full user asset array when every tranche is included. Returns the zero array
     *   when no L-denominated debt is repaid. The tranche count is chosen from absolute
     *   `satInLAssets`, while the slice geometry uses the corresponding relative saturation values.
     * @param satPairPerTranche Saturation entries for the borrower, ordered from the end of
     *   liquidation toward the start of liquidation.
     * @param lastTranche Last tranche occupied by the borrower in the liquidation direction.
     * @param userAssets Borrower assets in `[depositL, depositX, depositY, borrowL, borrowX, borrowY]` order.
     * @param activeLiquidityAssets Active liquidity used to scale tranche saturation.
     * @param netRepaidLAssets Net debt repaid by the liquidator, denominated in L.
     * @param netSeizedLAssets Net collateral seized by the liquidator, denominated in L.
     * @param netDebtX Whether the liquidation repays net X debt. If false, it repays net Y debt.
     * @return liquidation Component-bounded asset amounts to remove from the borrower.
     */
    function calculatePartialLiquidation(
        Saturation.SaturationPair[] memory satPairPerTranche,
        int16 lastTranche,
        uint256[6] memory userAssets,
        uint256 activeLiquidityAssets,
        uint256 netRepaidLAssets,
        uint256 netSeizedLAssets,
        bool netDebtX
    ) internal pure returns (uint256[6] memory liquidation) {
        if (netRepaidLAssets > 0) {
            uint256 partialSaturation;
            uint256 totalSaturation;
            uint256 remainingTranches;

            {
                LoopMemoryState memory loopMem = LoopMemoryState({
                    satArrayLength: satPairPerTranche.length,
                    partialSatInLAssets: 0,
                    includedTranches: 0,
                    partialSatLimit: Math.max(netRepaidLAssets, netSeizedLAssets * EXPECTED_SATURATION_LTV_MAG2 / MAG2)
                });

                uint256 bFactor = Q72;

                for (uint256 i = loopMem.satArrayLength; i > 0; --i) {
                    Saturation.SaturationPair memory borrowerTranche = satPairPerTranche[i - 1];
                    uint256 satInRelativeLAssets = borrowerTranche.satRelativeToL * Q72 / bFactor;
                    bFactor = bFactor * TRANCHE_B_IN_Q72 / Q72;

                    if (loopMem.partialSatLimit > loopMem.partialSatInLAssets) {
                        loopMem.includedTranches++;
                        partialSaturation += satInRelativeLAssets;
                    }
                    totalSaturation += satInRelativeLAssets;

                    // measure saturation
                    loopMem.partialSatInLAssets += borrowerTranche.satInLAssets;
                }

                if (loopMem.includedTranches == loopMem.satArrayLength) {
                    return userAssets;
                }
                remainingTranches = loopMem.satArrayLength - loopMem.includedTranches;
            }
            int16 adjTick = int16(uint16(remainingTranches));
            uint256 sqrtPriceQ72 = TickMath.getSqrtPriceAtTick(
                (netDebtX ? lastTranche + adjTick : lastTranche + 1 - adjTick) * int16(Saturation.TICKS_PER_TRANCHE)
            );

            liquidation = calcMutation(
                userAssets, sqrtPriceQ72, partialSaturation, totalSaturation, activeLiquidityAssets, netDebtX
            );
        }
    }

    // helpers

    /**
     * @notice Builds a liquidation slice from raw tranche-boundary and saturation inputs.
     *   It derives the target square-root price and asset weights from the same saturation window,
     *   applies L through a shared weight, then solves the deposit-side delta directly from the
     *   exact-LTV equation.
     *
     *   The target slice square-root price is the selected tranche boundary moved by the start
     *   weight from the same saturation walk:
     *
     *   ```math
     *   s_\Delta=b^T\sqrt{w_s}
     *   ```
     *
     *   In signed notation, the debt-side slice then fixes one raw borrow amount:
     *
     *   ```math
     *   X_\Delta=-borrowX\cdot w_X
     *     \qquad \text{for net debt X}
     *   ```
     *
     *   ```math
     *   Y_\Delta=-borrowY\cdot w_Y
     *     \qquad \text{for net debt Y}
     *   ```
     *
     *   L is selected next. The remaining side is solved last from the exact-LTV equation and may be
     *   either collateral seized or same-side borrow repaid, depending on the sign of the solved
     *   delta.
     * @param userAssets Borrower assets in `[depositL, depositX, depositY, borrowL, borrowX, borrowY]` order.
     * @param trancheBoundarySqrtPriceQ72 Boundary sqrt price for the tranche adjacent to the included slice.
     * @param partialSaturation Relative saturation included in the partial liquidation.
     * @param totalSaturation Total relative borrower saturation across all tranches.
     * @param activeLiquidityAssets Active liquidity used to scale tranche saturation.
     * @param netDebtX Whether the debt side is X. If false, the debt side is Y.
     * @return liquidation Component-bounded asset amounts to remove from the borrower.
     */
    function calcMutation(
        uint256[6] memory userAssets,
        uint256 trancheBoundarySqrtPriceQ72,
        uint256 partialSaturation,
        uint256 totalSaturation,
        uint256 activeLiquidityAssets,
        bool netDebtX
    ) internal pure returns (uint256[6] memory liquidation) {
        uint256 debtSideWeightQ72;
        uint256 targetLiquidationSqrtPriceQ72;
        {
            uint256 sqrtStartWeightQ72 = calcSqrtStartWeightQ72(partialSaturation, activeLiquidityAssets, netDebtX);

            uint256 sqrtEndWeightQ72 =
                calcSqrtEndWeightQ72(partialSaturation, totalSaturation, activeLiquidityAssets, netDebtX);

            debtSideWeightQ72 = calcDebtSideWeightQ72(sqrtStartWeightQ72, sqrtEndWeightQ72, netDebtX);

            targetLiquidationSqrtPriceQ72 = trancheBoundarySqrtPriceQ72 * sqrtStartWeightQ72 / Q72;
        }

        uint256 debtSideDelta = Convert.mulDiv(userAssets[netDebtX ? BORROW_X : BORROW_Y], debtSideWeightQ72, Q72, true);

        int256 lDelta;
        {
            uint256 lWeightQ72 =
                calcLWeightQ72(userAssets, debtSideWeightQ72, debtSideDelta, targetLiquidationSqrtPriceQ72, netDebtX);

            lDelta = applyLMutation(liquidation, userAssets, lWeightQ72);
        }

        {
            int256 remainingSideDelta =
                calcRemainingSideDelta(debtSideDelta, lDelta, targetLiquidationSqrtPriceQ72, netDebtX);

            if (netDebtX) {
                liquidation[BORROW_X] = debtSideDelta;
                applyRemainingSideDelta(liquidation, userAssets, remainingSideDelta, DEPOSIT_Y, BORROW_Y);
            } else {
                liquidation[BORROW_Y] = debtSideDelta;
                applyRemainingSideDelta(liquidation, userAssets, remainingSideDelta, DEPOSIT_X, BORROW_X);
            }
        }
    }

    /**
     * @notice Applies the L weight to both L legs and returns the resulting signed L delta.
     *   The raw L legs are both included at the same weight:
     *
     *   ```math
     *   depositL_{\Delta}=depositL\cdot w_L,\qquad borrowL_{\Delta}=borrowL\cdot w_L
     *   ```
     *
     *   The signed L contribution is:
     *
     *   ```math
     *   L_{\Delta}=depositL_{\Delta}-borrowL_{\Delta}
     *   ```
     * @param liquidation Liquidation array being built.
     * @param userAssets Borrower assets in `[depositL, depositX, depositY, borrowL, borrowX, borrowY]` order.
     * @param lWeightQ72 Q72 weight to apply to deposit L and borrow L.
     * @return lDelta Signed L contribution of the liquidated slice.
     */
    function applyLMutation(
        uint256[6] memory liquidation,
        uint256[6] memory userAssets,
        uint256 lWeightQ72
    ) private pure returns (int256 lDelta) {
        liquidation[DEPOSIT_L] = Convert.mulDiv(userAssets[DEPOSIT_L], lWeightQ72, Q72, false);
        liquidation[BORROW_L] = Convert.mulDiv(userAssets[BORROW_L], lWeightQ72, Q72, true);

        lDelta = int256(liquidation[DEPOSIT_L]) - int256(liquidation[BORROW_L]);
    }

    /**
     * @notice Calculates the saturation-derived weight for the debt-side borrow asset.
     *   The selected debt-side weight is:
     *
     *   ```math
     *   w_{debt}=
     *   \begin{cases}
     *     w_X & \text{if net debt X} \\
     *     w_Y & \text{if net debt Y}
     *   \end{cases}
     *   ```
     * @param sqrtStartWeightQ72 Start sqrt weight of the included saturation window.
     * @param sqrtEndWeightQ72 End sqrt weight of the included saturation window.
     * @param netDebtX Whether the debt side is X. If false, the debt side is Y.
     * @return debtSideWeightQ72 Q72 weight applied to the debt-side borrow amount.
     */
    function calcDebtSideWeightQ72(
        uint256 sqrtStartWeightQ72,
        uint256 sqrtEndWeightQ72,
        bool netDebtX
    ) private pure returns (uint256 debtSideWeightQ72) {
        uint256 xWeightQ72 = calcXWeightQ72(sqrtStartWeightQ72, sqrtEndWeightQ72);
        debtSideWeightQ72 = netDebtX ? xWeightQ72 : calcYWeightQ72(xWeightQ72, sqrtEndWeightQ72);
    }

    /**
     * @notice Applies the signed remaining-side delta to the matching deposit or borrow leg.
     *   Positive deltas seize remaining-side collateral. Negative deltas repay borrow on that side.
     *   Partial borrow repayment is valid as long as it is not greater than the starting borrow.
     *
     *   ```math
     *   R_\Delta>0 \Rightarrow deposit_\Delta=\min(R_\Delta, deposit)
     *   ```
     *
     *   ```math
     *   R_\Delta<0 \Rightarrow borrow_\Delta=\min(-R_\Delta, borrow)
     *   ```
     * @param liquidation Liquidation array being built.
     * @param userAssets Borrower assets in `[depositL, depositX, depositY, borrowL, borrowX, borrowY]` order.
     * @param remainingSideDelta Signed amount for the side opposite the fixed debt-side borrow.
     * @param depositIndex Deposit token index for the remaining side.
     * @param borrowIndex Borrow token index for the remaining side.
     */
    function applyRemainingSideDelta(
        uint256[6] memory liquidation,
        uint256[6] memory userAssets,
        int256 remainingSideDelta,
        uint256 depositIndex,
        uint256 borrowIndex
    ) private pure {
        if (remainingSideDelta > 0) {
            liquidation[depositIndex] = Math.min(uint256(remainingSideDelta), userAssets[depositIndex]);
        } else if (remainingSideDelta < 0) {
            liquidation[borrowIndex] = Math.min(uint256(-remainingSideDelta), userAssets[borrowIndex]);
        }
    }

    /**
     * @notice Solves the signed remaining-side delta for the fixed debt-side repayment.
     *   The returned delta is positive when the slice must seize deposit-side collateral and
     *   negative when it must repay borrow on that side to land on expected LTV.
     *
     *   For net debt X, define the fixed X-side debt value in L-units:
     *
     *   ```math
     *   debtSideValueInL=-\frac{X_\Delta}{s_\Delta}=\frac{borrowX_\Delta}{s_\Delta}
     *   ```
     *
     *   Then:
     *
     *   ```math
     *   Y_\Delta=\dfrac{debtSideValueInL-(1+k)L_\Delta}{ks_\Delta}
     *   ```
     *
     *   For net debt Y, define the fixed Y-side debt value in L-units:
     *
     *   ```math
     *   debtSideValueInL=-Y_\Delta s_\Delta=borrowY_\Delta s_\Delta
     *   ```
     *
     *   Then:
     *
     *   ```math
     *   X_\Delta=\dfrac{s_\Delta(debtSideValueInL-(1+k)L_\Delta)}{k}
     *   ```
     * @param borrowDelta Final debt-side borrow amount repaid by the liquidation.
     * @param lDelta Signed L contribution already included in the liquidation.
     * @param sqrtPriceQ72 Target liquidation sqrt price for the slice.
     * @param netDebtX Whether the debt side is X. If false, the debt side is Y.
     * @return remainingSideDelta Signed delta for the remaining side.
     */
    function calcRemainingSideDelta(
        uint256 borrowDelta,
        int256 lDelta,
        uint256 sqrtPriceQ72,
        bool netDebtX
    ) private pure returns (int256 remainingSideDelta) {
        uint256 debtSideValueInL = netDebtX
            ? Convert.mulDiv(borrowDelta, Q72, sqrtPriceQ72, false)
            : Convert.mulDiv(borrowDelta, sqrtPriceQ72, Q72, false);

        int256 numerator =
            int256(debtSideValueInL) * MAG2_INT - lDelta * int256(Saturation.EXPECTED_SATURATION_LTV_PLUS_ONE_MAG2);
        uint256 mulFactor = netDebtX ? Q72 : sqrtPriceQ72;
        uint256 denominator = EXPECTED_SATURATION_LTV_MAG2 * (netDebtX ? sqrtPriceQ72 : Q72);
        remainingSideDelta = numerator >= 0
            ? int256(Convert.mulDiv(uint256(numerator), mulFactor, denominator, false))
            : -int256(Convert.mulDiv(uint256(-numerator), mulFactor, denominator, true));
    }

    /**
     * @notice Calculates the partial liquidation weight for asset X.
     *   In unscaled terms, `sqrtStartWeightQ72` is $\sqrt{w_s}$ and
     *   `sqrtEndWeightQ72` is $\sqrt{w_e}$. The branch matches which side of
     *   one the saturation window starts on:
     *
     *   ```math
     *   w_X =
     *   \begin{cases}
     *     \dfrac{\sqrt{w_s}-1}{\sqrt{w_s}-\sqrt{w_e}} & \text{if } \sqrt{w_s}>1 \\
     *     \dfrac{1-\sqrt{w_s}}{\sqrt{w_e}-\sqrt{w_s}} & \text{otherwise}
     *   \end{cases}
     *   ```
     * @param sqrtStartWeightQ72 Q72 start sqrt weight for the included saturation window.
     * @param sqrtEndWeightQ72 Q72 end sqrt weight for the included saturation window.
     * @return xWeightQ72 Q72 weight for asset X.
     */
    function calcXWeightQ72(
        uint256 sqrtStartWeightQ72,
        uint256 sqrtEndWeightQ72
    ) private pure returns (uint256 xWeightQ72) {
        if (sqrtStartWeightQ72 > Q72) {
            xWeightQ72 = (sqrtStartWeightQ72 - Q72) * Q72 / (sqrtStartWeightQ72 - sqrtEndWeightQ72);
        } else {
            xWeightQ72 = (Q72 - sqrtStartWeightQ72) * Q72 / (sqrtEndWeightQ72 - sqrtStartWeightQ72);
        }
    }

    /**
     * @notice Calculates the partial liquidation weight for asset Y.
     *   Formula for `w_Y`:
     *  ```math
     *  \begin{equation}
     *    w_Y = \sqrt{w_e} \cdot w_X
     *  \end{equation}
     *  ```
     * @param weightXQ72 Q72 weight for asset X.
     * @param sqrtEndWeightQ72 Q72 end sqrt weight for the included saturation window.
     * @return yWeightQ72 Q72 weight for asset Y.
     */
    function calcYWeightQ72(uint256 weightXQ72, uint256 sqrtEndWeightQ72) private pure returns (uint256 yWeightQ72) {
        yWeightQ72 = sqrtEndWeightQ72 * weightXQ72 / Q72;
    }

    /**
     * @notice Calculates the partial liquidation weight for asset L from the debt-side slice.
     *   Net-zero L is omitted. Net-borrow L uses the debt-side weight. Net-deposit L
     *   chooses the lower feasible L endpoint implied by the fixed debt-side repayment.
     *
     *   For net-borrow L:
     *
     *   ```math
     *   L_\Delta=L_0\cdot w_{debt}
     *   ```
     *
     *   For net-deposit L, L is the free collateral-side variable:
     *
     *   ```math
     *   0 \le L_\Delta \le L_0
     *   ```
     *
     *   Let `debtSideValueInL` be the fixed debt-side value and `remainingCollateralInL` be the
     *   remaining positive deposit-side collateral, both in L-units:
     *
     *   ```math
     *   debtSideValueInL=
     *   \begin{cases}
     *     \dfrac{borrowX_\Delta}{s_\Delta} & \text{if net debt X} \\
     *     borrowY_\Delta s_\Delta & \text{if net debt Y}
     *   \end{cases}
     *   ```
     *
     *   ```math
     *   remainingCollateralInL=
     *   \begin{cases}
     *     (depositY-borrowY)s_\Delta & \text{if net debt X and } depositY>borrowY \\
     *     \dfrac{depositX-borrowX}{s_\Delta} & \text{if net debt Y and } depositX>borrowX \\
     *     0 & \text{otherwise}
     *   \end{cases}
     *   ```
     *
     *   Exact LTV gives the lower feasible endpoint. Only positive remaining-side collateral changes
     *   that endpoint; zero or net-borrow remaining-side value uses the same lower bound:
     *
     *   ```math
     *   L_\Delta=\max\left(0,\frac{debtSideValueInL-k\cdot remainingCollateralInL}{1+k}\right)
     *     \qquad \text{when } remainingCollateralInL>0
     *   ```
     *
     *   ```math
     *   L_\Delta=\frac{debtSideValueInL}{1+k}
     *     \qquad \text{when } remainingCollateralInL=0
     *   ```
     * @param userAssets Borrower assets in `[depositL, depositX, depositY, borrowL, borrowX, borrowY]` order.
     * @param debtSideWeightQ72 Q72 weight applied to the debt-side borrow amount.
     * @param debtSideDelta Final debt-side borrow amount repaid by the liquidation.
     * @param targetLiquidationSqrtPriceQ72 Target liquidation sqrt price for the slice.
     * @param netDebtX Whether the debt side is X. If false, the debt side is Y.
     * @return lWeightQ72 Q72 weight applied to deposit L and borrow L.
     */
    function calcLWeightQ72(
        uint256[6] memory userAssets,
        uint256 debtSideWeightQ72,
        uint256 debtSideDelta,
        uint256 targetLiquidationSqrtPriceQ72,
        bool netDebtX
    ) private pure returns (uint256 lWeightQ72) {
        int256 netL = int256(userAssets[DEPOSIT_L]) - int256(userAssets[BORROW_L]);

        if (netL == 0) {
            lWeightQ72 = 0;
        } else if (netL < 0) {
            lWeightQ72 = debtSideWeightQ72;
        } else {
            uint256 debtSideAssetsInL = netDebtX
                ? Convert.mulDiv(debtSideDelta, Q72, targetLiquidationSqrtPriceQ72, false)
                : Convert.mulDiv(debtSideDelta, targetLiquidationSqrtPriceQ72, Q72, false);

            uint256 remainingSideAssets;
            if (netDebtX) {
                if (userAssets[DEPOSIT_Y] > userAssets[BORROW_Y]) {
                    remainingSideAssets = userAssets[DEPOSIT_Y] - userAssets[BORROW_Y];
                }
            } else {
                if (userAssets[DEPOSIT_X] > userAssets[BORROW_X]) {
                    remainingSideAssets = userAssets[DEPOSIT_X] - userAssets[BORROW_X];
                }
            }

            uint256 denominator = Saturation.EXPECTED_SATURATION_LTV_PLUS_ONE_MAG2;
            uint256 lower;
            if (remainingSideAssets > 0) {
                uint256 remainingSideAssetsInL = netDebtX
                    ? Convert.mulDiv(remainingSideAssets, targetLiquidationSqrtPriceQ72, Q72, false)
                    : Convert.mulDiv(remainingSideAssets, Q72, targetLiquidationSqrtPriceQ72, false);

                uint256 debtSideComponent = debtSideAssetsInL * MAG2;

                uint256 remainingSideComponent = EXPECTED_SATURATION_LTV_MAG2 * remainingSideAssetsInL;

                lower = debtSideComponent > remainingSideComponent
                    ? (debtSideComponent - remainingSideComponent) / denominator
                    : 0;
            } else {
                lower = debtSideAssetsInL * MAG2 / denominator;
            }

            uint256 netLAbs = uint256(netL);
            lWeightQ72 = lower < netLAbs ? Convert.mulDiv(lower, Q72, netLAbs, true) : Q72;
        }
    }

    /**
     * @notice Calculates the start sqrt weight for the included saturation window.
     *   The saturation is normalized by the active liquidity scaled by the maximum allowed
     *   saturation ratio. Define:
     *
     *   ```math
     *   r_{max}=\frac{MAX\_SATURATION\_RATIO\_IN\_MAG2}{MAG2}
     *   ```
     *
     *   We round up the sqrt to avoid `sqrtStartWeightQ72 == Q72`, which would return `0` from `calcXWeightQ72`.
     *
     *   Normalize the included saturation by active liquidity:
     *
     *   ```math
     *   a_s=\frac{sat}{r_{max}L}
     *   ```
     *
     *   The underlying non-sqrt start weight is:
     *
     *   ```math
     *   \begin{equation}
     *     w_s = \begin{cases}
     *       1+a_s(B-1)
     *         & \text{ if net debt of X } \\
     *       \frac{1}{1+a_s(B-1)}
     *         & \text{ if net debt of Y}
     *     \end{cases}
     *   \end{equation}
     *   ```
     * @param partialSaturation Saturation included in the partial liquidation.
     * @param activeLiquidityAssets Active liquidity used to scale tranche saturation.
     * @param netDebtX Whether the debt side is X. If false, the reciprocal weight is used.
     * @return sqrtStartWeightQ72 Q72 start sqrt weight, adjusted for the debt side.
     */
    function calcSqrtStartWeightQ72(
        uint256 partialSaturation,
        uint256 activeLiquidityAssets,
        bool netDebtX
    ) internal pure returns (uint256 sqrtStartWeightQ72) {
        sqrtStartWeightQ72 = Math.sqrt(
            Q72
                * (
                    Q72
                        + Convert.mulDiv(
                            (TRANCHE_B_MINUS_ONE_IN_Q72) * MAG2,
                            partialSaturation,
                            activeLiquidityAssets * MAX_SATURATION_RATIO_IN_MAG2,
                            true
                        )
                ),
            Math.Rounding.Ceil
        );

        sqrtStartWeightQ72 = weightInNumeratorOrDenominator(sqrtStartWeightQ72, netDebtX);
    }

    /**
     * @notice Calculates the end sqrt weight for the included saturation window.
     *   Normalize the remaining saturation by active liquidity:
     *
     *   ```math
     *   r_{max}=\frac{MAX\_SATURATION\_RATIO\_IN\_MAG2}{MAG2},
     *   \qquad
     *   a_e=\frac{sat_{total}-sat}{r_{max}L}
     *   ```
     *
     *   The underlying non-sqrt end weight is:
     *
     *   ```math
     *   \begin{equation}
     *     w_e = \begin{cases}
     *       1-a_e(B-1)
     *         & \text{ if net debt of X } \\
     *       \frac{1}{1-a_e(B-1)}
     *         & \text{ if net debt of Y}
     *     \end{cases}
     *   \end{equation}
     *   ```
     * @param partialSaturation Saturation included in the partial liquidation.
     * @param totalSaturation Total borrower saturation across all tranches.
     * @param activeLiquidityAssets Active liquidity used to scale tranche saturation.
     * @param netDebtX Whether the debt side is X. If false, the reciprocal weight is used.
     * @return sqrtEndWeightQ72 Q72 end sqrt weight, adjusted for the debt side.
     */
    function calcSqrtEndWeightQ72(
        uint256 partialSaturation,
        uint256 totalSaturation,
        uint256 activeLiquidityAssets,
        bool netDebtX
    ) private pure returns (uint256 sqrtEndWeightQ72) {
        sqrtEndWeightQ72 = Math.sqrt(
            Q72
                * (
                    Q72
                        - Convert.mulDiv(
                            totalSaturation - partialSaturation,
                            (TRANCHE_B_MINUS_ONE_IN_Q72) * MAG2,
                            activeLiquidityAssets * MAX_SATURATION_RATIO_IN_MAG2,
                            false
                        )
                )
        );

        sqrtEndWeightQ72 = weightInNumeratorOrDenominator(sqrtEndWeightQ72, netDebtX);
    }

    /**
     * @notice Adjusts a sqrt weight into numerator form for X debt or denominator form for Y debt.
     *   Net debt Y walks the same tranche geometry in inverted square-root-price space:
     *
     *   ```math
     *   \sqrt{w}\mapsto\frac{1}{\sqrt{w}}
     *   ```
     * @param sqrtWeight Q72 sqrt weight before debt-side orientation.
     * @param netDebtX Whether the debt side is X. If false, the reciprocal weight is returned.
     * @return adjustedSqrtWeight Q72 sqrt weight oriented for the debt side.
     */
    function weightInNumeratorOrDenominator(
        uint256 sqrtWeight,
        bool netDebtX
    ) private pure returns (uint256 adjustedSqrtWeight) {
        adjustedSqrtWeight = netDebtX ? sqrtWeight : Q144 / sqrtWeight;
    }
}
