// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Convert} from 'contracts/libraries/Convert.sol';

/**
 * @title QuadraticSwapFees
 * @author Will
 * @notice A library to calculate fees that grow with respect to price deviation from a reference point.
 *   This library relies on a reference reserve from the start of the block to determine what the overall
 *   growth in price has been in the current block.
 *
 * Fee Model Overview:
 *   The fee structure uses two distinct models depending on the magnitude of price deviation:
 *
 *   1. Quadratic Fee Model (for moderate price changes):
 *      - Used when price deviation is relatively small
 *      - Fee grows proportionally to the square of the price movement
 *      - This creates a smooth, incentive-aligned fee curve that discourages large single swaps
 *        while keeping fees reasonable for normal market activity
 *      - Key property: If one swap would pay fee `F`, splitting it into two equal swaps would pay
 *        two fees that sum to approximately `F`
 *
 *   2. Linear Fee Model (for extreme price changes):
 *      - Used when price deviation exceeds the quadratic threshold
 *      - Fee grows linearly beyond the threshold point, capping at `MAX_QUADRATIC_FEE_PERCENT`
 *      - This prevents fees from becoming prohibitively expensive for very large swaps while
 *        still maintaining strong economic disincentives against massive price manipulations
 *      - The linear growth provides a more predictable fee structure for extreme market conditions
 *
 * Why Two Models?
 *   - Quadratic fees alone would become so high that the invariant curve property of being monotonic, leading
 *     larger swaps amounts in would eventually lead to less assets out than smaller swaps in.
 *   - Linear fees alone wouldn't provide enough protection against price manipulation for moderate swaps
 *
 * Price Movement Behavior:
 *   - If the price moves away from the reference, and then back toward it, the fee is minimal until
 *     the price again crosses the starting reference price
 *   - Only the net price deviation from the start-of-block reference is charged
 */
