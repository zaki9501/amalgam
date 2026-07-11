// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    ROUNDING_UP
} from '@core-v1/contracts/interfaces/tokens/ITokenController.sol';
import {Convert} from '@core-v1/contracts/libraries/Convert.sol';

import {IPeripheralLending} from './interfaces/IPeripheralLending.sol';
import {PairUtils, IAmmalgamPair} from '@peripheral-v1/libraries/PairUtils.sol';

/**
 * @title PeripheralLending
 * @notice Stateless deposit, withdraw, and repay helpers that pull user funds and drive the Ammalgam
 *         pair. Split out of Peripheral to relieve its EIP-170 size pressure. Opens no callback
 *         surface, so it carries no factory, transient state, or reentrancy lock.
 */
contract PeripheralLending is IPeripheralLending {
    using SafeERC20 for IERC20;

    function depositLiquidityHelper(
        HelperParams calldata helperParams
    ) external {
        pairTransfer(helperParams, false, 0, 0).mint(helperParams.to);
    }

    function depositHelper(
        HelperParams calldata helperParams
    ) external {
        pairTransfer(helperParams, false, 0, 0).deposit(helperParams.to);
    }

    function withdrawHelper(
        HelperParams calldata helperParams
    ) external {
        pairTransfer(helperParams, true, DEPOSIT_X, DEPOSIT_Y).withdraw(helperParams.to);
    }

    function withdrawLiquidityHelper(address to, address pairAddress, uint256 amount) external {
        IAmmalgamPair pair = IAmmalgamPair(pairAddress);
        IERC20 tokenL = pair.tokens(DEPOSIT_L);
        tokenL.safeTransferFrom(msg.sender, pairAddress, amount);
        pair.burn(to);
    }

    function repayHelper(
        HelperParams calldata helperParams
    ) external {
        pairTransfer(helperParams, false, 0, 0).repay(helperParams.to);
    }

    function repayFullHelper(
        HelperParams calldata helperParams
    ) external {
        (IAmmalgamPair pair, IERC20 tokenX, IERC20 tokenY) = PairUtils.getPairParams(helperParams.pairAddress);

        uint256 borrowXAssets = IERC4626(address(pair.tokens(BORROW_X))).maxWithdraw(helperParams.to);
        uint256 borrowYAssets = IERC4626(address(pair.tokens(BORROW_Y))).maxWithdraw(helperParams.to);

        PairUtils.transferFromXAndY(msg.sender, helperParams.pairAddress, tokenX, tokenY, borrowXAssets, borrowYAssets);

        pair.repay(helperParams.to);
    }

    function repayLiquidityHelper(
        HelperParams calldata helperParams
    ) external {
        pairTransfer(helperParams, false, 0, 0).repayLiquidity(helperParams.to);
    }

    function repayLiquidityFullHelper(
        HelperParams calldata helperParams
    ) external {
        (IAmmalgamPair pair, IERC20 tokenX, IERC20 tokenY) = PairUtils.getPairParams(helperParams.pairAddress);
        (uint112[6] memory assets, uint112[6] memory shares) = pair.totalAssetsAndShares(true);

        // We round up to repay more assets than the debt, to be in favor of the pair
        uint256 borrowLAssets = Convert.toAssets(
            pair.tokens(BORROW_L).balanceOf(helperParams.to), assets[BORROW_L], shares[BORROW_L], ROUNDING_UP
        );

        // round up here to get the borrowLX and borrowLY from borrowL in order to fully repay the borrowed liquidity in the close call back repayL().
        (uint256 borrowLX, uint256 borrowLY) =
            PairUtils.computeLXAndLYBorrowedLiquidity(helperParams.pairAddress, borrowLAssets, Math.Rounding.Ceil);

        PairUtils.transferFromXAndY(msg.sender, helperParams.pairAddress, tokenX, tokenY, borrowLX, borrowLY);

        pair.repayLiquidity(helperParams.to);
    }

    function pairTransfer(
        HelperParams calldata helperParams,
        bool useTokenTypes,
        uint256 tokenType1,
        uint256 tokenType2
    ) private returns (IAmmalgamPair ammalgamPair) {
        ammalgamPair = IAmmalgamPair(helperParams.pairAddress);
        (IERC20 token1, IERC20 token2) = useTokenTypes
            ? (ammalgamPair.tokens(tokenType1), ammalgamPair.tokens(tokenType2))
            : ammalgamPair.underlyingTokens();
        PairUtils.transferFromXAndY(
            msg.sender, helperParams.pairAddress, token1, token2, helperParams.amountX, helperParams.amountY
        );
        return ammalgamPair;
    }
}
