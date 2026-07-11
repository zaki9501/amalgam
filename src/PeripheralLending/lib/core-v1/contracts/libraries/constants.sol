// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @dev This basis was a modification to Uniswap V3's basis, to fit ticks into int16 instead of
 *  int24. We use the form $$\frac{2^{9}}{2^{9}-1}$$ which is just under 1.002. This basis
 *  format gives smaller errors since the fraction is more compatible with binary Q128
 *  fractions since the base is inverted in the tick math library before multiplications are
 *  applied.
 *  ```math
 *    \begin{align*}
 *    &   \frac{2^{9}}{2^{9}-1}^{-1} \cdot 2^{128}
 *    & & \frac{10001}{10000}^{-1} \cdot 2^{128}
 *    \\
 *    &   \frac{2^{9}-1}{2^{9}} \cdot 2^{256}
 *    & & \frac{10000\cdot2^{256}}{10001}
 *    \\
 *    &   339617752923046005526922703901628039168
 *    & & \frac{3402823669209384634633746074317682114560000}{10001}
 *    \\
 *    &   0xff800000000000000000000000000000
 *    & & 0xfffcb933bd6fad37aa2d162d1a594001
 *    \\
 *  \end{align*}
 *  ```
 *  We use this constant outside of the tick math library, and use a Q72 as that format is
 *  easier to work with multiplication without overflows.
 *  ```python
 *  >>> hex(int(mpm.nint(mpm.fdiv(2**9, 2**9-1) * 2**72)))
 *  ```
 *  We store in hex to reduce code size.
 */
uint256 constant B_IN_Q72 = 0x1008040201008040201;

/**
 * @dev In Saturation we combine 25 ticks to make one tranche.
 *  ```python
 *  >>> hex(int(mpm.nint(mpm.fdiv(2**9, 2**9-1)**25 * 2**72)))
 *  ```
 *  We store in hex to reduce code size.
 */
uint256 constant TRANCHE_B_IN_Q72 = 0x10cd2b2ae53a69d3552;

/**
 * @dev B - 1 or `TRANCHE_B_IN_Q72 - Q72`.
 */
uint256 constant TRANCHE_B_MINUS_ONE_IN_Q72 = 0xcd2b2ae53a69d3552;

/**
 * @dev We decrement the active liquidity used to measure available saturation by this
 *   percentage of fragile liquidity, or liquidity that has some amount of x or y borrowed
 *   against it. Reducing by 100% would ensure that that fragile liquidity could always be
 *   liquidated since burning it would not decrease the saturation. However, this also means
 *   that fragile liquidity adds no value to the risk of the pool, even if it may not be
 *   liquidated until after risk closer to the price. This value also ensures that recursively
 *   leveraging large amounts of x and y against liquidity can not allow more debt to be
 *   borrowed then the underlying stable liquidity not at risk of being seized and burned
 *   during liquidation. Crediting 10% of the fragile liquidity is a compromise to allow some
 *   benefit of leveraged liquidity to increase borrowing capacity without allowing for it to
 *   be vulnerable to allow excessive borrowing.
 */
uint256 constant FRAGILE_LIQUIDITY_DECREMENT_PERCENTAGE = 95;

/**
 * @dev The amount of LTV we expect liquidations to occur at
 */
uint256 constant EXPECTED_SATURATION_LTV_MAG2 = 85;

/**
 * @dev percentage of max sat per tranche considered healthy; max sat per
 * tranche is $$liquidity \cdot \frac{B-1}{2}$$ with B the tranche basis, which is the max
 * sat such that the liquidation would not cause a swap larger than a tranche
 */
uint256 constant MAX_SATURATION_RATIO_IN_MAG2 = 95;

/**
 * @dev the default zero address
 */
address constant ZERO_ADDRESS = address(0);

/**
 * @dev $2^{16}$.
 */
uint256 constant Q16 = 0x10000;

/**
 * @dev $2^{32}$.
 */
uint256 constant Q32 = 0x100000000;

/**
 * @dev $2^{56}$.
 */
uint256 constant Q56 = 0x100000000000000;

/**
 * @dev $2^{64}$.
 */
uint256 constant Q64 = 0x10000000000000000;

/**
 * @dev $2^{72}$.
 */
uint256 constant Q72 = 0x1000000000000000000;

/**
 * @dev $2^{88}$.
 */
uint256 constant Q88 = 0x10000000000000000000000;

/**
 * @dev $2^{112}$.
 */
uint256 constant Q112 = 0x10000000000000000000000000000;

/**
 *
 * @dev $2^{128}$.
 */
uint256 constant Q128 = 0x100000000000000000000000000000000;

/**
 * @dev $2^{144}$.
 */
uint256 constant Q144 = 0x1000000000000000000000000000000000000;

/**
 * @dev $2^{200}$.
 */
uint256 constant Q200 = 0x100000000000000000000000000000000000000000000000000;

/**
 * @dev number of bips in 1, 1 bips = 0.01%.
 */
uint256 constant BIPS = 10_000;

/**
 * @dev Initial fee applied to all newly opened debts and flash loans. This upfront fee prevents
 * griefing attacks via "dust" positions—small debts that would be unprofitable for liquidators to close.
 * The fee accumulates in the protocol, creating an economic incentive to liquidate these positions
 * if they become eligible for liquidation.
 * 5 bips = 0.05%.
 */
