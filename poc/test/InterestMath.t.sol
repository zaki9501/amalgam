// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";

contract InterestMathTest is Test {
    function test_nearCap_wrapShrinksDebt() public {
        uint256 U = type(uint112).max;
        // Near-cap balances: room for only 100 units of interest before cap
        uint256 borrowL = U - 100;
        uint256 depL = U - 100;
        uint256 capped = U - depL; // 100
        uint256 magnified = 5 * capped; // 500

        uint112 truncated;
        unchecked {
            truncated = uint112(borrowL + magnified);
        }

        console2.log("borrow before", borrowL);
        console2.log("magnified interest", magnified);
        console2.log("after trunc", uint256(truncated));
        assertLt(uint256(truncated), borrowL, "debt shrinks via wrap");
        console2.log("CONFIRMED: near-cap + mag wraps BORROW_L down");
    }

    function test_realisticPool_cannotHitCap() public {
        // Even a absurdly large 18-dec pool: 1e9 tokens each side
        uint256 reserve = 1e9 * 1e18;
        uint256 activeL = reserve; // ~sqrt(r*r)=r for 1:1
        console2.log("activeL huge pool", activeL);
        console2.log("uint112 max", type(uint112).max);
        assertLt(activeL * 1000, type(uint112).max, "even 1000x that pool << uint112");
        console2.log("PRACTICAL: uint112 interest cap unreachable for normal ERC20 pools");
    }
}
