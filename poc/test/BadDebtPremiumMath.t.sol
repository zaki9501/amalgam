// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";

contract BadDebtPremiumMathTest is Test {
    uint256 constant BIPS = 10_000;
    uint256 constant MAX_PREMIUM_IN_BIPS = 11_111;

    function test_badDebtPremiumCurve_exceedsCappedRepay() public pure {
        _check(10_000);
        _check(12_000);
        _check(15_000);
    }

    function test_logBadDebtPremiumCurve() public {
        _log(10_000);
        _log(12_000);
        _log(15_000);
    }

    function _check(uint256 ltvBips) internal pure {
        uint256 premium = _convertLtvToPremium(ltvBips);
        uint256 uncappedRepayRatio = BIPS * BIPS / premium;
        uint256 cappedRepayRatio = BIPS * BIPS / MAX_PREMIUM_IN_BIPS;

        assertGt(premium, MAX_PREMIUM_IN_BIPS, "premium should exceed bad-debt cap");
        assertLt(uncappedRepayRatio, cappedRepayRatio, "uncapped curve permits lower repay");
    }

    function _log(uint256 ltvBips) internal view {
        uint256 premium = _convertLtvToPremium(ltvBips);
        uint256 uncappedRepayRatio = BIPS * BIPS / premium;
        uint256 cappedRepayRatio = BIPS * BIPS / MAX_PREMIUM_IN_BIPS;

        console2.log("ltv bips", ltvBips);
        console2.log("uncapped max premium bips", premium);
        console2.log("min repay pct bips, uncapped", uncappedRepayRatio);
        console2.log("min repay pct bips, capped 11111", cappedRepayRatio);
        console2.log("extra extraction pct bips", cappedRepayRatio - uncappedRepayRatio);
    }

    function _convertLtvToPremium(uint256 ltvBips) internal pure returns (uint256 maxPremiumInBips) {
        if (ltvBips > 6000) {
            if (ltvBips < 7500) {
                maxPremiumInBips = 66_667 * ltvBips / BIPS - 40_000;
            } else {
                maxPremiumInBips = 7408 * ltvBips / BIPS + 4444;
            }
        }
    }
}
