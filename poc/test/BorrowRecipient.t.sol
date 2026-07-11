// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IAmmalgamPair {
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external;
    function deposit(address to) external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IWETH {
    function deposit() external payable;
}

contract BorrowRecipientTest is Test {
    address constant PAIR = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://rpc.mevblocker.io")));
    }

    function test_debtOnSender_assetsOnTo() public {
        IAmmalgamPair pair = IAmmalgamPair(PAIR);
        address attacker = makeAddr("attacker");
        address sink = makeAddr("sink");

        vm.deal(attacker, 50 ether);
        vm.startPrank(attacker);
        IWETH(WETH).deposit{value: 50 ether}();
        IERC20(WETH).transfer(PAIR, 50 ether);
        pair.deposit(attacker);

        (uint112 reserveX,,) = pair.getReserves();
        uint256 borrowAmount = uint256(reserveX) / 200;

        address borrowX = pair.tokens(4);
        uint256 sinkUsdcBefore = IERC20(USDC).balanceOf(sink);

        pair.borrow(sink, borrowAmount, 0, "");
        vm.stopPrank();

        console2.log("attacker BORROW_X", IERC20(borrowX).balanceOf(attacker));
        console2.log("sink BORROW_X", IERC20(borrowX).balanceOf(sink));
        console2.log("sink USDC gained", IERC20(USDC).balanceOf(sink) - sinkUsdcBefore);
        console2.log("attacker USDC", IERC20(USDC).balanceOf(attacker));

        assertGt(IERC20(borrowX).balanceOf(attacker), 0, "debt on sender");
        assertEq(IERC20(borrowX).balanceOf(sink), 0, "no debt on sink");
        assertEq(IERC20(USDC).balanceOf(sink) - sinkUsdcBefore, borrowAmount, "assets to sink");
    }
}
