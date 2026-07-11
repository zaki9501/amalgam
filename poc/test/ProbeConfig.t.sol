// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
import {Test, console2} from "forge-std/Test.sol";
interface IFactory { function saturationAndGeometricTWAPState() external view returns (address); function allPairs(uint256) external view returns (address); }
interface ISat { function midTermIntervalConfig() external view returns (uint24); function longTermIntervalConfig() external view returns (uint32); }
contract ProbeConfig is Test {
  function test_probe() public {
    vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
    address f = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    address s = IFactory(f).saturationAndGeometricTWAPState();
    console2.log("sat", s);
    console2.log("mid", ISat(s).midTermIntervalConfig());
    console2.log("long", ISat(s).longTermIntervalConfig());
    console2.log("pair0", IFactory(f).allPairs(0));
  }
}
