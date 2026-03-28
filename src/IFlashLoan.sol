// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 1: Interfaces — the "contracts" between contracts
// ─────────────────────────────────────────────────────────────────────────────
//
// An interface defines WHAT a contract can do, without saying HOW.
// Think of it like a job description: "you must implement these functions."
//
// We need two interfaces:
//   1. IVault     — the Balancer Vault we borrow FROM
//   2. IRecipient — what OUR contract must look like so Balancer can call back
//
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Minimal ERC-20 — we only need balanceOf and transfer for this demo.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice The Balancer V2 Vault.
///
///         This is the contract that HOLDS all the liquidity on Balancer.
///         It has one function we care about: flashLoan().
///
///         flashLoan() works like this:
///           1. You call it with: who should receive the loan, which tokens, how much
///           2. Balancer sends the tokens to you immediately
///           3. Balancer calls receiveFlashLoan() on your contract
///           4. Inside receiveFlashLoan() you do your thing
///           5. Before receiveFlashLoan() returns, you must have sent the tokens back
///           6. If you haven't sent them back → the entire transaction reverts
///
///         The fee on Balancer V2 is always 0%. Free money to borrow, as long as
///         you return it in the same transaction.
///
interface IVault {
    function flashLoan(
        IFlashLoanRecipient recipient, // who receives the loan (your contract)
        IERC20[] memory tokens,        // which tokens to borrow
        uint256[] memory amounts,      // how much of each token
        bytes memory userData          // any extra data you want to pass to yourself
    ) external;
}

/// @notice The callback interface YOUR contract must implement.
///
///         When Balancer sends you the tokens, it immediately calls
///         receiveFlashLoan() on your contract. This is where you do your work.
///
///         Balancer guarantees:
///           - tokens[]      = the tokens it sent you
///           - amounts[]     = how much it sent
///           - feeAmounts[]  = always [0, 0, ...] on Balancer V2 (no fee!)
///           - userData      = whatever bytes you passed into flashLoan()
///
interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}
