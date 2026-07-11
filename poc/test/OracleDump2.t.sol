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
contract M {
  mapping(address=>uint256) public balanceOf; uint256 public totalSupply;
  function mint(address t,uint256 a) external { totalSupply+=a; balanceOf[t]+=a; }
  function transfer(address t,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
}
contract OracleDump2 is Test {
  address constant S = 0xAaC0fA3C48d70683650184A80313A998ca48d9fc;
  function _obs(address p) internal view returns (int16 lastTick, uint8 midIdx, uint8 longIdx, bool longInit, uint24 longCfg) {
    (bool ok, bytes memory data) = S.staticcall(abi.encodeWithSignature("getObservations(address)", p));
    require(ok && data.length > 200, "obs call");
    // ABI head: 8 static words then offsets to dynamic? NO - fixed arrays are inlined in Solidity ABI for memory returns of structs
    // Actually for public view returning struct with fixed arrays, encoding is sequential:
    // [bool][bool][uint8][uint8][int16][uint24][uint24][int56] then 51*int56, 9*int56, 51*uint32, 9*uint32
    // But each ABI word is 32 bytes!
    bool midInit;
    (midInit, longInit, midIdx, longIdx, lastTick,, longCfg,) =
      abi.decode(data, (bool, bool, uint8, uint8, int16, uint24, uint24, int56));
  }
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
    {
      (int16 lt, uint8 mi, uint8 li, bool linit, uint24 lcfg) = _obs(p);
      console2.log("post-mint lastTick"); console2.logInt(lt);
      console2.log("mid/long idx", mi, li);
      console2.log("longInit", linit);
      console2.log("longCfg", lcfg);
    }
    for (uint256 i; i<50; i++) {
      (uint112 rx,uint112 ry,)=pair.getReserves();
      uint256 yIn=uint256(ry)/1000;
      uint256 xOut=uint256(rx)*yIn/(uint256(ry)+yIn)*90/100;
      y.mint(address(this),yIn); y.transfer(p,yIn); pair.swap(xOut,0,address(this),"");
    }
    for (uint256 i; i<20; i++) {
      vm.warp(block.timestamp+8);
      pair.sync();
      (int16 lt, uint8 mi, uint8 li, bool linit,) = _obs(p);
      console2.log("sync", i+1);
      console2.log("lastTick"); console2.logInt(lt);
      console2.log("mid/long", mi, li);
      console2.log("longInit", linit);
    }
  }
}
