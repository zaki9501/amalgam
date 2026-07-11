// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
import {Test, console2} from "forge-std/Test.sol";
interface IFactory { function createPair(address,address) external returns (address); }
interface IPair {
  function mint(address) external returns (uint256);
  function swap(uint256,uint256,address,bytes calldata) external;
  function sync() external;
  function getReserves() external view returns (uint112,uint112,uint32);
  function underlyingTokens() external view returns (address,address);
}
interface ISat {
  function getTickRange(address,uint256,uint256,bool) external view returns (int16,int16);
  function getObservedMidTermTick() external view returns (int16);
}
contract M {
  mapping(address=>uint256) public balanceOf; uint256 public totalSupply;
  function mint(address t,uint256 a) external { totalSupply+=a; balanceOf[t]+=a; }
  function transfer(address t,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
}
contract OracleDump is Test {
  function test_dump() public {
    vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
    M a=new M(); M b=new M();
    address p=IFactory(0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B).createPair(address(a),address(b));
    IPair pair=IPair(p);
    (address px,address py)=pair.underlyingTokens();
    M x=M(px); M y=M(py);
    uint256 SEED=1e24;
    x.mint(address(this),SEED*50); y.mint(address(this),SEED*50);
    x.transfer(p,SEED); y.transfer(p,SEED); pair.mint(address(this));
    for (uint256 i; i<200; i++) {
      (uint112 rx,uint112 ry,)=pair.getReserves();
      uint256 yIn=uint256(ry)/1000;
      uint256 xOut=uint256(rx)*yIn/(uint256(ry)+yIn)*90/100;
      y.mint(address(this),yIn); y.transfer(p,yIn); pair.swap(xOut,0,address(this),"");
    }
    (uint112 rx0,uint112 ry0,)=pair.getReserves();
    console2.log("reserves after dump", rx0, ry0);
    address S=0xAaC0fA3C48d70683650184A80313A998ca48d9fc;
    for (uint256 i; i<100; i++) {
      vm.warp(block.timestamp+8);
      pair.sync();
      if (i%10==9) {
        (uint112 rx,uint112 ry,)=pair.getReserves();
        (int16 mn,int16 mx)=ISat(S).getTickRange(p,rx,ry,false);
        (int16 mnL,int16 mxL)=ISat(S).getTickRange(p,rx,ry,true);
        console2.log("i", i+1);
        console2.log("short"); console2.logInt(mn); console2.logInt(mx);
        console2.log("long"); console2.logInt(mnL); console2.logInt(mxL);
      }
    }
  }
}
