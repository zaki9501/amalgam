// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IFactoryCallback} from 'contracts/interfaces/factories/IFactoryCallback.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {
    ITokenController,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    FIRST_DEBT_TOKEN,
    TOKEN_COUNT,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Interest} from 'contracts/libraries/Interest.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {
    BUFFER_OBS,
    BUFFER_OBS_NUMERATOR,
    DEFAULT_INTEREST_PERIOD,
    FRAGILE_LIQUIDITY_DECREMENT_PERCENTAGE,
    Q32,
    Q128,
    ZERO_ADDRESS,
    INTEREST_PERIOD_FOR_SWAP,
    MAG2
} from 'contracts/libraries/constants.sol';
import {InitializablePair} from 'contracts/proxy/PairBeaconProxy.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';
import {Validation} from 'contracts/libraries/Validation.sol';

/**
 * @dev Wrapper of the ERC20 tokens that has some functionality similar to the ERC1155.
 */
contract TokenController is InitializablePair, ITokenController {
    // These can not be constants as they are defined in initialize()
    // slither-disable-start constable-states
    IERC20 private tokenX;
    IERC20 private tokenY;
    IAmmalgamERC20 private _tokenDepositL;
    IAmmalgamERC20 private _tokenDepositX;
    IAmmalgamERC20 private _tokenDepositY;
    IAmmalgamERC20 private _tokenBorrowL;
    IAmmalgamERC20 private _tokenBorrowX;
    IAmmalgamERC20 private _tokenBorrowY;

    // State is initialized in initialize()
    // slither-disable-start uninitialized-state
    IFactoryCallback internal factory;
    ISaturationAndGeometricTWAPState internal saturationAndGeometricTWAPState;
    // slither-disable-end uninitialized-state
    // slither-disable-end constable-states
    uint112[6] private allShares;

    /**
     * @notice The first position in this array is never stored because it is instead computed as
     *         $\sqrt{reserveX\cdot reserveY}+borrowedLAssets$. We keep this storage spot because
     *         we heavily use DEPOSIT_L, DEPOSIT_X, DEPOSIT_Y, BORROW_L, BORROW_X, BORROW_Y to look
     *         up positions throughout the code and didn't want to change all those references.
     */
    uint112[6] private allAssets;

    uint112 private reserveXAssets;
    uint112 private reserveYAssets;
    uint32 internal lastUpdateTimestamp;
    uint112 internal referenceReserveX;
    uint112 internal referenceReserveY;
    uint32 internal lastLendingTimestamp;

    uint112 public override externalLiquidity;
    uint112 public override fragileLiquidityShares;
    mapping(address => uint256) internal userFragileLiquidityShares;

    uint112 internal transient totalDepositLAssets;
    uint112 internal transient totalDepositXAssets;
    uint112 internal transient totalDepositYAssets;
    uint112 internal transient totalBorrowLAssets;
    uint112 internal transient totalBorrowXAssets;
    uint112 internal transient totalBorrowYAssets;
    uint112 internal transient activeLiquidityAssets;

    error Forbidden();

    function _initialize() internal virtual override {
        IAmmalgamERC20[6] memory tokenData;
        factory = IFactoryCallback(msg.sender);

        // We are calling a trusted party, the factory creating the pair contract.
        // slither-disable-next-line reentrancy-benign
        (tokenX, tokenY, tokenData) = factory.generateTokensWithinFactory();

        _tokenDepositL = tokenData[DEPOSIT_L];
        _tokenDepositX = tokenData[DEPOSIT_X];
        _tokenDepositY = tokenData[DEPOSIT_Y];
        _tokenBorrowL = tokenData[BORROW_L];
        _tokenBorrowX = tokenData[BORROW_X];
        _tokenBorrowY = tokenData[BORROW_Y];

        saturationAndGeometricTWAPState = ISaturationAndGeometricTWAPState(factory.saturationAndGeometricTWAPState());
    }

    modifier onlyFeeToSetter() {
        _onlyFeeToSetter();
        _;
    }

    function _onlyFeeToSetter() private view {
        if (msg.sender != factory.feeToSetter()) {
            revert Forbidden();
        }
    }

    function underlyingTokens() public view virtual override returns (IERC20, IERC20) {
        return (tokenX, tokenY);
    }

    function updateAssets(uint256 tokenType, uint112 assets) internal {
        if (tokenType > DEPOSIT_L) allAssets[tokenType] = assets;

        // totalDepositLAssets == 0 => no transient vars set yet
        // slither-disable-next-line incorrect-equality
        if (totalDepositLAssets == 0) return;

        if (tokenType == DEPOSIT_L) {
            totalDepositLAssets = assets;
        } else if (tokenType == DEPOSIT_X) {
            totalDepositXAssets = assets;
        } else if (tokenType == DEPOSIT_Y) {
            totalDepositYAssets = assets;
        } else if (tokenType == BORROW_L) {
            totalBorrowLAssets = assets;
        } else if (tokenType == BORROW_X) {
            totalBorrowXAssets = assets;
        } else if (tokenType == BORROW_Y) {
            totalBorrowYAssets = assets;
        }
    }

    function updateExternalLiquidity(
        uint112 _externalLiquidity
    ) external virtual onlyFeeToSetter {
        accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS, DEFAULT_INTEREST_PERIOD);
        (, uint256 _activeLiquidityAssets) = getDepositAndActiveLiquidityAssets();
        // slither-disable-next-line uninitialized-local
        Validation.InputParams memory inputParams;

        inputParams.activeLiquidityAssets = _activeLiquidityAssets + _externalLiquidity;
        inputParams.activeLiquidityAssets -= fragileLiquidityAssets(inputParams.activeLiquidityAssets);
        // slither-disable-next-line reentrancy-benign,reentrancy-events
        saturationAndGeometricTWAPState.update(inputParams, ZERO_ADDRESS, false);
        externalLiquidity = _externalLiquidity;
        emit UpdateExternalLiquidity(_externalLiquidity);
    }

    function mintId(uint256 tokenType, address sender, address to, uint256 assets, uint256 shares_) internal {
        uint112 mintedShares = SafeCast.toUint112(shares_);

        allShares[tokenType] += mintedShares;
        uint112 updatedAssets = SafeCast.toUint112(rawTotalAssets(tokenType) + assets);
        updateAssets(tokenType, updatedAssets);

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        tokens(tokenType).ownerMint(sender, to, assets, shares_);

        if (tokenType == DEPOSIT_L) {
            updateFragileLiquidity(to);
        }
    }

    function burnId(uint256 tokenType, address sender, address receiver, uint256 assets, uint256 shares_) internal {
        // Burn tokens first, this will ensure user does not try to repay or burn more than they own.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        tokens(tokenType).ownerBurn(sender, receiver, assets, shares_);
        allShares[tokenType] -= SafeCast.toUint112(shares_);

        uint112 burnAssets = SafeCast.toUint112(assets);

        // We use Math.max() because when there is only one owner of the current assets and they
        // reduce their entire balance, this may underflow due to rounding up in prior
        // calculations. If the final change amount slightly exceed the remaining assets in the
        // pool, math max puts the asset balance at zero.
        updateAssets(tokenType, uint112(Math.max(rawTotalAssets(tokenType), burnAssets) - burnAssets));
    }

    function tokens(
        uint256 tokenType
    ) public view virtual override returns (IAmmalgamERC20) {
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        return [_tokenDepositL, _tokenDepositX, _tokenDepositY, _tokenBorrowL, _tokenBorrowX, _tokenBorrowY][tokenType];
    }

    function balanceOf(address account, uint256 tokenType) internal view returns (uint256) {
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events,calls-loop
        return tokens(tokenType).balanceOf(account);
    }

    function totalShares(
        uint256 tokenType
    ) internal view returns (uint256) {
        return allShares[tokenType];
    }

    function rawTotalAssets(
        uint256 tokenType
    ) internal view returns (uint256 assetAmount) {
        if (tokenType == DEPOSIT_L) {
            (assetAmount,) = getDepositAndActiveLiquidityAssets();
        } else {
            assetAmount = allAssets[tokenType];
        }
    }

    function getRawReserves() internal view returns (uint112 _reserveXAssets, uint112 _reserveYAssets) {
        _reserveXAssets = reserveXAssets;
        _reserveYAssets = reserveYAssets;
    }

    function getReserves()
        public
        view
        virtual
        returns (uint112 _reserveXAssets, uint112 _reserveYAssets, uint32 _lastUpdateTimestamp)
    {
        _lastUpdateTimestamp = lastUpdateTimestamp;

        uint32 deltaUpdateTimestamp;
        // underflow is desired
        unchecked {
            deltaUpdateTimestamp = GeometricTWAP.getCurrentTimestamp() - _lastUpdateTimestamp;
        }

        if (deltaUpdateTimestamp > INTEREST_PERIOD_FOR_SWAP) {
            (, _reserveXAssets, _reserveYAssets,) = computeAssetsState();
        } else {
            _reserveXAssets = reserveXAssets;
            _reserveYAssets = reserveYAssets;
        }
    }

    function referenceReserves() external view virtual returns (uint112, uint112) {
        uint32 deltaUpdateTimestamp;
        unchecked {
            deltaUpdateTimestamp = GeometricTWAP.getCurrentTimestamp() - lastUpdateTimestamp;
        }
        if (deltaUpdateTimestamp < saturationAndGeometricTWAPState.midTermIntervalConfig()) {
            return (referenceReserveX, referenceReserveY);
        }

        // We always use raw reserves to compute reference reserves, because they represent the last actual price state.
        return getUpdatedReferenceReserves(TickMath.getTickFromReserves(reserveXAssets, reserveYAssets));
    }

    function totalAssetsAndShares(
        bool withInterest
    ) public view virtual returns (uint112[6] memory _allAssets, uint112[6] memory _allShares) {
        // return stored values if no interest is to be applied
        if (!withInterest) {
            _allAssets = allAssets;
            (uint256 totalLAssets,) = getDepositAndActiveLiquidityAssets();
            _allAssets[DEPOSIT_L] = uint112(totalLAssets);
            return (_allAssets, allShares);
        }

        uint256[3] memory protocolFees;
        uint112 _reserveXAssets;
        uint112 _reserveYAssets;
        (_allAssets, _reserveXAssets, _reserveYAssets, protocolFees) = computeAssetsState();

        _allShares = allShares;

        // Mint protocol fees only to deposit tokens.
        // Convert each fee amount to shares (before updating assets) to preserve ratio accuracy.
        // Then add the fee amount to the corresponding asset balance.
        for (uint256 i; i < FIRST_DEBT_TOKEN; i++) {
            // it's safe down cast here because protocolFees < interest
            // and interest <= type(uint112).max - max(depositedAssets, borrowedAssets)
            // due to the check in computeInterestAssetsGivenRate()
            // DEPOSIT_L already counts the fee in _allAssets[i] via BORROW_L, so divide by the pre-fee total.
            _allShares[i] += uint112(
                Convert.toShares(
                    protocolFees[i],
                    i == DEPOSIT_L ? _allAssets[i] - uint112(protocolFees[i]) : _allAssets[i],
                    _allShares[i],
                    ROUNDING_UP
                )
            );
            // For deposited liquidity, we calculate growth using
            // $$\sqrt{reserveX * reserveY} + borrowedLAssets$$, We add protocol fees to borrowed L
            // in computeAssetsState() -> accrueInterestWithAssets() and due to the dependence of
            // borrowed L to compute deposited L, we would double count them if we added them here.
            if (i > DEPOSIT_L) _allAssets[i] += uint112(protocolFees[i]);
        }
    }

    /**
     * @notice Computes fragile liquidity and validates it can be removed from active liquidity.
     * @param _activeLiquidityAssets The active liquidity available before the fragile liquidity decrement.
     */
    function fragileLiquidityAssets(
        uint256 _activeLiquidityAssets
    ) internal view returns (uint256 _fragileLiquidityAssets) {
        _fragileLiquidityAssets = Convert.toAssets(
            fragileLiquidityShares, rawTotalAssets(DEPOSIT_L), totalShares(DEPOSIT_L), ROUNDING_UP
        ) * FRAGILE_LIQUIDITY_DECREMENT_PERCENTAGE / MAG2;

        if (_fragileLiquidityAssets > _activeLiquidityAssets) {
            revert FragileLiquidityExceedsActiveLiquidity();
        }
    }

    /**
     * @notice used to update fragileLiquidityShares that have a borrow of x or y against them
     * @dev  We then need to increase fragile liquidity when
     *   1. a new borrow of x or y is made when none existed and the user has l deposits.
     *   2. l deposits are minted to a user with existing borrows of x or y.
     *   3. l deposits are transferred to a user with no existing l and but borrows of x or y.
     *   4. debt of x or y is transferred to a user with l shares but no debt existing x or y debt.
     *   Fragile liquidity then needs to be decreased when
     *   1. all borrows of x and y are repaid for a user with l deposits.
     *   2. l deposits are burned from a user with existing borrows of x or y.
     *   3. l deposits are transferred from a user with borrows of x or y to a user with no borrow
     *      of x or y.
     *   4. last debt of x or y is transferred from a user with l deposits to a user with no l
     *      deposits.
     * @param user the address to update fragile liquidity for.
     */
    function updateFragileLiquidity(
        address user
    ) internal {
        uint256 priorFragileShares = userFragileLiquidityShares[user];
        uint256 balanceLShares = balanceOf(user, DEPOSIT_L);
        bool debtOfXOrY = balanceOf(user, BORROW_X) > 0 || balanceOf(user, BORROW_Y) > 0;

        if (balanceLShares > priorFragileShares && debtOfXOrY) {
            // adding

            userFragileLiquidityShares[user] = balanceLShares;
            fragileLiquidityShares += uint112(balanceLShares - priorFragileShares);
        } else if (priorFragileShares > balanceLShares || (!debtOfXOrY && priorFragileShares > 0)) {
            // removing

            uint256 newBalanceLShares = debtOfXOrY ? balanceLShares : 0;

            userFragileLiquidityShares[user] = newBalanceLShares;
            fragileLiquidityShares -= uint112(priorFragileShares - newBalanceLShares);
        }
    }

    /**
     * @notice Recalculates current total assets, reserves, and protocol fees, accounting for elapsed time and interest.
     *
     * @dev Core logic for interest accrual and state updates (used by `totalAssetsAndShares` when `withInterest` is true):
     *      1. Fetches raw reserves before computing interest.
     *      2. If `totalDepositLAssets` is not 0, returns transient asset values immediately (no interest to accrue).
     *      3. Calculates time elapsed since last update (`deltaUpdateTimestamp`) and last lending state check (`deltaLendingTimestamp`).
     *      4. If no time has elapsed since last lending check (`deltaLendingTimestamp == 0`), returns stored values without recalculation.
     *      5. Otherwise:
     *         - Computes the current market tick via `getTickFromReserves()` and bounds it to valid ranges.
     *         - Determines active lending state tick and saturation percentage using `getLendingStateTick()`.
     *         - Calls `Interest.accrueInterestWithAssets()` to calculate interest, update asset values, and compute protocol fees.
     *         - Adds LP-earned interest portions to X and Y reserves.
     *
     * @return _allAssets Array of six `uint112` values: Recalculated total assets for each of the 6 Ammalgam token types (post-interest).
     * @return _reserveXAssets Reserve balance for Asset X, updated with LP-earned interest.
     * @return _reserveYAssets Reserve balance for Asset Y, updated with LP-earned interest.
     * @return protocolFees Array of three `uint256` values: Accumulated protocol fees for DEPOSIT_L, DEPOSIT_X, and DEPOSIT_Y (from interest accrual).
     */
    function computeAssetsState()
        internal
        view
        returns (
            uint112[6] memory _allAssets,
            uint112 _reserveXAssets,
            uint112 _reserveYAssets,
            uint256[3] memory protocolFees
        )
    {
        (_reserveXAssets, _reserveYAssets) = getRawReserves();

        if (totalDepositLAssets != 0) {
            return (
                [
                    totalDepositLAssets,
                    totalDepositXAssets,
                    totalDepositYAssets,
                    totalBorrowLAssets,
                    totalBorrowXAssets,
                    totalBorrowYAssets
                ],
                _reserveXAssets,
                _reserveYAssets,
                protocolFees
            );
        }

        uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
        uint32 deltaUpdateTimestamp;
        uint32 deltaLendingTimestamp;
        unchecked {
            deltaUpdateTimestamp = currentTimestamp - lastUpdateTimestamp;
            deltaLendingTimestamp = currentTimestamp - lastLendingTimestamp;
        }

        _allAssets = allAssets;

        // Set active liquidity assets for needed calculations in interest accrual and transient
        // storage
        (uint256 depositLAssets,) = getDepositAndActiveLiquidityAssets();
        _allAssets[DEPOSIT_L] = uint112(depositLAssets);

        if (deltaLendingTimestamp == 0) return (_allAssets, _reserveXAssets, _reserveYAssets, protocolFees);

        (int16 lendingStateTick, uint256 satPercentageInWads) = saturationAndGeometricTWAPState.getLendingStateTick(
            TickMath.getTickFromReserves(_reserveXAssets, _reserveYAssets), deltaUpdateTimestamp, deltaLendingTimestamp
        );
        uint256 interestXPortionForLP;
        uint256 interestYPortionForLP;
        (_allAssets, interestXPortionForLP, interestYPortionForLP, protocolFees) = Interest.accrueInterestWithAssets(
            _allAssets,
            Interest.AccrueInterestParams({
                duration: deltaLendingTimestamp,
                lendingStateTick: lendingStateTick,
                shares: allShares,
                satPercentageInWads: satPercentageInWads,
                reserveXAssets: _reserveXAssets,
                reserveYAssets: _reserveYAssets
            })
        );

        // cast is safe which is assured by accrueInterestWithAssets
        _reserveXAssets += uint112(interestXPortionForLP);
        _reserveYAssets += uint112(interestYPortionForLP);
    }

    function accrueSaturationPenaltiesAndInterest(
        address affectedAccount,
        uint256 minimumTimeBeforeUpdate
    )
        internal
        returns (uint256 _reserveXAssets, uint256 _reserveYAssets, uint256 balanceXAssets, uint256 balanceYAssets)
    {
        (_reserveXAssets, _reserveYAssets) = getRawReserves();
        if (_reserveXAssets > 0 && _reserveYAssets > 0) {
            uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
            uint32 deltaUpdateTimestamp;
            unchecked {
                deltaUpdateTimestamp = currentTimestamp - lastUpdateTimestamp;
            }

            updateObservation(_reserveXAssets, _reserveYAssets, currentTimestamp, deltaUpdateTimestamp);

            // Enter the lending checkpoint once `deltaLendingTimestamp >= minimumTimeBeforeUpdate`.
            // `minimumTimeBeforeUpdate` is DEFAULT_INTEREST_PERIOD (0) for every caller except swap, so
            // it normally enters on any elapsed time; swap passes INTEREST_PERIOD_FOR_SWAP (~1 day) to
            // throttle accrual to at most once per day.
            uint32 deltaLendingTimestamp;
            unchecked {
                deltaLendingTimestamp = currentTimestamp - lastLendingTimestamp;
            }
            if (minimumTimeBeforeUpdate <= deltaLendingTimestamp) {
                // penalties
                mintPenalties(affectedAccount, deltaLendingTimestamp);

                // slither-disable-next-line incorrect-equality
                if (deltaLendingTimestamp > 0) {
                    // in the update, we mint protocol fees and update transient storage for allAssets
                    (_reserveXAssets, _reserveYAssets) = updateTokenController(
                        currentTimestamp, deltaUpdateTimestamp, deltaLendingTimestamp, _reserveXAssets, _reserveYAssets
                    );
                }
            }
        }

        (balanceXAssets, balanceYAssets) = getNetBalances(_reserveXAssets, _reserveYAssets);
    }

    // slither-disable-next-line naming-convention
    function updateObservation(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets,
        uint32 currentTimestamp,
        uint32 deltaUpdateTimestamp
    ) private {
        if (0 < deltaUpdateTimestamp && 0 < _reserveXAssets && 0 < _reserveYAssets) {
            (uint256 missingX, uint256 missingY) = missingAssets();

            int16 newTick = TickMath.getTickFromReserves(
                Convert.calculateReserveAdjustmentsForMissingAssets(
                    _reserveXAssets, missingX, BUFFER_OBS, BUFFER_OBS_NUMERATOR
                ),
                Convert.calculateReserveAdjustmentsForMissingAssets(
                    _reserveYAssets, missingY, BUFFER_OBS, BUFFER_OBS_NUMERATOR
                )
            );

            // Call to trusted contract holding some pair state.
            // slither-disable-next-line reentrancy-benign,reentrancy-no-eth
            if (saturationAndGeometricTWAPState.recordObservation(newTick, deltaUpdateTimestamp)) {
                lastUpdateTimestamp = currentTimestamp;
                updateReferenceReserve(newTick);
            }
        }
    }

    function mintPenalties(address account, uint32 deltaLendingTimestamp) internal {
        if (account != ZERO_ADDRESS || deltaLendingTimestamp > 0) {
            // add penalty before interest because penalty state existed for the duration
            // mint DL and BL for pair to the amount of penalty [LAssets] since the previous state update in total
            uint256 allAssetsDepositL = rawTotalAssets(DEPOSIT_L);
            uint256 allAssetsBorrowL = rawTotalAssets(BORROW_L);
            uint256 allSharesBorrowL = totalShares(BORROW_L);

            // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events External contract is under our control
            (uint256 totalPenaltyInBorrowLShares, uint256 accountPenaltyInBorrowLShares) =
            saturationAndGeometricTWAPState.accruePenalties(
                account,
                externalLiquidity,
                deltaLendingTimestamp,
                allAssetsDepositL,
                allAssetsBorrowL,
                allSharesBorrowL,
                fragileLiquidityAssets(allAssetsDepositL + externalLiquidity - allAssetsBorrowL)
            );

            if (totalPenaltyInBorrowLShares > 0) {
                // defensive check transient state should not be set for this path.
                // slither-disable-next-line incorrect-equality
                require(totalDepositLAssets == 0, 'TS');
                uint256 totalPenaltyInLAssets =
                    Convert.toAssets(totalPenaltyInBorrowLShares, allAssetsBorrowL, allSharesBorrowL, ROUNDING_UP);

                // mint BL for penalty not minted to any specific account
                // DL is derived from sqrt(reserveX * reserveY) + BL, so updating BL automatically
                // updates DL.
                mintId(BORROW_L, address(this), address(this), totalPenaltyInLAssets, totalPenaltyInBorrowLShares);
            }

            // update the account, we use the min in case rounding up exceeds the amount of shares
            // if there where only one account in penalty that receives the whole penalty.
            if (0 < accountPenaltyInBorrowLShares) {
                tokens(BORROW_L).ownerTransfer(
                    address(this),
                    account,
                    Math.min(accountPenaltyInBorrowLShares, _tokenBorrowL.balanceOf(address(this)))
                );
            }
        }
    }

    function getAssets(
        uint112[6] memory _totalAssets,
        uint112[6] memory _totalShares,
        address toCheck
    ) internal view returns (uint256[6] memory userAssets) {
        for (uint256 i; i < TOKEN_COUNT; i++) {
            uint256 currentShares = balanceOf(toCheck, i);
            if (0 < currentShares) {
                // FIRST_DEBT_TOKEN <= i <=> rounding up for borrow tokens
                userAssets[i] = Convert.toAssets(currentShares, _totalAssets[i], _totalShares[i], FIRST_DEBT_TOKEN <= i);
            }
        }
    }

    function updateTokenController(
        uint32 currentTimestamp,
        uint32 deltaUpdateTimestamp,
        uint32 deltaLendingTimestamp,
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal returns (uint256 updatedReservesX, uint256 updatedReservesY) {
        // slither-disable-next-line reentrancy-benign External contract is under our control
        (int16 lendingStateTick, uint256 satPercentageInWads) = saturationAndGeometricTWAPState
            .getLendingStateTickAndCheckpoint(deltaUpdateTimestamp, deltaLendingTimestamp);

        lastLendingTimestamp = currentTimestamp;

        (uint256 interestXForLP, uint256 interestYForLP, uint256[3] memory protocolFeeAssets) = Interest
            .accrueInterestAndUpdateReservesWithAssets(
            allAssets,
            Interest.AccrueInterestParams({
                duration: deltaLendingTimestamp,
                lendingStateTick: lendingStateTick,
                shares: allShares,
                satPercentageInWads: satPercentageInWads,
                reserveXAssets: _reserveXAssets,
                reserveYAssets: _reserveYAssets
            })
        );

        updatedReservesX = _reserveXAssets + interestXForLP;
        updatedReservesY = _reserveYAssets + interestYForLP;

        updateReserves(updatedReservesX, updatedReservesY);

        address feeTo = factory.feeTo();

        // DEPOSIT_L fee is already in its total via BORROW_L so we back it out to compute shares to mint.
        // X and Y fees are not included yet.
        mintProtocolFees(DEPOSIT_L, feeTo, protocolFeeAssets[DEPOSIT_L], true);
        mintProtocolFees(DEPOSIT_X, feeTo, protocolFeeAssets[DEPOSIT_X], false);
        mintProtocolFees(DEPOSIT_Y, feeTo, protocolFeeAssets[DEPOSIT_Y], false);

        (uint256 _totalDepositLAssets, uint256 _activeLiquidityAssets) = getDepositAndActiveLiquidityAssets();
        totalDepositLAssets = uint112(_totalDepositLAssets);
        activeLiquidityAssets = uint112(_activeLiquidityAssets);
        totalDepositXAssets = uint112(rawTotalAssets(DEPOSIT_X));
        totalDepositYAssets = uint112(rawTotalAssets(DEPOSIT_Y));
        totalBorrowLAssets = uint112(rawTotalAssets(BORROW_L));
        totalBorrowXAssets = uint112(rawTotalAssets(BORROW_X));
        totalBorrowYAssets = uint112(rawTotalAssets(BORROW_Y));
    }

    function updateReferenceReserve(
        int256 newTick
    ) internal {
        (referenceReserveX, referenceReserveY) = getUpdatedReferenceReserves(newTick);
    }

    function mintProtocolFees(
        uint256 tokenType,
        address feeTo,
        uint256 protocolFee,
        bool feeIncludedInTotalAssets
    ) internal {
        if (protocolFee > 0) {
            // Back the fee out of the denominator when it is already counted in rawTotalAssets(tokenType).
            uint256 totalDepositedAssets = rawTotalAssets(tokenType);
            if (feeIncludedInTotalAssets) {
                totalDepositedAssets -= protocolFee;
            }
            mintId(
                tokenType,
                address(this),
                feeTo,
                protocolFee,
                Convert.toShares(protocolFee, totalDepositedAssets, totalShares(tokenType), ROUNDING_UP)
            );
        }
    }

    function updateReserves(uint256 newReserveXAssets, uint256 newReserveYAssets) internal {
        (uint112 _castedXAssets, uint112 _castedYAssets) = _castReserves(newReserveXAssets, newReserveYAssets);

        reserveXAssets = _castedXAssets;
        reserveYAssets = _castedYAssets;

        // Update cached active liquidity if transient state is set
        // slither-disable-next-line incorrect-equality
        if (totalDepositLAssets != 0) {
            uint112 newActiveLiquidity = uint112(calculateActiveLiquidityAssets(newReserveXAssets, newReserveYAssets));
            activeLiquidityAssets = newActiveLiquidity;

            updateAssets(DEPOSIT_L, newActiveLiquidity + totalBorrowLAssets);
        }

        // slither-disable-next-line reentrancy-events
        emit Sync(_castedXAssets, _castedYAssets);
    }

    function updateReservesAndReference(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets,
        uint256 newReserveXAssets,
        uint256 newReserveYAssets
    ) internal {
        updateReserves(newReserveXAssets, newReserveYAssets);
        (referenceReserveX, referenceReserveY) = _castReserves(
            Convert.mulDiv(referenceReserveX, newReserveXAssets, _reserveXAssets, false),
            Convert.mulDiv(referenceReserveY, newReserveYAssets, _reserveYAssets, false)
        );
    }

    function _castReserves(uint256 _reserveXAssets, uint256 _reserveYAssets) internal pure returns (uint112, uint112) {
        return (SafeCast.toUint112(_reserveXAssets), SafeCast.toUint112(_reserveYAssets));
    }

    // slither-disable-next-line naming-convention
    function getNetBalances(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal view returns (uint256, uint256) {
        (IERC20 _tokenX, IERC20 _tokenY) = underlyingTokens();

        return (
            _tokenX.balanceOf(address(this)) + rawTotalAssets(BORROW_X) - rawTotalAssets(DEPOSIT_X) - _reserveXAssets,
            _tokenY.balanceOf(address(this)) + rawTotalAssets(BORROW_Y) - rawTotalAssets(DEPOSIT_Y) - _reserveYAssets
        );
    }

    function missingAssets() internal view returns (uint112 missingXAssets, uint112 missingYAssets) {
        uint256 depositXAssets = rawTotalAssets(DEPOSIT_X);
        uint256 depositYAssets = rawTotalAssets(DEPOSIT_Y);
        uint256 borrowXAssets = rawTotalAssets(BORROW_X);
        uint256 borrowYAssets = rawTotalAssets(BORROW_Y);
        // no need to safe cast.
        // 0 <= borrow <= uint112.max
        // 0 <= deposit <= uint112.max
        // -uint256.max <= -deposit <= 0
        // -uint256.max <= borrow - deposit <= uint112.max
        missingXAssets = uint112(Math.max(borrowXAssets, depositXAssets) - depositXAssets);
        missingYAssets = uint112(Math.max(borrowYAssets, depositYAssets) - depositYAssets);
    }

    /**
     * @notice Active liquidity from reserves, using the same depletion adjustment as the swap
     *  K-check in `calculateReserveAdjustmentsForMissingAssets`. Caching raw `sqrt(X*Y)` is
     *  non-monotonic across depletion cycles, letting saturation-tree leaves register above the
     *  post-recovery `maxLeaf` and bricking the pair with `MaxTrancheOverSaturated()`.
     * @param _reserveXAssets The reserve X used for the active-liquidity calculation.
     * @param _reserveYAssets The reserve Y used for the active-liquidity calculation.
     * @return The depletion-adjusted active liquidity, i.e. sqrt of the adjusted-reserve product.
     */
    function calculateActiveLiquidityAssets(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal view returns (uint256) {
        (uint112 _missingXAssets, uint112 _missingYAssets) = missingAssets();
        return
            Convert.depletionAdjustedActiveLiquidity(_reserveXAssets, _reserveYAssets, _missingXAssets, _missingYAssets);
    }

    /**
     * @notice Get the deposit, and active liquidity assets.
     * @return depositLiquidityAssets The deposit liquidity assets.
     * @return currentActiveLiquidityAssets The current active liquidity assets.
     */
    function getDepositAndActiveLiquidityAssets()
        internal
        view
        returns (uint256 depositLiquidityAssets, uint256 currentActiveLiquidityAssets)
    {
        // Return cached values if transient state is set
        // slither-disable-next-line incorrect-equality
        if (totalDepositLAssets != 0) {
            return (totalDepositLAssets, activeLiquidityAssets);
        }

        currentActiveLiquidityAssets = calculateActiveLiquidityAssets(uint256(reserveXAssets), uint256(reserveYAssets));

        depositLiquidityAssets = currentActiveLiquidityAssets + allAssets[BORROW_L];
    }

    function burnBadDebt(address borrower, uint256 tokenType, uint256 reserve) internal {
        uint256 badDebtShares = tokens(tokenType).balanceOf(borrower);
        // round down means the commons debt and commons deposit is 1 unit larger
        uint256 badDebtAssets =
            Convert.toAssets(badDebtShares, rawTotalAssets(tokenType), totalShares(tokenType), !ROUNDING_UP);

        burnId(tokenType, address(this), borrower, badDebtAssets, badDebtShares);
        if (tokenType == BORROW_L) {
            // distribute the loss to the pool. This call will update transient storage for any
            // interactions after the current one within the same transaction. Typically we don't
            // back out burned liquidity from the deposits since depositL = sqrt(reserveX *
            // reserveY) + borrowedL, and burning of borrowed L also requires the replenishment of
            // the reserves leaving deposit L unchanged. With bad debt the reserves do not get
            // replenished and thus we do need to back out bad debt.
            updateAssets(DEPOSIT_L, SafeCast.toUint112(rawTotalAssets(DEPOSIT_L) - badDebtAssets));
        } else {
            uint256 totalAssetsWithReserves = rawTotalAssets(tokenType - FIRST_DEBT_TOKEN) + reserve;
            uint256 burnReserves = Convert.mulDiv(badDebtAssets, reserve, totalAssetsWithReserves, false);

            if (tokenType == BORROW_X) {
                reserveXAssets -= SafeCast.toUint112(burnReserves);
                updateAssets(DEPOSIT_X, SafeCast.toUint112(rawTotalAssets(DEPOSIT_X) - (badDebtAssets - burnReserves)));
            } else {
                reserveYAssets -= SafeCast.toUint112(burnReserves);
                updateAssets(DEPOSIT_Y, SafeCast.toUint112(rawTotalAssets(DEPOSIT_Y) - (badDebtAssets - burnReserves)));
            }
            // Reserves changed, so cached active liquidity must be recalculated if transient
            // state is set.
            // slither-disable-next-line incorrect-equality
            if (totalDepositLAssets != 0) {
                uint112 newActiveLiquidity =
                    uint112(calculateActiveLiquidityAssets(uint256(reserveXAssets), uint256(reserveYAssets)));
                activeLiquidityAssets = newActiveLiquidity;
                uint256 newDepositL = newActiveLiquidity + allAssets[BORROW_L];
                updateAssets(DEPOSIT_L, SafeCast.toUint112(newDepositL));
            }
        }

        emit BurnBadDebt(borrower, tokenType, badDebtAssets, badDebtShares);
    }

    /**
     * @dev Get the updated reference reserves based on the `newTick`.
     * @param newTick The current tick.
     * @return _referenceReserveX The updated reference reserve X.
     * @return _referenceReserveY The updated reference reserve Y.
     */
    function getUpdatedReferenceReserves(
        int256 newTick
    ) internal view returns (uint112, uint112) {
        int256 midTermTick = saturationAndGeometricTWAPState.getObservedMidTermTick();
        (uint256 _refReserveX, uint256 _refReserveY) = Interest.getReservesAtTick(
            rawTotalAssets(DEPOSIT_L) - rawTotalAssets(BORROW_L),
            GeometricTWAP.calculateTickAverageTowardsMidTerm(midTermTick, newTick)
        );
        return _castReserves(_refReserveX, _refReserveY);
    }
}
