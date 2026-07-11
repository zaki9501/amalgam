/// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y
} from 'contracts/interfaces/tokens/ITokenController.sol';

import {
    Q72,
    Q128,
    LTVMAX_IN_MAG2,
    ALLOWED_LIQUIDITY_LEVERAGE,
    MAG2,
    MINIMUM_LIQUIDITY
} from 'contracts/libraries/constants.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {QuadraticSwapFees} from 'contracts/libraries/QuadraticSwapFees.sol';

library Validation {
    uint256 internal constant MAX_BORROW_PERCENTAGE = 90;

    struct InputParams {
        uint256[6] userAssets;
        int16 minTick;
        int16 maxTick;
        uint256 sqrtPriceMinInQ72;
        uint256 sqrtPriceMaxInQ72;
        uint256 activeLiquidityAssets;
        uint256 reservesXAssets;
        uint256 reservesYAssets;
        bool hasBorrow;
    }

    struct CheckLtvParams {
        uint256 netDepositedXinLAssets;
        uint256 netDepositedYinLAssets;
        uint256 netBorrowedXinLAssets;
        uint256 netBorrowedYinLAssets;
    }

    struct VerifyMaxBorrowParams {
        uint256 depositedAssets;
        uint256 borrowedAssets;
        uint256 reserve;
        uint256 totalDepositedLAssets;
        uint256 totalBorrowedLAssets;
    }

    error InsufficientLiquidity();
    error AmmalgamCannotBorrowAgainstSameCollateral();
    error AmmalgamMaxBorrowReached();
    error AmmalgamDepositIsNotStrictlyBigger();
    error AmmalgamLTV();
    error AmmalgamMaxSlippage();
    error AmmalgamTooMuchLeverage();
    error AmmalgamTransferAmtExceedsBalance();

    /**
     * @notice Get the input parameters for the validation
     * @dev hasBorrow is set to true here, because we assume that the caller has verified there is
     *      a borrowed asset
     * @param userAssets The user assets of the pool
     * @param activeLiquidityAssets The current active liquidity assets of the pool
     * @param reserveXAssets The reserve of the X asset
     * @param reserveYAssets The reserve of the Y asset
     * @param externalLiquidity The external liquidity of the pool
     * @param minTick The min tick of the pool
     * @param maxTick The max tick of the pool
     * @return inputParams The input parameters for the validation
     */
    function getInputParams(
        uint256[6] memory userAssets,
        uint256 activeLiquidityAssets,
        uint256 reserveXAssets,
        uint256 reserveYAssets,
        uint256 externalLiquidity,
        int16 minTick,
        int16 maxTick
    ) internal pure returns (Validation.InputParams memory inputParams) {
        inputParams = Validation.InputParams({
            userAssets: userAssets,
            minTick: minTick,
            maxTick: maxTick,
            sqrtPriceMinInQ72: TickMath.getSqrtPriceAtTick(minTick),
            sqrtPriceMaxInQ72: TickMath.getSqrtPriceAtTick(maxTick),
            activeLiquidityAssets: activeLiquidityAssets + externalLiquidity,
            reservesXAssets: reserveXAssets,
            reservesYAssets: reserveYAssets,
            hasBorrow: true
        });
    }

    /**
     * @notice Get the check LTV parameters for needed for `validateLTVAndLeverage()`
     * @dev the sqrt prices are in the input params, but by passing them we allow for the ability
     *      to switch them as needed in liquidation and other cases.
     * @param userAssets User asset array
     * @param sqrtPriceMinInQ72 The minimum sqrt price in Q72
     * @param sqrtPriceMaxInQ72 The maximum sqrt price in Q72
     */
    function getCheckLtvParams(
        uint256[6] memory userAssets,
        uint256 sqrtPriceMinInQ72,
        uint256 sqrtPriceMaxInQ72
    ) internal pure returns (CheckLtvParams memory checkLtvParams) {
        (checkLtvParams.netBorrowedXinLAssets, checkLtvParams.netBorrowedYinLAssets) =
            getBorrowedInL(userAssets, sqrtPriceMinInQ72, sqrtPriceMaxInQ72);
        (checkLtvParams.netDepositedXinLAssets, checkLtvParams.netDepositedYinLAssets) =
            getDepositsInL(userAssets, sqrtPriceMinInQ72, sqrtPriceMaxInQ72);
    }

    /**
     * @notice Verifies that debt is backed by liquidity from an independent provider and
     *   that users do not borrow the same underlying assets they supply as collateral.
     * @param userAssets The account's assets by token type.
     * @param activeLiquidityAssets The pair's active liquidity assets.
     */
    function validateBalanceAndLiqAndNotSameAssetsSuppliedAndBorrowed(
        uint256[6] memory userAssets,
        uint256 activeLiquidityAssets
    ) internal pure {
        if (activeLiquidityAssets < userAssets[DEPOSIT_L] + MINIMUM_LIQUIDITY) revert InsufficientLiquidity();

        verifyNotSameAssetsSuppliedAndBorrowed(
            userAssets[DEPOSIT_X], userAssets[DEPOSIT_Y], userAssets[BORROW_X], userAssets[BORROW_Y]
        );
    }

    function validateLTVAndLeverage(
        CheckLtvParams memory checkLtvParams,
        uint256 activeLiquidityAssets
    ) internal pure {
        checkLtv(checkLtvParams, activeLiquidityAssets);
        checkLeverage(checkLtvParams);
    }

    /**
     * Added TokenType and uint256s for amount, balance from, and balance to
     * to enable to pass a value for the current balance of a token to avoid one
     * check of a balance that can be done from within a token.
     */
    function validateSolvency(
        uint256[6] memory userAssets,
        uint256 sqrtPriceMinInQ72,
        uint256 sqrtPriceMaxInQ72,
        uint256 activeLiquidityAssets
    ) external pure {
        validateBalanceAndLiqAndNotSameAssetsSuppliedAndBorrowed(userAssets, activeLiquidityAssets);
        CheckLtvParams memory checkLtvParams = getCheckLtvParams(userAssets, sqrtPriceMinInQ72, sqrtPriceMaxInQ72);
        validateLTVAndLeverage(checkLtvParams, activeLiquidityAssets - userAssets[DEPOSIT_L]);
    }

    function verifyNotSameAssetsSuppliedAndBorrowed(
        uint256 depositedXAssets,
        uint256 depositedYAssets,
        uint256 borrowedXAssets,
        uint256 borrowedYAssets
    ) internal pure {
        if ((borrowedXAssets > 0 && depositedXAssets > 0) || (borrowedYAssets > 0 && depositedYAssets > 0)) {
            revert AmmalgamCannotBorrowAgainstSameCollateral();
        }
    }

    function verifyMaxBorrow(
        VerifyMaxBorrowParams memory params
    ) internal pure {
        unchecked {
            uint256 scaledBorrowedLiquidityAssets = Convert.mulDiv(
                params.reserve,
                params.totalBorrowedLAssets,
                params.totalDepositedLAssets - params.totalBorrowedLAssets,
                false
            );

            if (
                Convert.mulDiv(params.reserve + scaledBorrowedLiquidityAssets, MAX_BORROW_PERCENTAGE, MAG2, false)
                    + params.depositedAssets < scaledBorrowedLiquidityAssets + params.borrowedAssets
            ) {
                revert AmmalgamMaxBorrowReached();
            }
        }
    }

    function getDepositsInL(
        uint256[6] memory userAssets,
        uint256 sqrtPriceMinInQ72,
        uint256 sqrtPriceMaxInQ72
    ) private pure returns (uint256 netDepositedXinLAssets, uint256 netDepositedYinLAssets) {
        netDepositedXinLAssets = netDepositedYinLAssets = userAssets[DEPOSIT_L];

        if (0 < userAssets[DEPOSIT_X]) {
            netDepositedXinLAssets += Validation.convertXToL(
                userAssets[DEPOSIT_X],
                sqrtPriceMaxInQ72, // max tick is applied on X for deposit
                false
            );
        }
        if (0 < userAssets[DEPOSIT_Y]) {
            netDepositedYinLAssets += Validation.convertYToL(
                userAssets[DEPOSIT_Y],
                sqrtPriceMinInQ72, // min tick is applied on Y for deposit
                false
            );
        }
    }

    function getBorrowedInL(
        uint256[6] memory userAssets,
        uint256 sqrtPriceMinInQ72,
        uint256 sqrtPriceMaxInQ72
    ) private pure returns (uint256 netBorrowedXinLAssets, uint256 netBorrowedYinLAssets) {
        netBorrowedXinLAssets = netBorrowedYinLAssets = userAssets[BORROW_L];

        if (userAssets[BORROW_X] > 0) {
            netBorrowedXinLAssets += convertXToL(
                userAssets[BORROW_X],
                sqrtPriceMinInQ72, // min tick is applied on X for borrow
                true
            );
        }
        if (userAssets[BORROW_Y] > 0) {
            netBorrowedYinLAssets += convertYToL(
                userAssets[BORROW_Y],
                sqrtPriceMaxInQ72, // max tick is applied on Y for borrow
                true
            );
        }
    }

    /**
     * Convert X assets to L assets: L = x / sqrt(p)
     * amountLAssets = amountInXAssets * Q72 / sqrtPriceInXInQ72
     */
    function convertXToL(
        uint256 amountInXAssets,
        uint256 sqrtPriceInXInQ72,
        bool roundUp
    ) internal pure returns (uint256 amountLAssets) {
        if (amountInXAssets == 0) return 0;
        amountLAssets = Convert.mulDiv(amountInXAssets, Q72, sqrtPriceInXInQ72, roundUp);
    }

    /**
     * Convert L assets to X assets: x = L * sqrt(p)
     * amountXAssets = amount * sqrtPriceQ72 / Q72
     */
    function convertLToX(
        uint256 amount,
        uint256 sqrtPriceQ72,
        bool roundUp
    ) internal pure returns (uint256 amountXAssets) {
        if (amount == 0) return 0;
        amountXAssets = Convert.mulDiv(amount, sqrtPriceQ72, Q72, roundUp);
    }

    /**
     * Convert Y assets to L assets: L = y * sqrt(p)
     * amountLAssets = amountInYAssets * sqrtPriceInXInQ72 / Q72
     */
    function convertYToL(
        uint256 amountInYAssets,
        uint256 sqrtPriceInXInQ72,
        bool roundUp
    ) internal pure returns (uint256 amountInLAssets) {
        if (amountInYAssets == 0) return 0;
        amountInLAssets = Convert.mulDiv(amountInYAssets, sqrtPriceInXInQ72, Q72, roundUp);
    }

    /**
     * Convert L assets to Y assets: y = L / sqrt(p)
     * amountYAssets = amount * Q72 / sqrtPriceQ72
     */
    function convertLToY(
        uint256 amount,
        uint256 sqrtPriceQ72,
        bool roundUp
    ) internal pure returns (uint256 amountYAssets) {
        if (amount == 0) return 0;
        amountYAssets = Convert.mulDiv(amount, Q72, sqrtPriceQ72, roundUp);
    }

    function calcDebtAndCollateral(
        CheckLtvParams memory checkLtvParams
    ) internal pure returns (uint256 debtLiquidityAssets, uint256 collateralLiquidityAssets, bool netDebtX) {
        bool xDepositIsStrictlyBigger = checkLtvParams.netDepositedXinLAssets > checkLtvParams.netBorrowedXinLAssets;
        bool yDepositIsStrictlyBigger = checkLtvParams.netDepositedYinLAssets > checkLtvParams.netBorrowedYinLAssets;

        if (!xDepositIsStrictlyBigger && !yDepositIsStrictlyBigger) {
            unchecked {
                debtLiquidityAssets = checkLtvParams.netBorrowedXinLAssets - checkLtvParams.netDepositedXinLAssets
                    + (checkLtvParams.netBorrowedYinLAssets - checkLtvParams.netDepositedYinLAssets);
            }
        } else if (!xDepositIsStrictlyBigger) {
            unchecked {
                debtLiquidityAssets = checkLtvParams.netBorrowedXinLAssets - checkLtvParams.netDepositedXinLAssets;
                collateralLiquidityAssets = checkLtvParams.netDepositedYinLAssets - checkLtvParams.netBorrowedYinLAssets;
            }
            netDebtX = true;
        } else if (!yDepositIsStrictlyBigger) {
            unchecked {
                debtLiquidityAssets = checkLtvParams.netBorrowedYinLAssets - checkLtvParams.netDepositedYinLAssets;
                collateralLiquidityAssets = checkLtvParams.netDepositedXinLAssets - checkLtvParams.netBorrowedXinLAssets;
            }
        }
    }

    function checkLtv(
        CheckLtvParams memory checkLtvParams,
        uint256 activeLiquidityAssets
    ) private pure returns (uint256 debtLiquidityAssets, uint256 collateralLiquidityAssets) {
        if (checkLtvParams.netBorrowedXinLAssets == 0 && checkLtvParams.netBorrowedYinLAssets == 0) return (0, 0);

        (debtLiquidityAssets, collateralLiquidityAssets,) = calcDebtAndCollateral(checkLtvParams);
        if (collateralLiquidityAssets == 0 && debtLiquidityAssets > 0) {
            revert AmmalgamDepositIsNotStrictlyBigger();
        }

        // Exclude current user liquidity as liquidator may sell collateral after liquidation in
        // which case the slippage would not included deposited L.
        // underflow has been checked at 'Ammalgam: Insufficient liquidity'.
        unchecked {
            debtLiquidityAssets = increaseForSlippage(debtLiquidityAssets, activeLiquidityAssets);

            if (collateralLiquidityAssets * LTVMAX_IN_MAG2 < debtLiquidityAssets * MAG2) revert AmmalgamLTV();
        }
    }

    /**
     * @notice Increases an L-denominated debt amount by the constant-product slippage needed
     *   to buy that debt against the pool's active liquidity.
     *
     *   Let `D` be `debtLiquidityAssets` and `L` be `activeLiquidityAssets`. The function
     *   reverts when `D >= L`; otherwise it returns:
     *
     *   ```math
     *   D_{in}=\left\lceil\frac{L\cdot D}{L-D}\right\rceil
     *   ```
     *
     *   This is the amount of L assets that must enter the pool to remove `D` L assets
     *   of debt from the opposite reserve under the constant-product approximation.
     *
     * @param debtLiquidityAssets The amount of debt with units of L that will need to be purchased in case of liquidation.
     * @param activeLiquidityAssets The amount of liquidity in the pool available to swap against.
     */
    function increaseForSlippage(
        uint256 debtLiquidityAssets,
        uint256 activeLiquidityAssets
    ) internal pure returns (uint256) {
        if (debtLiquidityAssets >= activeLiquidityAssets) {
            revert AmmalgamMaxSlippage();
        }
        return Math.ceilDiv(activeLiquidityAssets * debtLiquidityAssets, (activeLiquidityAssets - debtLiquidityAssets));
    }

    function checkLeverage(
        CheckLtvParams memory checkLtvParams
    ) private pure {
        unchecked {
            uint256 totalNetDeposits = checkLtvParams.netDepositedXinLAssets + checkLtvParams.netDepositedYinLAssets;
            uint256 totalNetDebts = checkLtvParams.netBorrowedXinLAssets + checkLtvParams.netBorrowedYinLAssets;

            if (totalNetDebts > 0) {
                if (
                    totalNetDeposits < totalNetDebts
                        || (totalNetDeposits - totalNetDebts) * ALLOWED_LIQUIDITY_LEVERAGE < totalNetDeposits
                ) {
                    revert AmmalgamTooMuchLeverage();
                }
            }
        }
    }
}
