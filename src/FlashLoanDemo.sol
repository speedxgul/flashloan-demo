// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 2: A real flash loan contract — step by step
// ─────────────────────────────────────────────────────────────────────────────
//
// This contract demonstrates the COMPLETE flash loan lifecycle:
//
//   YOU                    BALANCER VAULT              THIS CONTRACT
//    │                           │                           │
//    │── borrow() ──────────────▶│                           │
//    │                           │── flashLoan() ───────────▶│
//    │                           │   (sends tokens)          │
//    │                           │                           │── receiveFlashLoan()
//    │                           │                           │   (do your work here)
//    │                           │                           │── repay tokens
//    │                           │◀─ verifies repayment ─────│
//    │◀── returns ───────────────│                           │
//
// The entire thing — borrow, work, repay — happens in ONE transaction.
// If repayment fails → everything reverts, as if it never happened.
//
// ─────────────────────────────────────────────────────────────────────────────

import "./IFlashLoan.sol";

contract FlashLoanDemo is IFlashLoanRecipient {

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice The Balancer V2 Vault we borrow from.
    ///         On Arbitrum mainnet: 0xBA12222222228d8Ba445958a75a0704d566BF2C8
    ///         In our tests: a mock we deploy ourselves
    IVault public immutable vault;

    /// @notice The owner — only they can trigger flash loans.
    address public immutable owner;

    /// @notice We store the last borrowed amount here just so tests can verify it.
    ///         In a real bot this would be where you do your swap/arbitrage.
    uint256 public lastBorrowedAmount;

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Fired every time we successfully complete a flash loan.
    /// @param token   Which token was borrowed.
    /// @param amount  How much was borrowed.
    event FlashLoanCompleted(address indexed token, uint256 amount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _vault) {
        vault = IVault(_vault);
        owner = msg.sender;
    }

    // ─── Step 1: You call this to START the flash loan ────────────────────────

    /// @notice Borrow `amount` of `token` from Balancer.
    ///
    ///         This is the ENTRY POINT. You call this function.
    ///         All it does is tell Balancer: "send me tokens and call me back."
    ///
    ///         IMPORTANT: Nothing else happens here. The real work happens
    ///         inside receiveFlashLoan() which Balancer calls next.
    ///
    /// @param token  The ERC-20 token to borrow (e.g. USDC, WETH)
    /// @param amount How much to borrow (in the token's smallest unit)
    function borrow(address token, uint256 amount) external {
        require(msg.sender == owner, "Not owner");

        // Build the arrays Balancer expects.
        // We're borrowing just one token, so arrays have one element each.
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // We can pass any data we want to ourselves via userData.
        // Here we're not passing anything (empty bytes).
        // In a real bot, you'd encode your arbitrage parameters here.
        bytes memory userData = "";

        // This is the only line that matters in this function.
        // Balancer will:
        //   1. Send `amount` of `token` to this contract
        //   2. Call receiveFlashLoan() on this contract
        //   3. After receiveFlashLoan() returns, verify tokens were repaid
        //   4. If not repaid → revert everything
        vault.flashLoan(
            IFlashLoanRecipient(address(this)),
            tokens,
            amounts,
            userData
        );

        // If we reach here, the flash loan succeeded and was repaid.
        emit FlashLoanCompleted(token, amount);
    }

    // ─── Step 2: Balancer calls THIS after sending you the tokens ─────────────

    /// @notice Flash loan callback — called by Balancer AFTER it sends tokens.
    ///
    ///         When this function runs, this contract already HAS the borrowed tokens.
    ///         You can do ANYTHING with them in here:
    ///           - Swap on one DEX
    ///           - Swap back on another DEX
    ///           - Liquidate an undercollateralized position
    ///           - Arbitrage a price difference
    ///
    ///         The ONLY rule: by the time this function RETURNS, you must have
    ///         sent back (amounts[0] + feeAmounts[0]) of each token to the Vault.
    ///         On Balancer V2, feeAmounts[0] is always 0, so just return amounts[0].
    ///
    ///         If you don't return the tokens → Balancer's flashLoan() call reverts
    ///         → your borrow() call reverts → nothing happened, you just lost gas.
    ///
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,  // always [0] on Balancer V2
        bytes memory                  // userData — not used in this demo
    ) external override {

        // ── SECURITY CHECK ────────────────────────────────────────────────────
        // VERY IMPORTANT: Anyone could call this function directly and try to
        // trick your contract. You MUST verify the caller is the Balancer Vault.
        require(msg.sender == address(vault), "Only Balancer can call this");

        // ── YOU NOW HAVE THE TOKENS ───────────────────────────────────────────
        // At this point, this contract holds `amounts[0]` of `tokens[0]`.
        //
        // In a real arbitrage bot, THIS is where you would:
        //   1. Swap tokens[0] on DEX A to get tokenMid
        //   2. Swap tokenMid on DEX B back to tokens[0]
        //   3. End up with MORE tokens[0] than you started with
        //
        // For this demo, we just record what was borrowed.
        lastBorrowedAmount = amounts[0];

        // ── REPAY THE LOAN ────────────────────────────────────────────────────
        // This is mandatory. Send back exactly what Balancer lent us.
        // fee = feeAmounts[0] = 0 on Balancer V2, but we add it anyway to be correct.
        uint256 repayAmount = amounts[0] + feeAmounts[0];

        // Transfer repayAmount back to the Balancer Vault.
        // If we don't have enough tokens here → this reverts → entire tx reverts.
        tokens[0].transfer(address(vault), repayAmount);

        // ── PROFIT? ───────────────────────────────────────────────────────────
        // After repaying, if we made any profit from our swaps,
        // it stays in this contract. We could then send it to the owner.
        // (In this demo we didn't do any swaps so there's no profit.)
    }

    // ─── Emergency recovery ───────────────────────────────────────────────────

    /// @notice If any tokens end up stuck in this contract, owner can recover them.
    function recover(address token, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        IERC20(token).transfer(owner, amount);
    }
}
