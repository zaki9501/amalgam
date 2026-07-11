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
interface ISat { function getTickRange(address,uint256,uint256,bool) external view returns (int16,int16); }
contract M {
  mapping(address=>uint256) public balanceOf; uint256 public totalSupply;
  function mint(address t,uint256 a) external { totalSupply+=a; balanceOf[t]+=a; }
  function transfer(address t,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
}
contract OracleCrawl is Test {
  address constant F=0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
  address constant S=0xAaC0fA3C48d70683650184A80313A998ca48d9fc;
  function test_crawl() public {
    vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
    M a=new M(); M b=new M();
    address p=IFactory(F).createPair(address(a),address(b));
    IPair pair=IPair(p);
    (address px,address py)=pair.underlyingTokens();
    M x=M(px); M y=M(py);
    uint256 SEED=1e24;
    x.mint(address(this),SEED*50); y.mint(address(this),SEED*50);
    x.transfer(p,SEED); y.transfer(p,SEED); pair.mint(address(this));

    // one big-ish adverse move via many tiny swaps in one block
    for (uint256 i; i<200; i++) {
      (uint112 rx,uint112 ry,)=pair.getReserves();
      uint256 yIn=uint256(ry)/1000;
      uint256 xOut=uint256(rx)*yIn/(uint256(ry)+yIn)*90/100;
      y.mint(address(this),yIn); y.transfer(p,yIn); pair.swap(xOut,0,address(this),"");
    }
    (uint112 rx1,uint112 ry1,)=pair.getReserves();
    console2.log("spot rx/ry after swaps", rx1, ry1);

    for (uint256 i; i<200; i++) {
      vm.warp(block.timestamp+8);
      pair.sync();
      if (i%20==19) {
        (int16 mn,int16 mx)=ISat(S).getTickRange(p,rx1,ry1,false);
        console2.log("after syncs", i+1);
        console2.logInt(mn); console2.logInt(mx);
        (int16 mnL,int16 mxL)=ISat(S).getTickRange(p,rx1,ry1,true);
        console2.log("with long");
        console2.logInt(mnL); console2.logInt(mxL);
      }
    }
  }
}
