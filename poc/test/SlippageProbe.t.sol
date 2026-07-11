// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
interface IAmmalgamPair {
    function deposit(address to) external;
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function externalLiquidity() external view returns (uint112);
}
interface IWETH { function deposit() external payable; }
contract SlippageProbe is Test {
    address constant PAIR = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    function test_probe() public {
        vm.createSelectFork("https://mainnet.gateway.tenderly.co");
        IAmmalgamPair pair = IAmmalgamPair(PAIR);
        console2.log("externalLiquidity", pair.externalLiquidity());
        (uint112 rx, uint112 ry,) = pair.getReserves();
        // try 89% borrow with 2.2x collateral
        uint256 borrowUsdc = uint256(rx) * 89 / 100;
        uint256 coll = (uint256(ry) * borrowUsdc / uint256(rx)) * 220 / 100;
        address a = makeAddr("a");
        vm.deal(a, coll);
        vm.startPrank(a);
        IWETH(WETH).deposit{value: coll}();
        IERC20(WETH).transfer(PAIR, coll);
        pair.deposit(a);
        try pair.borrow(a, borrowUsdc, 0, "") {
            console2.log("BORROW OK at 89% with 2.2x coll");
        } catch (bytes memory reason) {
            console2.log("BORROW REVERT");
            console2.logBytes(reason);
        }
        vm.stopPrank();
    }
}
