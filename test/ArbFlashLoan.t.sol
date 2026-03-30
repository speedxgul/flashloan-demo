// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 5c: Testing the full arbitrage
// ─────────────────────────────────────────────────────────────────────────────

import "forge-std/Test.sol";
import "../src/ArbFlashLoan.sol";
import "../src/MockDEX.sol";
import "../src/MockVault.sol";

contract ArbFlashLoanTest is Test {

    address public owner = makeAddr("owner");

    MockVault    public vault;
    MockERC20    public usdc;
    MockERC20    public weth;
    MockDEX      public dexA;   // 1 WETH = 2000 USDC
    MockDEX      public dexB;   // 1 WETH = 2020 USDC
    ArbFlashLoan public arb;

    function setUp() public {
        vault = new MockVault();
        usdc  = new MockERC20("Mock USDC");
        weth  = new MockERC20("Mock WETH");

        // DEX A: cheap  (2000 USDC per WETH)
        dexA = new MockDEX(address(weth), address(usdc), 2000_000000, "DEX A");

        // DEX B: pricey (2020 USDC per WETH)
        dexB = new MockDEX(address(weth), address(usdc), 2020_000000, "DEX B");

        // Deploy arbitrage contract
        vm.prank(owner);
        arb = new ArbFlashLoan(
            address(vault),
            address(dexA),
            address(dexB),
            address(weth),
            address(usdc)
        );

        // Seed liquidity
        // Vault gets USDC to lend out
        usdc.mint(address(vault), 1_000_000e6);      // 1M USDC

        // DEX A gets WETH to sell (it sells WETH for USDC)
        weth.mint(address(dexA), 1_000e18);          // 1000 WETH

        // DEX B gets USDC to pay out (it buys WETH with USDC)
        usdc.mint(address(dexB), 1_000_000e6);       // 1M USDC
    }

    // ─── Test 1: Arb makes correct profit ─────────────────────────────────────

    /// @notice Core test: borrow 2000 USDC, buy 1 WETH at $2000, sell at $2020 → $20 profit
    function test_arbProfit() public {
        uint256 usdcBorrow = 2000e6; // borrow 2000 USDC
        uint256 minProfit  = 19e6;   // expect at least 19 USDC profit

        uint256 ownerBefore = usdc.balanceOf(owner);

        vm.prank(owner);
        arb.execute(usdcBorrow, minProfit);

        uint256 ownerAfter = usdc.balanceOf(owner);
        uint256 profit = ownerAfter - ownerBefore;

        // Borrowed 2000, sold 1 WETH for 2020 → profit = 20 USDC
        assertEq(profit, 20e6, "unexpected profit amount");

        // Vault must be fully repaid
        // It started with 1M and lent 2000 — must be back to 1M
        assertEq(usdc.balanceOf(address(vault)), 1_000_000e6, "vault not repaid");

        // Arb contract must hold nothing (all profit sent to owner)
        assertEq(usdc.balanceOf(address(arb)), 0, "arb contract holding funds");
    }

    // ─── Test 2: Profit scales with loan size ─────────────────────────────────

    /// @notice Borrow 10x more → profit is 10x more. Linear relationship.
    function test_largerLoanMoreProfit() public {
        uint256 usdcBorrow = 20_000e6; // borrow 20,000 USDC → buy 10 WETH

        vm.prank(owner);
        arb.execute(usdcBorrow, 0);

        // 10 WETH * $20 gap = $200 profit
        assertEq(usdc.balanceOf(owner), 200e6, "unexpected profit");
    }

    // ─── Test 3: minProfit acts as a kill switch ───────────────────────────────

    /// @notice If minProfit is set too high, the arb correctly reverts.
    ///
    ///         In a real bot, you set minProfit = gas cost + buffer.
    ///         If the market moved and profit is less than gas, you abort.
    ///
    function test_minProfitKillSwitch() public {
        uint256 usdcBorrow = 2000e6;
        uint256 minProfit  = 100e6; // demand $100 profit, but gap only gives $20

        vm.prank(owner);
        vm.expectRevert("Arb: profit below minimum");
        arb.execute(usdcBorrow, minProfit);
    }

    // ─── Test 4: No price gap = no arb ────────────────────────────────────────

    /// @notice If both DEXes have the same price, there's no profit → reverts.
    ///
    ///         This is the normal state of an efficient market.
    ///         Arb bots are what KEEP markets efficient — they profit only
    ///         when prices diverge, and their trades push prices back together.
    ///
    function test_noPriceGapReverts() public {
        // Deploy a DEX B with the SAME price as DEX A (2000 USDC)
        MockDEX equalDexB = new MockDEX(address(weth), address(usdc), 2000_000000, "Equal DEX B");
        usdc.mint(address(equalDexB), 1_000_000e6);

        // Deploy arb contract pointing at equal-price DEXes
        vm.prank(owner);
        ArbFlashLoan noGapArb = new ArbFlashLoan(
            address(vault),
            address(dexA),
            address(equalDexB),
            address(weth),
            address(usdc)
        );

        vm.prank(owner);
        vm.expectRevert("Arb: no profit");
        noGapArb.execute(2000e6, 0);
    }

    // ─── Test 5: End-to-end with zero of your own capital ─────────────────────

    /// @notice Prove the owner starts with $0 and ends with profit.
    ///         This is the core flash loan promise: no capital required.
    function test_zeroCapitalRequired() public {
        // Owner has no USDC at all
        assertEq(usdc.balanceOf(owner), 0, "owner should start with nothing");

        // Execute arb with zero personal capital
        vm.prank(owner);
        arb.execute(2000e6, 0);

        // Owner now has profit despite starting with nothing
        assertGt(usdc.balanceOf(owner), 0, "owner should have profit");

        console.log("Profit earned with $0 starting capital:", usdc.balanceOf(owner));
    }
}
