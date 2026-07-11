// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IFactorySatBrickBurn {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IAmmalgamPairSatBrickBurn {
    function mint(address to) external returns (uint256);
    function burn(address to) external returns (uint256, uint256);
    function deposit(address to) external;
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;
    function repay(address onBehalfOf) external returns (uint256, uint256);
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
    function validateOnUpdate(address validate, address update, bool alwaysUpdate) external;
    function sync() external;
    function swap(uint256 amountXOut, uint256 amountYOut, address to, bytes calldata data) external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function underlyingTokens() external view returns (address, address);
    function totalAssetsAndShares(bool withInterest)
        external
        view
        returns (uint112[6] memory allAssets, uint112[6] memory allShares);
}

interface ISaturationStateSatBrickBurn {
    function getTreeLeafDetails(address pairAddress, bool netDebtX, uint256 leaf)
        external
        view
        returns (
            SaturationPair memory saturation,
            uint256 currentPenaltyInBorrowLSharesPerSatInQ72,
            uint128 totalSatInLAssets,
            uint16 highestSetLeaf,
            uint16[] memory tranches
        );
    function accountExistsInSaturation(address pairAddress, address accountAddress) external view returns (bool exists);
}

struct SaturationPair {
    uint128 satRelativeToL;
    uint128 satInLAssets;
}

