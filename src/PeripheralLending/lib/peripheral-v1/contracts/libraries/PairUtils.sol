// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IAmmalgamPair as IPair} from '@core-v1/contracts/interfaces/IAmmalgamPair.sol';
import {
    ITokenController,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_X,
    BORROW_Y
} from '@core-v1/contracts/interfaces/tokens/ITokenController.sol';

interface IAmmalgamPair is IPair, ITokenController {}

library PairUtils {
    using SafeERC20 for IERC20;

    function missingAssets(
        IAmmalgamPair _pair
    ) internal view returns (uint112 missingXAssets, uint112 missingYAssets) {
        (uint112[6] memory assets,) = _pair.totalAssetsAndShares(true);
        uint256 depositXAssets = assets[DEPOSIT_X];
        uint256 depositYAssets = assets[DEPOSIT_Y];
        uint256 borrowXAssets = assets[BORROW_X];
        uint256 borrowYAssets = assets[BORROW_Y];
        missingXAssets = uint112(borrowXAssets > depositXAssets ? borrowXAssets - depositXAssets : 0);
        missingYAssets = uint112(borrowYAssets > depositYAssets ? borrowYAssets - depositYAssets : 0);
    }

    function getPairParams(
        address _pair
    ) internal view returns (IAmmalgamPair ammalgamPair, IERC20 tokenX, IERC20 tokenY) {
        ammalgamPair = IAmmalgamPair(_pair);
        (tokenX, tokenY) = ammalgamPair.underlyingTokens();
    }

    function computeLXAndLYBorrowedLiquidity(
        address _pair,
        uint256 userBorrowedLiquidityAssets,
        Math.Rounding rounding
    ) internal view returns (uint256 LX, uint256 LY) {
        IAmmalgamPair pair = IAmmalgamPair(_pair);
        (uint256 reserveX, uint256 reserveY,) = pair.getReserves();
        uint256 activeLiquidityAssets = Math.sqrt(reserveX * reserveY);

        LX = Math.mulDiv(userBorrowedLiquidityAssets, reserveX, activeLiquidityAssets, rounding);
        LY = Math.mulDiv(userBorrowedLiquidityAssets, reserveY, activeLiquidityAssets, rounding);
    }

    function transferFromXAndY(
        address from,
        address to,
        IERC20 tokenX,
        IERC20 tokenY,
        uint256 transferX,
        uint256 transferY
    ) internal returns (bool transferred) {
        if (transferX > 0) {
            tokenX.safeTransferFrom(from, to, transferX);
            transferred = true;
        }
        if (transferY > 0) {
            tokenY.safeTransferFrom(from, to, transferY);
            transferred = true;
        }
    }
}
