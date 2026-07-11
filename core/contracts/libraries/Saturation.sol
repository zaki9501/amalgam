// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {BitLib} from '@mangrovedao/mangrove-core/lib/core/BitLib.sol';
import {MathLib, WAD} from '@morpho-org/morpho-blue/src/libraries/MathLib.sol';

import {Convert} from 'contracts/libraries/Convert.sol';
import {Uint16Set} from 'contracts/libraries/Uint16Set.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {
    B_IN_Q72,
    BIPS,
    EXPECTED_SATURATION_LTV_MAG2,
    MAG1,
    MAG2,
    MAG4,
    MAG6,
    MAX_SATURATION_RATIO_IN_MAG2,
    MINIMUM_LIQUIDITY,
    Q16,
    Q32,
    Q56,
    Q72,
    Q88,
    Q112,
    Q128,
    Q144,
    Q200,
    TRANCHE_B_IN_Q72,
    TRANCHE_B_MINUS_ONE_IN_Q72,
    SAT_PERCENTAGE_DELTA_DEFAULT_WAD,
    SAT_PERCENTAGE_DELTA_4_WAD,
    SAT_PERCENTAGE_DELTA_5_WAD,
    SAT_PERCENTAGE_DELTA_6_WAD,
    SAT_PERCENTAGE_DELTA_7_WAD,
    ZERO_ADDRESS,
    MAX_SATURATION_PERCENT_IN_WAD,
    MAX_UTILIZATION_PERCENT_IN_WAD,
    LIQUIDITY_INTEREST_RATE_MAGNIFICATION,
    SECONDS_IN_YEAR
} from 'contracts/libraries/constants.sol';
import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Interest} from 'contracts/libraries/Interest.sol';

/**
 * @title   A lib to maintain the saturation of all the positions
 * @author  imi@1m1.io
 * @author  Will duelingGalois@protonmail.com
 * @notice  Saturation, or sat, is defined as the net borrow. In theory, we would want to divide net
 *  borrow by the total liquidity; in practice, we keep the net borrow only in the tree. The unit
 *  of sat is relative to active liquidity assets, or the amount of L deposited less the amount
 *  borrowed.
 *
 *  When we determine how much a swap moves the price, or square root price, we can define our
 *  equation using ticks, or tranches (25 ticks), where for some base $b$, the square root price
 *  is $b^t$ for some tick $t$. Alternatively for a larger base $B = b^{25}$ we can define the
 *  square root price as $B^T$ for some tranche $T$. Using the square root price, we can define the
 *  amount of x or y in each tranche as:
 *  ```math
 *  \begin{align*}
 *    x =  L \cdot B^{T_0} - L \cdot B^{T_1} \\
 *    y = \frac{L}{ B^{T_1}} - \frac{L}{B^{T_0}}
 *  \end{align*}
 *  ```
 *  where liquidity is $L = \sqrt{reserveX \cdot reserveY}$. If we want to know how much debt of x
 *  or y can be liquidated within one tick, we can solve these equations for L and then the amount
 *  of x and y are considered the debt we would like to see if it could be liquidated in one tick.
 *  If saturation with respect to our starting $L$ is smaller, that amount of debt can be
 *  liquidated in one swap in the given ticks. Otherwise it is too big and can not. Note that we
 *  assume $$t_1 \text{ and } t_0 \in \mathbb{Z}$$ and $$t_0 + 1 = t_1$$. Then our definition of
 *  saturation relative to L is as follows,
 *
 *  ```math
 *    \begin{equation}
 *      saturationRelativeToL =
 *        \begin{cases}
 *          \frac{ debtX }{ b^{ t_1 } } \left( \frac{ b }{ b - 1 } \right) \\
 *          debtY \cdot b^{ t_0 } \cdot \left( \frac{ b }{ b - 1 } \right)
 *        \end{cases}
 *    \end{equation}
 *   ```
 *  Saturation is kept in a tree, starting with a root, levels and leafs. We keep 2 trees, one for
 *  net X borrows, another for net Y borrows. The price is always the price of Y in units of X.
 *  Mostly, the code works with the sqrt of price. A net X borrow refers to a position that if
 *  liquidated would cause the price to become smaller; the opposite for net Y positions. Ticks are
 *  along the price dimension and int16. Tranches are 25 ticks, stored as int16.
 *
 *  Leafs (uint16) split the sat, which is uint112, into intervals. From left to right, the leafs
 *  of the tree cover the sat space in increasing order. Each account with a position has a price
 *  at which its LTV would reach LTVMAX, which is its liquidation (=liq) price.
 *
 *  To place a debt into the appropriate tranche, we think of each debt and its respective
 *  collateral as a series of sums, where each item in the series fits in one tranche. Using
 *  formulas above, we determine the number of ticks a debt would cross if liquidated. This is
 *  considered the span of the liquidation. Using this value we then determine the start and end
 *  points of the liquidation, where the start would be closer to the prices, on the right of the
 *  end for net debt of x and on the left of the end for net debt of Y.
 *
 *  Once we have the liquidation start, end, and span, we begin to place the debt, one tranche at a
 *  time moving towards the price. In this process we compare the prior recorded saturation and
 *  allow the insertion up to some max, set at 90% or the configuration set by the user.
 *
 *  A Tranche contains multiple accounts and thus a total sat. The tranche's sat assigns it to a
 *  leaf. Each leaf can contain multiple tranches and thus has a total actual sat whilst
 *  representing a specific sat per tranche range. Leafs and thus tranches and thus accounts above
 *  a certain sat threshold are considered over saturated. These accounts are penalized for being
 *  in an over saturated tranche. Each account, tranche and leaf has a total penalty that needs to
 *  be repaid to close the position fully. Sat is distributed over multiple tranches, in case a
 *  single tranche does not have enough available sat left. Sat is kept cumulatively in the tree,
 *  meaning a node contains the sum of the sat of its parents. Updating a sat at the  bottom of the
 *  tree requires updating all parents. Penalty is kept as a path sum, in uints of LAssets, meaning
 *  the penalty of an account is the sum of the penalties of all its parents. Updating the penalty
 *  for a range of leafs only requires updating the appropriate parent. Position (=pos) refers to
 *  the relative index of a child within its parent. Index refers to the index of a node in within
 *  its level
 *
 *  The formula for allocating saturation is derived from,
 *  ```math
 *  \begin{align*}
 *    X = L \cdot \left( b^{t_e} - b^{t_s} \right) \\
 *    Y = L \cdot \left( \frac{1}{b^{t_s}} - \frac{1}{b^{t_e}} \right)
 *  \end{align*}
 *  ```
 *
 *  for the start and end of liquidation $$t_s$$ and $$t_e$$ respectively. When we consider our
 *  buckets of `TICKS_PER_TRANCHE` we can rewrite this as a series where each boundary of each
 *  tranche $$T_i$$ where $$T_0 = t_e \bmod \mathrm{TICKS\_PER\_TRANCHE}$$ for a net debt of X and
 *  $$T_0 = (-t_e) \bmod \mathrm{TICKS\_PER\_TRANCHE}$$ for a net debt of Y and
 *  $$T_i = T_{i-1} + \mathrm{TICKS\_PER\_TRANCHE}$$ for each subsequent tranche and
 *  $$B= b^{\mathrm{TICKS\_PER\_TRANCHE}}$$. Thus we can rewrite the equations as:
 *
 *  ```math
 *  \begin{align*}
 *    X &=
 *      L \left(b^{T_1} - b^{t_e} \right)
 *      + L \left( b^{T_2} - b^{T_1}\right)
 *      + ...
 *      + L \left( b^{T_n} - b^{T_{n-1}}\right)
 *      + L \left(b^{t_s}-b^{T_n}  \right)
 *    \\
 *
 *    \Large\frac{X}{b^{t_e}(B-1)} &=
 *      \Large L \left(
 *        \frac{B \cdot b^{t_e-T_0} - 1}{B-1}
 *        + \frac{ \sum_{i=1}^{n-1} B^{i} }{ b^{t_e-T_0} }
 *        + \frac{B^{n} \left(
 *  \frac{b^{t_s}}{B^{n} \cdot  b^{T_0}}-1 \right) }{ b^{t_e-T_0}(B-1)}
 *        \right)
 *  \end{align*}
 *  ```
 *
 *  We then define the left side of this equation as total saturation $T_{sat}$ or newSaturation as
 *  we call it in the parameter passed in. Saturation is relative to the saturation in one tranche.
 *  The right side of the equation defines the saturation in each tranche $s_i$, starting at the
 *  furthest point from the tranche and moving forward.
 *
 *  ```math
 *  \begin{align*}
 *    T_{sat} &=
 *      s_0
 *      + \frac{\sum_{i=1}^{n-1} s_i \cdot B^{i}}{b^{t_e-T_0}}
 *      + \frac{B^n \cdot  s_n}{b^{t_e-T_0}}
 *    \\
 *
 *    \frac{(T_{sat} - s_0)b^{t_e-T_0}}{B} - s_1 &=
 *      \left(\sum_{i=2}^{n-1} s_i \cdot B^{i-1} \right)
 *      + B^{n-1} \cdot s_n
 *    \\
 *
 *   \frac{\frac{(T_{sat} - s_0)b^{t_e-T_0}}{B} - s_1 }{ B } -s_2 &=
 *      \left(\sum_{i=2}^{n-1} s_i \cdot B^{i-2} \right)
 *      + B^{n-2} \cdot s_n
 *  \end{align*}
 *  ```
 *
 *  When calculating the case for Y, the result is almost identical, except our definition for
 *  $T_{sat}$ requires us to multiply by $$b^{t_e}$$ rather than divide.
 *
 *  The above shows the logic applied in this function. We can allocate saturation across each
 *  tranche until the total remaining saturation is depleted. We allow less than the ideal
 *  saturation to be consumed if there is less available. Extra saturation is then carried forward
 *  to tranches closer to the price, requiring part of the position to be liquidated sooner as
 *  needed based on the available liquidity.
 *
 *  Two critical nuances of this algorithm is that we reduce by a factor of $$B$$ after each
 *  iteration and we multiply one time by $$b^{t_e - T_0}$$ after we allocate $$s_0$$ one time. The
 *  reduction of $$B$$ each iteration reflects the increase in the size of each tranche relative to
 *  a unit of X or Y as you move from one tranche to the next towards the price. The one time
 *  multiplication of $$b^{t_e - T_0}$$ is an adjustment for the offset of the start of liquidation
 *  relative to the start of the second tranche to minimize the impact of the reduction by $$B$$
 *  since the first portion of saturation does not use an entire tranche.
 *
 *  If saturation reaches the minOrMaxTick, we revert as the position is already reaching the limit
 *  of our probable price range and may require immediate liquidation if opened.
 */
