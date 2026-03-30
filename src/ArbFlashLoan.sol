// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 5b: Putting it all together — flash loan arbitrage
// ─────────────────────────────────────────────────────────────────────────────
//
// This is a complete, working arbitrage contract.
// It borrows USDC for free, exploits a price gap between two DEXes,
// repays the loan, and sends profit to the owner.
//
// This is structurally identical to what arbx does on Arbitrum mainnet —
// just with mock DEXes instead of real Uniswap/Camelot pools.
//
// Flow:
//
//   owner calls execute()
//       │
//       ▼
//   vault.flashLoan()  →  vault sends USDC to this contract
//       │
//       ▼
//   receiveFlashLoan() runs (we now hold borrowed USDC)
//       │
//       ├─ Step 1: send USDC to DEX A, call swap → receive WETH
//       ├─ Step 2: send WETH to DEX B, call swap → receive USDC
//       ├─ Step 3: check we have profit
//       ├─ Step 4: repay loan to vault
//       └─ Step 5: send profit to owner
//
// ─────────────────────────────────────────────────────────────────────────────

import "./IFlashLoan.sol";
import "./MockDEX.sol";

contract ArbFlashLoan is IFlashLoanRecipient {

    IVault    public immutable vault;
    MockDEX   public immutable dexA;   // cheap DEX  (buy WETH here)
    MockDEX   public immutable dexB;   // pricey DEX (sell WETH here)
    IERC20    public immutable weth;
    IERC20    public immutable usdc;
    address   public immutable owner;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ArbExecuted(
        uint256 borrowed,    // USDC borrowed
        uint256 repaid,      // USDC repaid (= borrowed, fee=0)
        uint256 profit       // USDC profit sent to owner
    );

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _vault,
        address _dexA,
        address _dexB,
        address _weth,
        address _usdc
    ) {
        vault  = IVault(_vault);
        dexA   = MockDEX(_dexA);
        dexB   = MockDEX(_dexB);
        weth   = IERC20(_weth);
        usdc   = IERC20(_usdc);
        owner  = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ENTRY POINT: owner calls this to kick off the arb
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Borrow `usdcAmount` from Balancer, arb the two DEXes, pocket profit.
    ///
    /// @param usdcAmount   How much USDC to borrow (and use to buy WETH on DEX A)
    /// @param minProfit    Minimum profit required — if we'd make less, revert.
    ///                     This is your safety floor: "don't execute unless I make at least X"
    function execute(uint256 usdcAmount, uint256 minProfit) external {
        require(msg.sender == owner, "Not owner");

        // Pack our parameters into bytes so we can read them in the callback.
        // This is how you pass data through the flash loan to yourself.
        bytes memory userData = abi.encode(usdcAmount, minProfit);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = usdc;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = usdcAmount;

        // Fire the flash loan. Balancer will call receiveFlashLoan() next.
        vault.flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, userData);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CALLBACK: Balancer calls this after sending us the USDC
    // ─────────────────────────────────────────────────────────────────────────

    function receiveFlashLoan(
        IERC20[] memory, /* tokens */
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {

        // Security: only the vault can call this
        require(msg.sender == address(vault), "Only vault");

        // Decode the parameters we packed in execute()
        (uint256 usdcBorrowed, uint256 minProfit) = abi.decode(userData, (uint256, uint256));

        // ── At this point: this contract holds `usdcBorrowed` USDC ────────────

        // ── STEP 1: Buy WETH cheap on DEX A ───────────────────────────────────
        //
        // Push our USDC to DEX A, then call the swap.
        // DEX A sends WETH back to us at its fixed price (2000 USDC per WETH).
        //
        usdc.transfer(address(dexA), usdcBorrowed);
        uint256 wethReceived = dexA.swapUsdcForWeth(usdcBorrowed, 0);

        // ── STEP 2: Sell WETH expensive on DEX B ──────────────────────────────
        //
        // Push our WETH to DEX B, then call the swap.
        // DEX B sends USDC back to us at its (higher) fixed price (2020 USDC per WETH).
        //
        weth.transfer(address(dexB), wethReceived);
        uint256 usdcReceived = dexB.swapWethForUsdc(wethReceived, 0);

        // ── STEP 3: Check profit ───────────────────────────────────────────────
        //
        // We borrowed `usdcBorrowed` and now hold `usdcReceived`.
        // Profit = usdcReceived - usdcBorrowed (fee is 0 on Balancer V2).
        //
        // If we don't have enough to repay → this reverts → entire tx reverts.
        // We lose only gas. This is the atomicity guarantee.
        //
        require(usdcReceived > usdcBorrowed, "Arb: no profit");
        uint256 profit = usdcReceived - usdcBorrowed;
        require(profit >= minProfit, "Arb: profit below minimum");

        // ── STEP 4: Repay the flash loan ───────────────────────────────────────
        //
        // Send exactly what we borrowed back to the vault.
        // feeAmounts[0] = 0 on Balancer V2, but we add it for correctness.
        //
        uint256 repayAmount = amounts[0] + feeAmounts[0];
        usdc.transfer(address(vault), repayAmount);

        // ── STEP 5: Send profit to owner ───────────────────────────────────────
        usdc.transfer(owner, profit);

        emit ArbExecuted(usdcBorrowed, repayAmount, profit);
    }
}
