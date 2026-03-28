// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 4: Tests — proving the contract works exactly as expected
// ─────────────────────────────────────────────────────────────────────────────
//
// Foundry tests are Solidity contracts that inherit from `Test`.
// Each function starting with `test` is run as a separate test case.
//
// Key Foundry concepts used here:
//
//   vm.expectRevert("message")  →  assert the NEXT call reverts with this message
//   vm.prank(address)           →  make the NEXT call come from a different address
//   assertEq(a, b)              →  assert a == b, print values if they differ
//   assertTrue(x)               →  assert x is true
//
// ─────────────────────────────────────────────────────────────────────────────

import "forge-std/Test.sol";
import "../src/FlashLoanDemo.sol";
import "../src/MockVault.sol";

contract FlashLoanDemoTest is Test {

    // ─── Actors ───────────────────────────────────────────────────────────────

    address public owner = makeAddr("owner");  // our wallet (triggers the bot)

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockVault    public vault;
    MockERC20    public usdc;
    FlashLoanDemo public demo;

    // ─── Setup ────────────────────────────────────────────────────────────────

    /// @notice setUp() runs before EVERY test function.
    ///         Think of it as a clean slate for each test.
    function setUp() public {
        // Deploy the mock vault (fake Balancer)
        vault = new MockVault();

        // Deploy a fake USDC token
        usdc = new MockERC20("Mock USDC");

        // Deploy our flash loan contract, pointing at the mock vault
        // We prank as `owner` so FlashLoanDemo.owner == our owner address
        vm.prank(owner);
        demo = new FlashLoanDemo(address(vault));

        // Give the vault 1,000,000 USDC to lend out
        // (In real life, Balancer's vault already has billions in it)
        usdc.mint(address(vault), 1_000_000e6);
    }

    // ─── Test 1: Basic flash loan works ───────────────────────────────────────

    /// @notice Happy path: borrow 10,000 USDC, verify the loan completed.
    ///
    ///         This test proves:
    ///           - The vault sends tokens to our contract
    ///           - receiveFlashLoan() runs
    ///           - Tokens are returned to the vault
    ///           - lastBorrowedAmount was recorded correctly
    ///           - Vault balance is unchanged after the loan
    ///
    function test_basicFlashLoan() public {
        uint256 borrowAmount = 10_000e6; // 10,000 USDC

        // Record vault balance before
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        // Trigger the flash loan as owner
        vm.prank(owner);
        demo.borrow(address(usdc), borrowAmount);

        // Our contract should have recorded the borrow amount
        assertEq(demo.lastBorrowedAmount(), borrowAmount, "borrow amount not recorded");

        // Vault balance should be identical before and after — loan was repaid
        uint256 vaultAfter = usdc.balanceOf(address(vault));
        assertEq(vaultAfter, vaultBefore, "vault balance changed - loan not repaid fully");

        // Our demo contract should have zero tokens (it borrowed and repaid)
        assertEq(usdc.balanceOf(address(demo)), 0, "demo contract kept tokens");
    }

    // ─── Test 2: Only owner can trigger ───────────────────────────────────────

    /// @notice A random address must not be able to call borrow().
    ///
    ///         This tests the access control guard in FlashLoanDemo.borrow().
    ///         If this guard weren't there, anyone could use our contract
    ///         to take flash loans (and potentially drain it or cause issues).
    ///
    function test_onlyOwnerCanBorrow() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert("Not owner");
        demo.borrow(address(usdc), 1_000e6);
    }

    // ─── Test 3: Only vault can call receiveFlashLoan ─────────────────────────

    /// @notice Nobody except the vault can directly call receiveFlashLoan().
    ///
    ///         Without this check, an attacker could:
    ///           1. Call receiveFlashLoan() directly (no real loan)
    ///           2. Trick the contract into transferring tokens it holds
    ///
    ///         This is one of the most common flash loan exploits.
    ///
    function test_onlyVaultCanCallback() public {
        address attacker = makeAddr("attacker");

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdc));

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;

        // Attacker tries to call receiveFlashLoan directly
        vm.prank(attacker);
        vm.expectRevert("Only Balancer can call this");
        demo.receiveFlashLoan(tokens, amounts, fees, "");
    }

    // ─── Test 4: Vault reverts if loan not repaid ─────────────────────────────

    /// @notice What happens if a borrower takes the tokens and doesn't repay?
    ///
    ///         This proves the atomicity guarantee — if repayment fails,
    ///         the ENTIRE transaction reverts. The borrower gets nothing.
    ///
    ///         We test this with a "GreedyBorrower" — a contract that
    ///         takes the flash loan and deliberately doesn't repay.
    ///
    function test_vaultRevertsIfNotRepaid() public {
        GreedyBorrower greedy = new GreedyBorrower(address(vault));

        // Give the greedy contract no tokens (it won't be able to repay)
        // Try to flash loan — should revert
        vm.expectRevert("MockVault: flash loan not repaid");
        greedy.steal(address(usdc), 1_000e6);
    }

    // ─── Test 5: Borrow the entire vault balance ──────────────────────────────

    /// @notice Flash loans have no collateral limit — you can borrow 100% of the vault.
    ///
    ///         This is what makes flash loans powerful (and scary):
    ///         with $0 of your own money, you can control millions for one transaction.
    ///
    function test_borrowEntireVaultBalance() public {
        uint256 entireBalance = usdc.balanceOf(address(vault)); // 1,000,000 USDC

        vm.prank(owner);
        demo.borrow(address(usdc), entireBalance);

        assertEq(demo.lastBorrowedAmount(), entireBalance);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper contract for Test 4
// A malicious borrower that takes the tokens but never repays.
// ─────────────────────────────────────────────────────────────────────────────

contract GreedyBorrower is IFlashLoanRecipient {
    IVault public vault;

    constructor(address _vault) {
        vault = IVault(_vault);
    }

    function steal(address token, uint256 amount) external {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vault.flashLoan(this, tokens, amounts, "");
    }

    function receiveFlashLoan(
        IERC20[] memory,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external override {
        // Deliberately do nothing — don't repay.
        // The vault's repayment check will catch this and revert.
    }
}