library QuadraticSwapFees {
    /**
     * @notice Minimum fee is one tenth of a basis point.
     */
    uint256 public constant MIN_FEE_Q64 = 0x1999999999999999;

    /**
     * @notice 10000 bips per 100 percent in Q64.
     */
    uint256 public constant BIPS_Q64 = 0x27100000000000000000;

    /**
     * @notice Max percent fee growing at a quadratic rate. After this the growths slows down.
     */
    uint256 internal constant MAX_QUADRATIC_FEE_PERCENT = 40;

    /**
     * @notice A scaler that controls how fast the fee grows, at 20, 9x price change will be
     *   a 40% fee.
     */
    uint256 internal constant N = 20;

    /**
     * @notice A reserve multiplier used to determine the boundary at which we switch from quadratic to linear fee.
     */
    uint256 private constant RESERVE_MULTIPLIER = 2;

    /**
     * @notice the $$\sqrt{price}$$ at which we switch from quadratic fee to a more linear fee.
     *   ```math
     *     \frac{MAX\_QUADRATIC\_FEE\_PERCENT + 2\cdot N}{N}
     *   ```
     */
    uint256 private constant LINEAR_START_REFERENCE_SCALER = 4;

    /**
     * @notice the fee at `LINEAR_START_REFERENCE_SCALER` in bips
     */
    uint256 private constant MAX_QUADRATIC_FEE_PERCENT_BIPS = 4000;

    /**
     * @notice $$N \cdot 100 \cdot Q64$$ or `N` times bips in one percent in Q64
     */
    uint256 private constant N_TIMES_BIPS_Q64_PER_PERCENT = 0x7d00000000000000000;

    /**
     * @notice 2 times Q64 or Q65
     */
    uint256 private constant TWO_Q64 = 0x20000000000000000;

    /**
     * @notice `MAX_QUADRATIC_FEE_PERCENT` in Q64, $$MAX\_QUADRATIC\_FEE\_PERCENT \cdot Q64$$
     */
    uint256 private constant MAX_QUADRATIC_FEE_Q64 = 0x280000000000000000;

    /**
     * @notice Computes the swap fee based on the `input` amount and the pool's
     *   `currentReserve` and `referenceReserve` for the input asset.
     *
     * Control flow by scenario:
     *   - `currentReserve >= referenceReserve` (price already at/away from reference):
     *     - If `input + RESERVE_MULTIPLIER * currentReserve < referenceReserve * LINEAR_START_REFERENCE_SCALER`:
     *       Use the quadratic fee model (closer to reference, pre-threshold).
     *     - Otherwise:
     *       Use the linear fee model (farther from reference, post-threshold).
     *   - `currentReserve < referenceReserve` (price at/moving back toward the start-of-block reference):
     *     - If `input + currentReserve <= referenceReserve`:
     *       Does not cross the reference. Only the global minimum fee will apply at the end.
     *     - If `input + currentReserve > referenceReserve`:
     *       Crosses the reference. The portion beyond the reference (`pastBy`) is charged using
     *       either the quadratic or linear model depending on `pastBy`:
     *         - `pastBy > RESERVE_MULTIPLIER * referenceReserve` → use linear fee model
     *         - otherwise → use quadratic fee model
     *       The resulting fee for the beyond-reference portion is then weighted by `pastBy / input`.
     *
     *   ```math
     *     \begin{equation*}
     *       f_\phi(X_{in}) =
     *         \begin{cases}
     *           n \cdot \frac{2(X_{0}-X_{R})+X_{in}}{X_{R}}
     *             &\text{if } X_0 \ge X_R \text{ \& } X_{in} + 2 X_{0} \le X_{R}\left(\frac{M_Q +\ 2n}{n}\right) \\
     *
     *           M_Q \left( 2 - X_R \frac{M_Q}{n\left( X_{in} + 2 (X_0 - X_R) \right)} \right)
     *             &\text {if } X_0 \ge X_R \text{ \& } X_{in} + 2X_{0} \ge X_{R}\left(\frac{M_Q+\ 2n}{n}\right) \\
     *
     *           \frac{n \cdot \left( \frac{pastBy^2}{X_R} \right)}{X_{in}}
     *             &\text{ if } X_0 + X_{in} \gt X_R \text{ \& } X_{in} + 2 X_{0} \le X_{R}\left(\frac{M_Q +\ 2n}{n}\right) \\
     *
     *           \frac{M_Q \left( 2 - X_R \frac{M_Q}{n \cdot pastBy} \right) \cdot pastBy}{X_{in}}
     *             &\text{ if } X_0 + X_{in} \gt X_R \text{ \& } X_{in} + 2 X_{0} \ge X_{R}\left(\frac{M_Q +\ 2n}{n}\right) \\
     *
     *           MinBips &\text{ otherwise } X_0 + X_{in} \le  X_R \\
     *         \end{cases}
     *     \end{equation*}
     *   ```
     *
     *   where:
     *   - `X_in` is the `input` amount
     *   - `X_0` is the `currentReserve`
     *   - `X_R` is the `referenceReserve`
     *   - `M_Q` is `MAX_QUADRATIC_FEE_PERCENT`
     *   - `n` is `N`
     *   - `pastBy` is the amount by which the price has moved past the `referenceReserve`
     *   - `MinBips` is `MIN_FEE_Q64`
     *
     * @param input The input amount of the asset (units of the asset).
     * @param currentReserve The current reserve of the input asset in the pool.
     * @param referenceReserve The start-of-block reference reserve for the input asset.
     * @return fee The swap fee in Q64 bips.
     */
    function calculateSwapFeeBipsQ64(
        uint256 input,
        uint256 currentReserve,
        uint256 referenceReserve
    ) internal pure returns (uint256 fee) {
        if (input == 0) return 0;

        /**
         * @dev All arithmetic operations within this `unchecked` block are safe from overflow/underflow.
         *
         * 1. `input + currentReserve` cannot overflow:
         *    - The caller `AmmalgamPair` verifies reserves via `updateReserves(reserveAssets + amountIn)`
         *    - Reserves are casted using `SafeCast` to `uint112` before being stored,
         *      so `input + currentReserve <= type(uint112).max`
         *
         * 2. a) `LINEAR_START_REFERENCE_SCALER * referenceReserve` cannot overflow:
         *    b) `RESERVE_MULTIPLIER * referenceReserve` cannot overflow:
         *       - `referenceReserve` is bounded by `uint112`
         *
         * 3. `currentReserveAfterSwap + currentReserve` cannot overflow:
         *    - `currentReserveAfterSwap = input + currentReserve` is bounded by `uint112`
         *    - `currentReserve` is bounded by `uint112`
         */
        unchecked {
            uint256 currentReserveAfterSwap = input + currentReserve;
            if (currentReserve >= referenceReserve) {
                if (currentReserveAfterSwap + currentReserve > referenceReserve * LINEAR_START_REFERENCE_SCALER) {
                    fee = calculateLinearFeeBipsQ64(input, currentReserve, referenceReserve);
                } else {
                    fee = calculateQuadraticFeeBipsQ64(input, currentReserve, referenceReserve);
                }
            } else {
                if (currentReserveAfterSwap > referenceReserve) {
                    uint256 pastBy = currentReserveAfterSwap - referenceReserve;

                    // similar inequality as above but treating `currentReserve == referenceReserve`
                    if (pastBy > RESERVE_MULTIPLIER * referenceReserve) {
                        fee = calculateLinearFeeBipsQ64(pastBy, referenceReserve, referenceReserve);
                    } else {
                        fee = calculateQuadraticFeeBipsQ64(pastBy, referenceReserve, referenceReserve);
                    }

                    // We weight the fee based on how far past the reference reserve
                    fee = Convert.mulDiv(fee, pastBy, input, false);
                }
            }
        }

        fee = Math.max(fee, MIN_FEE_Q64);
    }

    /**
     * @notice Calculates the quadratic fee in Q64 bips.
     * @dev The quadratic fee model charges fees proportional to the square of price movement.
     * Refer to `calculateSwapFeeBipsQ64` NatSpec for the quadratic fee formula.
     *
     * @param input The input amount of the asset (units of the asset).
     * @param currentReserve The current reserve of the input asset in the pool.
     * @param referenceReserve The start-of-block reference reserve for the input asset.
     * @return fee The quadratic fee in Q64 bips.
     */
    function calculateQuadraticFeeBipsQ64(
        uint256 input,
        uint256 currentReserve,
        uint256 referenceReserve
    ) private pure returns (uint256 fee) {
        fee = Convert.mulDiv(
            N_TIMES_BIPS_Q64_PER_PERCENT,
            input + RESERVE_MULTIPLIER * (currentReserve - referenceReserve),
            referenceReserve,
            false
        );
    }

    /**
     * @notice Calculates the linear fee in Q64 bips.
     * @dev The linear fee model charges fees that grow linearly (not quadratically) for extreme price deviations.
     * Refer to `calculateSwapFeeBipsQ64` NatSpec for the linear fee formula.
     *
     * @param input The input amount of the asset (units of the asset).
     * @param currentReserve The current reserve of the input asset in the pool.
     * @param referenceReserve The start-of-block reference reserve for the input asset.
     * @return fee The linear fee in Q64 bips.
     */
    function calculateLinearFeeBipsQ64(
        uint256 input,
        uint256 currentReserve,
        uint256 referenceReserve
    ) private pure returns (uint256 fee) {
        fee = MAX_QUADRATIC_FEE_PERCENT_BIPS
            * (
                TWO_Q64
                    - Convert.mulDiv(
                        referenceReserve,
                        MAX_QUADRATIC_FEE_Q64,
                        N * (input + RESERVE_MULTIPLIER * (currentReserve - referenceReserve)),
                        false
                    )
            );
    }
}