library Saturation {
    // constants

    /**
     * @notice time budget added to sat before adding it to the tree; compensates for the fact that
     * the liq price moves closer to the current price over time.
     */
    uint256 internal constant SATURATION_TIME_BUFFER_IN_MAG2 = 101;

    /**
     * @notice percentage of max sat per tranche where penalization begins
     */
    uint256 internal constant START_SATURATION_PENALTY_RATIO_IN_MAG2 = 85;

    /**
     * @notice maximum initial saturation percentage when adding a new position
     */
    uint256 internal constant MAX_INITIAL_SATURATION_MAG2 = 90;

    /**
     * @notice $$\mathrm{EXPECTED\_SATURATION\_LTV\_MAG2} \cdot \mathrm{SATURATION\_TIME\_BUFFER\_IN\_MAG2}^{2}$$,
     * a constant used in calculations.
     */
    uint256 internal constant EXPECTED_SATURATION_LTV_MAG2_TIMES_SAT_BUFFER_SQUARED = 867_085;

    /**
     * @notice $$\mathrm{EXPECTED\_SATURATION\_LTV\_MAG2} + 100$$, a constant used in calculations.
     */
    uint256 internal constant EXPECTED_SATURATION_LTV_PLUS_ONE_MAG2 = 185;

    /**
     * @notice Slope for calculating premium when resetting saturation for straddle positions
     *         where $$L^2 < X \cdot Y$$ transitions to $$L^2 > X \cdot Y$$. Applied to
     *         $$(L^{2} - X \cdot Y) / (X \cdot Y)$$ to produce `premiumBips`. Matches the
     *         Desmos coefficient $$\frac{BIPS}{10} \cdot 100 = 100000$$. At
     *         $$L^{2} = 1.02 \cdot X \cdot Y$$ the raw premium evaluates to
     *         `MAX_SAT_RESET_FOR_STRADDLE_PREMIUM_BIPS`; past that point the cap engages.
     */
    uint256 internal constant SAT_RESET_FOR_STRADDLE_SLOPE_BIPS = 100_000;

    /**
     * @notice Maximum premium when resetting saturation for zero-to-positive straddle positions.
     */
    uint256 internal constant MAX_SAT_RESET_FOR_STRADDLE_PREMIUM_BIPS = 2000;

    /**
     * @notice a constant used to change the log base from the tick math base to the saturation to
     * leaf base.
     */
    uint256 private constant SAT_CHANGE_OF_BASE_Q128 = 0xa39713406ef781154a9e682c2331a7c03;

    /**
     * @notice a constant used to shift when changing the base from tick math base to the
     * saturation leaf base.
     */
    uint256 private constant SAT_CHANGE_OF_BASE_TIMES_SHIFT = 0xb3f2fb93ad437464387b0c308d1d05537;

    /**
     * @notice tick offset added to ensure leaf calculation starts from 0 at the lowest leaf
     */
    int16 private constant TICK_OFFSET = 1112;

    /**
     * @notice the lowest possible saturation is always in penalty
     * $$MAX\_ASSETS \cdot \mathrm{START\_SATURATION\_PENALTY\_RATIO\_IN\_MAG2} / \mathrm{TICKS\_PER\_TRANCHE}$$
     */
    uint256 internal constant LOWEST_POSSIBLE_IN_PENALTY = 0xd9999999999999999999999999999999;

    /**
     * @notice the minimum liquidity to reach the possibility of being in penalty.
     * $$MINIMUM\_LIQUIDITY \cdot \mathrm{START\_SATURATION\_PENALTY\_RATIO\_IN\_MAG2} / \mathrm{TICKS\_PER\_TRANCHE}$$
     */
    uint256 private constant MIN_LIQ_TO_REACH_PENALTY = 850;

    /**
     * @notice Constant number one as an int type. Used for rounding or iterating direction.
     */
    int256 private constant INT_ONE = 1;

    /**
     * @notice Constant number negative one. Used for rounding or iterating direction.
     */
    int256 private constant INT_NEGATIVE_ONE = -1;

    /**
     * @notice Constant number zero as an int type. Used for rounding or iterating direction.
     */
    int256 private constant INT_ZERO = 0;

    /**
     * @notice Tree leafs are on level LEVELS_WITHOUT_LEAFS; root is level 0
     */
    uint256 internal constant LEVELS_WITHOUT_LEAFS = 3;

    /**
     * @notice for convenience, since used a lot, ==LEVELS_WITHOUT_LEAFS - 1
     */
    uint256 internal constant LOWEST_LEVEL_INDEX = 2;

    /**
     * @notice $$2^{\mathrm{LEAFS\_IN\_BITS}}$$
     */
    uint256 internal constant LEAFS = 4096;

    /**
     * @notice $$2^4$$
     */
    uint256 internal constant CHILDREN_PER_NODE = 16;

    /**
     * @notice $$2^{2 \cdot 4}$$
     */
    uint256 private constant CHILDREN_AT_THIRD_LEVEL = 256;

    /**
     * @notice $$b = \frac{2^9}{2^9-1}$$ is the base for ticks, then the tranche base is
     * $$B = b^{\mathrm{TICKS\_PER\_TRANCHE}}$$, int only to not need casting below, equals TICKS_PER_TRANCHE
     */
    int256 internal constant TICKS_PER_TRANCHE = 25;

    /**
     * @notice for convenience, used to determine max sat per tranche to not cross in liq swap:
     * $$\frac{B}{B-1}$$
     */
    uint256 constant TRANCHE_BASE_OVER_BASE_MINUS_ONE_Q72 = 0x5a19b9039a07efd7b39;

    /**
     * @notice `TickMath.MIN_TICK / TICKS_PER_TRANCHE - 1;` // -1 to floor
     */
    int256 internal constant MIN_TRANCHE = -795;

    /**
     * @notice `TickMath.MAX_TICK / TICKS_PER_TRANCHE;`
     */
    int256 internal constant MAX_TRANCHE = 794;

    //
    /**
     * @notice constants for bit reading and writing in nodes.
     * `type(uint256).max >> (TOTAL_BITS - FIELD_BITS);`
     */
    uint256 private constant FIELD_NODE_MASK = 0xffff;

    /**
     * @notice Buffer space (in tranches) allowed above the highest used tranche before hitting
     * maxLeaf limit
     */
    uint8 internal constant SATURATION_MAX_BUFFER_TRANCHES = 3;

    /**
     * @notice Twenty-five percent magnitude of two.
     */
    uint256 private constant QUARTER_OF_MAG2 = 25;

    /**
     * @notice Twenty-five percent minus one magnitude of two.
     */
    uint256 private constant QUARTER_MINUS_ONE = 24;

    /**
     * @notice quarters per tranche.
     */
    uint256 private constant NUMBER_OF_QUARTERS = 4;

    /**
     * @notice $$2 \cdot 2^{72}$$, used in saturation formula.
     */
    uint256 private constant TWO_Q72 = 0x2000000000000000000;

    /**
     * @notice $$4 \cdot 2^{128}$$, needed in quadratic formula is saturation.
     */
    uint256 private constant FOUR_Q144 = 0x4000000000000000000000000000000000000;

    /**
     * @notice $$MAG4 \cdot Q72$$ constant needed in formula.
     */
    uint256 private constant MAG4_TIMES_Q72 = 0x2710000000000000000000;

    /**
     * @notice $$b^2 \cdot Q72 - 1$$ used to round up results of `TickMath.getTickAtPrice()`.
     */
    uint256 private constant B_SQUARED_Q72_MINUS_ONE = 0x10100c08050301c1008;

    /**
     * @notice A large number that will not overflow when multiplied by `B_SQUARED_Q72_MINUS_ONE`
     * $$\left\lfloor \frac{ 2^{ 256 } }{ B\_SQUARED\_Q72\_MINUS\_ONE } \right\rfloor$$
     */
    uint256 private constant Q183 = 0x8000000000000000000000000000000000000000000000;

    /**
     * @notice $$\mathrm{TICKS\_PER\_TRANCHE} \cdot MAG2$$ used for calculating available liquidity.
     */
    uint256 private constant TICKS_PER_TRANCHE_MAG2 = 2500;

    // errors

    /**
     * @notice if the largest sat in the trees is too large
     */
    error MaxTrancheOverSaturated();

    /**
     * @notice raised if the start of liquidation would occur on the wrong side of the min or max
     *  tick price from the GeometricTWAP.
     */
    error LiquidationPassesMinOrMaxTick();

    /**
     * @notice raised if the the available saturation is not sufficient to keep the start of
     *  liquidation from reaching the wrong side of the min or max tick price from the
     *  GeometricTWAP.
     */
    error SaturationReachesMinOrMaxTick();

    // storage structs

    /**
     * @notice final structure containing all the storage data
     */
    struct SaturationStruct {
        // the tree containing sat and penalties for netX sat
        Tree netXTree;
        // the tree containing sat and penalties for netY sat
        Tree netYTree;
        uint16 maxLeaf;
    }

    /**
     * @notice the main storage type of tree struct within the `SaturationStruct`.
     */
    struct Tree {
        // is this tree netX xor not
        bool netX;
        // highest leaf that contains a tranche/account in the tree, useful to quickly decide whether the entire tree is over saturated
        uint16 highestSetLeaf;
        // nodes per level, each node contains a bit field of size of the number of its children
        // and a uint112 saturation
        uint128 totalSatInLAssets;
        uint256[][LEVELS_WITHOUT_LEAFS] nodes;
        // last level of nodes is kept as leafs
        Leaf[LEAFS] leafs;
        // which leaf does a tranche belong to
        mapping(int16 => uint16) trancheToLeaf;
        // sat per tranche
        mapping(int16 => SaturationPair) trancheToSaturation;
        // data per account
        mapping(address => Account) accountData;
        // cumulative penalty adjustment per tranche, bridging leaf penalty gaps when tranche moves
        mapping(int16 => int256) tranchePenaltyAdjustment;
    }

    /**
     * @notice a leaf contains multiple tranches and contains the total sat and penalty for the leaf
     */
    struct Leaf {
        // set of tranches in a leaf
        Uint16Set.Set tranches;
        // sum of sat of each tranche in this leaf
        SaturationPair leafSatPair;
        // penalty for the leaf
        uint256 penaltyInBorrowLSharesPerSatInQ72;
    }

    /**
     * @notice basic data per account associated with an address stored in the `Tree` struct in a
     * map as the value associated with the owners address as the key.
     */
    struct Account {
        //does account exist, needed as accountToTranche has default value 0 and tranche 0 is ok
        bool exists;
        // tranche that account belongs to
        int16 lastTranche;
        // penalty of account
        uint112 penaltyInBorrowLShares;
        // sat per tranche starting at `tranche` and running in the direction dictated by
        // netX/netY; netX trees have us distributing sat over increasing tranches, netY over
        // decreasing tranches, in both cases, towards the current price
        SaturationPair[] satPairPerTranche;
        // penalty per sat per tranche starting at `tranche` and running in the direction dictated
        // by netX/netY; netX trees have us distributing sat over increasing tranches, netY over
        // decreasing tranches, in both cases, towards the current price
        uint256[] treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche;
    }

    // memory structs

    /**
     * @notice used in memory to avoid stack overflow in `calcLiqSqrtPriceQ72()`.
     */
    struct CalcLiqSqrtPriceHandleAllABCNonZeroStruct {
        int256 netLInMAG2;
        int256 netXInMAG2;
        int256 netYInMAG2;
        uint256 netYAbsInMAG2;
        uint256 borrowedXAssets;
        uint256 borrowedYAssets;
    }

    /**
     * @notice used in memory to avoid stack overflow in `addSatToTranche()`.
     */
    struct AddSatToTrancheStateUpdatesStruct {
        int256 tranche;
        uint256 newLeaf;
        SaturationPair oldTrancheSaturation;
        SaturationPair newTrancheSaturation;
        SaturationPair satAvailableToAdd;
        uint256 targetCapacityRelativeToLAssets;
        address account;
    }

    /**
     * @notice a pair of saturation values used and stored throughout this library.
     */
    struct SaturationPair {
        // the value of a debt in units of L assets at a given liquidation price.
        uint128 satInLAssets;
        // the amount of active liquidity assets, L, that the swap required to liquidate the debt
        // would consume.
        uint128 satRelativeToL;
    }

    // init functions

    /**
     * @notice  initializes the satStruct, allocating storage for all nodes
     * @dev     initCheck can be removed once the tree structure is fixed
     * @param   satStruct contains the entire sat data
     */
    function initializeSaturationStruct(
        SaturationStruct storage satStruct
    ) internal {
        // init nodes in storage
        initTree(satStruct.netXTree);
        // init nodes in storage
        initTree(satStruct.netYTree);
        // set 1 of the tree to netX, the other stays netY by default
        satStruct.netXTree.netX = true;
    }

    /**
     * @notice  init the nodes of the tree
     * @param   tree that is being read from or written to
     */
    function initTree(
        Tree storage tree
    ) internal {
        tree.nodes[0] = new uint256[](1);
        tree.nodes[1] = new uint256[](CHILDREN_PER_NODE);
        tree.nodes[2] = new uint256[](CHILDREN_AT_THIRD_LEVEL);
    }

    // update functions

    /**
     * @notice  update the borrow position of an account and potentially check (and revert) if the
     * resulting sat is too high
     * @dev     run accruePenalties before running this function
     * @param   satStruct  main data struct
     * @param   inputParams  contains the position and pair params, like account borrows/deposits,
     * current price and active liquidity
     * @param   account  for which is position is being updated
     */
    function update(
        SaturationStruct storage satStruct,
        Validation.InputParams memory inputParams,
        address account,
        uint256 userSaturationRatioMAG2,
        bool skipMinOrMaxTickCheck
    ) internal {
        if (account != ZERO_ADDRESS) {
            SaturationPair memory zeroSat = SaturationPair({satRelativeToL: 0, satInLAssets: 0});

            // if the account has no borrow position, it could be getting repaid
            if (!inputParams.hasBorrow) {
                updateTreeGivenAccountTrancheAndSat(
                    satStruct.netXTree,
                    zeroSat,
                    account,
                    0,
                    inputParams.activeLiquidityAssets,
                    0,
                    userSaturationRatioMAG2
                );

                updateTreeGivenAccountTrancheAndSat(
                    satStruct.netYTree,
                    zeroSat,
                    account,
                    0,
                    inputParams.activeLiquidityAssets,
                    0,
                    userSaturationRatioMAG2
                );
            } else {
                // calc the netX and netY prices where the position would reach LTVMAX
                (uint256 netXLiqSqrtPriceInXInQ72, uint256 netYLiqSqrtPriceInXInQ72) =
                    calcLiqSqrtPriceQ72(inputParams.userAssets);

                // if a netX exists, update the netX tree
                if (0 < netXLiqSqrtPriceInXInQ72) {
                    (SaturationPair memory saturation, int256 endOfLiquidationInTicks, int256 minTick) =
                    calcLastTickAndSaturation(
                        inputParams,
                        netXLiqSqrtPriceInXInQ72,
                        netYLiqSqrtPriceInXInQ72,
                        userSaturationRatioMAG2,
                        true,
                        skipMinOrMaxTickCheck
                    );

                    updateTreeGivenAccountTrancheAndSat(
                        satStruct.netXTree,
                        saturation,
                        account,
                        endOfLiquidationInTicks,
                        inputParams.activeLiquidityAssets,
                        minTick,
                        userSaturationRatioMAG2
                    );
                } else if (satStruct.netXTree.accountData[account].exists) {
                    updateTreeGivenAccountTrancheAndSat(
                        satStruct.netXTree,
                        zeroSat,
                        account,
                        0,
                        inputParams.activeLiquidityAssets,
                        0,
                        userSaturationRatioMAG2
                    );
                }

                // if a netY exists, update the netY tree
                if (0 < netYLiqSqrtPriceInXInQ72) {
                    (SaturationPair memory saturation, int256 endOfLiquidationInTicks, int256 maxTick) =
                    calcLastTickAndSaturation(
                        inputParams,
                        netXLiqSqrtPriceInXInQ72,
                        netYLiqSqrtPriceInXInQ72,
                        userSaturationRatioMAG2,
                        false,
                        skipMinOrMaxTickCheck
                    );

                    updateTreeGivenAccountTrancheAndSat(
                        satStruct.netYTree,
                        saturation,
                        account,
                        endOfLiquidationInTicks,
                        inputParams.activeLiquidityAssets,
                        maxTick,
                        userSaturationRatioMAG2
                    );
                } else if (satStruct.netYTree.accountData[account].exists) {
                    updateTreeGivenAccountTrancheAndSat(
                        satStruct.netYTree,
                        zeroSat,
                        account,
                        0,
                        inputParams.activeLiquidityAssets,
                        0,
                        userSaturationRatioMAG2
                    );
                }
            }
        }

        uint256 maxLeaf = satToLeaf(inputParams.activeLiquidityAssets);
        // check whether the max sat is too high
        if (
            maxLeaf
                < Math.max(satStruct.netXTree.highestSetLeaf, satStruct.netYTree.highestSetLeaf)
                    + SATURATION_MAX_BUFFER_TRANCHES
        ) {
            revert MaxTrancheOverSaturated();
        }

        satStruct.maxLeaf = uint16(maxLeaf);
    }

    /**
     * @notice  internal update that removes the account from the tree (if it exists) from its prev
     * position and adds it to its new position
     * @param   tree that is being read from or written to
     * @param   newSaturation  the new sat of the account, in units of LAssets (absolute) and
     * relative to active liquidity
     * @param   account  whos position is being considered
     * @param   newEndOfLiquidationInTicks the new tranche of the account in mag2.
     * @param   activeLiquidityInLAssets  of the pair
     */
    function updateTreeGivenAccountTrancheAndSat(
        Tree storage tree,
        SaturationPair memory newSaturation,
        address account,
        int256 newEndOfLiquidationInTicks,
        uint256 activeLiquidityInLAssets,
        int256 minOrMaxTick,
        uint256 userSaturationRatioMAG2
    ) internal {
        // flag whether the highest sat needs updating
        bool highestSetLeafRemoved;
        bool highestSetLeafAdded;

        // if account exists at all, remove from the tree
        if (tree.accountData[account].exists) {
            highestSetLeafRemoved = removeSatFromTranche(tree, account);
        }

        // if the account has any sat, add to the tree
        if (0 < newSaturation.satRelativeToL) {
            highestSetLeafAdded = addSatToTranche(
                tree,
                account,
                newEndOfLiquidationInTicks,
                newSaturation,
                activeLiquidityInLAssets,
                userSaturationRatioMAG2,
                minOrMaxTick
            );
        }

        // update highestSetLeaf
        if (highestSetLeafRemoved && !highestSetLeafAdded) {
            unchecked {
                tree.highestSetLeaf =
                    uint16(findHighestSetLeafUpwards(tree, LOWEST_LEVEL_INDEX, tree.highestSetLeaf / CHILDREN_PER_NODE));
            }
        }
    }

    /**
     * @notice  remove sat from tree, for each tranche in a loop that could hold sat for the account
     * @param   tree that is being read from or written to
     * @param   account whose position is being considered
     * @return  highestSetLeafRemoved  flag indicating whether we removed sat from the highest leaf
     * xor not
     */
    function removeSatFromTranche(Tree storage tree, address account) internal returns (bool highestSetLeafRemoved) {
        // beginning tranche
        int256 tranche = tree.accountData[account].lastTranche;
        uint256 satArrayLength = tree.accountData[account].satPairPerTranche.length;
        // loop through each tranche that could contain sat, we cannot short circuit as we might have added sat to the last tranche
        for (uint256 trancheIndex = 0; trancheIndex < satArrayLength; trancheIndex++) {
            // if we have reached the edges of price, we are definitely done
            if (MAX_TRANCHE < tranche || tranche < MIN_TRANCHE) break;

            SaturationPair memory oldAccountSaturationInTranche =
                tree.accountData[account].satPairPerTranche[trancheIndex];
            // if the account had no sat in this tranche, move to next tranche
            if (0 < oldAccountSaturationInTranche.satRelativeToL) {
                // remember old leaf before state update
                uint256 oldLeaf = tree.trancheToLeaf[int16(tranche)];

                // update sat, fields and penalties for leafs, parents
                removeSatFromTrancheStateUpdates(tree, oldAccountSaturationInTranche, tranche, oldLeaf);

                uint256 highestSetLeaf = tree.highestSetLeaf;
                bool isLeafEmpty = Uint16Set.count(tree.leafs[highestSetLeaf].tranches) == 0;
                if (oldLeaf == highestSetLeaf && isLeafEmpty) {
                    highestSetLeafRemoved = true;
                }
            }

            // move to next tranche
            unchecked {
                tranche += trancheDirection(tree.netX);
            }
        }
        // we have removed the account from the tree and update the state of the account
        delete tree.accountData[account];
    }

    /**
     * @notice  depending on old and new leaf of the tranche, update the sats, fields and penalties
     * of the tree
     * @param   tree that is being read from or written to
     * @param   oldAccountSaturationInTranche account sat
     * @param   tranche  under consideration
     * @param   oldLeaf where tranche was located before this sat removal
     */
    function removeSatFromTrancheStateUpdates(
        Tree storage tree,
        SaturationPair memory oldAccountSaturationInTranche,
        int256 tranche,
        uint256 oldLeaf
    ) internal {
        // old sat of tranche (both absolute and relative)
        SaturationPair memory oldTrancheSaturation = tree.trancheToSaturation[int16(tranche)];

        // tranche sat decreases by removed account sat, account can not be greater than tranche of
        // accounts
        SaturationPair memory newTrancheSaturation;
        unchecked {
            newTrancheSaturation.satRelativeToL =
                oldTrancheSaturation.satRelativeToL - oldAccountSaturationInTranche.satRelativeToL;
            newTrancheSaturation.satInLAssets =
                oldTrancheSaturation.satInLAssets - oldAccountSaturationInTranche.satInLAssets;
        }

        // Use relative saturation for satToLeaf calculation
        uint256 newLeaf = satToLeaf(newTrancheSaturation.satRelativeToL);

        // update both absolute and relative saturation
        tree.trancheToSaturation[int16(tranche)] = newTrancheSaturation;

        if (newTrancheSaturation.satRelativeToL == 0) {
            // case remove tranche from tree. Reset the per-tranche penalty adjustment so a
            // future account joining this tranche key starts a fresh lifecycle. Required to
            // maintain the invariant `leafPen + adjustment >= 0` — see `getEffectivePenalty`.
            removeTrancheToLeaf(tree, oldTrancheSaturation, tranche, oldLeaf);
            delete tree.tranchePenaltyAdjustment[int16(tranche)];
        } else if (newLeaf < oldLeaf) {
            // case change to lower leaf, since we are removing sat
            addSatToTrancheStateUpdatesHigherLeaf(
                tree, tranche, oldTrancheSaturation, newTrancheSaturation, oldLeaf, newLeaf
            );
        } else {
            // case change to same leaf, oldLeaf == newLeaf, less updating needed

            // decrease leaf sat (both absolute and relative)
            tree.leafs[newLeaf].leafSatPair.satInLAssets -= oldAccountSaturationInTranche.satInLAssets;
            tree.leafs[newLeaf].leafSatPair.satRelativeToL -= oldAccountSaturationInTranche.satRelativeToL;
            unchecked {
                // update sat up the tree (use absolute saturation)
                addSatUpTheTree(tree, oldAccountSaturationInTranche.satInLAssets, false);
                // penalty offset stays the same
            }
        }
        // case oldLeaf < newLeaf does not exist
    }

    /**
     * @notice  add sat to tree, for each tranche in a loop as needed. we add to each tranche as
     *          much as it can bear.
     *          Saturation Distribution Logic
     *
     *          This function distributes debt across multiple tranches, maintaining two types of
     *          saturation:
     *          1. satInLAssets: The absolute debt amount in L assets (should remain constant total)
     *          2. satRelativeToL: The relative saturation that depends on the tranche's price level
     *
     *          As we move between tranches (different price levels), the same absolute debt
     *          translates to different relative saturations due to the price-dependent formula.
     *
     *          conceptually satInLAssets should not be scaled as it represents actual debt that
     *          doesn't change with price.
     *
     *          The formula applied here, derived in the introduction, is,
     *          ```math
     *          \begin{align*}
     *            T_{sat} &=
     *              s_0
     *              + \frac{\sum_{i=1}^{n-1} s_i \cdot B^{i}}{b^{t_e-T_0}}
     *              + \frac{B^n \cdot  s_n}{b^{t_e-T_0}}
     *            \\
     *
     *            \frac{(T_{sat} - s_0)b^{t_e-T_0}}{B} - s_1 &=
     *              \left(\sum_{i=2}^{n-1} s_i \cdot B^{i-1} \right)
     *              + B^{n-1} \cdot s_n
     *            \\
     *
     *           \frac{\frac{(T_{sat} - s_0)b^{t_e-T_0}}{B} - s_1 }{ B } -s_2 &=
     *              \left(\sum_{i=2}^{n-1} s_i \cdot B^{i-2} \right)
     *              + B^{n-2} \cdot s_n
     *          \end{align*}
     *          ```
     * @param   tree that is being read from or written to
     * @param   account whose position is being considered
     * @param   newEndOfLiquidationInTicks the new tranche of the account location in MAG2
     * @param   newSaturation the new sat of the account, in units of LAssets (absolute) and
     *   relative to active liquidity
     * @param   activeLiquidityInLAssets of the pair
     * @return  highestSetLeafAdded flag indicating whether we removed sat from the highest leaf
     *   xor not
     */
    function addSatToTranche(
        Tree storage tree,
        address account,
        int256 newEndOfLiquidationInTicks,
        SaturationPair memory newSaturation,
        uint256 activeLiquidityInLAssets,
        uint256 userSaturationRatioMAG2,
        int256 minOrMaxTick
    ) internal returns (bool highestSetLeafAdded) {
        bool netDebtX = tree.netX;
        // `nextTranche` starts as the last tranche and moves forward to the first.
        (uint256 usableTicks, int256 nextTranche) = getUsableTicksAndLastTranche(newEndOfLiquidationInTicks, netDebtX);

        usableTicks = restrictUsableTicksForMinOrMaxTick(usableTicks, nextTranche, minOrMaxTick, netDebtX);

        tree.accountData[account].lastTranche = int16(nextTranche);

        uint256 endOfLiquidationAdjustmentQ72 =
            calculateEndOfLiquidationAdjustment(newEndOfLiquidationInTicks, netDebtX);

        // keep adding sat to tranches as long as more needs adding
        while (0 < newSaturation.satRelativeToL) {
            if (
                (netDebtX && nextTranche * TICKS_PER_TRANCHE >= minOrMaxTick)
                    || (!netDebtX && (nextTranche + 1) * TICKS_PER_TRANCHE <= minOrMaxTick)
            ) {
                revert SaturationReachesMinOrMaxTick();
            }

            // if we have reached the edges of price, we are definitely done
            if (MAX_TRANCHE < nextTranche || nextTranche < MIN_TRANCHE) break;

            // convenience struct to avoid 'stack too deep'
            AddSatToTrancheStateUpdatesStruct memory addSatToTrancheStateUpdatesParams =
            getAddSatToTrancheStateUpdatesParams(
                tree,
                account,
                nextTranche,
                newSaturation,
                activeLiquidityInLAssets,
                userSaturationRatioMAG2,
                usableTicks
            );

            // if we have nothing to add to this tranche (it is full), move to the next
            if (0 < addSatToTrancheStateUpdatesParams.satAvailableToAdd.satRelativeToL) {
                // update the sat per tranche
                tree.accountData[account].satPairPerTranche.push(
                    SaturationPair({
                        satInLAssets: addSatToTrancheStateUpdatesParams.satAvailableToAdd.satInLAssets,
                        satRelativeToL: addSatToTrancheStateUpdatesParams.satAvailableToAdd.satRelativeToL
                    })
                );
                // update sat, fields and penalties for leafs, parents
                tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche.push(
                    addSatToTrancheStateUpdates(tree, addSatToTrancheStateUpdatesParams)
                );
                // if we have a new highest leaf, we set this to true so the caller knows the
                // highestSetLeaf needs updating.
                if (tree.highestSetLeaf < addSatToTrancheStateUpdatesParams.newLeaf) {
                    tree.highestSetLeaf = uint16(addSatToTrancheStateUpdatesParams.newLeaf);
                    highestSetLeafAdded = true;
                }
            } else {
                // Keep one array slot per traversed tranche so index-to-tranche mapping
                // (lastTranche + i * direction) remains aligned for removal/penalty loops.
                tree.accountData[account].satPairPerTranche.push(SaturationPair({satInLAssets: 0, satRelativeToL: 0}));
                tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche.push(0);
            }

            unchecked {
                // we have less to add for the next tranches
                newSaturation.satRelativeToL -= addSatToTrancheStateUpdatesParams.satAvailableToAdd.satRelativeToL;
                newSaturation.satInLAssets -= addSatToTrancheStateUpdatesParams.satAvailableToAdd.satInLAssets;

                if (newSaturation.satRelativeToL > 0) {
                    // decrease only relative saturation by a factor of B (absolute debt doesn't
                    // change with price) safe to cast since it makes the value smaller.
                    newSaturation.satRelativeToL = uint128(
                        Convert.mulDiv(
                            newSaturation.satRelativeToL, endOfLiquidationAdjustmentQ72, TRANCHE_B_IN_Q72, false
                        )
                    );

                    // We only need to adjust by this factor once.
                    endOfLiquidationAdjustmentQ72 = Q72;

                    // move to next tranche
                    nextTranche += trancheDirection(netDebtX);
                    // Suggested change
                    // use all available ticks in tranche for the next iteration.
                    usableTicks = restrictUsableTicksForMinOrMaxTick(
                        uint256(TICKS_PER_TRANCHE), nextTranche, minOrMaxTick, netDebtX
                    );
                }
            }
        }

        // account exists in the tree now
        tree.accountData[account].exists = true;
    }

    /**
     * @notice get the number of ticks in the tranche that can be used based on where the
     *   liquidation ends.
     * @dev we approximate the this calculation using a percentage of ticks available.
     */
    function getUsableTicksAndLastTranche(
        int256 endOfLiquidationTick,
        bool netDebtX
    ) internal pure returns (uint256 usableTicks, int256 lastTranche) {
        int256 modResult = endOfLiquidationTick % TICKS_PER_TRANCHE;
        lastTranche = endOfLiquidationTick / TICKS_PER_TRANCHE;

        if ((modResult == 0 && !netDebtX) || (modResult != 0 && endOfLiquidationTick < 0)) {
            lastTranche += INT_NEGATIVE_ONE;
        }

        modResult = netDebtX ? -modResult : modResult;
        usableTicks = uint256(modResult < 0 ? modResult + TICKS_PER_TRANCHE : modResult);
        usableTicks = usableTicks == 0 ? uint256(TICKS_PER_TRANCHE) : usableTicks;
    }

    /**
     * @notice when the min or max tick bounding our price estimate is reached while allocating
     *   saturation, we limit how much of that tranche can be used so that we don't exceed the
     *   liquidation capacity of the tranche closest to the price with the given position.
     */
    function restrictUsableTicksForMinOrMaxTick(
        uint256 initialUsableTicks,
        int256 nextTranche,
        int256 minOrMaxTick,
        bool netDebtX
    ) internal pure returns (uint256 usableTicks) {
        int256 trancheToTicks = nextTranche * TICKS_PER_TRANCHE;
        uint256 subtract;

        if (netDebtX && minOrMaxTick < trancheToTicks + TICKS_PER_TRANCHE) {
            if (trancheToTicks < minOrMaxTick) {
                // reduce usable ticks by the min or max tick that is within the current tranche
                int256 minOrMaxTickMod25 = minOrMaxTick % TICKS_PER_TRANCHE;
                subtract = Math.min(
                    initialUsableTicks,
                    uint256(minOrMaxTick < 0 ? -minOrMaxTickMod25 : TICKS_PER_TRANCHE - minOrMaxTickMod25)
                );
            } else {
                // min tick is below the current tranche
                subtract = initialUsableTicks;
            }
        } else if (!netDebtX && minOrMaxTick > trancheToTicks) {
            if (trancheToTicks + TICKS_PER_TRANCHE > minOrMaxTick) {
                // reduce usable ticks by the min or max tick that is within the current tranche
                int256 minOrMaxTickMod25 = minOrMaxTick % TICKS_PER_TRANCHE;
                subtract = Math.min(
                    initialUsableTicks,
                    uint256(minOrMaxTick < 0 ? TICKS_PER_TRANCHE + minOrMaxTickMod25 : minOrMaxTickMod25)
                );
            } else {
                // max tick is above the current tranche
                subtract = initialUsableTicks;
            }
        }

        // subtract is always the minimum of initialUsableTicks and some calculated quantity.
        unchecked {
            usableTicks = initialUsableTicks - subtract;
        }
    }

    /**
     * @notice  helper function for adding saturation to appropriate tranches for the given
     *   parameters.
     * @param   tree that is being read from or written to
     * @param   account whose position is being considered
     * @param   tranche under consideration
     * @param   newSaturation the saturation values to add
     * @param   activeLiquidityInLAssets of the pair
     * @param   userSaturationRatioMAG2 user saturation ratio
     * @param   usableTicks number of ticks available to use
     * @return  addSatToTrancheStateUpdatesParams the struct with required params to
     */
    function getAddSatToTrancheStateUpdatesParams(
        Tree storage tree,
        address account,
        int256 tranche,
        SaturationPair memory newSaturation,
        uint256 activeLiquidityInLAssets,
        uint256 userSaturationRatioMAG2,
        uint256 usableTicks
    ) internal view returns (AddSatToTrancheStateUpdatesStruct memory addSatToTrancheStateUpdatesParams) {
        SaturationPair memory oldTrancheSaturation = tree.trancheToSaturation[int16(tranche)];

        // calculate how much relative sat can be added
        (uint128 satAvailableToAddRelativeToL, uint256 targetCapacityRelativeToLAssets) = calcSatAvailableToAddToTranche(
            activeLiquidityInLAssets,
            newSaturation.satRelativeToL,
            oldTrancheSaturation.satRelativeToL,
            userSaturationRatioMAG2,
            usableTicks
        );

        // Calculate absolute sat to add based on available space and remaining debt
        uint128 satAvailableToAddInLAssets;
        if (satAvailableToAddRelativeToL == newSaturation.satRelativeToL) {
            // We can add all remaining debt to this tranche
            satAvailableToAddInLAssets = newSaturation.satInLAssets;
        } else {
            // We can only add a portion of the debt to this tranche based on relative saturation
            // limits keeping the percentage of both absolute and relative saturation the same.
            // Safe to cast since we make satInLAssets smaller since we make
            // $$satAvailableToAddRelativeToL < newSaturation.satRelativeToL$$
            // in `calcSatAvailableToAddToTranche()`
            satAvailableToAddInLAssets = uint128(
                Convert.mulDiv(
                    satAvailableToAddRelativeToL, newSaturation.satInLAssets, newSaturation.satRelativeToL, false
                )
            );
        }

        SaturationPair memory newTrancheSaturation;
        newTrancheSaturation.satInLAssets = oldTrancheSaturation.satInLAssets + satAvailableToAddInLAssets;
        newTrancheSaturation.satRelativeToL = oldTrancheSaturation.satRelativeToL + satAvailableToAddRelativeToL;

        uint256 newLeaf = satToLeaf(newTrancheSaturation.satRelativeToL);

        addSatToTrancheStateUpdatesParams = AddSatToTrancheStateUpdatesStruct({
            tranche: tranche,
            newLeaf: newLeaf,
            oldTrancheSaturation: oldTrancheSaturation,
            newTrancheSaturation: newTrancheSaturation,
            satAvailableToAdd: SaturationPair({
                satInLAssets: satAvailableToAddInLAssets,
                satRelativeToL: satAvailableToAddRelativeToL
            }),
            targetCapacityRelativeToLAssets: targetCapacityRelativeToLAssets,
            account: account
        });
    }

    /**
     * @notice  depending on old and new leaf of the tranche, update the sats, fields and penalties
     * of the tree
     * @param   tree that is being read from or written to
     * @param   params  convenience struct holding params needed for these updates
     */
    function addSatToTrancheStateUpdates(
        Tree storage tree,
        AddSatToTrancheStateUpdatesStruct memory params
    ) internal returns (uint256) {
        // stack for gas savings
        int256 tranche = params.tranche;
        SaturationPair memory newTrancheSaturation = params.newTrancheSaturation;
        uint256 newLeaf = params.newLeaf;

        // Handle leaf transitions
        uint256 oldLeaf = tree.trancheToLeaf[int16(tranche)];

        // update sat of tranche
        tree.trancheToSaturation[int16(tranche)] = newTrancheSaturation;

        unchecked {
            if (
                oldLeaf == 0
                    && !Uint16Set.exists(tree.leafs[oldLeaf].tranches, uint16(uint256(tranche + MAX_TRANCHE + 1)))
            ) {
                // case tranche does not exist in tree, only add
                addTrancheToLeaf(tree, newTrancheSaturation, tranche, newLeaf);
            } else if (oldLeaf < newLeaf) {
                // case change to higher leaf, since we are adding sat
                addSatToTrancheStateUpdatesHigherLeaf(
                    tree, tranche, params.oldTrancheSaturation, newTrancheSaturation, oldLeaf, newLeaf
                );
            } else {
                // increase leaf sat (both absolute and relative)
                tree.leafs[newLeaf].leafSatPair.satInLAssets += params.satAvailableToAdd.satInLAssets;
                tree.leafs[newLeaf].leafSatPair.satRelativeToL += params.satAvailableToAdd.satRelativeToL;

                // update sat up the tree (use absolute saturation)
                addSatUpTheTree(tree, params.satAvailableToAdd.satInLAssets, true);
            }
        }

        return getEffectivePenalty(tree, newLeaf, tranche);
    }

    /**
     * @notice  Add sat to tranche state updates higher leaf
     * @param   tree that is being read from or written to
     * @param   tranche  the tranche that is being moved
     * @param   oldTrancheSaturation  the old sat of the tranche
     * @param   newTrancheSaturation  the new sat of the tranche
     * @param   oldLeaf  the leaf that the tranche was located in before it was removed
     * @param   newLeaf  the leaf that the tranche was located in after it was removed
     */
    function addSatToTrancheStateUpdatesHigherLeaf(
        Tree storage tree,
        int256 tranche,
        SaturationPair memory oldTrancheSaturation,
        SaturationPair memory newTrancheSaturation,
        uint256 oldLeaf,
        uint256 newLeaf
    ) internal {
        // Accumulate penalty adjustment before modifying leaf state.
        // Bridges the gap between old and new leaf penalty accumulators. `SafeCast.toInt256`
        // guards the uint→int conversion against the (astronomically unlikely) case where a
        // leaf penalty exceeds `type(int256).max`.
        tree.tranchePenaltyAdjustment[int16(tranche)] += SafeCast.toInt256(
            getPenaltySharesPerSatFromLeaf(tree, oldLeaf)
        ) - SafeCast.toInt256(getPenaltySharesPerSatFromLeaf(tree, newLeaf));

        // remove from old leaf by updating sats and fields
        removeTrancheToLeaf(tree, oldTrancheSaturation, tranche, oldLeaf);
        // add to new leaf by updating sats and fields
        addTrancheToLeaf(tree, newTrancheSaturation, tranche, newLeaf);
    }

    /**
     * @notice  removing a tranche from a leaf, update the fields and sats up the tree
     * @param   tree that is being read from or written to
     * @param   trancheSaturation  the saturation of the tranche being moved
     * @param   tranche  that is being moved
     * @param   leaf  the leaf
     */
    function removeTrancheToLeaf(
        Tree storage tree,
        SaturationPair memory trancheSaturation,
        int256 tranche,
        uint256 leaf
    ) internal {
        // set the new leaf of the tranche
        tree.trancheToLeaf[int16(tranche)] = 0;

        unchecked {
            // update the sat of leaf (both absolute and relative)
            tree.leafs[uint16(leaf)].leafSatPair.satInLAssets -= trancheSaturation.satInLAssets;
            tree.leafs[uint16(leaf)].leafSatPair.satRelativeToL -= trancheSaturation.satRelativeToL;

            // update the tranches set of the leaf
            uint256 nodeIndex = leaf / CHILDREN_PER_NODE;
            // unset the fields up the tree
            if (!Uint16Set.remove(tree.leafs[uint16(leaf)].tranches, uint16(uint256(tranche + MAX_TRANCHE + 1)))) {
                setXorUnsetFieldBitUpTheTree(tree, LOWEST_LEVEL_INDEX, nodeIndex, leaf % CHILDREN_PER_NODE, 0);
            }

            // update sat up the tree (use absolute saturation for tree to be used for penalty calculation)
            addSatUpTheTree(tree, trancheSaturation.satInLAssets, false);
        }
    }

    /**
     * @notice  adding a tranche from a leaf, update the fields and sats up the tree
     * @param   tree that is being read from or written to
     * @param   tranche  that is being moved
     * @param   trancheSaturation  the saturation of the tranche being moved
     * @param   leaf  the leaf
     */
    function addTrancheToLeaf(
        Tree storage tree,
        SaturationPair memory trancheSaturation,
        int256 tranche,
        uint256 leaf
    ) internal {
        unchecked {
            // set the new leaf of the tranche
            tree.trancheToLeaf[int16(tranche)] = uint16(leaf);

            // update the sat of leaf (both absolute and relative)
            tree.leafs[uint16(leaf)].leafSatPair.satInLAssets += trancheSaturation.satInLAssets;
            tree.leafs[uint16(leaf)].leafSatPair.satRelativeToL += trancheSaturation.satRelativeToL;

            // update the tranches set of the leaf
            uint256 nodeIndex = leaf / CHILDREN_PER_NODE;
            // set the fields up the tree
            if (!Uint16Set.insert(tree.leafs[uint16(leaf)].tranches, uint16(uint256(tranche + MAX_TRANCHE + 1)))) {
                setXorUnsetFieldBitUpTheTree(tree, LOWEST_LEVEL_INDEX, nodeIndex, leaf % CHILDREN_PER_NODE, 1);
            }

            // update sat up the tree (use absolute saturation for tree to be used for penalty calculation)
            addSatUpTheTree(tree, trancheSaturation.satInLAssets, true);
        }
    }

    /**
     * @notice  recursively add sat up the tree
     * @param   tree that is being read from or written to
     * @param   satInLAssets  sat to add to the current node, usually uint112, int to allow subtracting sat up the tree
     */
    function addSatUpTheTree(Tree storage tree, uint128 satInLAssets, bool add) internal {
        uint128 currentSat = tree.totalSatInLAssets;
        // We should never have negative sat, this is a precaution.
        tree.totalSatInLAssets =
            add ? currentSat + satInLAssets : currentSat - uint128(Math.min(currentSat, satInLAssets));
    }

    // penalty functions

    /**
     * @notice  update penalties in the tree given
     * @param   tree that is being read from or written to
     * @param   thresholdLeaf  from which leaf on the penalty needs to be added inclusive
     * @param   addPenaltyInBorrowLSharesPerSatInQ72  the penalty to be added
     */
    function updatePenalties(
        Tree storage tree,
        uint256 thresholdLeaf,
        uint256 addPenaltyInBorrowLSharesPerSatInQ72
    ) internal {
        uint256 highestLeafPlusOne = tree.highestSetLeaf + 1;
        if (thresholdLeaf < highestLeafPlusOne) {
            for (uint256 leafIndex = thresholdLeaf; leafIndex < highestLeafPlusOne; leafIndex++) {
                tree.leafs[leafIndex].penaltyInBorrowLSharesPerSatInQ72 += addPenaltyInBorrowLSharesPerSatInQ72;
            }
        }
    }

    /**
     * @notice  recursive function to sum penalties from leaf to root
     * @param   tree that is being read from or written to
     * @param   leaf  index (0 based) of the leaf
     * @return  penaltyInBorrowLSharesPerSatInQ72  total penalty at the leaf, non-negative but
     * returned as an int for recursion
     */
    function getPenaltySharesPerSatFromLeaf(
        Tree storage tree,
        uint256 leaf
    ) private view returns (uint256 penaltyInBorrowLSharesPerSatInQ72) {
        return tree.leafs[uint16(leaf)].penaltyInBorrowLSharesPerSatInQ72;
    }

    /**
     * @notice  get effective penalty for a tranche, combining leaf penalty and tranche adjustment.
     * When a tranche moves between leaves, the adjustment bridges the gap between the old and new
     * leaf accumulators so that existing accounts' onset values remain valid.
     * @dev Invariant: `leafPen + adjustment >= 0` always holds. Within a single tranche
     * lifecycle, moves preserve continuity of `effective` (the move logic adds the same delta
     * to `adjustment` that it subtracts from `leafPen`), so `effective` only ever grows from
     * its initial non-negative value. The `delete` in `removeSatFromTrancheStateUpdates` resets
     * the adjustment when a tranche empties so each new lifecycle starts from `adj = 0`.
     * @param   tree that is being read from
     * @param   leaf  index (0 based) of the leaf containing the tranche
     * @param   tranche  the tranche identifier
     * @return  effectivePenalty  the effective cumulative penalty for this tranche
     */
    function getEffectivePenalty(
        Tree storage tree,
        uint256 leaf,
        int256 tranche
    ) private view returns (uint256 effectivePenalty) {
        uint256 leafPenalty = getPenaltySharesPerSatFromLeaf(tree, leaf);
        int256 adjustment = tree.tranchePenaltyAdjustment[int16(tranche)];
        effectivePenalty = adjustment >= 0 ? leafPenalty + uint256(adjustment) : leafPenalty - uint256(-adjustment);
    }

    /**
     * @notice  calc penalty owed by account for repay, total over all the tranches that might
     * contain this accounts' sat
     * @param   tree that is being read from or written to
     * @param   account  whose position is being considered
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     */
    function accrueAccountPenalty(
        Tree storage tree,
        address account
    ) internal returns (uint256 penaltyInBorrowLShares) {
        unchecked {
            // beginning tranche
            int256 tranche = tree.accountData[account].lastTranche;

            uint256 satArrayLength = tree.accountData[account].satPairPerTranche.length;
            // add penalty per tranche
            for (uint256 trancheIndex = 0; trancheIndex < satArrayLength; trancheIndex++) {
                // account might have no sat in this tranche
                SaturationPair memory accountSaturationInTranche =
                    tree.accountData[account].satPairPerTranche[trancheIndex];
                if (accountSaturationInTranche.satInLAssets > 0) {
                    // leaf that the tranche belongs to
                    uint256 leaf = tree.trancheToLeaf[int16(tranche)];

                    uint256 penaltyTrancheInBorrowLShares;
                    // calculate penalty for this tranche and update its onset value in the penalties array
                    (
                        penaltyTrancheInBorrowLShares,
                        tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche[trancheIndex]
                    ) = calcNewAccountPenalty(
                        tree, leaf, accountSaturationInTranche.satInLAssets, account, trancheIndex, tranche
                    );
                    penaltyInBorrowLShares += penaltyTrancheInBorrowLShares;
                }
                // next tranche
                tranche += trancheDirection(tree.netX);
            }
        }

        tree.accountData[account].penaltyInBorrowLShares += SafeCast.toUint112(penaltyInBorrowLShares);
    }

    /**
     * @notice move in the appropriate direction when iterating.
     * @param netDebtX direction flag
     */
    function trancheDirection(
        bool netDebtX
    ) private pure returns (int256) {
        return netDebtX ? INT_ONE : INT_NEGATIVE_ONE;
    }

    /**
     * @notice  calc penalty owed by account for repay, total over all the tranches that might
     * contain this accounts' sat
     * @param   tree that is being read from or written to
     * @param   leaf  the leaf that the tranche belongs to
     * @param   accountSatInTrancheInLAssets  the sat of the account in the tranche
     * @param   account  whose position is being considered
     * @param   trancheIndex  the index of the tranche that is being added to
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     * @return  accountTreePenaltyInBorrowLSharesPerSatInQ72  the penalty owed by the account in the tranche
     */
    function calcNewAccountPenalty(
        Tree storage tree,
        uint256 leaf,
        uint256 accountSatInTrancheInLAssets,
        address account,
        uint256 trancheIndex,
        int256 tranche
    ) private view returns (uint256 penaltyInBorrowLShares, uint256 accountTreePenaltyInBorrowLSharesPerSatInQ72) {
        // account being moved in the tree => account should take penalty
        accountTreePenaltyInBorrowLSharesPerSatInQ72 = getEffectivePenalty(tree, leaf, tranche);
        // round up to assign account more penalty
        penaltyInBorrowLShares = Convert.mulDiv(
            accountTreePenaltyInBorrowLSharesPerSatInQ72
                - tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche[trancheIndex],
            accountSatInTrancheInLAssets,
            Q72,
            true
        );
    }

    /**
     * @notice  accrue penalties since last accrual based on all over saturated positions
     *
     * @param   satStruct  main data struct
     * @param   account  whose position is being considered
     * @param   externalLiquidity  Swap liquidity outside this pool
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     * @param   fragileLiquidityAssets  fragile liquidity removed from active liquidity so the penalty
     * threshold reads the same liquidity we use to measure risk capacity in update()
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     * @return  accountPenaltyInBorrowLShares  the penalty owed by the account
     */
    function accruePenalties(
        SaturationStruct storage satStruct,
        address account,
        uint256 externalLiquidity,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL,
        uint256 fragileLiquidityAssets
    ) internal returns (uint112 penaltyInBorrowLShares, uint112 accountPenaltyInBorrowLShares) {
        if (duration > 0) {
            // Penalty threshold leaf, on active liquidity with fragile liquidity removed, matching liquidation
            uint256 thresholdLeaf = satToLeaf(
                (externalLiquidity + allAssetsDepositL - allAssetsBorrowL - fragileLiquidityAssets)
                    * START_SATURATION_PENALTY_RATIO_IN_MAG2 / MAG2
            );
            (
                uint256 penaltyNetXInBorrowLShares,
                uint256 penaltyNetXInBorrowLSharesPerSatInQ72,
                uint256 penaltyNetYInBorrowLShares,
                uint256 penaltyNetYInBorrowLSharesPerSatInQ72
            ) = calcNewPenalties(
                satStruct, thresholdLeaf, duration, allAssetsDepositL, allAssetsBorrowL, allSharesBorrowL
            );
            penaltyInBorrowLShares = SafeCast.toUint112(penaltyNetXInBorrowLShares + penaltyNetYInBorrowLShares);

            // update penalties for the tree

            if (penaltyNetXInBorrowLSharesPerSatInQ72 > 0) {
                updatePenalties(satStruct.netXTree, thresholdLeaf, penaltyNetXInBorrowLSharesPerSatInQ72);
            }
            if (penaltyNetYInBorrowLSharesPerSatInQ72 > 0) {
                updatePenalties(satStruct.netYTree, thresholdLeaf, penaltyNetYInBorrowLSharesPerSatInQ72);
            }
        }

        // update penalties for the account

        if (account != ZERO_ADDRESS) {
            accountPenaltyInBorrowLShares = accrueAndRemoveAccountPenalty(satStruct, account);
        }
    }

    /**
     * @notice  calc new penalties
     * @param   satStruct  main data struct
     * @param   thresholdLeaf  the leaf at and above which saturation is in penalty; derived from the
     * active liquidity with fragile liquidity removed so it matches saturation updates and liquidation.
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     * @return  penaltyNetXInBorrowLShares  the penalty net X in borrow l shares
     * @return  penaltyNetXInBorrowLSharesPerSatInQ72  the penalty net X in borrow l shares per sat
     * in q72
     * @return  penaltyNetYInBorrowLShares  the penalty net Y in borrow l shares
     * @return  penaltyNetYInBorrowLSharesPerSatInQ72  the penalty net Y in borrow l shares per sat
     * in q72
     */
    function calcNewPenalties(
        SaturationStruct storage satStruct,
        uint256 thresholdLeaf,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL
    )
        private
        view
        returns (
            uint256 penaltyNetXInBorrowLShares,
            uint256 penaltyNetXInBorrowLSharesPerSatInQ72,
            uint256 penaltyNetYInBorrowLShares,
            uint256 penaltyNetYInBorrowLSharesPerSatInQ72
        )
    {
        uint256 currentBorrowUtilizationInWad = Interest.getUtilizationInWads(allAssetsBorrowL, allAssetsDepositL);

        // Calculate saturation percentage using the full satStruct
        uint256 saturationUtilizationInWad = getSatPercentageInWads(satStruct);

        (penaltyNetXInBorrowLShares, penaltyNetXInBorrowLSharesPerSatInQ72) = calcNewPenaltiesGivenTree(
            satStruct.netXTree,
            thresholdLeaf,
            duration,
            currentBorrowUtilizationInWad,
            saturationUtilizationInWad,
            allAssetsDepositL,
            allAssetsBorrowL,
            allSharesBorrowL
        );
        (penaltyNetYInBorrowLShares, penaltyNetYInBorrowLSharesPerSatInQ72) = calcNewPenaltiesGivenTree(
            satStruct.netYTree,
            thresholdLeaf,
            duration,
            currentBorrowUtilizationInWad,
            saturationUtilizationInWad,
            allAssetsDepositL,
            allAssetsBorrowL,
            allSharesBorrowL
        );
    }

    /**
     * @notice  calc new penalties given tree
     * @param   tree that is being read from or written to
     * @param   thresholdLeaf the threshold leaf
     * @param   duration since last accrual of penalties
     * @param   currentBorrowUtilizationInWad current borrow utilization in WAD
     * @param   saturationUtilizationInWad saturation utilization in WAD
     * @param   allAssetsDepositL allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL allAsset[BORROW_L]
     * @param   allSharesBorrowL allShares[BORROW_L]
     * @return  penaltyInBorrowLShares the penalty net X in borrow l shares
     * @return  penaltyInBorrowLSharesPerSatInQ72 the penalty net X in borrow l shares per sat in
     * q72
     */
    function calcNewPenaltiesGivenTree(
        Tree storage tree,
        uint256 thresholdLeaf,
        uint256 duration,
        uint256 currentBorrowUtilizationInWad,
        uint256 saturationUtilizationInWad,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL
    ) private view returns (uint256 penaltyInBorrowLShares, uint256 penaltyInBorrowLSharesPerSatInQ72) {
        unchecked {
            // total saturation after thresholdLeaf
            uint128 totalSatLAssetsInPenalty = calcTotalSatAfterLeafInclusive(tree, thresholdLeaf);

            // if no sat over threshold, we are done
            if (totalSatLAssetsInPenalty == 0) return (0, 0);

            // Calculate penalty rate
            uint256 penaltyRatePerSecondInWads = calcSaturationPenaltyRatePerSecondInWads(
                currentBorrowUtilizationInWad, saturationUtilizationInWad, totalSatLAssetsInPenalty, allAssetsDepositL
            );

            uint256 penaltyInBorrowLAssets = Interest.computeInterestAssetsGivenRate(
                duration, totalSatLAssetsInPenalty, allAssetsDepositL, penaltyRatePerSecondInWads
            );

            // have accounts owe more (ceil)
            uint256 penaltyInBorrowLAssetsPerSatInQ72 =
                Math.ceilDiv(penaltyInBorrowLAssets * Q72, totalSatLAssetsInPenalty);

            // convert to shares
            penaltyInBorrowLSharesPerSatInQ72 =
                Convert.toShares(penaltyInBorrowLAssetsPerSatInQ72, allAssetsBorrowL, allSharesBorrowL, ROUNDING_UP);

            penaltyInBorrowLShares =
                Convert.toShares(penaltyInBorrowLAssets, allAssetsBorrowL, allSharesBorrowL, !ROUNDING_UP);
        }
    }

    /**
     * @notice  accrue and remove account penalty
     * @param   satStruct  main data struct
     * @param   account  whose position is being considered
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     */
    function accrueAndRemoveAccountPenalty(
        SaturationStruct storage satStruct,
        address account
    ) internal returns (uint112 penaltyInBorrowLShares) {
        penaltyInBorrowLShares = SafeCast.toUint112(accrueAccountPenalty(satStruct.netXTree, account))
            + SafeCast.toUint112(accrueAccountPenalty(satStruct.netYTree, account));

        satStruct.netXTree.accountData[account].penaltyInBorrowLShares = 0;
        satStruct.netYTree.accountData[account].penaltyInBorrowLShares = 0;
    }

    // tree util functions

    /**
     * @notice  recursive function to unset the field when removing a tranche from a leaf
     * @param   tree that is being read from or written to
     * @param   level  level being updated
     * @param   nodeIndex  index is the position (0 based) of the node in its level
     * @param   lowerNodePos  pos is the relative position (0 based) of the node in its parent
     * @param   set  1 for set, 0 for unset
     */
    function setXorUnsetFieldBitUpTheTree(
        Tree storage tree,
        uint256 level,
        uint256 nodeIndex,
        uint256 lowerNodePos,
        uint256 set
    ) internal {
        unchecked {
            // our bit fields store the bits in reverse order of the tree
            uint256 invertedLowerNodePos = CHILDREN_PER_NODE - 1 - lowerNodePos;

            uint256 currentNode = tree.nodes[level][nodeIndex];
            // read the current bit of the node in its field
            uint256 currentBit = readFieldBitFromNode(currentNode, invertedLowerNodePos);
            // if we are unsetting and bit is unset, we are done, since all parents will already be unset
            // if we are setting and bit is set, we are done, since all parents will already be set
            if (currentBit == set) return;

            // flip un-sets the bit since the bit must have been set
            currentNode = writeFlippedFieldBitToNode(currentNode, invertedLowerNodePos);
            // write to currentNode on stack first to save gas
            tree.nodes[level][nodeIndex] = currentNode;

            // if we are at the root, we are done
            if (level == 0) return;

            if (set == 0) {
                // some other child is set, parents can remain set, since we are unsetting
                if (readFieldFromNode(currentNode) != 0) return;
            }

            // nothing else set, unset parents recursively
            setXorUnsetFieldBitUpTheTree(
                tree, level - 1, nodeIndex / CHILDREN_PER_NODE, nodeIndex % CHILDREN_PER_NODE, set
            );
        }
    }

    /**
     * @notice  recursive function to find the highest set leaf starting from a leaf, first
     * upwards, until a set field is found, then downwards to find the best set leaf
     * @param   tree that is being read from or written to
     * @param   level  that we are checking
     * @param   nodeIndex  corresponding to our leaf at our `level`
     * @return  highestSetLeaf highest leaf that is set in the tree
     */
    function findHighestSetLeafUpwards(
        Tree storage tree,
        uint256 level,
        uint256 nodeIndex
    ) private view returns (uint256 highestSetLeaf) {
        unchecked {
            if (readFieldFromNode(tree.nodes[level][nodeIndex]) == 0) {
                if (level == 0) return 0;
                return findHighestSetLeafUpwards(tree, level - 1, nodeIndex / CHILDREN_PER_NODE);
            }
            return findHighestSetLeafDownwards(tree, level, nodeIndex);
        }
    }

    /**
     * @notice  recursive function to find the highest set leaf starting from a node, downwards
     * @dev internal for testing only
     * @param   tree that is being read from or written to
     * @param   level  that we are starting from
     * @param   nodeIndex  that we are starting from
     * @return  leaf highest leaf under the node that is set
     */
    function findHighestSetLeafDownwards(
        Tree storage tree,
        uint256 level,
        uint256 nodeIndex
    ) internal view returns (uint256 leaf) {
        unchecked {
            nodeIndex = CHILDREN_PER_NODE * (nodeIndex + 1) - BitLib.ctz64(tree.nodes[level][nodeIndex]) - 1;

            // if we are at the bottom of the tree, we have found the leaf, which is the node
            if (level == LOWEST_LEVEL_INDEX) return nodeIndex;

            // recurse to the lower level
            return findHighestSetLeafDownwards(tree, level + 1, nodeIndex);
        }
    }

    // liq sqrt price functions

    /**
     * @notice Calc sqrt price at which positions' LTV would reach LTV_MAX. Given the net $$L$$,
     *   $$X$$, and Y, we define the the sqrt price $$s_p$$ at which the position would be at the
     *   expected loan to value of liquidation $$k$$, then the following formulas are what we are
     *   calculating,
     *
     *   ```math
     *     \begin{align}
     *       k &=
     *         \begin{cases}
     *           -\frac{L + \frac{X}{s_p}}{L + Y \cdot s_p}
     *           \text{ if } L+ \frac{X}{s_p} < 0
     *           \\
     *           -\frac{L + Y \cdot s_p}{L + \frac{X}{s_p}}
     *           \text{ if } L + Y \cdot s_p < 0
     *         \end{cases}
     *       \\
     *
     *       s_p &=
     *         \begin{cases}
     *           \frac{
     *             -(k+1)L +
     *             \sqrt{\left((k+1)L\right)^2 - 4 \left( k\cdot Y \right) \left(X \right)}
     *           }{
     *             2 \cdot k \cdot Y
     *           }
     *           \text{ if } L + \frac{X}{s_p} < 0
     *         \\
     *           \frac{
     *             -(k+1)L -
     *             \sqrt{((k+1)L)^2-4(Y)(k\cdot X)}
     *           }{
     *             2\cdot k
     *           }
     *           \text{ if } L + Y \cdot s_p < 0
     *         \end{cases}
     *     \end{align}
     *   ```
     *
     *  The equation gives four solutions due to the plus minus of the radical, but we choose the
     *  direction due to the conditions. When we have a net debt of x, $$L + \frac{X}{s_p} < 0$$,
     *  the loan to value will be increasing as the price decreases, thus we choose the positive
     *  value of the radical. For the net debt of y, $$L + Y \cdot s_p < 0$$ we have the loan to
     *  value increasing as the price increases, thus we use the negative value of the radical.
     *
     * @notice Output guarantees $$0 \le liqSqrtPriceXInQ72 \le uint256(type(uint56).max) << 72$$
     * (fuzz tested and logic)
     * @notice Outside above range, outputs 0 (essentially no liq)
     * @notice Does not revert if `LTV_MAX < LTV`, rather `LTV_MAX < LTV` causing liq points are
     *  returned as 0, as if they do not exist, based on the assumption `LTV \le LTV_MAX`
     * @param   userAssets  The position
     * @return  netDebtXLiqSqrtPriceXInQ72  0 if no netX liq price exists
     * @return  netDebtYLiqSqrtPriceXInQ72  0 if no netY liq price exists
     */
    function calcLiqSqrtPriceQ72(
        uint256[6] memory userAssets
    ) internal pure returns (uint256 netDebtXLiqSqrtPriceXInQ72, uint256 netDebtYLiqSqrtPriceXInQ72) {
        int256 netLInMAG2;
        int256 netXInMAG2;
        int256 netYInMAG2;
        unchecked {
            netLInMAG2 = int256(userAssets[DEPOSIT_L]) - int256(userAssets[BORROW_L]);
            netXInMAG2 = int256(userAssets[DEPOSIT_X]) - int256(userAssets[BORROW_X]);
            netYInMAG2 = int256(userAssets[DEPOSIT_Y]) - int256(userAssets[BORROW_Y]);
        }

        if (netLInMAG2 >= 0 && netXInMAG2 >= 0 && netYInMAG2 >= 0) {
            // no net debt, no liquidation sqrt price
            return (0, 0);
        }

        uint256 netLAbsInMAG2; // uint112
        uint256 netXAbsInMAG2; // uint112
        uint256 netYAbsInMAG2; // uint112

        unchecked {
            // netY*x^2 + netL*x + netX == 0
            // with netY == Y_hat, netL == L_hat * (LTV_MAX/TICKS_PER_TRANCHE + 1), netX == X_hat * LTV_MAX/TICKS_PER_TRANCHE
            // and x is the liq sqrt price in X of Y

            netYInMAG2 *= int256(MAG2); // everything in MAG2 saves some computation later
            netYAbsInMAG2 = uint256(0 <= netYInMAG2 ? netYInMAG2 : -netYInMAG2);

            bool netLPositive = 0 <= netLInMAG2;
            netLAbsInMAG2 = uint256(netLPositive ? netLInMAG2 : -netLInMAG2);
            netLAbsInMAG2 = netLAbsInMAG2 * EXPECTED_SATURATION_LTV_PLUS_ONE_MAG2;
            netLInMAG2 = int256(netLAbsInMAG2);
            if (!netLPositive) netLInMAG2 = -netLInMAG2;

            bool netXPositive = 0 <= netXInMAG2;
            netXAbsInMAG2 = uint256(netXPositive ? netXInMAG2 : -netXInMAG2);
            netXAbsInMAG2 = netXAbsInMAG2 * EXPECTED_SATURATION_LTV_MAG2;
            netXInMAG2 = int256(netXAbsInMAG2);
            if (!netXPositive) netXInMAG2 = -netXInMAG2;
        }

        unchecked {
            if (netYAbsInMAG2 == 0) {
                // Ŷ==0

                // netL != 0 != netX
                // netL xor netX < 0 else under col => 0 <= -netX/netL
                // netL*x+netX=0 <=> x=-netX/netL
                uint256 liqSqrtPriceXInQ72 = Convert.mulDiv(netXAbsInMAG2, Q72, netLAbsInMAG2, false);

                // borrowing L against X
                if (userAssets[BORROW_X] == 0) {
                    netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
                // borrowing X against L
                else {
                    netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
            }
            // netY != 0
            else if (netXAbsInMAG2 == 0) {
                // X̂==0

                // netL xor netY < 0 else under col => 0 <= -netL/netY and netY*x^2+netL*x=0 <=> x=-netL/netY
                uint256 liqSqrtPriceXInQ72 = Convert.mulDiv(netLAbsInMAG2, Q72, netYAbsInMAG2, false);

                // borrowing L against Y
                if (userAssets[BORROW_Y] == 0) {
                    netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
                // borrowing Y against L
                else {
                    netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
            }
            // netX != 0
            else if (netLAbsInMAG2 == 0) {
                // L̂==0
                // positionXY == mixed genuinely
                // netX xor netY < 0 else under col => 0 <= -netX/netY and netY*x^2+netX=0 <=> x=sqrt(-netX/netY)

                // 0 < accountLXYInAssets[BORROW_X] && 0 < accountLXYInAssets[BORROW_Y] not possible, assuming good LTV

                if (0 < userAssets[DEPOSIT_X]) {
                    if (0 < userAssets[DEPOSIT_Y]) return (0, 0);
                } // no solution

                uint256 liqSqrtPriceXInQ72 = Math.sqrt(
                    netXAbsInMAG2 < Q112
                        ? Convert.mulDiv(netXAbsInMAG2, Q144, netYAbsInMAG2, false)
                        // divide by MAG2 first to preserve more precision in Q144 / netY
                        // calculation
                        : (netXAbsInMAG2 / MAG2) * (Q144 / (netYAbsInMAG2 / MAG2))
                );

                // borrowing Y against X
                if (0 < userAssets[DEPOSIT_X]) {
                    netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
                // borrowing X against Y
                else {
                    netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
            } else {
                // netY != 0 && netL != 0 && netX != 0

                (netDebtXLiqSqrtPriceXInQ72, netDebtYLiqSqrtPriceXInQ72) = calcLiqSqrtPriceQ72HandleAllABCNonZero(
                    CalcLiqSqrtPriceHandleAllABCNonZeroStruct(
                        netLInMAG2, netXInMAG2, netYInMAG2, netYAbsInMAG2, userAssets[BORROW_X], userAssets[BORROW_Y]
                    )
                );
            }

            // netX uses the saturation LTV divisor before bounding so the final value is checked.
            if (0 < netDebtXLiqSqrtPriceXInQ72) {
                netDebtXLiqSqrtPriceXInQ72 =
                    Convert.mulDiv(netDebtXLiqSqrtPriceXInQ72, MAG2, EXPECTED_SATURATION_LTV_MAG2, false);
            }

            // bounding
            if (
                netDebtXLiqSqrtPriceXInQ72 < TickMath.MIN_SQRT_PRICE_IN_Q72
                    || TickMath.MAX_SQRT_PRICE_IN_Q72 < netDebtXLiqSqrtPriceXInQ72
            ) {
                netDebtXLiqSqrtPriceXInQ72 = 0;
            }
            if (
                netDebtYLiqSqrtPriceXInQ72 < TickMath.MIN_SQRT_PRICE_IN_Q72
                    || TickMath.MAX_SQRT_PRICE_IN_Q72 < netDebtYLiqSqrtPriceXInQ72
            ) {
                netDebtYLiqSqrtPriceXInQ72 = 0;
            }
        }
    }

    /**
     * @notice  calc liq price when the quadratic has all 3 terms, netY,netL,netX, i.e. X, Y, L are
     * all significant
     * @param   input the position
     * @return  netDebtXLiqSqrtPriceXInQ72 0 if no netX liq price exists
     * @return  netDebtYLiqSqrtPriceXInQ72 0 if no netY liq price exists
     */
    function calcLiqSqrtPriceQ72HandleAllABCNonZero(
        CalcLiqSqrtPriceHandleAllABCNonZeroStruct memory input
    ) internal pure returns (uint256 netDebtXLiqSqrtPriceXInQ72, uint256 netDebtYLiqSqrtPriceXInQ72) {
        int256 numeratorPlusInMAG2;
        int256 numeratorMinusInMAG2;
        unchecked {
            // stack for gas savings
            int256 netLInMAG2 = input.netLInMAG2;

            // calc radical == netL^2 - 4*netY*netX
            int256 radicalInMAG4 = netLInMAG2 * netLInMAG2 - 4 * input.netYInMAG2 * input.netXInMAG2;

            // Two cases, if negative sqrt has no solution in the reals.
            // If negative, there are no solutions to the equation, this is a straddle that does
            // not ever reach our liquidation price.
            // Otherwise,
            // netL^2=4*netY*netX <=> x=-netL/2/netY => !MixedXY
            // !AllB, else would violate LTV
            // AllD, which has no liq point, except a single point where we cannot be, else bad LTV
            if (radicalInMAG4 <= 0) return (0, 0);

            // 0 < radical

            int256 sqrtRadicalInMAG2 = int256(Math.sqrt(uint256(radicalInMAG4)));
            numeratorPlusInMAG2 = netLInMAG2 + sqrtRadicalInMAG2;
            numeratorMinusInMAG2 = netLInMAG2 - sqrtRadicalInMAG2;
        }

        // stack for gas savings
        uint256 netYAbsInMAG2 = input.netYAbsInMAG2;

        // calc solution fraction
        uint256 liqSqrtPriceXPlusInQ72;
        uint256 liqSqrtPriceXMinusInQ72;
        unchecked {
            liqSqrtPriceXPlusInQ72 = Convert.mulDiv(
                uint256(numeratorPlusInMAG2 < 0 ? -numeratorPlusInMAG2 : numeratorPlusInMAG2),
                Q72,
                2 * netYAbsInMAG2,
                false
            );
            liqSqrtPriceXMinusInQ72 = Convert.mulDiv(
                uint256(numeratorMinusInMAG2 < 0 ? -numeratorMinusInMAG2 : numeratorMinusInMAG2),
                Q72,
                2 * netYAbsInMAG2,
                false
            );
        }

        if (input.borrowedXAssets == 0) {
            if (input.borrowedYAssets == 0) {
                // AllD => good LTV outside range
                netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXPlusInQ72;
                netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXMinusInQ72;
            } else {
                // YB != 0
                // XY mixed, XD != 0
                netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXPlusInQ72;
            }
        } else {
            // XB != 0
            // if (accountLXYInAssets[BORROW_Y] == 0) {
            if (input.borrowedYAssets == 0) {
                // XY mixed, YD != 0
                netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXMinusInQ72;
            } else {
                // AllB => good LTV inside range
                netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXPlusInQ72;
                netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXMinusInQ72;
            }
        }
    }

    // sat functions

    /**
     * @notice Calculate the ratio by which the saturation has changed for `account`.
     * @dev the algorithm here matches that of `addSatToTranche()`, but accumulates the total
     *   saturation to compare it to what is needed. If the allocated total saturation is less than
     *   what is needed, we return the ratio to help determine the saturation adjustment premium.
     * @param satStruct The saturation struct containing both netX and netY trees.
     * @param inputParams The params containing the position of `account`.
     * @param liqSqrtPriceInXInQ72 The liquidation price for netX.
     * @param liqSqrtPriceInYInQ72 The liquidation price for netY.
     * @param account The account for which we are calculating the saturation change ratio.
     * @return ratioBips The ratio representing the change in saturation for account.
     */
    function calcSatChangeRatioBips(
        SaturationStruct storage satStruct,
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 liqSqrtPriceInYInQ72,
        address account,
        uint256 desiredSaturationMAG2
    ) internal view returns (uint256 ratioBips) {
        uint256 ratioNetXBips;
        uint256 ratioNetYBips;

        // Calculate ratios for netX tree only if netX liquidation price exists
        if (liqSqrtPriceInXInQ72 > 0) {
            ratioNetXBips = calcTreeRatioBips(
                satStruct.netXTree.accountData[account],
                inputParams,
                liqSqrtPriceInXInQ72,
                liqSqrtPriceInYInQ72,
                desiredSaturationMAG2,
                true
            );
        }
        // Calculate ratios for netY tree only if netY liquidation price exists
        if (liqSqrtPriceInYInQ72 > 0) {
            ratioNetYBips = calcTreeRatioBips(
                satStruct.netYTree.accountData[account],
                inputParams,
                liqSqrtPriceInXInQ72,
                liqSqrtPriceInYInQ72,
                desiredSaturationMAG2,
                false
            );
        }
        ratioBips = Math.max(ratioNetXBips, ratioNetYBips);
    }

    /**
     * @dev Per-tree ratio computation extracted from `calcSatChangeRatioBips`.
     *
     * Stored `satPairs[i].satRelativeToL` lives in tranche-i units
     * (= 1/B^i of tranche-0 units, modulo the partial first-tranche adjustment).
     * `scaleAndSumSaturation` converts each stored sat back to tranche-0 units, so
     * the old and new saturation totals are compared in the same unit system.
     *
     * @param accountData Stored account saturation data for the tree being evaluated.
     * @param inputParams User asset balances and pool state used to compute the new saturation.
     * @param liqSqrtPriceInXInQ72 Liquidation sqrt price (upper root) in Q72, for the netDebtX side.
     * @param liqSqrtPriceInYInQ72 Liquidation sqrt price (lower root) in Q72, for the netDebtY side.
     * @param desiredSaturationMAG2 Target saturation level in MAG2 units used to project the new sat.
     * @param netDebtX True when evaluating the netDebtX tree; false for the netDebtY tree.
     * @return ratioBips Growth ratio in BIPS of (old + remaining) / old saturation for this tree;
     *                  zero when the new saturation does not exceed the absorbed old saturation.
     */
    function calcTreeRatioBips(
        Account storage accountData,
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 liqSqrtPriceInYInQ72,
        uint256 desiredSaturationMAG2,
        bool netDebtX
    ) private view returns (uint256 ratioBips) {
        // Note that we don't check the start of liquidation since we don't want this check
        // to fail during a liquidation.
        (SaturationPair memory newSaturation, int256 endOfLiquidationInTicks,) = calcLastTickAndSaturation(
            inputParams, liqSqrtPriceInXInQ72, liqSqrtPriceInYInQ72, desiredSaturationMAG2, netDebtX, true
        );

        // reduce saturation by newSaturation by buffer
        uint256 newSatInLAssets = uint256(newSaturation.satRelativeToL) * MAG2 / SATURATION_TIME_BUFFER_IN_MAG2;

        (, int256 currentLastTranche) = getUsableTicksAndLastTranche(endOfLiquidationInTicks, netDebtX);
        uint256 oldSatInLAssets = scaleAndSumSaturation(
            accountData.satPairPerTranche,
            endOfLiquidationInTicks,
            netDebtX,
            accountData.lastTranche,
            currentLastTranche
        );

        if (newSatInLAssets > oldSatInLAssets) {
            uint256 remaining = newSatInLAssets - oldSatInLAssets;
            ratioBips = oldSatInLAssets > 0
                ? (remaining + oldSatInLAssets) * BIPS / oldSatInLAssets
                : calcStraddlePremiumRatioBips(inputParams.userAssets);
        }
    }

    /**
     * @dev Sum stored per-tranche saturation in tranche-0 units.
     *
     *   `satPairs[i].satRelativeToL` is stored in tranche-`i` units (= 1/B^i of tranche-0 units,
     *   modulo the partial first-tranche adjustment from `calculateEndOfLiquidationAdjustment`).
     *   Summing them directly would mix units across tranches and undercount the total. The loop
     *   tracks an inverse Q72 scale factor `bScaleQ72` that rescales each stored sat back into
     *   tranche-0 units before accumulation. When the current endpoint has drifted from the stored
     *   `lastTranche`, `trancheShift` keeps the stored array anchored to its original tranches.
     *
     * @param satPairs Storage array of per-tranche saturation pairs.
     * @param endOfLiquidationInTicks Tick at which liquidation ends (sets the first-tranche offset).
     * @param netDebtX True when summing the netDebtX tree; false for the netDebtY tree.
     * @param storedLastTranche Account tranche anchor when the stored saturation array was written.
     * @param currentLastTranche Current tranche anchor implied by `endOfLiquidationInTicks`.
     * @return oldSatInLAssets Total saturation in tranche-0 (L-asset) units.
     */
    function scaleAndSumSaturation(
        SaturationPair[] storage satPairs,
        int256 endOfLiquidationInTicks,
        bool netDebtX,
        int256 storedLastTranche,
        int256 currentLastTranche
    ) internal view returns (uint256 oldSatInLAssets) {
        uint256 endOfLiquidationAdjustmentQ72 = calculateEndOfLiquidationAdjustment(endOfLiquidationInTicks, netDebtX);

        int256 trancheShift = (storedLastTranche - currentLastTranche) * trancheDirection(netDebtX);
        uint256 bScaleQ72 = Q72;
        if (trancheShift > 0) {
            for (int256 j; j < trancheShift; ++j) {
                bScaleQ72 =
                    Convert.mulDiv(bScaleQ72, TRANCHE_B_IN_Q72, j == 0 ? endOfLiquidationAdjustmentQ72 : Q72, false);
            }
        } else if (trancheShift < 0) {
            for (int256 j; j > trancheShift; --j) {
                bScaleQ72 =
                    Convert.mulDiv(bScaleQ72, j == 0 ? endOfLiquidationAdjustmentQ72 : Q72, TRANCHE_B_IN_Q72, false);
            }
        }

        uint256 satArrayLength = satPairs.length;

        for (uint256 i; i < satArrayLength; i++) {
            int256 relativeIndex = int256(i) + trancheShift;

            // Scale stored sat up to tranche-0 units
            // Values were computed rounding down so we add one and round up to benefit borrower.
            oldSatInLAssets += Convert.mulDiv(satPairs[i].satRelativeToL + 1, bScaleQ72, Q72, true);

            // Update scaling only if there is a next tranche to process.
            if (i + 1 < satArrayLength) {
                bScaleQ72 = Convert.mulDiv(
                    bScaleQ72,
                    TRANCHE_B_IN_Q72,
                    relativeIndex == INT_NEGATIVE_ONE || relativeIndex == 0 ? endOfLiquidationAdjustmentQ72 : Q72,
                    false
                );
            }
        }
    }

    /**
     * @notice Calculate the ratio bips for a straddle position transitioning from zero to positive saturation.
     *
     *  Let $$S$$ be `SAT_RESET_FOR_STRADDLE_SLOPE_BIPS`, the slope that controls how quickly the
     *  straddle reset premium increases once $$L^2 > X \cdot Y$$.
     *
     *  Let $$P_{max}$$ be `MAX_SAT_RESET_FOR_STRADDLE_PREMIUM_BIPS`, the maximum premium allowed for
     *  this zero-to-positive straddle reset path.
     *
     *  ```math
     *  premiumBips = \min\left(
     *      P_{max},
     *      \left\lceil\frac{(L^2 - X \cdot Y) \cdot S}{X \cdot Y}\right\rceil
     *  \right)
     *  ```
     *
     *  The ratioBips encodes premium for downstream consumption:
     *  ```math
     *  \text{ratioBips} = \text{premiumBips} \cdot \text{MAG1} + \text{BIPS}
     *  ```
     *  and premium is recovered as: `(ratioBips - BIPS) / MAG1`.
     * @param userAssets The user's position parameters.
     * @return ratioBips The ratio in bips, or 0 if $$L^2 <= X \cdot Y$$.
     */
    function calcStraddlePremiumRatioBips(
        uint256[6] memory userAssets
    ) private pure returns (uint256 ratioBips) {
        uint256 lSquared = userAssets[BORROW_L] ** 2;
        uint256 xyProduct = userAssets[DEPOSIT_X] * userAssets[DEPOSIT_Y];

        if (lSquared > xyProduct) {
            uint256 premiumBips =
                Convert.mulDiv((lSquared - xyProduct), SAT_RESET_FOR_STRADDLE_SLOPE_BIPS, xyProduct, ROUNDING_UP);
            premiumBips = Math.min(premiumBips, MAX_SAT_RESET_FOR_STRADDLE_PREMIUM_BIPS);

            ratioBips = premiumBips * MAG1 + BIPS;
        }
    }

    /**
     * @notice  a helper function to calculate the one time adjustment for the offset of the end
     *   of the liquidation relative to the the boundary of the tranches.
     * @dev This formula is described in the introduction.
     * @param   endOfLiquidationInTicks  the tick at which liquidation should end by.
     * @param   netDebtX  whether this is a net X debt path.
     * @return  endOfLiquidationSqrtPriceAdjustment  the sqrt price adjustment required to be applied.
     */
    function calculateEndOfLiquidationAdjustment(
        int256 endOfLiquidationInTicks,
        bool netDebtX
    ) internal pure returns (uint256 endOfLiquidationSqrtPriceAdjustment) {
        unchecked {
            int256 tickForAdjustment = netDebtX ? endOfLiquidationInTicks : -endOfLiquidationInTicks;
            int16 modEndOfLiquidationInTicks = int16(tickForAdjustment % TICKS_PER_TRANCHE);
            if (modEndOfLiquidationInTicks < 0) modEndOfLiquidationInTicks += int16(TICKS_PER_TRANCHE);
            endOfLiquidationSqrtPriceAdjustment =
                modEndOfLiquidationInTicks == 0 ? Q72 : TickMath.getSqrtPriceAtTick(modEndOfLiquidationInTicks);
        }
    }

    /**
     * @notice  calc total sat of all accounts/tranches/leafs higher (and same) as the threshold
     * @dev     iterate through leaves directly since penalty range is fixed (~8 leaves from 85% to
     * 95% sat)
     * @param   tree that is being read from or written to
     * @param   thresholdLeaf leaf to start adding sat from
     * @return  satInPenaltyInLAssets total sat of all accounts with tranche in a leaf from at
     * least `thresholdLeaf` (absolute saturation)
     */
    function calcTotalSatAfterLeafInclusive(
        Tree storage tree,
        uint256 thresholdLeaf
    ) internal view returns (uint128 satInPenaltyInLAssets) {
        uint256 maxLeaf = tree.highestSetLeaf;
        if (thresholdLeaf > maxLeaf) {
            return 0; // No leaves in penalty range
        }

        for (uint256 leafIndex = thresholdLeaf; leafIndex <= maxLeaf; leafIndex++) {
            // Add absolute saturation stored in each leaf
            uint128 leafSat = tree.leafs[leafIndex].leafSatPair.satInLAssets;
            satInPenaltyInLAssets += leafSat;
        }
    }

    /**
     * @notice  Get precalculated saturation percentage for a given delta (maxLeaf - highestLeaf)
     * @param   satStruct  The saturation struct
     * @return  saturationPercentage  The precalculated saturation percentage as uint256
     */
    function getSatPercentageInWads(
        SaturationStruct storage satStruct
    ) internal view returns (uint256 saturationPercentage) {
        uint16 highestLeaf = uint16(Math.max(satStruct.netXTree.highestSetLeaf, satStruct.netYTree.highestSetLeaf));
        if (satStruct.maxLeaf == 0 && highestLeaf == 0) {
            return 0;
        }
        uint16 delta = satStruct.maxLeaf - highestLeaf;
        if (delta > 7) {
            return 0;
        }

        assembly {
            switch delta
            case 4 { saturationPercentage := SAT_PERCENTAGE_DELTA_4_WAD }
            case 5 { saturationPercentage := SAT_PERCENTAGE_DELTA_5_WAD }
            case 6 { saturationPercentage := SAT_PERCENTAGE_DELTA_6_WAD }
            case 7 { saturationPercentage := SAT_PERCENTAGE_DELTA_7_WAD }
            default { saturationPercentage := SAT_PERCENTAGE_DELTA_DEFAULT_WAD } // return 95% by default
        }
    }

    /**
     * @notice  convert sat to leaf
     * @param   satLAssets sat to convert
     * @return  leaf  resulting leaf from 0 to $2^{12}-1$
     */
    function satToLeaf(
        uint256 satLAssets
    ) internal pure returns (uint256 leaf) {
        // handle edge cases
        if (satLAssets >= MIN_LIQ_TO_REACH_PENALTY) {
            if (satLAssets >= LOWEST_POSSIBLE_IN_PENALTY) return LEAFS - 1;
            // Q112 to ensure our max value of our desired range is within the range of the function.
            uint256 satInQ112 = satLAssets * Q112;
            // the smaller Q number means some of our values are less than 0, so we correct all values to be positive by adding TICK_OFFSET (1112).
            int16 tick = TickMath.getTickAtPrice(satInQ112) + TICK_OFFSET;
            // multiply by 2 since `getTickAtPrice` does a square root on the value before taking the log. Then we change the base and shift to our desired domain.
            leaf = (2 * uint256(int256(tick)) * Q128 + SAT_CHANGE_OF_BASE_TIMES_SHIFT) / SAT_CHANGE_OF_BASE_Q128;
        }
    }

    /**
     * @notice  calc how much sat can be added to a tranche such that it is healthy.
     *   With `newSaturationRelativeToLAssets` as `newSat` and
     *   `currentTrancheSatRelativeToLAssets` as `currentSat`, the return values are:
     *
     *   ```math
     *   satAvailable = min(newSat, max(trancheSat, currentSat) - currentSat)
     *   ```
     *
     *   ```math
     *   target = min(trancheSat, newSat)
     *   ```
     *
     *   Therefore `target >= satAvailable` and `newSat >= target`.
     *
     * @param   activeLiquidityInLAssets  of the pair
     * @param   newSaturationRelativeToLAssets  the sat that we want to add
     * @param   currentTrancheSatRelativeToLAssets  the sat that the tranche already holds
     * @param   userSaturationRatioMAG2  the user's desired saturation ratio
     * @param   usableTicks  the number of usable ticks within the tranche, restricted by either
     *          the end of liquidation or the min/max tick.
     * @return  satAvailableToAddRelativeToLAssets  considering the `currentTrancheSatRelativeToLAssets` and the
     * max a tranche can have
     */
    function calcSatAvailableToAddToTranche(
        uint256 activeLiquidityInLAssets,
        uint128 newSaturationRelativeToLAssets,
        uint128 currentTrancheSatRelativeToLAssets,
        uint256 userSaturationRatioMAG2,
        uint256 usableTicks
    ) internal pure returns (uint128 satAvailableToAddRelativeToLAssets, uint256 targetCapacityRelativeToLAssets) {
        uint256 trancheSaturation =
            Math.ceilDiv(activeLiquidityInLAssets * userSaturationRatioMAG2 * usableTicks, TICKS_PER_TRANCHE_MAG2);

        satAvailableToAddRelativeToLAssets = uint128(
            Math.min(
                newSaturationRelativeToLAssets,
                Math.max(trancheSaturation, currentTrancheSatRelativeToLAssets) - currentTrancheSatRelativeToLAssets
            )
        );

        // limit the returned amount to guarantee no underflow when subtracting used from the
        // target so that we know that satRelative >= target.
        targetCapacityRelativeToLAssets = Math.min(trancheSaturation, newSaturationRelativeToLAssets);
    }

    /**
     * @notice  calc the tick at which the best case liquidation would end and the saturation of
     *  the last tranche containing that tick. Not all the saturation may fit into that tranche,
     *  but we calculate it as if it will which means that adjustments to the saturation will need
     *  to be made if it doesn't fit when placing it into the tree.
     * @param   inputParams  the input params
     * @param   netXLiqSqrtPriceInXInQ72  the midpoint of liquidation sqrt price of debt X in X/Y
     * @param   netYLiqSqrtPriceInXInQ72  the midpoint of liquidation sqrt price of debt Y in X/Y
     * @param   desiredThresholdMag2  the desired threshold
     * @param   netDebtX  whether the net debt is X or Y
     * @param   skipMinOrMaxTickCheck when borrowing liquidity, the two liquidations will
     *  start facing opposite ways and the current price can only be on one side. When this
     *  happens, only one side's liquidation is valid, the other could not occur without the price
     *  moving through the valid liquidation.
     *  We also skip this check during `calcSatChangeRatioBips()` as we don't want to block
     *  liquidations.
     * @return  saturation the saturation of the tranche
     * @return  endOfLiquidationInTicks  the point at which the liquidation would end.
     * @return  currentTickLimit The point at which the liquidation can not start before due to the
     *   current price.
     */
    function calcLastTickAndSaturation(
        Validation.InputParams memory inputParams,
        uint256 netXLiqSqrtPriceInXInQ72,
        uint256 netYLiqSqrtPriceInXInQ72,
        uint256 desiredThresholdMag2,
        bool netDebtX,
        bool skipMinOrMaxTickCheck
    )
        internal
        pure
        returns (SaturationPair memory saturation, int256 endOfLiquidationInTicks, int256 currentTickLimit)
    {
        // Check if this liquidation price is on the opposite side of the price and
        // thus not checked against saturation.
        skipMinOrMaxTickCheck = skipMinOrMaxTickCheck
            || (
                netDebtX
                    ? inputParams.sqrtPriceMaxInQ72 < netYLiqSqrtPriceInXInQ72
                        && netYLiqSqrtPriceInXInQ72 < netXLiqSqrtPriceInXInQ72
                    : netYLiqSqrtPriceInXInQ72 < netXLiqSqrtPriceInXInQ72
                        && netXLiqSqrtPriceInXInQ72 < inputParams.sqrtPriceMinInQ72
            );

        currentTickLimit = skipMinOrMaxTickCheck
            ? (netDebtX ? type(int256).max : type(int256).min)
            : (netDebtX ? inputParams.minTick : inputParams.maxTick);

        uint256 startOfLiquidationPriceQ128;
        {
            uint256 liqSqrtPriceInXInQ72 = netDebtX ? netXLiqSqrtPriceInXInQ72 : netYLiqSqrtPriceInXInQ72;

            (uint256 netDebtXorYAssets, uint256 tempSatInLAssets, uint256 sqrtPriceSpanQ72) =
                calculateNetDebtAndSpan(inputParams, liqSqrtPriceInXInQ72, desiredThresholdMag2, netDebtX);

            saturation.satInLAssets = SafeCast.toUint128(tempSatInLAssets);

            uint256 endOfLiquidationPriceQ128;
            (startOfLiquidationPriceQ128, endOfLiquidationPriceQ128) =
                calculateStartAndEndOfLiquidationPriceQ128(liqSqrtPriceInXInQ72, sqrtPriceSpanQ72, netDebtX);

            // Calculate relative saturation
            uint256 endOfLiquidationSqrtPriceQ72 = Math.sqrt(endOfLiquidationPriceQ128) << 8;
            saturation.satRelativeToL = calculateSaturation(netDebtXorYAssets, endOfLiquidationSqrtPriceQ72, netDebtX);

            endOfLiquidationPriceQ128 = netDebtX
                // round up if netDebt X by multiplying by $$b^2 \cdot Q72 - 1$$ prior to
                // passing to `getTickAtPrice()`. Checks size to prior to picking division or
                // multiplication to execute first to avoid overflows or vanishing the result.
                ? endOfLiquidationPriceQ128 > Q183
                    ? endOfLiquidationPriceQ128 / Q72 * B_SQUARED_Q72_MINUS_ONE
                    : endOfLiquidationPriceQ128 * B_SQUARED_Q72_MINUS_ONE / Q72
                : endOfLiquidationPriceQ128;

            // Cap the converted tick to `TickMath`'s valid tick range. Extreme low-LTV positions
            // can push `endOfLiquidationPriceQ128` outside `[MIN_PRICE_IN_Q128, MAX_PRICE_IN_Q128]`
            // — capping here avoids a `getTickAtPrice` revert (DoS). When the b^2 round-up rescale
            // pushes past MAX_PRICE_IN_Q128 we return MAX_TICK + 1
            if (endOfLiquidationPriceQ128 > TickMath.MAX_PRICE_IN_Q128) {
                endOfLiquidationInTicks = TickMath.MAX_TICK + 1;
            } else if (endOfLiquidationPriceQ128 < TickMath.MIN_PRICE_IN_Q128) {
                endOfLiquidationInTicks = TickMath.MIN_TICK;
            } else {
                endOfLiquidationInTicks = TickMath.getTickAtPrice(endOfLiquidationPriceQ128);
            }
        }
        // Verify that the liquidation does not start past the current min or max price.

        if (
            !skipMinOrMaxTickCheck
                && (
                    (netDebtX && startOfLiquidationPriceQ128 > inputParams.sqrtPriceMinInQ72 ** 2 / Q16)
                        || (!netDebtX && startOfLiquidationPriceQ128 < inputParams.sqrtPriceMaxInQ72 ** 2 / Q16)
                )
        ) {
            revert LiquidationPassesMinOrMaxTick();
        }
    }

    /**
     * @notice Convert from sqrtPrice by squaring, but we don't square the span because we only want
     *   to shift by half of the span to move from the middle of the liquidation to the end.
     *   Division prior to multiplication to avoid overflow since sqrtPriceQ72 is is 128 bits.
     */
    function calculateStartAndEndOfLiquidationPriceQ128(
        uint256 liqSqrtPriceQ72,
        uint256 sqrtPriceSpanQ72,
        bool netDebtX
    ) internal pure returns (uint256 startOfLiquidationPriceQ128, uint256 endOfLiquidationPriceQ128) {
        uint256 liqPriceQ144 = liqSqrtPriceQ72 ** 2;
        (startOfLiquidationPriceQ128, endOfLiquidationPriceQ128) = netDebtX
            ? (
                liqPriceDividedBySpan(liqPriceQ144, sqrtPriceSpanQ72),
                liqPriceMultipliedBySpan(liqPriceQ144, sqrtPriceSpanQ72)
            )
            : (
                liqPriceMultipliedBySpan(liqPriceQ144, sqrtPriceSpanQ72),
                liqPriceDividedBySpan(liqPriceQ144, sqrtPriceSpanQ72)
            );
    }

    function liqPriceDividedBySpan(
        uint256 liqPriceQ144,
        uint256 sqrtPriceSpanQ72
    ) private pure returns (uint256 priceQ128) {
        priceQ128 = liqPriceQ144 < Q128 ? liqPriceQ144 * sqrtPriceSpanQ72 / Q88 : liqPriceQ144 / Q88 * sqrtPriceSpanQ72;
    }

    function liqPriceMultipliedBySpan(
        uint256 liqPriceQ144,
        uint256 sqrtPriceSpanQ72
    ) private pure returns (uint256 priceQ128) {
        priceQ128 =
            (liqPriceQ144 < Q200 ? liqPriceQ144 * Q56 / sqrtPriceSpanQ72 : liqPriceQ144 / sqrtPriceSpanQ72 * Q56);
    }

    /**
     * @notice  calc net debt and span
     * @param   inputParams  the input params
     * @param   desiredThresholdMag2  the desired threshold
     * @param   netDebtX  whether the net debt is X or Y
     * @return  netDebtXorYAssets  the net debt
     * @return  netDebtLAssets  the net debt in L assets
     * @return  minSqrtPriceSpanQ72  the tranche span in sqrtPrice
     */
    function calculateNetDebtAndSpan(
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 desiredThresholdMag2,
        bool netDebtX
    ) internal pure returns (uint256 netDebtXorYAssets, uint256 netDebtLAssets, uint256 minSqrtPriceSpanQ72) {
        Validation.CheckLtvParams memory checkLtvParams =
            Validation.getCheckLtvParams(inputParams.userAssets, liqSqrtPriceInXInQ72, liqSqrtPriceInXInQ72);
        uint256 netCollateralLAssets;
        (netDebtLAssets, netCollateralLAssets,) = Validation.calcDebtAndCollateral(checkLtvParams);

        minSqrtPriceSpanQ72 = calculateMinSqrtPriceSpanQ72(
            netCollateralLAssets, netDebtLAssets, inputParams.activeLiquidityAssets, desiredThresholdMag2
        );

        // Convert to assets of X or Y so that `calcTickAtStartOfLiquidation` &
        // `calculateSaturation()` does not need to convert from L to X or Y.
        netDebtXorYAssets = netDebtX
            ? Validation.convertLToX(netDebtLAssets, liqSqrtPriceInXInQ72, false)
            : Validation.convertLToY(netDebtLAssets, liqSqrtPriceInXInQ72, false);
    }

    /**
     * @notice  calculate the relative saturation of the position at the end of liquidation.
     *   Since we place saturation in tranches starting at the tick where the liquidation would
     *   end and moving forward to the start of liquidation, this calculates the entire saturation
     *   as if it would fit in the last tranche, we then we will need to adjust the saturation each
     *   time we move forward a tranche to the next tranche by dividing by a factor of $$B$$ when
     *   we allocate the saturation later. The equation here is slightly different than the
     *   equation in our description since we multiply by a factor of $$B$$ for each tranche we
     *   move back from the start of liquidation tick. Thus here we use, where $$tSpan$$ is the
     *   number of tranches we need to move back,
     *
     *   ```math
     *   \begin{equation}T_{sat} =
     *   \begin{cases}
     *     \Large\frac{debt}{b^{t_e}(B-1)}
     *     &\text{ when debt is in X asset }
     *   \\
     *
     *     \Large\frac{debt \cdot b^{t_e}}{B-1}
     *     &\text{ otherwise }
     *   \end{cases}
     *   \end{equation}
     *   ```
     *
     *   As we iterate through tranches, we divide by a factor of $$B$$ such that when we reach the
     *   final tranche, our equation from the start applies.
     *
     *   Note that we also magnify the debt by the `SATURATION_TIME_BUFFER_IN_MAG2` to account for
     *   the potential growth that will occur over time due to interest. This allows for our
     *   estimate of saturation to be static in spite of the dynamic impact of interest.
     *
     * @param  netDebtXOrYAssets  the net debt in X or Y assets.
     * @param  endOfLiquidationSqrtPriceQ72 the tick at which the liquidation ends.
     * @param  netDebtX  whether the debt is net in X or Y assets
     * @return saturation  the saturation relative to active liquidity assets.
     */
    function calculateSaturation(
        uint256 netDebtXOrYAssets,
        uint256 endOfLiquidationSqrtPriceQ72,
        bool netDebtX
    ) internal pure returns (uint128 saturation) {
        saturation = SafeCast.toUint128(
            Convert.mulDiv(
                netDebtXOrYAssets * SATURATION_TIME_BUFFER_IN_MAG2,
                netDebtX ? Math.ceilDiv(Q144, endOfLiquidationSqrtPriceQ72) : endOfLiquidationSqrtPriceQ72,
                (TRANCHE_B_MINUS_ONE_IN_Q72) * MAG2,
                ROUNDING_UP
            )
        );
    }

    function calculateMinSqrtPriceSpanQ72(
        uint256 collateral,
        uint256 debt,
        uint256 activeLiquidityAssets,
        uint256 desiredThresholdMag2
    ) internal pure returns (uint256 sqrtPriceSpanQ72) {
        uint256 bQ72 =
        // debt and collateral are 256 bits together, so we have to divide
        // by MAG6 before multiplying by collateral to avoid overflow on multiplication.
        Convert.mulDiv(
            Convert.mulDiv(
                Convert.mulDiv(debt, EXPECTED_SATURATION_LTV_MAG2_TIMES_SAT_BUFFER_SQUARED, MAG6, false),
                collateral,
                // divide active liquidity in two steps to avoid the result vanishing.
                activeLiquidityAssets * desiredThresholdMag2 ** 2,
                false
            ),
            // scale to Q72 and multiply by Mag4 to cancel Mag4 from last division Mag4 units.
            MAG4_TIMES_Q72,
            // divide by by the second active liquidity asset.
            activeLiquidityAssets,
            false
        ) + TWO_Q72;

        // apply quadratic formula, a and c are both 1.
        sqrtPriceSpanQ72 = Math.ceilDiv((bQ72 + Math.sqrt(bQ72 ** 2 - FOUR_Q144)), 2);
    }

    // bit functions
    // node read write
    // uint node = [112 empty bits, 16 tranche count bits, 112 sat bits, 16 field bits]

    /**
     * @notice  read single bit value from the field of a node
     * @param   node  the full node
     * @param   bitPos  position of the bit $ \le 16 $
     * @return  bit  the resulting bit, 0 xor 1, as a uint
     */
    function readFieldBitFromNode(uint256 node, uint256 bitPos) internal pure returns (uint256 bit) {
        uint256 MASK = 1 << bitPos;
        assembly ("memory-safe") {
            bit := iszero(iszero(and(node, MASK)))
        }
    }

    /**
     * @notice  write to node
     * @param   nodeIn  node to read from
     * @param   bitPos  position of the bit $ \le 16 $
     * @return  nodeOut  node with bit flipped
     */
    function writeFlippedFieldBitToNode(uint256 nodeIn, uint256 bitPos) internal pure returns (uint256 nodeOut) {
        uint256 MASK = 1 << bitPos;
        nodeOut = nodeIn ^ MASK;
    }

    /**
     * @notice  read field from node
     * @param   node  node to read from
     * @return  field  field of the node
     */
    function readFieldFromNode(
        uint256 node
    ) internal pure returns (uint256 field) {
        field = node & FIELD_NODE_MASK;
    }

    /**
     * @notice Calculates the penalty scaling factor based on current borrow utilization and
     *   saturation
     *   This implements the penalty rate function
     *      Formula:
     *      ```math
     *        ((1 - u_0) \cdot f_{interestPerSecond}(u_1) \cdot allAssetsDepositL) / (WAD
     *        \cdot satInPenaltyInLAssets)
     *      ```
     *      Where,
     *      ```math
     *        u_1 = (0.90 - (1 - u_0) \cdot (0.95 - u_s) / 0.95)
     *      ```
     * @param currentBorrowUtilizationInWad Current borrow utilization of L (u_0)
     * @param saturationUtilizationInWad Current saturation utilization (u_s)
     * @param satInPenaltyInLAssets The saturation in L assets in the penalty
     * @param allAssetsDepositL The total assets deposited in L
     * @return penaltyRatePerSecondInWads The penalty rate per second in WADs
     */
    function calcSaturationPenaltyRatePerSecondInWads(
        uint256 currentBorrowUtilizationInWad,
        uint256 saturationUtilizationInWad,
        uint128 satInPenaltyInLAssets,
        uint256 allAssetsDepositL
    ) internal pure returns (uint256 penaltyRatePerSecondInWads) {
        uint256 oneMinusCurrentUtilizationWads = WAD - currentBorrowUtilizationInWad;

        // f_interestPerSecond(u_1) | Get the interest rate at target utilization (this is already magnified by 5x for liquidity)
        uint256 interestRateAtTargetUtilizationInWads = Interest.getAnnualInterestRatePerSecondInWads(
            // in this case we have low borrow utilization and low saturation
            MAX_UTILIZATION_PERCENT_IN_WAD
                - Math.min(
                    MAX_UTILIZATION_PERCENT_IN_WAD,
                    // Calculate target utilization:
                    // u_1 = 0.90 - (1 - u_0) * (0.95 - u_s) / 0.95
                    Convert.mulDiv(
                        oneMinusCurrentUtilizationWads,
                        MAX_SATURATION_PERCENT_IN_WAD - saturationUtilizationInWad,
                        MAX_SATURATION_PERCENT_IN_WAD,
                        false
                    )
                )
        ) * LIQUIDITY_INTEREST_RATE_MAGNIFICATION;

        // penaltyRatePerSecondInWads =
        // ((1 - u_0) * f_interestPerSecond(u_1) * allAssetsDepositL) / WAD * satInPenaltyInLAssets
        penaltyRatePerSecondInWads = Convert.mulDiv(
            Convert.mulDiv(oneMinusCurrentUtilizationWads, interestRateAtTargetUtilizationInWads, WAD, false),
            allAssetsDepositL,
            satInPenaltyInLAssets,
            false
        );
    }
}
