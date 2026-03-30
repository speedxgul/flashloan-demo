// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// LESSON 5a: Mock DEXes — two exchanges with different prices
// ─────────────────────────────────────────────────────────────────────────────
//
// In the real world, DEXes use AMM formulas (x*y=k) and prices shift with
// every trade. For teaching purposes, we use FIXED prices so the math is
// obvious and doesn't get in the way of understanding flash loans.
//
// The setup:
//
//   DEX A: 1 WETH = 2000 USDC  (cheaper  → we BUY  WETH here)
//   DEX B: 1 WETH = 2020 USDC  (pricier  → we SELL WETH here)
//
//   Arbitrage:
//     Borrow 2000 USDC via flash loan (free, Balancer fee = 0%)
//     → Send 2000 USDC to DEX A, receive 1 WETH
//     → Send 1 WETH to DEX B, receive 2020 USDC
//     → Repay 2000 USDC to vault
//     → Keep 20 USDC profit
//
// Swap model (push-then-pull):
//   Caller sends tokens TO the DEX first, then calls swap().
//   DEX checks what arrived and sends back the other token.
//   This avoids needing approve/transferFrom for the demo.
//
// ─────────────────────────────────────────────────────────────────────────────

import "./IFlashLoan.sol";

contract MockDEX {

    IERC20 public immutable weth;
    IERC20 public immutable usdc;

    /// @notice How many USDC per 1 WETH (6 decimals).
    ///         DEX A: 2000_000000   DEX B: 2020_000000
    uint256 public immutable wethPriceInUsdc;

    string public name;

    // Track how many tokens the DEX held BEFORE a swap call.
    // We use this to figure out how much the caller actually sent in.
    uint256 private _usdcBefore;
    uint256 private _wethBefore;

    constructor(
        address _weth,
        address _usdc,
        uint256 _wethPriceInUsdc,
        string memory _name
    ) {
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        wethPriceInUsdc = _wethPriceInUsdc;
        name = _name;
    }

    // ─── Swap A: pay USDC → receive WETH ──────────────────────────────────────
    //
    // How to use:
    //   1. Transfer your USDC to this contract (usdc.transfer(dexA, amount))
    //   2. Call swapUsdcForWeth(usdcSent, minWethOut)
    //   3. DEX sends WETH to msg.sender
    //
    function swapUsdcForWeth(
        uint256 usdcIn,    // how much USDC you sent
        uint256 minWethOut // minimum WETH you'll accept (slippage protection)
    ) external returns (uint256 wethOut) {
        // Calculate WETH out at the fixed price
        // usdcIn has 6 decimals, wethOut has 18 decimals
        wethOut = (usdcIn * 1e18) / wethPriceInUsdc;

        require(wethOut >= minWethOut, "DEX: slippage exceeded");
        require(weth.balanceOf(address(this)) >= wethOut, "DEX: insufficient WETH liquidity");

        // Send WETH to the caller
        weth.transfer(msg.sender, wethOut);
    }

    // ─── Swap B: pay WETH → receive USDC ──────────────────────────────────────
    //
    // How to use:
    //   1. Transfer your WETH to this contract (weth.transfer(dexB, amount))
    //   2. Call swapWethForUsdc(wethSent, minUsdcOut)
    //   3. DEX sends USDC to msg.sender
    //
    function swapWethForUsdc(
        uint256 wethIn,    // how much WETH you sent
        uint256 minUsdcOut // minimum USDC you'll accept
    ) external returns (uint256 usdcOut) {
        // Calculate USDC out at the fixed price
        usdcOut = (wethIn * wethPriceInUsdc) / 1e18;

        require(usdcOut >= minUsdcOut, "DEX: slippage exceeded");
        require(usdc.balanceOf(address(this)) >= usdcOut, "DEX: insufficient USDC liquidity");

        // Send USDC to the caller
        usdc.transfer(msg.sender, usdcOut);
    }
}