uint256 constant INITIAL_LENDING_FEE_BIPS = 5;

/**
 * @dev Default mid-term interval config used at the time of GeometricTWAP initialization.
 */
uint16 constant DEFAULT_MID_TERM_INTERVAL = 8;

/**
 * @dev minimum liquidity to initialize a pool, amount is burned to eliminate the threat of
 *  donation attacks.
 */
uint256 constant MINIMUM_LIQUIDITY = 1000;

/**
 * @dev Represents the minimum time period required between recorded long-term intervals.
 * Calculated as the product of `DEFAULT_MID_TERM_INTERVAL` and `GeometricTWAP.
 * MINIMUM_LONG_TERM_INTERVAL_FACTOR`.
 */
uint24 constant MINIMUM_LONG_TERM_TIME_UPDATE_CONFIG = 112;

/**
 * @dev `MAX_TICK_DELTA` limits the `newTick` to be within the outlier range of the current mid-term price.
 */
int256 constant MAX_TICK_DELTA = 10;

/**
 * @dev `DEFAULT_TICK_DELTA_FACTOR` is used when the long-term buffer is initialized.
 */
int256 constant DEFAULT_TICK_DELTA_FACTOR = 1;

/**
 * @dev the system loan to value minimum, 75% * 100.
 */
uint256 constant LTVMAX_IN_MAG2 = 75;

/**
 * @dev the system allowed leverage exposures with similar underlying assets, ie L is half X and
 * half Y, so we allow 100X leverage of borrowed X and Y against L.
 */
uint256 constant ALLOWED_LIQUIDITY_LEVERAGE = 100;

/**
 * @dev Allowed leverage minus one.
 */
uint256 constant ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE = 99;

/**
 * @dev constant used in Quadratic swap fees that controls the speed at which fees increase with
 * respect to the price change.
 */
uint256 constant N_TIMES_FEE = 20;

/**
 * @dev Magnitude 1
 */
uint256 constant MAG1 = 10;

/**
 * @dev Magnitude 2
 */
uint256 constant MAG2 = 100;

/**
 * @dev Magnitude 4
 */
uint256 constant MAG4 = 10_000;

/**
 * @dev Magnitude 6
 */
uint256 constant MAG6 = 1_000_000;

/**
 * @dev Saturation percentages in WADs
 */
uint256 constant SAT_PERCENTAGE_DELTA_4_WAD = 94.1795538580338563e16;
uint256 constant SAT_PERCENTAGE_DELTA_5_WAD = 92.3156868017020937e16;
uint256 constant SAT_PERCENTAGE_DELTA_6_WAD = 90.4887067368814135e16;
uint256 constant SAT_PERCENTAGE_DELTA_7_WAD = 88.6978836489829983e16;
uint256 constant SAT_PERCENTAGE_DELTA_DEFAULT_WAD = 95e16;

uint256 constant LIQUIDITY_INTEREST_RATE_MAGNIFICATION = 5;
/**
 * @dev Maximum percentage for the saturation allowed, used to limit the maximum saturation per tranche.
 */
uint256 constant MAX_SATURATION_PERCENT_IN_WAD = 0.95e18; // 95%

/**
 * @dev Maximum percentage for the utilization allowed.
 */
uint256 constant MAX_UTILIZATION_PERCENT_IN_WAD = 0.9e18; // 90%

uint256 constant SECONDS_IN_YEAR = 365 days;

/**
 * @dev The interval for swap to check borrowed interest to update reserves.
 *  Updating once a day would limit rate change in price to 0.003% if one reserve
 *  had max interest and the other had none.
 *  It also would require 40 days to go from 94% depletion to 95% depletion.
 *  ref: https://www.desmos.com/calculator/sxfc3tcz8c
 */
uint32 constant INTEREST_PERIOD_FOR_SWAP = 1 days - 1;

/**
 * @dev The interval for non-swap to check borrowed interest to update reserves.
 */
uint32 constant DEFAULT_INTEREST_PERIOD = 0;

/**
 * @dev Buffer ratio at which lending of the scarce asset stops.
 *      Derived from 95 / 5.
 */
uint256 constant BUFFER = 19;

/**
 * @dev Numerator buffer used for depleted-asset threshold calculations.
 *      Derived from 100 / 5.
 */
uint256 constant BUFFER_NUMERATOR = 20;

/**
 * @dev Observation buffer used when computing the new tick from reserves.
 *      Derived from 45 / 5.
 */
uint256 constant BUFFER_OBS = 9;

/**
 * @dev Observation buffer numerator used for depleted-asset threshold calculations.
 *      Derived from 50 / 5.
 */
uint256 constant BUFFER_OBS_NUMERATOR = 10;

/**
 * @dev index implementation for default full functionality
 */
uint256 constant INDEX_FULL_IMPL = 0;
/**
 * @dev index implementation that locks borrowing, withdrawing, burning, except liquidation
 */
uint256 constant INDEX_LOCKED_LOANS = 1;
/**
 * @dev index implementation that blocks all transfers:  withdraw, burn, borrow and liquidation
 */
uint256 constant INDEX_BLOCK_ALL_TRANSFERS = 2;
/**
 * @dev index implementation that freezes any function calling the pair: mints, swaps, ..etc
 */
uint256 constant INDEX_FROZEN = 3;