contract MockERC20SatBrickBurn {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Fork PoC: LP burn shrinks active liquidity without reshaping saturation tranches.
contract SatBrickBurnTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    address constant SAT_PROXY = 0xAaC0fA3C48d70683650184A80313A998ca48d9fc;
    bytes4 constant MAX_TRANCHE_OVER_SAT = 0x4ea97c63;

    uint256 constant DEPOSIT_L = 0;
    uint256 constant DEPOSIT_Y = 2;
    uint256 constant BORROW_X = 4;
    uint256 constant HARD = 0;
    uint256 constant SEED = 1e24;

    IAmmalgamPairSatBrickBurn pair;
    ISaturationStateSatBrickBurn sat;
    MockERC20SatBrickBurn assetX;
    MockERC20SatBrickBurn assetY;
    address borrower = makeAddr("borrower");
    address whale = makeAddr("whale");
    address secondLp = makeAddr("secondLp");
    address liquidator = makeAddr("liquidator");
    uint256 seedLpShares;
    uint256 borrowerDebtAssets;
    uint256 borrowerCollateralAssets;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        sat = ISaturationStateSatBrickBurn(SAT_PROXY);

        MockERC20SatBrickBurn tokenA = new MockERC20SatBrickBurn("Mock X", "MX", 18);
        MockERC20SatBrickBurn tokenB = new MockERC20SatBrickBurn("Mock Y", "MY", 18);
        pair = IAmmalgamPairSatBrickBurn(IFactorySatBrickBurn(FACTORY).createPair(address(tokenA), address(tokenB)));
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20SatBrickBurn(px);
        assetY = MockERC20SatBrickBurn(py);

        assetX.mint(address(this), SEED * 1_000);
        assetY.mint(address(this), SEED * 1_000);
        assetX.transfer(address(pair), SEED);
        assetY.transfer(address(pair), SEED);
        seedLpShares = pair.mint(address(this));

        console2.log("fresh pair", address(pair));
        console2.log("seed LP shares", seedLpShares);
    }

    function test_DISPUTED_publicBurnGuardPreventsMaxTrancheBrick() public {
        _openHighLeafBorrower();

        uint16 highestBefore = _highestLeaf();
        uint256 alaBefore = _activeLiquidityAssets();
        console2.log("highest leaf before burn", highestBefore);
        console2.log("ALA before burn", alaBefore);
        assertGt(highestBefore, 3, "borrower should occupy a nontrivial leaf");

        _fundSecondLp();
        IERC20(pair.tokens(DEPOSIT_L)).transfer(whale, seedLpShares * 90 / 100);

        uint256 attemptedBurnShares = IERC20(pair.tokens(DEPOSIT_L)).balanceOf(whale);
        (bool attemptedOk, bytes memory attemptedErr) = _tryBurnLp(whale, attemptedBurnShares);
        console2.log("attempted large burn ok", attemptedOk);
        if (!attemptedOk) console2.logBytes4(bytes4(attemptedErr));
        assertFalse(attemptedOk, "unsafe large LP burn is blocked before burn()");
        assertTrue(_isMaxTranche(attemptedErr), "large burn transfer is guarded by MaxTrancheOverSaturated");

        uint256 burnShares = _maxBurnable(whale, attemptedBurnShares);
        console2.log("attempted whale burn shares", attemptedBurnShares);
        console2.log("max public burn shares", burnShares);
        assertGt(burnShares, 0, "no public LP burn could pass validation");

        (uint256 whaleOutX, uint256 whaleOutY) = _burnLpCommit(whale, burnShares);
        uint256 alaAfterWhaleBurn = _activeLiquidityAssets();
        uint16 highestAfterWhaleBurn = _highestLeaf();
        console2.log("whale burn out X", whaleOutX);
        console2.log("whale burn out Y", whaleOutY);
        console2.log("ALA after whale burn", alaAfterWhaleBurn);
        console2.log("highest leaf after burn", highestAfterWhaleBurn);

        assertLt(alaAfterWhaleBurn, alaBefore, "LP burn shrinks ALA");
        assertEq(highestAfterWhaleBurn, highestBefore, "burn did not reshape saturation tree");

        (bool updateOk, bytes memory updateErr) = _tryValidateBorrower();
        console2.log("validateOnUpdate(pair, borrower) after burn ok", updateOk);
        if (!updateOk) console2.logBytes4(bytes4(updateErr));
        assertTrue(updateOk, "largest successful burn leaves borrower saturation update healthy");

        uint256 secondLpShares = IERC20(pair.tokens(DEPOSIT_L)).balanceOf(secondLp);
        assertGt(secondLpShares, 0, "second LP setup failed");
        (bool secondBurnOk, bytes memory secondBurnErr) = _tryBurnLp(secondLp, secondLpShares / 2);
        console2.log("second LP post-brick burn ok", secondBurnOk);
        if (!secondBurnOk) console2.logBytes4(bytes4(secondBurnErr));
        assertFalse(secondBurnOk, "after max burn, further LP exit is capped by the same guard");
        assertTrue(_isMaxTranche(secondBurnErr), "second LP burn is blocked by MaxTrancheOverSaturated");

        (bool liquidateOk, bytes memory liquidateErr) = _tryHardLiquidate();
        console2.log("liquidate after max burn ok", liquidateOk);
        if (!liquidateOk) console2.logBytes4(bytes4(liquidateErr));
        if (!liquidateOk) assertFalse(_isMaxTranche(liquidateErr), "liquidation was not bricked by max tranche");

        (bool mintOk,) = _tryMintRestore(alaBefore - alaAfterWhaleBurn + 1e18);
        console2.log("mint restore unbricks", mintOk);

        (bool repayOk, bytes memory repayErr) = _tryBorrowerRepay();
        console2.log("top borrower repay unbricks", repayOk);
        if (!repayOk) console2.logBytes4(bytes4(repayErr));
        assertTrue(repayOk, "borrower repayment should clear/update its own sat entry");
        assertFalse(sat.accountExistsInSaturation(address(pair), borrower), "repay should remove borrower from sat tree");

        updateErr;
        console2.log("DISPUTED: public burn staging guard prevents MaxTranche brick");
    }

    function _openHighLeafBorrower() internal {
        _openBorrower(2000, 5);
    }

    function _openBorrower(uint256 borrowBps, uint256 collateralMultiple) internal {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        borrowerDebtAssets = uint256(rx) * borrowBps / 10_000;
        borrowerCollateralAssets = (uint256(ry) * borrowerDebtAssets / uint256(rx)) * collateralMultiple;

        assetY.mint(borrower, borrowerCollateralAssets);
        vm.startPrank(borrower);
        assetY.transfer(address(pair), borrowerCollateralAssets);
        pair.deposit(borrower);
        pair.borrow(borrower, borrowerDebtAssets, 0, "");
        vm.stopPrank();

        assertTrue(sat.accountExistsInSaturation(address(pair), borrower), "borrower missing from saturation tree");
        console2.log("borrower debt assets", borrowerDebtAssets);
        console2.log("borrower collateral assets", borrowerCollateralAssets);
        console2.log("borrower debt shares", IERC20(pair.tokens(BORROW_X)).balanceOf(borrower));
        console2.log("borrower deposit Y shares", IERC20(pair.tokens(DEPOSIT_Y)).balanceOf(borrower));
    }

    function _fundSecondLp() internal {
        uint256 lpSeed = SEED / 10;
        assetX.mint(secondLp, lpSeed);
        assetY.mint(secondLp, lpSeed);

        vm.startPrank(secondLp);
        assetX.transfer(address(pair), lpSeed);
        assetY.transfer(address(pair), lpSeed);
        uint256 minted = pair.mint(secondLp);
        vm.stopPrank();

        console2.log("second LP shares", minted);
    }

    function _burnLpCommit(address who, uint256 shares) internal returns (uint256 amountX, uint256 amountY) {
        vm.startPrank(who);
        IERC20(pair.tokens(DEPOSIT_L)).transfer(address(pair), shares);
        (amountX, amountY) = pair.burn(who);
        vm.stopPrank();
    }

    function _maxBurnable(address who, uint256 high) internal returns (uint256 best) {
        uint256 lo;
        uint256 hi = high + 1;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _tryBurnLp(who, mid);
            if (ok) {
                best = mid;
                lo = mid;
            } else {
                hi = mid;
            }
        }
    }

    function _tryBurnLp(address who, uint256 shares) internal returns (bool ok, bytes memory err) {
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(who);
        try IERC20(pair.tokens(DEPOSIT_L)).transfer(address(pair), shares) {
            try pair.burn(who) {
                ok = true;
            } catch (bytes memory r) {
                err = r;
            }
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    function _tryValidateBorrower() internal returns (bool ok, bytes memory err) {
        uint256 snapshot = vm.snapshotState();
        try pair.validateOnUpdate(address(pair), borrower, true) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.revertToState(snapshot);
    }

    function _tryHardLiquidate() internal returns (bool ok, bytes memory err) {
        uint256 snapshot = vm.snapshotState();
        uint256 repayX = borrowerDebtAssets / 10;
        uint256 seizeY = borrowerCollateralAssets / 10;
        assetX.mint(liquidator, repayX);
        vm.startPrank(liquidator);
        assetX.transfer(address(pair), repayX);
        try pair.liquidate(borrower, liquidator, 0, 0, seizeY, repayX, 0, HARD) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    function _tryMintRestore(uint256 amountEach) internal returns (bool ok, bytes memory err) {
        uint256 snapshot = vm.snapshotState();
        address restorer = makeAddr("restorer");
        assetX.mint(restorer, amountEach);
        assetY.mint(restorer, amountEach);
        vm.startPrank(restorer);
        assetX.transfer(address(pair), amountEach);
        assetY.transfer(address(pair), amountEach);
        try pair.mint(restorer) {
            (bool updateOk,) = _tryValidateBorrower();
            ok = updateOk;
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    function _tryBorrowerRepay() internal returns (bool ok, bytes memory err) {
        uint256 repayX = borrowerDebtAssets + borrowerDebtAssets / 10 + 1e18;
        assetX.mint(borrower, repayX);
        vm.startPrank(borrower);
        assetX.transfer(address(pair), repayX);
        try pair.repay(borrower) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
    }

    function _highestLeaf() internal view returns (uint16) {
        (,,, uint16 highestX,) = sat.getTreeLeafDetails(address(pair), true, 0);
        (,,, uint16 highestY,) = sat.getTreeLeafDetails(address(pair), false, 0);
        return highestX > highestY ? highestX : highestY;
    }

    function _activeLiquidityAssets() internal view returns (uint256) {
        (uint112[6] memory assets,) = pair.totalAssetsAndShares(true);
        return uint256(assets[DEPOSIT_L]) - uint256(assets[3]);
    }

    function _isMaxTranche(bytes memory err) internal pure returns (bool) {
        return err.length >= 4 && bytes4(err) == MAX_TRANCHE_OVER_SAT;
    }
}
