// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 3: Mock contracts — how to test without a real blockchain
// ─────────────────────────────────────────────────────────────────────────────
//
// The real Balancer Vault lives on Arbitrum mainnet. We can't use it in tests.
// So we build a "mock" — a fake version that behaves the same way but runs
// locally inside our test environment.
//
// This is a core pattern in smart contract development:
//   - Real code talks to interfaces (IVault, IERC20)
//   - Tests swap in mocks that implement the same interfaces
//   - Your real contract never knows the difference
//
// ─────────────────────────────────────────────────────────────────────────────

import "./IFlashLoan.sol";

/// @notice A fake ERC-20 token we can mint freely in tests.
///
///         Real tokens (USDC, WETH) have rules about who can mint.
///         This mock lets us create as many tokens as we want so we can
///         pre-fund the vault and test our contract.
///
contract MockERC20 is IERC20 {

    string public name;
    mapping(address => uint256) private _balances;

    constructor(string memory _name) {
        name = _name;
    }

    /// @notice Create tokens out of thin air and send them to `to`.
    ///         Only possible in this mock — real tokens don't have this.
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(_balances[msg.sender] >= amount, "MockERC20: insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
}

/// @notice A fake Balancer Vault that mimics the real flash loan flow.
///
///         The real Balancer Vault:
///           1. Checks it has enough tokens
///           2. Sends tokens to the recipient
///           3. Calls receiveFlashLoan() on the recipient
///           4. Checks it got the tokens back (+ fee)
///           5. Reverts if not repaid
///
///         This mock does the exact same steps — just without
///         all the production complexity of the real Vault.
///
contract MockVault is IVault {

    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external override {

        // ── STEP 1: Record how much we have before lending ────────────────────
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = tokens[i].balanceOf(address(this));
        }

        // ── STEP 2: Send the tokens to the borrower ───────────────────────────
        // The borrower's contract now has `amounts[i]` of each token.
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(address(recipient), amounts[i]);
        }

        // ── STEP 3: Call back the borrower ────────────────────────────────────
        // feeAmounts is all zeros — Balancer V2 charges no flash loan fees.
        uint256[] memory feeAmounts = new uint256[](tokens.length);
        recipient.receiveFlashLoan(tokens, amounts, feeAmounts, userData);

        // ── STEP 4: Verify repayment ──────────────────────────────────────────
        // After receiveFlashLoan() returns, we MUST have our tokens back.
        // If the borrower didn't repay, this check fails and the entire
        // transaction reverts — as if the flash loan never happened.
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balanceAfter = tokens[i].balanceOf(address(this));
            require(
                balanceAfter >= balancesBefore[i] + feeAmounts[i],
                "MockVault: flash loan not repaid"
            );
        }
    }
}
