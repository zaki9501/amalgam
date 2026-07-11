// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {OwnableUpgradeable} from '@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {PriceExtremes} from 'contracts/libraries/PriceExtremes.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';

contract SaturationAndGeometricTWAPState is Initializable, ISaturationAndGeometricTWAPState, OwnableUpgradeable {
    // main state

    uint24 public midTermIntervalConfig;
    uint24 public longTermIntervalConfig;

    // slither-disable-next-line uninitialized-state
    mapping(address => Saturation.SaturationStruct) internal satDataGivenPair;
    mapping(address => GeometricTWAP.Observations) internal TWAPDataGivenPair;
    mapping(address => mapping(address => uint256)) maxNewPositionSaturationInMAG2; // pair => account => value
    mapping(address => mapping(address => uint256)) lastUsedActiveLiquidityInLAssets;
    mapping(address => bool) internal isPairInitialized;
    mapping(address => PriceExtremes.State) internal priceExtremesGivenPair;

    constructor() {
        _disableInitializers(); // Disable constructor (proxy pattern)
    }

    function initialize(
        uint24 _midTermIntervalConfig,
        uint24 _longTermIntervalConfig,
        address _owner
    ) public initializer {
        __Ownable_init(_owner);
        // slither-disable-next-line events-maths
        midTermIntervalConfig = _midTermIntervalConfig;
        // slither-disable-next-line events-maths
        longTermIntervalConfig = _longTermIntervalConfig;
    }

    modifier isInitialized() {
        _isInitialized();
        _;
    }

    function _isInitialized() internal view {
        if (!isPairInitialized[msg.sender]) revert PairDoesNotExist();
    }

    /**
     * @notice  initializes the sat and TWAP struct
     * @dev     initCheck can be removed once the tree structure is fixed
     */
    function init(uint256 reserveXAssets, uint256 reserveYAssets) external {
        if (isPairInitialized[msg.sender]) revert PairAlreadyExists();
        Saturation.SaturationStruct storage satStruct = satDataGivenPair[msg.sender];
        GeometricTWAP.Observations storage observations = TWAPDataGivenPair[msg.sender];

        Saturation.initializeSaturationStruct(satStruct);
        GeometricTWAP.initializeObservationStruct(observations, midTermIntervalConfig, longTermIntervalConfig);
        isPairInitialized[msg.sender] = true;

        GeometricTWAP.addObservationAndSetLendingState(
            observations, TickMath.getTickFromReserves(reserveXAssets, reserveYAssets)
        );
    }

    // saturation

    function setNewPositionSaturation(address pair, uint256 maxDesiredSaturationMag2) external {
        if (!isPairInitialized[pair]) revert PairDoesNotExist();
        if (maxDesiredSaturationMag2 > Saturation.MAX_INITIAL_SATURATION_MAG2 || maxDesiredSaturationMag2 == 0) {
            revert InvalidUserConfiguration();
        }
        maxNewPositionSaturationInMAG2[pair][msg.sender] = maxDesiredSaturationMag2;
    }

    function getTree(address pairAddress, bool netDebtX) private view returns (Saturation.Tree storage) {
        Saturation.SaturationStruct storage satStruct = satDataGivenPair[pairAddress];
        return netDebtX ? satStruct.netXTree : satStruct.netYTree;
    }

    function getTreeLeafDetails(
        address pairAddress,
        bool netDebtX,
        uint256 leafIndex
    )
        external
        view
        returns (
            Saturation.SaturationPair memory saturation,
            uint256 currentPenaltyInBorrowLSharesPerSatInQ72,
            uint128 totalSatInLAssets,
            uint16 highestSetLeaf,
            uint16[] memory tranches
        )
    {
        Saturation.Tree storage tree = getTree(pairAddress, netDebtX);
        totalSatInLAssets = tree.totalSatInLAssets;
        highestSetLeaf = tree.highestSetLeaf;
        Saturation.Leaf storage leaf = tree.leafs[leafIndex];
        saturation = leaf.leafSatPair;
        currentPenaltyInBorrowLSharesPerSatInQ72 = leaf.penaltyInBorrowLSharesPerSatInQ72;
        tranches = leaf.tranches.keyList;
    }

    function getTrancheDetails(
        address pairAddress,
        bool netDebtX,
        int16 tranche
    ) external view returns (uint16 leaf, Saturation.SaturationPair memory saturation) {
        Saturation.Tree storage tree = getTree(pairAddress, netDebtX);
        leaf = tree.trancheToLeaf[tranche];
        saturation = tree.trancheToSaturation[tranche];
    }

    function getAccount(
        address pairAddress,
        bool netDebtX,
        address accountAddress
    ) external view returns (Saturation.Account memory) {
        return getTree(pairAddress, netDebtX).accountData[accountAddress];
    }

    /**
     * @inheritdoc ISaturationAndGeometricTWAPState
     */
    function accountExistsInSaturation(
        address pairAddress,
        address accountAddress
    ) external view returns (bool exists) {
        exists = _accountExistsInSaturation(pairAddress, accountAddress);
    }

    /**
     * @notice Internal sibling of `accountExistsInSaturation` so callers within this contract
     *   can check tree membership without paying the external-call overhead or making the
     *   getter `public`.
     */
    function _accountExistsInSaturation(
        address pairAddress,
        address accountAddress
    ) private view returns (bool exists) {
        Saturation.SaturationStruct storage satStruct = satDataGivenPair[pairAddress];
        exists = satStruct.netXTree.accountData[accountAddress].exists
            || satStruct.netYTree.accountData[accountAddress].exists;
    }

    /**
     * @notice  update the borrow position of an account and potentially check (and revert) if the
     *   resulting sat is too high
     * @dev     run accruePenalties before running this function. `lastUsedActiveLiquidityInLAssets`
     *   is captured only on the transition into saturation, so third-party-triggered updates
     *   cannot clobber a position's baseline ALA (OV-6-1).
     * @param   inputParams  contains the position and pair params, like account borrows/deposits,
     *   current price and active liquidity
     * @param   account  for which is position is being updated
     */
    function update(
        Validation.InputParams memory inputParams,
        address account,
        bool skipMinOrMaxTickCheck
    ) public virtual isInitialized {
        bool existedBefore = _accountExistsInSaturation(msg.sender, account);

        uint256 desiredSaturationInMAG2 =
            scaleDesiredSaturation(msg.sender, account, inputParams.activeLiquidityAssets, true);

        Saturation.update(
            satDataGivenPair[msg.sender], inputParams, account, desiredSaturationInMAG2, skipMinOrMaxTickCheck
        );

        if (!existedBefore && _accountExistsInSaturation(msg.sender, account)) {
            lastUsedActiveLiquidityInLAssets[msg.sender][account] = inputParams.activeLiquidityAssets;
        }
    }

    /**
     * @notice Scales the desired saturation threshold based on changes in Active Liquidity Assets (ALA).
     * @dev When liquidity is burned from the pool, ALA decreases. Without scaling, this would cause
     *      existing positions to appear more saturated (since saturation = borrows / ALA), potentially
     *      triggering unwarranted liquidation premiums. This function scales the desired saturation
     *      proportionally to ALA changes to maintain the position's relative health.
     *      The scaling formula: scaled = lastUsedALA * desiredSat / currentALA.
     *      Scaling is applied only while the account is in the saturation tree, so baselines
     *      left over from previously-closed positions cannot influence a freshly-opened one.
     * @param pair The address of the pair contract.
     * @param account The account whose saturation threshold is being scaled.
     * @param currentALA The current active liquidity assets in the pool.
     * @param capAtPenaltyStart If `true`, caps the scaled value at START_SATURATION_PENALTY_RATIO_IN_MAG2.
     *        Used in _update() to prevent excessive.
     *        Set to `false` in calcSatChangeRatioBips() for accurate premium calculations.
     * @return desiredSaturationInMAG2 The scaled desired saturation threshold.
     */
    function scaleDesiredSaturation(
        address pair,
        address account,
        uint256 currentALA,
        bool capAtPenaltyStart
    ) internal view returns (uint256 desiredSaturationInMAG2) {
        desiredSaturationInMAG2 = maxNewPositionSaturationInMAG2[pair][account];
        if (desiredSaturationInMAG2 == 0) {
            desiredSaturationInMAG2 = Saturation.START_SATURATION_PENALTY_RATIO_IN_MAG2;
        }

        uint256 lastUsedALA = lastUsedActiveLiquidityInLAssets[pair][account];
        if (lastUsedALA > 0 && _accountExistsInSaturation(pair, account)) {
            uint256 scaled = lastUsedALA * desiredSaturationInMAG2 / currentALA;
            if (capAtPenaltyStart) {
                scaled = Math.min(Saturation.START_SATURATION_PENALTY_RATIO_IN_MAG2, scaled);
            }
            desiredSaturationInMAG2 = Math.max(desiredSaturationInMAG2, scaled);
        }
    }

    /**
     * @notice  accrue penalties since last accrual based on all over saturated positions
     *
     * @param   externalLiquidity  Swap liquidity outside this pool
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     * @param   fragileLiquidityAssets  fragile liquidity removed from active liquidity so the penalty
     * threshold reads the same liquidity we use to measure risk capacity in update()
     */
    function accruePenalties(
        address account,
        uint256 externalLiquidity,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL,
        uint256 fragileLiquidityAssets
    ) external isInitialized returns (uint112 penaltyInBorrowLShares, uint112 accountPenaltyInBorrowLShares) {
        // slither-disable-next-line unused-return false positive
        return Saturation.accruePenalties(
            satDataGivenPair[msg.sender],
            account,
            externalLiquidity,
            duration,
            allAssetsDepositL,
            allAssetsBorrowL,
            allSharesBorrowL,
            fragileLiquidityAssets
        );
    }

    /**
     * @notice Calculate the ratio by which the saturation has changed for `account`.
     * @param inputParams The params containing the position of `account`.
     * @param liqSqrtPriceInXInQ72 The liquidation sqrt price for netX in Q72; pass 0 if not applicable.
     * @param liqSqrtPriceInYInQ72 The liquidation sqrt price for netY in Q72; pass 0 if not applicable.
     * @param pairAddress The address of the pair
     * @param account The account for which we are calculating the saturation change ratio.
     * @return ratioBips The ratio representing the change saturation for account.
     */
    function calcSatChangeRatioBips(
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 liqSqrtPriceInYInQ72,
        address pairAddress,
        address account
    ) external view virtual returns (uint256 ratioBips) {
        // Don't cap at START_SATURATION_PENALTY_RATIO_IN_MAG2 - this is for premium calculation
        uint256 desiredSaturationInMAG2 =
            scaleDesiredSaturation(pairAddress, account, inputParams.activeLiquidityAssets, false);

        // slither-disable-next-line unused-return false positive
        return Saturation.calcSatChangeRatioBips(
            satDataGivenPair[pairAddress],
            inputParams,
            liqSqrtPriceInXInQ72,
            liqSqrtPriceInYInQ72,
            account,
            desiredSaturationInMAG2
        );
    }

    // price extremes

    function recordPriceExtreme(
        uint256 priceQ128
    ) external isInitialized {
        PriceExtremes.record(priceExtremesGivenPair[msg.sender], priceQ128, uint32(midTermIntervalConfig));
    }

    // twap
    // view

    function getObservations(
        address pairAddress
    ) external view returns (GeometricTWAP.Observations memory) {
        return TWAPDataGivenPair[pairAddress];
    }

    /**
     * @notice Configures the interval of long-term observations.
     * @dev This function is used to set the long-term interval between observations for the long-term buffer.
     * @param pairAddress The address of the pair for which the long-term interval is being configured.
     * @param _longTermIntervalConfig The desired duration for each long-term period.
     *      The size is set as a factor of the mid-term interval to ensure a sufficient buffer, requiring
     *      at least 16 * 12 = 192 seconds per period, resulting in a total of ~25 minutes (192 * 8 = 1536 seconds)
     *      for the long-term buffer.
     */
    function configLongTermInterval(address pairAddress, uint24 _longTermIntervalConfig) external onlyOwner {
        GeometricTWAP.configLongTermInterval(TWAPDataGivenPair[pairAddress], _longTermIntervalConfig);
    }

    /**
     * @notice Records a new observation tick value and updates the observation data.
     * @dev This function is used to record new observation data for the contract. It ensures that
     *      the provided tick value is stored appropriately in both mid-term and long-term
     *      observations, updates interval counters, and handles tick cumulative values based
     *      on the current interval configuration. Ensures that this function is called in
     *      chronological order, with increasing timestamps. Returns in case the
     *      provided block timestamp is less than or equal to the last recorded timestamp.
     * @param newTick The new tick value to be recorded, representing the most recent update of
     *      reserveXAssets and reserveYAssets.
     * @param timeElapsed The time elapsed since the last observation.
     * @return bool indicating whether the observation was recorded or not.
     */
    function recordObservation(int16 newTick, uint32 timeElapsed) public virtual isInitialized returns (bool) {
        return GeometricTWAP.recordObservation(TWAPDataGivenPair[msg.sender], newTick, timeElapsed);
    }

    /**
     * @notice Gets the min and max range of tick values from the stored oracle observations.
     * @dev This function calculates the minimum and maximum tick values among three observed ticks:
     *          long-term tick, mid-term tick, and current tick.
     * @param pair The address of the pair for which the tick range is being calculated.
     * @param reserveXAssets The current pair reserves of asset X.
     * @param reserveYAssets The current pair reserves of asset Y.
     * @param includeLongTermTick Boolean value indicating whether to include the long-term tick in the range.
     * @return minTick The minimum tick value among the three observed ticks.
     * @return maxTick The maximum tick value among the three observed ticks.
     */
    function getTickRange(
        address pair,
        uint256 reserveXAssets,
        uint256 reserveYAssets,
        bool includeLongTermTick
    ) external view virtual returns (int16 minTick, int16 maxTick) {
        if (includeLongTermTick) {
            // slither-disable-next-line unused-return false positive.
            (minTick, maxTick) = GeometricTWAP.getTickRange(
                TWAPDataGivenPair[pair], TickMath.getTickFromReserves(reserveXAssets, reserveYAssets)
            );
            (minTick, maxTick) =
                PriceExtremes.widen(priceExtremesGivenPair[pair], minTick, maxTick, uint32(midTermIntervalConfig));
        } else {
            // slither-disable-next-line unused-return false positive.
            (minTick, maxTick) = GeometricTWAP.getTickRangeWithoutLongTerm(TWAPDataGivenPair[pair]);
        }
    }

    /**
     * @notice Gets the tick value representing the TWAP since the last
     *         lending update and checkpoints the current lending cumulative sum
     *         as `self.lendingCumulativeSum` and the current block timestamp as `self.lastLendingTimestamp`.
     * @dev See `getLendingStateTick` for implementation details which was
     *      separated to allow view access without any state updates.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     */
    function getLendingStateTickAndCheckpoint(
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) external isInitialized returns (int16 lendingStateTick, uint256 maxSatInWads) {
        lendingStateTick = GeometricTWAP.getLendingStateTickAndCheckpoint(
            TWAPDataGivenPair[msg.sender], timeElapsedSinceUpdate, timeElapsedSinceLendingUpdate
        );
        maxSatInWads = Saturation.getSatPercentageInWads(satDataGivenPair[msg.sender]);
    }

    /**
     * @dev Retrieves the mid-term tick value based on the stored observations.
     * @return midTermTick The mid-term tick value.
     */
    function getObservedMidTermTick() external view returns (int16) {
        return GeometricTWAP.getObservedMidTermTick(TWAPDataGivenPair[msg.sender]);
    }

    /**
     * @notice Gets the tick value representing the TWAP since the last lending update.
     * @param newTick The new tick value to be recorded, representing the most recent update of reserveXAssets and reserveYAssets.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     * @return maxSatInWads The maximum saturation in WADs.
     */
    function getLendingStateTick(
        int56 newTick,
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) external view returns (int16 lendingStateTick, uint256 maxSatInWads) {
        // slither-disable-next-line unused-return false positive.
        (lendingStateTick,) = GeometricTWAP.getLendingStateTick(
            TWAPDataGivenPair[msg.sender], newTick, timeElapsedSinceUpdate, timeElapsedSinceLendingUpdate, true
        );
        maxSatInWads = Saturation.getSatPercentageInWads(satDataGivenPair[msg.sender]);
    }
}
