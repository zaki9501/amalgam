// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {ICallback} from 'contracts/interfaces/callbacks/IAmmalgamCallee.sol';
import {IAmmalgamPair} from 'contracts/interfaces/IAmmalgamPair.sol';
import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {QuadraticSwapFees} from 'contracts/libraries/QuadraticSwapFees.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {TokenController} from 'contracts/tokens/TokenController.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {
    BIPS,
    BUFFER,
    BUFFER_NUMERATOR,
    DEFAULT_INTEREST_PERIOD,
    INTEREST_PERIOD_FOR_SWAP,
    MINIMUM_LIQUIDITY,
    MAG2,
    INITIAL_LENDING_FEE_BIPS,
    Q128,
    Q72,
    ZERO_ADDRESS
} from 'contracts/libraries/constants.sol';
import {
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    FIRST_DEBT_TOKEN,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {SaturationAndGeometricTWAPState} from 'contracts/SaturationAndGeometricTWAPState.sol';

contract AmmalgamPair is IAmmalgamPair, TokenController {
    uint256 private constant ZERO_DEPOSIT_DUE_TO_NETTING = 0;
    uint256 private constant UNLOCKED = 0;
    uint256 private constant LOCKED = 1;

    uint256 private transient locked;
    address private transient activeBorrower;

    error Locked();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidToAddress();
    error K();
    error InsufficientRepayLiquidity();

    modifier lock() {
        _lock();
        _;
        _unlock();
    }

    function _lock() private {
        if (locked == LOCKED) {
            revert Locked();
        }
        locked = LOCKED;
    }

    function _unlock() private {
        locked = UNLOCKED;
    }

    function _revertNestedBorrow() private view {
        if (activeBorrower != ZERO_ADDRESS) revert Locked();
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(
        address to
    ) external virtual lock returns (uint256 liquidityShares) {
        uint256 _reserveXAssets;
        uint256 _reserveYAssets;
        // slither-disable-start uninitialized-local
        uint256 amountXAssets;
        uint256 amountYAssets;
        uint256 liquidityAssets;
        // slither-disable-end uninitialized-local

        uint256 totalLShares = totalShares(DEPOSIT_L);
        // slither-disable-next-line incorrect-equality
        if (totalLShares == 0) {
            (_reserveXAssets, _reserveYAssets) = getNetBalances(0, 0);

            (referenceReserveX, referenceReserveY) = _castReserves(_reserveXAssets, _reserveYAssets);

            uint256 reserveLiquidity = Math.sqrt(_reserveXAssets * _reserveYAssets);

            if (reserveLiquidity < MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();

            unchecked {
                liquidityShares = liquidityAssets = reserveLiquidity - MINIMUM_LIQUIDITY;
            }

            mintId(DEPOSIT_L, msg.sender, address(factory), MINIMUM_LIQUIDITY, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            saturationAndGeometricTWAPState.init(_reserveXAssets, _reserveYAssets);
            uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
            lastUpdateTimestamp = currentTimestamp;
            lastLendingTimestamp = currentTimestamp;
        } else {
            (_reserveXAssets, _reserveYAssets, amountXAssets, amountYAssets) =
                accrueSaturationPenaltiesAndInterest(to, DEFAULT_INTEREST_PERIOD);

            (uint256 _totalDepositLAssets, uint256 _activeLiquidityAssets) = getDepositAndActiveLiquidityAssets();
            liquidityAssets = calculateMinimumLiquidityAssets(
                amountXAssets, amountYAssets, _reserveXAssets, _reserveYAssets, _activeLiquidityAssets, !ROUNDING_UP
            );

            liquidityShares = Convert.toShares(liquidityAssets, _totalDepositLAssets, totalLShares, !ROUNDING_UP);
        }

        // slither-disable-next-line incorrect-equality,reentrancy-balance
        if (liquidityShares == 0) revert InsufficientLiquidityMinted();

        mintId(DEPOSIT_L, msg.sender, to, liquidityAssets, liquidityShares);

        // slither-disable-next-line reentrancy-events Sync not related to mint.
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets + amountXAssets, _reserveYAssets + amountYAssets
        );

        updateSaturationIfNeeded(to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(
        address to
    ) external virtual lock returns (uint256 amountXAssets, uint256 amountYAssets) {
        // Accrual of penalties and interest is handled within `validateOnUpdate` at the time of token transfer
        (uint256 _reserveXAssets, uint256 _reserveYAssets) = getRawReserves();

        uint256 liquidityShares = balanceOf(address(this), DEPOSIT_L);
        (uint256 depositLiquidityAssets, uint256 _activeLiquidityAssets) = getDepositAndActiveLiquidityAssets();
        uint256 depositLiquidityShares = totalShares(DEPOSIT_L);

        uint256 liquidityAssetsBurned =
            Convert.toAssets(liquidityShares, depositLiquidityAssets, depositLiquidityShares, !ROUNDING_UP);

        amountXAssets = Convert.toLiquidityAssets(
            liquidityShares, _reserveXAssets, _activeLiquidityAssets, depositLiquidityAssets, depositLiquidityShares
        );
        amountYAssets = Convert.toLiquidityAssets(
            liquidityShares, _reserveYAssets, _activeLiquidityAssets, depositLiquidityAssets, depositLiquidityShares
        );

        // slither-disable-next-line incorrect-equality
        if (amountXAssets == 0 || amountYAssets == 0) {
            revert InsufficientLiquidityBurned();
        }

        // Calculate post-burn reserves
        uint256 newReserveX = _reserveXAssets - amountXAssets;
        uint256 newReserveY = _reserveYAssets - amountYAssets;

        checkMaxBorrowForLiquidity(
            newReserveX, newReserveY, depositLiquidityAssets - liquidityAssetsBurned, rawTotalAssets(BORROW_L), 0
        );

        burnId(DEPOSIT_L, msg.sender, to, liquidityAssetsBurned, liquidityShares);

        transferAssets(to, amountXAssets, amountYAssets);

        // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for burn
        updateReservesAndReference(_reserveXAssets, _reserveYAssets, newReserveX, newReserveY);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amountXOut, uint256 amountYOut, address to, bytes calldata data) external virtual lock {
        if (amountXOut == 0 && amountYOut == 0) revert InsufficientOutputAmount();
        (uint256 _reserveXAssets, uint256 _reserveYAssets,,) =
            accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS, INTEREST_PERIOD_FOR_SWAP);
        uint256 amountXIn;
        uint256 amountYIn;

        {
            (uint256 _missingXAssets, uint256 _missingYAssets) = missingAssets();

            if (amountXOut >= _reserveXAssets - _missingXAssets || amountYOut >= _reserveYAssets - _missingYAssets) {
                revert InsufficientLiquidity();
            }

            // reentry guarded using lock modifier
            // slither-disable-start reentrancy-no-eth,reentrancy-benign
            // optimistically transfer tokens
            transferAssets(to, amountXOut, amountYOut);
            if (data.length > 0) {
                ICallback(to).ammalgamSwapCallV1(msg.sender, amountXOut, amountYOut, data);
            }
            // slither-disable-end reentrancy-no-eth,reentrancy-benign
            (uint256 balanceXAdjusted, uint256 balanceYAdjusted) = getNetBalances(0, 0);

            amountXIn = calculateAmountIn(amountXOut, balanceXAdjusted, _reserveXAssets);
            amountYIn = calculateAmountIn(amountYOut, balanceYAdjusted, _reserveYAssets);

            // slither-disable-next-line incorrect-equality,reentrancy-balance
            if (amountXIn == 0 && amountYIn == 0) revert InsufficientInputAmount();

            // slither-disable-next-line reentrancy-balance
            if (
                // Note: referenceReserves has been updated in accrueSaturationPenaltiesAndInterest with the reserves
                calculateBalanceAfterFees(
                    amountXIn, balanceXAdjusted, _reserveXAssets, referenceReserveX, _missingXAssets
                )
                    * calculateBalanceAfterFees(
                        amountYIn, balanceYAdjusted, _reserveYAssets, referenceReserveY, _missingYAssets
                    )
                    < Convert.calculateReserveAdjustmentsForMissingAssets(
                        _reserveXAssets, _missingXAssets, BUFFER, BUFFER_NUMERATOR
                    )
                        * Convert.calculateReserveAdjustmentsForMissingAssets(
                            _reserveYAssets, _missingYAssets, BUFFER, BUFFER_NUMERATOR
                        )
            ) {
                revert K();
            }
        }

        // slither-disable-next-line reentrancy-events Cant log event until in is known after callback in some cases
        emit Swap(msg.sender, amountXIn, amountYIn, amountXOut, amountYOut, to);

        uint256 newReserveXAssets = _reserveXAssets + amountXIn - amountXOut;
        uint256 newReserveYAssets = _reserveYAssets + amountYIn - amountYOut;

        updateReserves(newReserveXAssets, newReserveYAssets);

        // Track intra-observation price extremes for TWAP lag mitigation
        saturationAndGeometricTWAPState.recordPriceExtreme(
            Convert.mulDiv(newReserveXAssets, Q128, newReserveYAssets, !ROUNDING_UP)
        );
    }

    /**
     * @notice helper method to calculate amountIn for swap
     * @dev Adds jump, saves on runtime size. Must check that `reserve > amountOut`,
     *  which happens in swap where function is called.
     * @param amountOut the amount out
     * @param balance the balance
     * @param reserve the reserve
     */
    function calculateAmountIn(
        uint256 amountOut,
        uint256 balance,
        uint256 reserve
    ) private pure returns (uint256 amountIn) {
        unchecked {
            uint256 reserveAfterSwap = reserve - amountOut;
            if (balance > reserveAfterSwap) amountIn = balance - reserveAfterSwap;
        }
    }

    /**
     * @notice helper method to calculate balance after fees
     * @dev Note that amountIn + reserve does not always equal balance if amountOut > 0.
     *      In the depleted case the balance is scaled by `BUFFER_NUMERATOR`; the matching
     *      scaling is applied on the reserve side in `calculateReserveAdjustmentsForMissingAssets`
     *      so the K comparison stays division-free on both branches.
     * @param amountIn the swap amount in
     * @param balance the balance
     * @param reserve the reserve
     * @param referenceReserve the reference reserve for the block
     * @param missing the missing assets, zero if deposits > borrows of X or Y
     */
    function calculateBalanceAfterFees(
        uint256 amountIn,
        uint256 balance,
        uint256 reserve,
        uint256 referenceReserve,
        uint256 missing
    ) private pure returns (uint256 calculatedBalance) {
        uint256 fee = QuadraticSwapFees.calculateSwapFeeBipsQ64(amountIn, reserve, referenceReserve);

        if (balance * BUFFER < missing * BUFFER_NUMERATOR) {
            // depleted case
            calculatedBalance = ((balance - missing) * QuadraticSwapFees.BIPS_Q64 - amountIn * fee) * BUFFER_NUMERATOR
                / QuadraticSwapFees.BIPS_Q64;
        } else {
            // not depleted case
            calculatedBalance = (balance * QuadraticSwapFees.BIPS_Q64 - amountIn * fee) / QuadraticSwapFees.BIPS_Q64;
        }
    }

    function deposit(
        address to
    ) external virtual lock {
        (,, uint256 amountXAssets, uint256 amountYAssets) =
            accrueSaturationPenaltiesAndInterest(to, DEFAULT_INTEREST_PERIOD);

        // slither-disable-next-line similar-names
        uint256 userBorrowedX = balanceOf(to, BORROW_X);
        uint256 userBorrowedY = balanceOf(to, BORROW_Y);

        Validation.verifyNotSameAssetsSuppliedAndBorrowed(amountXAssets, amountYAssets, userBorrowedX, userBorrowedY);
        if (amountXAssets > 0) updateBorrowOrDepositSharesHelper(to, DEPOSIT_X, amountXAssets, !ROUNDING_UP);
        if (amountYAssets > 0) updateBorrowOrDepositSharesHelper(to, DEPOSIT_Y, amountYAssets, !ROUNDING_UP);

        // update Saturation if depositor already had a borrow
        updateSaturationIfNeeded(to);
    }

    /**
     * withdraw X and/or Y
     */
    function withdraw(
        address to
    ) external virtual lock {
        // Accrual of penalties and interest is handled within `validateOnUpdate` at the time of token transfer
        (uint256 _reserveXAssets, uint256 _reserveYAssets) = getRawReserves();

        uint256 assetsX = updateWithdrawShares(to, DEPOSIT_X, _reserveXAssets);
        uint256 assetsY = updateWithdrawShares(to, DEPOSIT_Y, _reserveYAssets);

        transferAssets(to, assetsX, assetsY);
    }

    function updateWithdrawShares(
        address to,
        uint256 depositedTokenType,
        uint256 _reserve
    ) private returns (uint256 withdrawnAssets) {
        uint256 depositedShares = balanceOf(address(this), depositedTokenType);
        // slither-disable-next-line incorrect-equality
        if (depositedShares != 0) {
            uint256 currentAssets = rawTotalAssets(depositedTokenType);
            uint256 _totalShares = totalShares(depositedTokenType);

            withdrawnAssets = Convert.toAssets(depositedShares, currentAssets, _totalShares, !ROUNDING_UP);

            checkMaxBorrow(
                currentAssets - withdrawnAssets,
                rawTotalAssets(depositedTokenType + FIRST_DEBT_TOKEN),
                _reserve,
                rawTotalAssets(DEPOSIT_L),
                rawTotalAssets(BORROW_L)
            );

            burnId(depositedTokenType, msg.sender, to, withdrawnAssets, depositedShares);
        }
    }

    function borrow(
        address to,
        uint256 amountXAssets,
        uint256 amountYAssets,
        bytes calldata data
    ) external virtual lock {
        _revertNestedBorrow();

        (uint256 _reserveXAssets, uint256 _reserveYAssets,,) =
            accrueSaturationPenaltiesAndInterest(msg.sender, DEFAULT_INTEREST_PERIOD);

        uint256 amountXShares = borrowHelper(to, amountXAssets, _reserveXAssets, DEPOSIT_X, BORROW_X);
        uint256 amountYShares = borrowHelper(to, amountYAssets, _reserveYAssets, DEPOSIT_Y, BORROW_Y);

        transferAssets(to, amountXAssets, amountYAssets);

        if (data.length > 0) {
            activeBorrower = msg.sender;
            _unlock();
            ICallback(to).ammalgamBorrowCallV1(
                msg.sender, amountXAssets, amountYAssets, amountXShares, amountYShares, data
            );
            _lock();
            delete activeBorrower;
        }

        updateFragileLiquidity(msg.sender);
        validateSolvency(msg.sender, false);
    }

    function borrowHelper(
        address to,
        uint256 amountAssets,
        uint256 reserve,
        uint256 depositedTokenType,
        uint256 borrowedTokenType
    ) private returns (uint256 amountShares) {
        if (amountAssets > 0) {
            uint256 initialLendingFee = Convert.mulDiv(amountAssets, INITIAL_LENDING_FEE_BIPS, BIPS, ROUNDING_UP);
            uint256 amountAssetsWithFee = amountAssets + initialLendingFee;

            checkMaxBorrow(
                rawTotalAssets(depositedTokenType),
                rawTotalAssets(borrowedTokenType) + amountAssetsWithFee,
                reserve,
                rawTotalAssets(DEPOSIT_L),
                rawTotalAssets(BORROW_L)
            );

            // slither-disable-next-line events-maths
            amountShares = updateBorrowOrDepositSharesHelper(to, borrowedTokenType, amountAssetsWithFee, ROUNDING_UP);

            mintProtocolFees(depositedTokenType, factory.feeTo(), initialLendingFee, false);
        }
    }

    function updateBorrowOrDepositSharesHelper(
        address to,
        uint256 tokenType,
        uint256 amountAssets,
        bool isRoundingUp
    ) private returns (uint256 amountShares) {
        amountShares = Convert.toShares(amountAssets, rawTotalAssets(tokenType), totalShares(tokenType), isRoundingUp);
        mintId(tokenType, msg.sender, to, amountAssets, amountShares);
    }

    function borrowLiquidity(
        address to,
        uint256 borrowAmountLAssets,
        bytes calldata data
    ) external virtual lock returns (uint256 borrowedLXAssets, uint256 borrowedLYAssets) {
        _revertNestedBorrow();

        uint256 borrowAmountLShares;

        {
            (uint256 _reserveXAssets, uint256 _reserveYAssets,,) =
                accrueSaturationPenaltiesAndInterest(msg.sender, DEFAULT_INTEREST_PERIOD);

            uint256 _totalBorrowLAssets = rawTotalAssets(BORROW_L);
            uint256 initialLendingFee = Convert.mulDiv(borrowAmountLAssets, INITIAL_LENDING_FEE_BIPS, BIPS, ROUNDING_UP);
            uint256 borrowedAmountLAssetsWithFee = borrowAmountLAssets + initialLendingFee;

            checkMaxBorrowForLiquidity(
                _reserveXAssets,
                _reserveYAssets,
                rawTotalAssets(DEPOSIT_L),
                _totalBorrowLAssets,
                borrowedAmountLAssetsWithFee
            );

            (, uint256 _activeLiquidityAssets) = getDepositAndActiveLiquidityAssets();
            borrowedLXAssets = Convert.mulDiv(borrowAmountLAssets, _activeLiquidityAssets, _reserveYAssets, false);
            borrowedLYAssets = Convert.mulDiv(borrowAmountLAssets, _activeLiquidityAssets, _reserveXAssets, false);

            borrowAmountLShares =
                Convert.toShares(borrowedAmountLAssetsWithFee, _totalBorrowLAssets, totalShares(BORROW_L), ROUNDING_UP);

            // We use the state before minting because we have not yet distributed the borrowed lx
            // and ly assets and the reserves will be inflated relative to the shares after we mint
            // the new borrowed L assets.
            mintProtocolFees(DEPOSIT_L, factory.feeTo(), initialLendingFee, false);

            // slither-disable-next-line incorrect-equality
            mintId(BORROW_L, msg.sender, to, borrowedAmountLAssetsWithFee, borrowAmountLShares);

            transferAssets(to, borrowedLXAssets, borrowedLYAssets);

            // Reserves are updated to reflect the borrowed L being deducted from the pool that can no longer be used for trading
            // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for borrowLiquidity
            updateReservesAndReference(
                _reserveXAssets, _reserveYAssets, _reserveXAssets - borrowedLXAssets, _reserveYAssets - borrowedLYAssets
            );
        }

        if (data.length > 0) {
            // Reuse `activeBorrower` as a temporary lock to prevent liquidations during the
            // liquidity flash-borrow callback; cleared after the callback returns.
            activeBorrower = address(this);
            _unlock();
            ICallback(to).ammalgamBorrowLiquidityCallV1(
                msg.sender, borrowedLXAssets, borrowedLYAssets, borrowAmountLShares, data
            );
            _lock();
            delete activeBorrower;
        }

        updateFragileLiquidity(msg.sender);
        validateSolvency(msg.sender, false);
    }

    function repay(
        address onBehalfOf
    ) external virtual lock returns (uint256 repayXAssets, uint256 repayYAssets) {
        (,, repayXAssets, repayYAssets) = accrueSaturationPenaltiesAndInterest(onBehalfOf, DEFAULT_INTEREST_PERIOD);
        (repayXAssets, repayYAssets) = _repay(onBehalfOf, repayXAssets, repayYAssets);

        // update Saturation
        updateSaturationIfNeeded(onBehalfOf);
    }

    /**
     * @notice Internal version to allow for direct calls during liquidations
     */
    function _repay(
        address onBehalfOf,
        uint256 repayXAssets,
        uint256 repayYAssets
    ) private returns (uint256 actualRepayXAssets, uint256 actualRepayYAssets) {
        actualRepayXAssets = repayHelper(onBehalfOf, repayXAssets, BORROW_X);
        actualRepayYAssets = repayHelper(onBehalfOf, repayYAssets, BORROW_Y);
        updateFragileLiquidity(onBehalfOf);
    }

    function repayHelper(
        address onBehalfOf,
        uint256 repayInAssets,
        uint256 borrowTokenType
    ) private returns (uint256 actualRepayInAssets) {
        if (repayInAssets > 0) {
            actualRepayInAssets = repayInAssets;
            uint256 totalBorrowedAssets = rawTotalAssets(borrowTokenType);
            uint256 totalBorrowedShares = totalShares(borrowTokenType);

            uint256 repayInShares =
                Convert.toShares(repayInAssets, totalBorrowedAssets, totalBorrowedShares, !ROUNDING_UP);

            uint256 balanceOfBorrowToken = balanceOf(onBehalfOf, borrowTokenType);

            // slither-disable-next-line uninitialized-local
            uint256 overPaidAssets;

            if (repayInShares > balanceOfBorrowToken) {
                repayInShares = balanceOfBorrowToken;

                uint256 owedAssets =
                    Convert.toAssets(repayInShares, totalBorrowedAssets, totalBorrowedShares, ROUNDING_UP);
                overPaidAssets = repayInAssets - owedAssets;
                actualRepayInAssets = owedAssets;
            }

            // Ensure we burn first and then mint protocol fees for the excess repaid assets.
            // Minting the protocol fees can slightly change the ratio of `shares` to `assets` (by 1 when you round)
            // which can result in a different amount burned, if we do that after minting the protocol fees.
            burnId(borrowTokenType, msg.sender, onBehalfOf, actualRepayInAssets, repayInShares);

            // Any repayment above the owed amount is minted as protocol fees to block skimming.
            // Repays can sync before repaying to avoid this fee, though the gas cost may outweigh it.
            if (overPaidAssets > 0) {
                mintProtocolFees(borrowTokenType - FIRST_DEBT_TOKEN, factory.feeTo(), overPaidAssets, false);
            }
        }
    }

    function repayLiquidity(
        address onBehalfOf
    ) external virtual lock returns (uint256 repaidXAssets, uint256 repaidYAssets, uint256 repayLiquidityAssets) {
        uint256 _reserveXAssets;
        uint256 _reserveYAssets;
        (_reserveXAssets, _reserveYAssets, repaidXAssets, repaidYAssets) =
            accrueSaturationPenaltiesAndInterest(onBehalfOf, DEFAULT_INTEREST_PERIOD);
        repayLiquidityAssets =
            _repayLiquidity(onBehalfOf, repaidXAssets, repaidYAssets, _reserveXAssets, _reserveYAssets);

        // update Saturation
        updateSaturationIfNeeded(onBehalfOf);
    }

    function _repayLiquidity(
        address onBehalfOf,
        uint256 repaidXAssets,
        uint256 repaidYAssets,
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) private returns (uint256 repayLiquidityAssets) {
        // BLA, ALA
        uint256 totalBorrowedLiquidityShares = totalShares(BORROW_L);
        uint256 totalBorrowLiquidityAssets = rawTotalAssets(BORROW_L);

        repayLiquidityAssets = calculateMinimumLiquidityAssets(
            repaidXAssets,
            repaidYAssets,
            _reserveXAssets,
            _reserveYAssets,
            Math.sqrt(_reserveXAssets * _reserveYAssets, Math.Rounding.Ceil),
            ROUNDING_UP
        );

        uint256 repayLiquidityShares = Convert.toShares(
            repayLiquidityAssets, totalBorrowLiquidityAssets, totalBorrowedLiquidityShares, !ROUNDING_UP
        );

        // slither-disable-next-line incorrect-equality // repayLiquidityShares is a uint256 can never be less than 0
        if (repayLiquidityShares == 0) {
            revert InsufficientRepayLiquidity();
        }
        uint256 balanceOfBorrowLShares = balanceOf(onBehalfOf, BORROW_L);

        if (repayLiquidityShares > balanceOfBorrowLShares) {
            repayLiquidityShares = balanceOfBorrowLShares;
            unchecked {
                repayLiquidityAssets = Convert.toAssets(
                    repayLiquidityShares, totalBorrowLiquidityAssets, totalBorrowedLiquidityShares, ROUNDING_UP
                );
            }
        }

        // the first `repayAmountLShares` is considered as assets for function burnId.
        burnId(BORROW_L, msg.sender, onBehalfOf, repayLiquidityAssets, repayLiquidityShares);
        // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for repayLiquidity
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets + repaidXAssets, _reserveYAssets + repaidYAssets
        );
    }

    /**
     * @notice accrues interest and determines the amount sent to the contract prior to executing
     *   liquidation.
     * @inheritdoc IAmmalgamPair
     */
    function liquidate(
        address borrower,
        address to,
        uint256 seizedLAssets,
        uint256 seizedXAssets,
        uint256 seizedYAssets,
        uint256 repayXAssets,
        uint256 repayYAssets,
        uint256 liquidationType
    ) external virtual lock {
        // First disjunct: prevent self-liquidation that would bypass the LTV check.
        // Second disjunct: block any liquidation during the borrowLiquidity flash-borrow
        // callback, where `activeBorrower` is set to this contract as a sentinel.
        if (borrower == activeBorrower || activeBorrower == address(this)) revert Locked();

        // accrue interest to get the borrower state before repaying the debt.
        (,, uint256 actualRepaidXAssets, uint256 actualRepaidYAssets) =
            accrueSaturationPenaltiesAndInterest(borrower, DEFAULT_INTEREST_PERIOD);

        // get position of borrower
        Validation.InputParams memory inputParams = getInputParams(borrower, false);

        if (inputParams.hasBorrow) {
            if (liquidationType == Liquidation.HARD) {
                liquidateHard(
                    borrower,
                    to,
                    inputParams,
                    [
                        seizedLAssets,
                        seizedXAssets,
                        seizedYAssets,
                        0, // inserted later if needed after _repayLiquidity()
                        repayXAssets,
                        repayYAssets
                    ],
                    actualRepaidXAssets,
                    actualRepaidYAssets
                );
            } else if (liquidationType == Liquidation.SATURATION) {
                resetSaturation(inputParams, borrower, to);
            } else if (liquidationType == Liquidation.LEVERAGE) {
                liquidateLeverage(inputParams, borrower, to, actualRepaidXAssets, actualRepaidYAssets);
            } // noop if type > 2

            emit Liquidate(
                borrower,
                to,
                seizedLAssets,
                seizedXAssets,
                seizedYAssets,
                repayXAssets,
                repayYAssets,
                actualRepaidXAssets,
                actualRepaidYAssets,
                liquidationType
            );
        }
    }

    /**
     * @notice LTV based liquidation. The LTV dictates the max premium that can be had by the
     *  liquidator. We determine the amount of borrowed liquidity to be repaid by reducing the
     *  actual amount transferred prior to calling `liquidate()` by the amount passed in for the
     *  repayXAssets and repayYAssets parameters.
     *
     *  ## Calculating a Hard Liquidation
     *
     *  Hard liquidations can be partial subset of the borrower's entire position based on
     *  tranche saturation composition. Use `LiquidationUtils.calculatePartialLiquidationAmount()`
     *  to compute the partial position, max premium, and the amounts needed for the call.
     *
     *  Three prices are in play and each is used at a different stage:
     *
     *  | Price               | Source                  | Where used                         |
     *  |---------------------|-------------------------|------------------------------------|
     *  | Reserve price       | reserveX / reserveY     | `_repayLiquidity`: splits tokens   |
     *  |                     |                         | into the X/Y ratio the pool needs  |
     *  |                     |                         | to burn BORROW_L.                  |
     *  | sqrtPriceMin (TWAP) | geometric TWAP low tick | Verification converts:             |
     *  |                     |                         |   BORROW_X → L (worst-case borrow) |
     *  |                     |                         |   DEPOSIT_Y → L (worst-case dep.)  |
     *  | sqrtPriceMax (TWAP) | geometric TWAP high tick| Verification converts:             |
     *  |                     |                         |   BORROW_Y → L (worst-case borrow) |
     *  |                     |                         |   DEPOSIT_X → L (worst-case dep.)  |
     *
     *  Verification (`verifyHardLiquidation`) swaps min and max when calling
     *  `getCheckLtvParams(proposed, sqrtPriceMax, sqrtPriceMin)`. This values deposits at
     *  their highest and borrows at their lowest, favoring the borrower by making the
     *  position appear as healthy as possible. This limits the ability of liquidators to
     *  manipulate premiums.
     *
     *  The reserve price and TWAP prices may diverge. Seized deposit amounts must be
     *  computed using TWAP prices (the verification domain), not reserve prices.
     *
     *  ### Net Debt Calculation and the BORROW_L Overlap
     *
     *  `getBorrowedInL` initializes BOTH sides from BORROW_L:
     *
     *  ```text
     *    netBorrowedXinL = BORROW_L + convertXToL(BORROW_X, sqrtPriceMin)
     *    netBorrowedYinL = BORROW_L + convertYToL(BORROW_Y, sqrtPriceMax)
     *  ```
     *
     *  `getDepositsInL` initializes BOTH sides from DEPOSIT_L:
     *
     *  ```text
     *    netDepositedXinL = DEPOSIT_L + convertXToL(DEPOSIT_X, sqrtPriceMax)
     *    netDepositedYinL = DEPOSIT_L + convertYToL(DEPOSIT_Y, sqrtPriceMin)
     *  ```
     *
     *  `calcDebtAndCollateral` then nets these to determine `netDebtX`:
     *
     *  ```text
     *    netDebtX = true  when netDepositedX <= netBorrowedX AND netDepositedY > netBorrowedY
     *    netDebtX = false when netDepositedY <= netBorrowedY AND netDepositedX > netBorrowedX
     *  ```
     *
     *  `netDebtX` selects the saturation account. A wrong value causes
     *  `calculatePartialLiquidation` to return the wrong tranche set, reverting the
     *  liquidation.
     *
     *  ### Computing Seized amounts Borrow X, Seize Y
     *
     *  For a position with BORROW_X and DEPOSIT_Y, the seized Y only needs
     *  to cover the liquidation premium on the repaid debt:
     *
     *  ```text
     *    borrowXInL  = ceil(BORROW_X * Q72 / sqrtPriceMax)
     *    premiumInL  = borrowXInL * maxPremiumBips / BIPS
     *    seizedY     = premiumInL * Q72 / sqrtPriceMax
     *  ```
     *
     *  ### Overlap Case: Borrow X + Borrow L, Seize Y
     *
     *  When BORROW_L is present and BORROW_Y is zero, `getBorrowedInL` computes:
     *
     *  ```text
     *    netBorrowedXinL = BORROW_L + convertXToL(BORROW_X, sqrtPriceMin)
     *    netBorrowedYinL = BORROW_L
     *  ```
     *
     *  The seized Y (in L-terms at TWAP price) must exceed BORROW_L so that
     *  `netDepositedYinL > netBorrowedYinL`, which is required for `netDebtX = true`.
     *  The seized amount includes the BORROW_L overlap plus the liquidation premium:
     *
     *  ```text
     *    borrowXInL     = ceil(BORROW_X * Q72 / sqrtPriceMax)
     *    netRepaidInL   = BORROW_L + borrowXInL
     *    premiumInL     = netRepaidInL * maxPremiumBips / BIPS
     *    seizedYInL     = BORROW_L + premiumInL
     *    seizedY        = seizedYInL * Q72 / sqrtPriceMax
     *  ```
     *
     *  ### Token Transfer Amounts
     *
     *  The liquidator must transfer enough tokens to cover both direct borrows and BORROW_L:
     *
     *  ```text
     *    repayLX = ceil(BORROW_L * reserveX / activeLiquidity)
     *    repayLY = ceil(BORROW_L * reserveY / activeLiquidity)
     *    totalXTransfer = BORROW_X + repayLX
     *    totalYTransfer = repayLY
     *  ```
     *
     *  These use reserve prices because `_repayLiquidity` splits tokens by the reserve ratio.
     *  The seized Y amount uses TWAP prices because `verifyHardLiquidation` operates in that
     *  domain.
     *
     * @param borrower The account being liquidated
     * @param to The account to send the liquidated deposit to
     * @param inputParams The input parameters for the liquidation, including reserves and price
     *  limits.
     * @param proposedLiquidation The inputted amount of deposits to be seized and borrows to be
     *  repaid.
     * @param actualRepaidXAssets The actual amount of X assets repaid by the liquidator.
     * @param actualRepaidYAssets The actual amount of Y assets repaid by the liquidator.
     */
    function liquidateHard(
        address borrower,
        address to,
        Validation.InputParams memory inputParams,
        uint256[6] memory proposedLiquidation,
        uint256 actualRepaidXAssets,
        uint256 actualRepaidYAssets
    ) private {
        _liquidationRepayHelper(
            borrower,
            proposedLiquidation,
            actualRepaidXAssets,
            actualRepaidYAssets,
            inputParams.reservesXAssets,
            inputParams.reservesYAssets
        );

        bool badDebt;
        // `fragileLiquidityAssets` shrinks active liquidity only for the saturation-tranche split;
        // liquidation premium cap uses total `activeLiquidityAssets` available.
        (proposedLiquidation, badDebt) = Liquidation.verifyHardLiquidation(
            saturationAndGeometricTWAPState,
            address(this),
            inputParams,
            proposedLiquidation,
            fragileLiquidityAssets(inputParams.activeLiquidityAssets),
            borrower
        );

        if (badDebt) {
            _burnBadDebt(borrower, inputParams.userAssets);
        }

        finalizeLiquidation(
            borrower,
            to,
            proposedLiquidation[DEPOSIT_L],
            proposedLiquidation[DEPOSIT_X],
            proposedLiquidation[DEPOSIT_Y],
            badDebt
        );
    }

    /**
     * @notice Liquidation based on change of saturation because of time.
     * @param borrower The account being liquidated.
     * @param to The account to send the liquidated deposit to
     */
    function resetSaturation(Validation.InputParams memory inputParams, address borrower, address to) private {
        // remove fragile liquidity from active liquidity
        inputParams.activeLiquidityAssets -= fragileLiquidityAssets(inputParams.activeLiquidityAssets);

        (uint256 seizedLAssets, uint256 seizedXAssets, uint256 seizedYAssets) =
            Liquidation.checkSaturationPremiums(saturationAndGeometricTWAPState, inputParams, borrower);

        finalizeLiquidation(borrower, to, seizedLAssets, seizedXAssets, seizedYAssets, false);
    }

    /**
     * @notice Liquidation based on leverage.
     * @param inputParams The input parameters for the liquidation, including reserves and price.
     * @param borrower The account being liquidated.
     * @param to The account to send the liquidated deposit to.
     * @param actualRepaidXAssets The actual amount of X assets repaid by the liquidator.
     * @param actualRepaidYAssets The actual amount of Y assets repaid by the liquidator.
     */
    function liquidateLeverage(
        Validation.InputParams memory inputParams,
        address borrower,
        address to,
        uint256 actualRepaidXAssets,
        uint256 actualRepaidYAssets
    ) private {
        (uint256[6] memory leveragedLiquidationParams, bool badDebt) =
            Liquidation.liquidateLeverageCalcDeltaAndPremium(inputParams);

        _liquidationRepayHelper(
            borrower,
            leveragedLiquidationParams,
            actualRepaidXAssets,
            actualRepaidYAssets,
            inputParams.reservesXAssets,
            inputParams.reservesYAssets
        );

        if (badDebt) {
            _burnBadDebt(borrower, inputParams.userAssets);
        }

        finalizeLiquidation(
            borrower,
            to,
            leveragedLiquidationParams[DEPOSIT_L],
            leveragedLiquidationParams[DEPOSIT_X],
            leveragedLiquidationParams[DEPOSIT_Y],
            badDebt
        );
    }

    /**
     * @notice Repays the borrow legs of a liquidation and verifies the liquidator repaid enough.
     * @dev Shared by hard and leverage liquidations. The required X/Y repayments must be fully
     *   covered by the assets the liquidator sent in; any remainder repays borrowed liquidity.
     *   `liquidationParams[BORROW_L]` carries the minimum liquidity that must be repaid and is
     *   overwritten with the liquidity actually repaid so `verifyHardLiquidation` can read it back.
     * @param borrower The account being liquidated.
     * @param liquidationParams Borrow legs to repay, indexed by BORROW_X / BORROW_Y / BORROW_L.
     * @param actualRepaidXAssets The X assets the liquidator transferred in for the repayment.
     * @param actualRepaidYAssets The Y assets the liquidator transferred in for the repayment.
     * @param _reserveXAssets Current X reserves, used to split repaid liquidity by the reserve ratio.
     * @param _reserveYAssets Current Y reserves, used to split repaid liquidity by the reserve ratio.
     */
    function _liquidationRepayHelper(
        address borrower,
        uint256[6] memory liquidationParams,
        uint256 actualRepaidXAssets,
        uint256 actualRepaidYAssets,
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) private {
        uint256 requiredRepayXAssets = liquidationParams[BORROW_X];
        uint256 requiredRepayYAssets = liquidationParams[BORROW_Y];
        // non-zero only for leverage liquidations. liquidate() passes 0 for hard liquidations
        uint256 minRequiredRepayLAssets = liquidationParams[BORROW_L];

        if (requiredRepayXAssets > 0 || requiredRepayYAssets > 0) {
            // checks case where L is zero
            if (requiredRepayXAssets > actualRepaidXAssets || requiredRepayYAssets > actualRepaidYAssets) {
                _revertNotEnoughRepaidForLiquidation();
            }

            // we verified this would not underflow above
            unchecked {
                actualRepaidXAssets -= requiredRepayXAssets;
                actualRepaidYAssets -= requiredRepayYAssets;
            }

            (liquidationParams[BORROW_X], liquidationParams[BORROW_Y]) =
                _repay(borrower, requiredRepayXAssets, requiredRepayYAssets);
        }

        if (actualRepaidXAssets > 0 && actualRepaidYAssets > 0) {
            liquidationParams[BORROW_L] =
                _repayLiquidity(borrower, actualRepaidXAssets, actualRepaidYAssets, _reserveXAssets, _reserveYAssets);
        } else {
            // liquidator did not repay any liquidity, setting actual repaid L assets to 0
            liquidationParams[BORROW_L] = 0;
        }

        // checks case if L > 0, regardless if x and y are included
        if (liquidationParams[BORROW_L] < minRequiredRepayLAssets) {
            _revertNotEnoughRepaidForLiquidation();
        }
    }

    function _revertNotEnoughRepaidForLiquidation() private pure {
        revert Liquidation.NotEnoughRepaidForLiquidation();
    }

    function _burnBadDebt(address borrower, uint256[6] memory userAssets) private {
        if (userAssets[BORROW_L] > 0) {
            burnBadDebt(borrower, BORROW_L, 0);
        }
        if (userAssets[BORROW_X] > 0 || userAssets[BORROW_Y] > 0) {
            (uint256 _reserveXAssets, uint256 _reserveYAssets) = getRawReserves();
            burnBadDebt(borrower, BORROW_X, _reserveXAssets);
            burnBadDebt(borrower, BORROW_Y, _reserveYAssets);

            (uint112 newReserveXAssets, uint112 newReserveYAssets) = getRawReserves();

            // slither-disable-next-line incorrect-equality
            if (!(newReserveXAssets == _reserveXAssets && newReserveYAssets == _reserveYAssets)) {
                // burnBadDebt mutates reserves without updating referenceReserveX/Y
                // sync so post-liquidation swaps pay the correct quadratic fee.
                updateReservesAndReference(_reserveXAssets, _reserveYAssets, newReserveXAssets, newReserveYAssets);
            }
        }
    }

    function finalizeLiquidation(
        address borrower,
        address to,
        uint256 depositLToBeTransferredInLAssets,
        uint256 depositXToBeTransferredInXAssets,
        uint256 depositYToBeTransferredInYAssets,
        bool isBadDebt
    ) private {
        liquidationTransfer(borrower, to, depositLToBeTransferredInLAssets, DEPOSIT_L, isBadDebt);
        liquidationTransfer(borrower, to, depositXToBeTransferredInXAssets, DEPOSIT_X, isBadDebt);
        liquidationTransfer(borrower, to, depositYToBeTransferredInYAssets, DEPOSIT_Y, isBadDebt);

        updateFragileLiquidity(borrower);
        // accrue global interest/penalties and update the `to` address's penalties, saturation,
        // and fragile-liquidity-related state. Internal call so it is not blocked by the `lock`
        // modifier on the public `validateOnUpdate` (liquidate holds the lock).
        _validateOnUpdate(address(this), to, true);

        Validation.InputParams memory inputParams = getInputParams(borrower, false);

        // remove fragile liquidity from active liquidity
        inputParams.activeLiquidityAssets -= fragileLiquidityAssets(inputParams.activeLiquidityAssets);

        // refetch borrower state and update saturation for borrower. Skip tick check because
        // it could fail which would make liquidation impossible. In some cases this
        // position will be eligible for a hard liquidation after this one.
        saturationAndGeometricTWAPState.update(inputParams, borrower, true);
    }

    /**
     * Transfer deposit to the liquidator from the borrower (==from).
     * @param from The account the deposit is being transferred from.
     * @param to The account the deposit is being transferred to.
     * @param depositToTransferInAssets The amount being transferred to the liquidator.
     * @param tokenType The deposit token type being transferred.
     */
    function liquidationTransfer(
        address from,
        address to,
        uint256 depositToTransferInAssets,
        uint256 tokenType,
        bool isBadDebt
    ) private {
        // slither-disable-next-line incorrect-equality
        if (depositToTransferInAssets != 0) {
            // this is fairly complex specifically for when L bad debt is burned
            // and the the transfer amount is also L, but the ratio of shares to
            // assets is different than before those bad debts shares were burned.
            IAmmalgamERC20 token = tokens(tokenType);
            uint256 remainingShares = token.balanceOf(from);
            uint256 _totalShares = totalShares(tokenType);
            uint256 _totalAssets = rawTotalAssets(tokenType);
            uint256 expectedShares =
                Convert.toShares(depositToTransferInAssets, _totalAssets, _totalShares, ROUNDING_UP);
            token.ownerTransfer(from, to, Math.min(remainingShares, expectedShares));

            // In case of bad debt, if liquidator didn't take all the collateral shares (max premium),
            // we burn the remaining shares which gets distributed to the remaining LPs when `sync()` is called.
            if (isBadDebt && remainingShares > expectedShares) {
                uint256 burnShares = remainingShares - expectedShares;

                token.ownerTransfer(from, address(this), burnShares);

                // We use `msg.sender` as the `sender` and `address(this)` as the `receiver` because we transfer the shares
                // to the pair itself and then burn them. Underlying assets are kept in the pair.
                burnId(
                    tokenType,
                    msg.sender,
                    address(this),
                    Convert.toAssets(burnShares, _totalAssets, _totalShares, !ROUNDING_UP),
                    burnShares
                );
            }
        }
    }

    // force balances to match reserves
    // slither-disable-start reentrancy-no-eth,reentrancy-benign
    function skim(
        address to
    ) external virtual lock {
        (,, uint256 balanceXAssets, uint256 balanceYAssets) =
            accrueSaturationPenaltiesAndInterest(to, DEFAULT_INTEREST_PERIOD);
        transferAssets(to, balanceXAssets, balanceYAssets);
    }

    // slither-disable-end reentrancy-no-eth,reentrancy-benign
    // force reserves to match balances
    function sync() external virtual lock {
        (uint256 _reserveXAssets, uint256 _reserveYAssets, uint256 extraXAssets, uint256 extraYAssets) =
            accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS, DEFAULT_INTEREST_PERIOD);
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets + extraXAssets, _reserveYAssets + extraYAssets
        );
    }

    function validateOnUpdate(address validate, address update, bool alwaysUpdate) external virtual lock {
        _validateOnUpdate(validate, update, alwaysUpdate);
    }

    function _validateOnUpdate(address validate, address update, bool alwaysUpdate) private {
        accrueSaturationPenaltiesAndInterest(validate, DEFAULT_INTEREST_PERIOD);

        if (validate != address(this)) updateFragileLiquidity(validate);
        if (update != address(this)) updateFragileLiquidity(update);

        validateSolvency(validate, alwaysUpdate);

        // we do not want to update the pair itself.
        if (address(this) != update) {
            // mint penalties for the `update` address before clearing the state in `update`.
            // Use 0 as time so global penalties are not minted twice
            mintPenalties(update, 0);
            Validation.InputParams memory inputParams = getInputParams(update, true);

            if (inputParams.hasBorrow || alwaysUpdate) {
                Validation.verifyNotSameAssetsSuppliedAndBorrowed(
                    inputParams.userAssets[DEPOSIT_X],
                    inputParams.userAssets[DEPOSIT_Y],
                    inputParams.userAssets[BORROW_X],
                    inputParams.userAssets[BORROW_Y]
                );

                // remove fragile liquidity from active liquidity
                inputParams.activeLiquidityAssets -= fragileLiquidityAssets(inputParams.activeLiquidityAssets);
                saturationAndGeometricTWAPState.update(inputParams, update, false);
            }
        }
    }

    function validateSolvency(address validate, bool alwaysUpdate) private {
        // we do not want to validate the pair itself, only possible if `validateOnUpdate` is
        // called.
        if (address(this) != validate) {
            Validation.InputParams memory inputParams = getInputParams(validate, true);
            if (inputParams.hasBorrow || alwaysUpdate) {
                Validation.validateSolvency(
                    inputParams.userAssets,
                    inputParams.sqrtPriceMinInQ72,
                    inputParams.sqrtPriceMaxInQ72,
                    inputParams.activeLiquidityAssets
                );

                // remove fragile liquidity from active liquidity
                inputParams.activeLiquidityAssets -= fragileLiquidityAssets(inputParams.activeLiquidityAssets);

                saturationAndGeometricTWAPState.update(inputParams, validate, false);
            }
        }
    }

    /**
     * @notice Update saturation state for an account if it already exists in saturation.
     * @dev Note that during a repay of debt, we may not have an entry in saturation if
     *      1. The position is a straddle with a payout that never reaches zero
     *      2. Repay is occurring during a callback of a flash loan, saturation will not be updated
     *         until the end of the borrow call after the callback concludes.
     * @param toUpdate The account to update saturation for.
     */
    function updateSaturationIfNeeded(
        address toUpdate
    ) private {
        if (saturationAndGeometricTWAPState.accountExistsInSaturation(address(this), toUpdate)) {
            Validation.InputParams memory inputParams = getInputParams(toUpdate, true);
            // remove fragile liquidity from active liquidity
            inputParams.activeLiquidityAssets -= fragileLiquidityAssets(inputParams.activeLiquidityAssets);
            saturationAndGeometricTWAPState.update(inputParams, toUpdate, false);
        }
    }

    function getInputParams(
        address toCheck,
        bool includeLongTermPrice
    ) internal view returns (Validation.InputParams memory inputParams) {
        (uint112[6] memory _totalAssets, uint112[6] memory _totalShares) = totalAssetsAndShares(true);

        uint256 _activeLiquidityAssets = _totalAssets[DEPOSIT_L] - _totalAssets[BORROW_L];
        // We want to update the active liquidity assets to not include liquidity to be burnt
        uint256 stagedBurnAssets = Convert.toAssets(
            balanceOf(address(this), DEPOSIT_L), _totalAssets[DEPOSIT_L], _totalShares[DEPOSIT_L], !ROUNDING_UP
        );
        if (stagedBurnAssets > _activeLiquidityAssets) {
            revert InsufficientLiquidity();
        }
        unchecked {
            _activeLiquidityAssets -= stagedBurnAssets;
        }

        uint256[6] memory userAssets = getAssets(_totalAssets, _totalShares, toCheck);

        if (userAssets[BORROW_L] == 0 && userAssets[BORROW_X] == 0 && userAssets[BORROW_Y] == 0) {
            inputParams.activeLiquidityAssets = _activeLiquidityAssets + externalLiquidity;
            // Early return since there is no borrow, now that `hasBorrow` is correctly false at initialization and other params are not not used.
            return inputParams;
        }

        (uint256 _reserveXAssets, uint256 _reserveYAssets) = getRawReserves();
        (int16 minTick, int16 maxTick) = saturationAndGeometricTWAPState.getTickRange(
            address(this), _reserveXAssets, _reserveYAssets, includeLongTermPrice
        );

        inputParams = Validation.getInputParams(
            userAssets, _activeLiquidityAssets, _reserveXAssets, _reserveYAssets, externalLiquidity, minTick, maxTick
        );
    }

    function transferAssets(address to, uint256 amountXAssets, uint256 amountYAssets) private {
        (IERC20 _tokenX, IERC20 _tokenY) = underlyingTokens();
        if (to == address(_tokenX) || to == address(_tokenY)) {
            revert InvalidToAddress();
        }
        if (amountXAssets > 0) SafeERC20.safeTransfer(_tokenX, to, amountXAssets);
        if (amountYAssets > 0) SafeERC20.safeTransfer(_tokenY, to, amountYAssets);
    }

    function calculateMinimumLiquidityAssets(
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 _reserveXAssets,
        uint256 _reserveYAssets,
        uint256 liquidityAssetsNumerator,
        bool isRoundingUp
    ) private pure returns (uint256 liquidityAssets) {
        liquidityAssets = Math.min(
            Convert.mulDiv(amountXAssets, liquidityAssetsNumerator, _reserveXAssets, isRoundingUp),
            Convert.mulDiv(amountYAssets, liquidityAssetsNumerator, _reserveYAssets, isRoundingUp)
        );
    }

    function checkMaxBorrowForLiquidity(
        uint256 reserveX,
        uint256 reserveY,
        uint256 totalDepositedLAssets,
        uint256 totalBorrowedLAssets,
        uint256 newBorrowLAssets
    ) private view {
        (uint256 netBorrowedX, uint256 netBorrowedY) = missingAssets();
        uint256 _activeLiquidityAssets = totalDepositedLAssets - totalBorrowedLAssets;

        // Deposits are fully netted out above, so here we pass 0 for depositedXAssets and depositedYAssets.
        checkMaxBorrow(
            ZERO_DEPOSIT_DUE_TO_NETTING,
            netBorrowedX + Convert.mulDiv(newBorrowLAssets, reserveX, _activeLiquidityAssets, ROUNDING_UP),
            reserveX,
            totalDepositedLAssets,
            totalBorrowedLAssets
        );

        checkMaxBorrow(
            ZERO_DEPOSIT_DUE_TO_NETTING,
            netBorrowedY + Convert.mulDiv(newBorrowLAssets, reserveY, _activeLiquidityAssets, ROUNDING_UP),
            reserveY,
            totalDepositedLAssets,
            totalBorrowedLAssets
        );
    }

    function checkMaxBorrow(
        uint256 depositedAssets,
        uint256 borrowedAssets,
        uint256 reserve,
        uint256 totalDepositedLAssets,
        uint256 totalBorrowedLiquidityAssets
    ) private pure {
        Validation.verifyMaxBorrow(
            Validation.VerifyMaxBorrowParams({
                depositedAssets: depositedAssets,
                borrowedAssets: borrowedAssets,
                reserve: reserve,
                totalDepositedLAssets: totalDepositedLAssets,
                totalBorrowedLAssets: totalBorrowedLiquidityAssets
            })
        );
    }
}
