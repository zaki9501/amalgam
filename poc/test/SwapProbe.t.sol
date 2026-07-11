// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
import {Test, console2} from "forge-std/Test.sol";

interface IFactory { function createPair(address,address) external returns (address); }
interface IPair {
  function mint(address) external returns (uint256);
  function swap(uint256,uint256,address,bytes calldata) external;
  function getReserves() external view returns (uint112,uint112,uint32);
  function underlyingTokens() external view returns (address,address);
}
contract M {
  mapping(address=>uint256) public balanceOf; uint256 public totalSupply;
  function mint(address t,uint256 a) external { totalSupply+=a; balanceOf[t]+=a; }
  function transfer(address t,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
}
contract SwapProbe is Test {
  function test_swap() public {
    vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
    M a=new M(); M b=new M();
    address p=IFactory(0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B).createPair(address(a),address(b));
    IPair pair=IPair(p);
    (address px,address py)=pair.underlyingTokens();
    M x=M(px); M y=M(py);
    uint256 S=1e24;
    x.mint(address(this),S*10); y.mint(address(this),S*10);
    x.transfer(p,S); y.transfer(p,S); pair.mint(address(this));
    (uint112 rx,uint112 ry,)=pair.getReserves();
    console2.log(rx,ry);
    for (uint256 pct=1; pct<=20; pct++) {
      uint256 yIn = uint256(ry)*pct/1000; // 0.1% .. 2%
      uint256 xOut = uint256(rx)*yIn/(uint256(ry)+yIn)*90/100;
      uint256 snap=vm.snapshotState();
      y.mint(address(this), yIn);
      y.transfer(p, yIn);
      try pair.swap(xOut,0,address(this),"") {
        console2.log("ok pct", pct, "yIn", yIn);
        vm.revertToState(snap);
        // commit one working size
        y.mint(address(this), yIn);
        y.transfer(p, yIn);
        pair.swap(xOut,0,address(this),"");
        return;
      } catch (bytes memory err) {
        console2.log("fail pct", pct);
        console2.logBytes(err);
        vm.revertToState(snap);
      }
    }
    revert("no swap worked");
  }
}
