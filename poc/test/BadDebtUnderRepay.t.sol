// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IFactoryBadDebt {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IAmmalgamPairBadDebt {
    function mint(address to) external returns (uint256);
    function deposit(address to) external;
    function withdraw(address to) external;
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
    function totalAssetsAndShares(bool withInterest)
        external
        view
        returns (uint112[6] memory assets, uint112[6] memory shares);
}

interface ISatBadDebt {
    function getTickRange(address pair, uint256 rx, uint256 ry, bool includeLong)
        external
        view
        returns (int16, int16);
}

contract MockERC20BadDebt {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

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

/// @dev Hard-liq bad-debt branch: uncapped convertLtvToPremium lets liquidator under-repay
///      vs a MAX_PREMIUM (11111) cap, socializing extra loss to LPs.
contract BadDebtUnderRepayTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    address constant SAT_PROXY = 0xAaC0fA3C48d70683650184A80313A998ca48d9fc;

    uint256 constant DEPOSIT_Y = 2;
    uint256 constant BORROW_X = 4;
    uint256 constant HARD = 0;
    uint256 constant BIPS = 10_000;
    uint256 constant MAX_PREMIUM = 11_111;
    uint256 constant SEED = 1e24;
    bytes32 constant BURN_BAD_DEBT_SIG = keccak256("BurnBadDebt(address,uint256,uint256,uint256)");

    MockERC20BadDebt assetX;
    MockERC20BadDebt assetY;
    IAmmalgamPairBadDebt pair;
    address borrower;
    address liquidator;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));

        MockERC20BadDebt a = new MockERC20BadDebt("X", "X", 18);
        MockERC20BadDebt b = new MockERC20BadDebt("Y", "Y", 18);
        address p = IFactoryBadDebt(FACTORY).createPair(address(a), address(b));
        pair = IAmmalgamPairBadDebt(p);
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20BadDebt(px);
        assetY = MockERC20BadDebt(py);

        borrower = makeAddr("borrower");
        liquidator = makeAddr("liquidator");

        assetX.mint(address(this), SEED * 200);
        assetY.mint(address(this), SEED * 200);
        assetX.transfer(p, SEED);
        assetY.transfer(p, SEED);
        pair.mint(address(this));
        assertEq(pair.externalLiquidity(), 0);
    }

    function test_badDebt_underRepay_extraLpLoss() public {
        (uint112 rx0, uint112 ry0,) = pair.getReserves();
        // Small borrow vs pool so gradual ≤25%/8s moves dominate; fresh-pair long TWAP caps LTV ~37%.
        uint256 borrowX = uint256(rx0) / 200;
        uint256 collY = borrowX * 270 / 100;

        assetY.mint(borrower, collY);
        vm.startPrank(borrower);
        assetY.transfer(address(pair), collY);
        pair.deposit(borrower);
        pair.borrow(borrower, borrowX, 0, "");
        vm.stopPrank();

        uint256 debtX = _assets(BORROW_X, borrower);
        uint256 depY = _assets(DEPOSIT_Y, borrower);
        console2.log("open debtX", debtX);
        console2.log("open depY", depY);
        console2.log("open raw LTV bips", debtX * BIPS / depY);

        // Adverse for borrow-X / deposit-Y: push Y in, X out → Y cheaper in X.
        // Oracle lastTick crawls ≤ ~10–80 ticks/obs; keep each spot step small (fees + ≤25%/8s).
        _crawlOracleAdverseYCheaper(20, 400);

        (uint112 rx, uint112 ry,) = pair.getReserves();
        (int16 minT, int16 maxT) = ISatBadDebt(SAT_PROXY).getTickRange(address(pair), rx, ry, false);
        console2.log("short min tick");
        console2.logInt(minT);
        console2.log("short max tick");
        console2.logInt(maxT);

        debtX = _assets(BORROW_X, borrower);
        depY = _assets(DEPOSIT_Y, borrower);
        // Conservative TWAP LTV using maxTick (favors collateral Y = Y * sqrtP).
        // For net debt X: debt ~ X/sqrtP_min, coll ~ Y*sqrtP_max — use rough spot for logging.
        uint256 collValueX = depY * uint256(rx) / uint256(ry);
        uint256 spotLtv = debtX * BIPS / collValueX;
        uint256 prem = _premium(spotLtv);
        console2.log("spot coll value X", collValueX);
        console2.log("spot LTV bips", spotLtv);
        console2.log("spot premium", prem);

        // Binary search minimal repay that hard-liq accepts.
        uint256 minRepay = _minAcceptedRepay(depY, debtX);
        console2.log("min accepted repay X", minRepay);

        uint256 cappedRepay = collValueX * BIPS / MAX_PREMIUM;
        if (cappedRepay > debtX) cappedRepay = debtX;
        console2.log("capped-premium repay X", cappedRepay);

        assertGt(prem, MAX_PREMIUM, "need bad-debt premium regime");
        assertLt(minRepay, cappedRepay, "uncapped allows less repay than MAX_PREMIUM cap");

        uint256 snap = vm.snapshotState();
        (uint256 burnedLo, uint256 profitLo) = _doLiq(depY, minRepay);
        vm.revertToState(snap);
        (uint256 burnedHi, uint256 profitHi) = _doLiq(depY, cappedRepay);

        console2.log("burned debt under-repay", burnedLo);
        console2.log("burned debt capped", burnedHi);
        console2.log("liq profit under-repay", profitLo);
        console2.log("liq profit capped", profitHi);

        assertGt(burnedLo, burnedHi, "under-repay socializes more bad debt");
        assertGt(profitLo, profitHi, "liquidator extracts extra vs capped premium");
    }

    function _crawlOracleAdverseYCheaper(uint256 stepBipsOfReserve, uint256 maxSteps) internal {
        // Phase 1: move spot with small swaps (≤~0.2%/step), syncing every step so oracle crawls.
        // Phase 2: if spot is deep enough but oracle lags, warp+sync only.
        for (uint256 i; i < maxSteps; i++) {
            if (i < maxSteps * 2 / 3) {
                _stepYInXOut(stepBipsOfReserve);
            }
            vm.warp(block.timestamp + 8);
            pair.sync();

            if (i % 25 == 24) {
                (uint112 rx, uint112 ry,) = pair.getReserves();
                (int16 a, int16 b) = ISatBadDebt(SAT_PROXY).getTickRange(address(pair), rx, ry, false);
                uint256 debtX = _assets(BORROW_X, borrower);
                uint256 depY = _assets(DEPOSIT_Y, borrower);
                uint256 collX = depY * uint256(rx) / uint256(ry);
                uint256 spotLtv = collX == 0 ? type(uint256).max : debtX * BIPS / collX;
                console2.log("crawl", i + 1);
                console2.logInt(a);
                console2.logInt(b);
                console2.log("spotLtv", spotLtv);
                if (_canLiq(depY, debtX)) {
                    console2.log("full-repay hard liq accepted at step", i + 1);
                    return;
                }
            }
        }
        uint256 debtX = _assets(BORROW_X, borrower);
        uint256 depY = _assets(DEPOSIT_Y, borrower);
        if (!_canLiq(depY, debtX)) {
            _logLiqRevert(depY, debtX);
            revert("oracle crawl did not reach liquidatable state");
        }
    }

    function _stepYInXOut(uint256 targetMoveBips) internal {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        // targetMoveBips here is used as "tenths of a bip of reserve" style small input.
        // yIn ≈ ry * targetMoveBips / 10000 keeps quadratic fees happy (~0.2% at 20).
        uint256 yIn = uint256(ry) * targetMoveBips / BIPS;
        if (yIn == 0) yIn = 1;
        uint256 xOut = uint256(rx) * yIn / (uint256(ry) + yIn) * 90 / 100;
        if (xOut == 0) xOut = 1;

        address trader = address(uint160(0xBEEF0000 + (block.timestamp % 10000)));
        assetY.mint(trader, yIn);
        vm.startPrank(trader);
        assetY.transfer(address(pair), yIn);
        pair.swap(xOut, 0, trader, "");
        vm.stopPrank();
    }

    function _minAcceptedRepay(uint256 seizeY, uint256 debtX) internal returns (uint256 best) {
        uint256 lo = 1;
        uint256 hi = 0;
        for (uint256 pct = 1; pct <= 100; pct++) {
            uint256 probe = debtX * pct / 100;
            if (probe == 0) probe = 1;
            if (_canLiq(seizeY, probe)) {
                hi = probe;
                lo = pct == 1 ? 1 : debtX * (pct - 1) / 100 + 1;
                console2.log("first accepted repay pct", pct);
                break;
            }
        }
        if (hi == 0) {
            _logLiqRevert(seizeY, debtX);
            revert("no repay accepted");
        }
        best = hi;
        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;
            if (_canLiq(seizeY, mid)) {
                best = mid;
                if (mid == 0) break;
                hi = mid - 1;
            } else {
                lo = mid + 1;
            }
        }
    }

    function _canLiq(uint256 seizeY, uint256 repayX) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        _fund(repayX);
        vm.startPrank(liquidator);
        assetX.transfer(address(pair), repayX);
        try pair.liquidate(borrower, liquidator, 0, 0, seizeY, repayX, 0, HARD) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _logLiqRevert(uint256 seizeY, uint256 repayX) internal {
        uint256 snap = vm.snapshotState();
        _fund(repayX);
        vm.startPrank(liquidator);
        assetX.transfer(address(pair), repayX);
        try pair.liquidate(borrower, liquidator, 0, 0, seizeY, repayX, 0, HARD) {}
        catch (bytes memory reason) {
            console2.logBytes(reason);
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _doLiq(uint256 seizeY, uint256 repayX) internal returns (uint256 burned, uint256 profit) {
        _fund(repayX);
        uint256 yBefore = assetY.balanceOf(liquidator);
        vm.recordLogs();
        vm.startPrank(liquidator);
        assetX.transfer(address(pair), repayX);
        pair.liquidate(borrower, liquidator, 0, 0, seizeY, repayX, 0, HARD);
        // Withdraw seized DEPOSIT_Y to underlying for PnL.
        uint256 depShares = IERC20(pair.tokens(DEPOSIT_Y)).balanceOf(liquidator);
        if (depShares > 0) {
            IERC20(pair.tokens(DEPOSIT_Y)).transfer(address(pair), depShares);
            pair.withdraw(liquidator);
        }
        vm.stopPrank();
        uint256 yGained = assetY.balanceOf(liquidator) - yBefore;
        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 yValueX = yGained * uint256(rx) / uint256(ry);
        profit = yValueX > repayX ? yValueX - repayX : 0;
        burned = _burnedX();
    }

    function _burnedX() internal returns (uint256 burned) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == BURN_BAD_DEBT_SIG) {
                if (uint256(logs[i].topics[2]) == BORROW_X) {
                    (burned,) = abi.decode(logs[i].data, (uint256, uint256));
                }
            }
        }
    }

    function _fund(uint256 repayX) internal {
        uint256 bal = assetX.balanceOf(liquidator);
        if (bal < repayX) assetX.mint(liquidator, repayX - bal);
    }

    function _assets(uint256 tokenType, address user) internal view returns (uint256) {
        (uint112[6] memory assets, uint112[6] memory shares) = pair.totalAssetsAndShares(false);
        uint256 userShares = IERC20(pair.tokens(tokenType)).balanceOf(user);
        if (userShares == 0) return 0;
        return uint256(assets[tokenType]) * userShares / uint256(shares[tokenType]);
    }

    function _premium(uint256 ltvBips) internal pure returns (uint256) {
        if (ltvBips <= 6000) return 0;
        if (ltvBips < 7500) return 66_667 * ltvBips / BIPS - 40_000;
        return 7408 * ltvBips / BIPS + 4444;
    }
}
