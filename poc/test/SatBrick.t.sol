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
    function repay(address onBehalfOf) external returns (uint256, uint256);
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
    function validateOnUpdate(address validate, address update, bool alwaysUpdate) external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function underlyingTokens() external view returns (address, address);
}

interface ISat {
    function getTreeLeafDetails(address pairAddress, bool netDebtX, uint256 leaf)
        external
        view
        returns (
            uint128 satRelativeToL,
            uint128 satInLAssets,
            uint256 currentPenaltyInBorrowLSharesPerSatInQ72,
            uint128 totalSatInLAssets,
            uint16 highestSetLeaf,
            uint16[] memory tranches
        );
    function accountExistsInSaturation(address pairAddress, address accountAddress)
        external
        view
        returns (bool exists);
    function getTickRange(address pair, uint256 rx, uint256 ry, bool includeLong)
        external
        view
        returns (int16, int16);
}

contract MockERC20 {
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

/// @notice Dispute PoC for claim: LP burn drops ALA so later liquidate/sat update
///         reverts MaxTrancheOverSaturated (0x4ea97c63), bricking liquidations.
///
/// Observed on fresh mainnet-factory pairs (wide TWAP ticks ~-178..179):
/// - Borrower sat entries land at very high leaves (e.g. 2420).
/// - `burn()` does NOT reshape the sat tree (highestSetLeaf unchanged).
/// - But DEPOSIT_L transfer-into-pair runs `validateOnUpdate(..., alwaysUpdate=true)`
///   with staged-burn-reduced ALA, which reverts MaxTrancheOverSaturated BEFORE a
///   burn large enough to brick subsequent sat updates can complete.
/// - Max successful burn (~10% here) leaves sat update + repay healthy.
/// - 50%+ burns are blocked at the guard; liquidate does not revert MaxTranche.
contract SatBrickTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    address constant SAT_PROXY = 0xAaC0fA3C48d70683650184A80313A998ca48d9fc;
    bytes4 constant MAX_TRANCHE_OVER_SAT = 0x4ea97c63;
    uint256 constant HARD = 0;
    uint256 constant SEED = 1e24;

    IAmmalgamPair pair;
    ISat sat;
    MockERC20 assetX;
    MockERC20 assetY;
    uint256 seedLp;
    address borrower;
    address lpWhale;
    address liquidator;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        sat = ISat(SAT_PROXY);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        address p = IFactory(FACTORY).createPair(address(a), address(b));
        pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20(px);
        assetY = MockERC20(py);

        assetX.mint(address(this), SEED * 2000);
        assetY.mint(address(this), SEED * 2000);
        assetX.transfer(p, SEED);
        assetY.transfer(p, SEED);
        seedLp = pair.mint(address(this));

        borrower = makeAddr("borrower");
        lpWhale = makeAddr("lpWhale");
        liquidator = makeAddr("liquidator");

        (uint112 rx, uint112 ry,) = pair.getReserves();
        (int16 mn, int16 mx) = sat.getTickRange(p, rx, ry, true);
        console2.log("pair", p);
        console2.log("ticks");
        console2.logInt(mn);
        console2.logInt(mx);
    }

    function _highestLeaf() internal view returns (uint16) {
        (,,,, uint16 hx,) = sat.getTreeLeafDetails(address(pair), true, 0);
        (,,,, uint16 hy,) = sat.getTreeLeafDetails(address(pair), false, 0);
        return hx > hy ? hx : hy;
    }

    function _openBorrower(uint256 borrowBps, uint256 collMultBps) internal returns (uint256 borrowAmt) {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        borrowAmt = uint256(rx) * borrowBps / 10_000;
        uint256 collAmt = (uint256(ry) * borrowAmt / uint256(rx)) * collMultBps / 10_000;
        assetY.mint(borrower, collAmt);
        vm.startPrank(borrower);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(borrower);
        pair.borrow(borrower, borrowAmt, 0, "");
        vm.stopPrank();
        assertTrue(sat.accountExistsInSaturation(address(pair), borrower), "borrower missing from sat");
        console2.log("borrowAmt", borrowAmt);
        console2.log("highestLeaf", _highestLeaf());
    }

    function _canBurn(address who, uint256 shares) internal returns (bool ok, bytes memory err) {
        if (shares == 0) return (true, "");
        uint256 snap = vm.snapshotState();
        vm.startPrank(who);
        try IERC20(pair.tokens(0)).transfer(address(pair), shares) {
            try pair.burn(who) {
                ok = true;
            } catch (bytes memory r) {
                err = r;
            }
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _burnCommit(address who, uint256 shares) internal {
        vm.startPrank(who);
        IERC20(pair.tokens(0)).transfer(address(pair), shares);
        pair.burn(who);
        vm.stopPrank();
    }

    function _isMaxTranche(bytes memory err) internal pure returns (bool) {
        return err.length >= 4 && bytes4(err) == MAX_TRANCHE_OVER_SAT;
    }

    function _maxBurnable(address who, uint256 bal) internal returns (uint256 best) {
        uint256 lo;
        uint256 hi = bal;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _canBurn(who, mid);
            if (ok) {
                best = mid;
                lo = mid;
            } else {
                hi = mid;
            }
        }
        (bool hiOk,) = _canBurn(who, hi);
        if (hiOk) best = hi;
    }

    function _tryValidate(address who) internal returns (bool ok, bytes memory err) {
        uint256 snap = vm.snapshotState();
        try pair.validateOnUpdate(who, who, true) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.revertToState(snap);
    }

    function _tryRepay() internal returns (bool ok, bytes memory err) {
        uint256 debtShares = IERC20(pair.tokens(4)).balanceOf(borrower);
        uint256 pay = debtShares + debtShares / 5 + 1e18;
        uint256 snap = vm.snapshotState();
        assetX.mint(borrower, pay);
        vm.startPrank(borrower);
        assetX.transfer(address(pair), pay);
        try pair.repay(borrower) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _tryLiquidate(uint256 repayX, uint256 seizeY) internal returns (bool ok, bytes memory err) {
        uint256 snap = vm.snapshotState();
        assetX.mint(liquidator, repayX + 1);
        vm.startPrank(liquidator);
        assetX.transfer(address(pair), repayX);
        try pair.liquidate(borrower, liquidator, 0, 0, seizeY, repayX, 0, HARD) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// @dev CLAIM PATH: large LP burn then liquidate/sat-update MaxTranche.
    function test_DISPUTED_largeBurnDoesNotBrickLiquidationSatUpdate() public {
        uint256 borrowAmt = _openBorrower(2000, 50_000); // 20% X, 5x Y collateral
        uint16 leaf0 = _highestLeaf();
        assertGt(leaf0, 0, "expected sat tree entries");

        IERC20(pair.tokens(0)).transfer(lpWhale, seedLp);

        // Claim step: "large fraction" burn
        (bool burn50Ok, bytes memory burn50Err) = _canBurn(lpWhale, seedLp / 2);
        console2.log("50% burn ok", burn50Ok);
        assertFalse(burn50Ok, "large burn should be blocked by sat guard");
        assertTrue(_isMaxTranche(burn50Err), "large burn blocked with MaxTrancheOverSaturated");

        // Largest burn that can actually complete
        uint256 maxBurn = _maxBurnable(lpWhale, seedLp);
        console2.log("maxBurnable bps", maxBurn * 10_000 / seedLp);
        assertGt(maxBurn, 0, "some LP should still be burnable");
        assertLt(maxBurn * 100 / seedLp, 50, "max burnable is well below claimed large fraction");

        _burnCommit(lpWhale, maxBurn);
        assertEq(_highestLeaf(), leaf0, "successful burn does not reshape sat tree");

        // Post-burn sat update (same check liquidate finalize uses) still works
        (bool valOk, bytes memory valErr) = _tryValidate(borrower);
        console2.log("sat update after max burn ok", valOk);
        assertTrue(valOk, "max successful burn must not brick Saturation.update");
        valErr; // silence

        // Further burn of even 1 wei hits the guard (boundary)
        (bool oneWeiOk, bytes memory oneWeiErr) = _canBurn(lpWhale, 1);
        assertFalse(oneWeiOk, "beyond-max burn blocked");
        assertTrue(_isMaxTranche(oneWeiErr), "beyond-max burn is MaxTrancheOverSaturated");

        // Unstick path: borrower can repay
        (bool repayOk,) = _tryRepay();
        assertTrue(repayOk, "borrower repay still works after max burn");

        // Liquidate does not fail with MaxTranche (may fail for other reasons if not liquidatable)
        (bool liqOk, bytes memory liqErr) = _tryLiquidate(borrowAmt / 4, borrowAmt / 20);
        console2.log("liquidate ok", liqOk);
        if (!liqOk) {
            console2.logBytes(abi.encodePacked(bytes4(liqErr)));
            assertFalse(_isMaxTranche(liqErr), "liquidate must not revert MaxTrancheOverSaturated");
        }

        console2.log("DISPUTED: burn guard prevents post-burn sat/liquidation brick");
        console2.log("NOTE: LPs may be partially exit-capped while high-leaf borrows exist; repay unsticks");
    }

    /// @dev Partial burns below the guard keep the pair healthy.
    function test_partialBurnsRemainHealthy() public {
        _openBorrower(2000, 50_000);
        IERC20(pair.tokens(0)).transfer(lpWhale, seedLp);
        uint256 maxBurn = _maxBurnable(lpWhale, seedLp);
        uint256 safe = maxBurn / 2;
        assertGt(safe, 0, "need burnable room");

        _burnCommit(lpWhale, safe);
        (bool valOk,) = _tryValidate(borrower);
        (bool repayOk,) = _tryRepay();
        assertTrue(valOk, "sat update ok after partial burn");
        assertTrue(repayOk, "repay ok after partial burn");
        console2.log("partial burn of half maxBurnable: healthy");
    }

    /// @dev After max burn, modest swaps that still succeed do not brick sat update.
    function test_maxBurnPlusSwapDoesNotBrickSatUpdate() public {
        _openBorrower(2000, 50_000);
        IERC20(pair.tokens(0)).transfer(lpWhale, seedLp);
        _burnCommit(lpWhale, _maxBurnable(lpWhale, seedLp));

        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 amountOut = uint256(rx) / 100; // 1%
        uint256 amountIn = (uint256(ry) * amountOut * 1000) / ((uint256(rx) - amountOut) * 997) + 1;
        assetY.mint(address(this), amountIn);
        assetY.transfer(address(pair), amountIn);
        pair.swap(amountOut, 0, address(this), "");

        (bool valOk,) = _tryValidate(borrower);
        (bool repayOk,) = _tryRepay();
        assertTrue(valOk, "sat update ok after max burn + 1% swap");
        assertTrue(repayOk, "repay ok after max burn + 1% swap");
        console2.log("DISPUTED variant: burn+swap does not brick sat update");
    }
}
