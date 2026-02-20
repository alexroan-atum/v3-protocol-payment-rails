// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ISwapModule
/// @notice Interface for modules that swap tokens via DEXs or other venues
/// @dev Implements IActionModule with swap-specific functionality
///
/// # Overview
/// ISwapModule extends IActionModule to support automated token swaps through decentralized
/// exchanges (Uniswap, Curve, Balancer, etc.) or other swap venues. It includes specialized
/// functions for price validation, oracle integration, and slippage protection.
///
/// # Use Cases
/// - Converting stablecoins (USDC → DAI, USDT → USDC)
/// - Selling yield tokens for base assets (COMP → ETH)
/// - Auto-rebalancing portfolios (sell overweight, buy underweight)
/// - Converting receivables to preferred denomination
/// - Tax-loss harvesting (sell losers, buy similar assets)
///
/// # Security Features
///
/// **Oracle-Based Validation:**
/// - Compare swap prices against trusted price feeds (Chainlink, Uniswap TWAP)
/// - Reject swaps with excessive deviation (price manipulation protection)
/// - Configurable deviation threshold per token pair
///
/// **Slippage Protection:**
/// - Maximum allowed slippage from expected price
/// - Prevents sandwich attacks and front-running
/// - Dynamic adjustment based on market conditions
///
/// **MEV Protection:**
/// - Private mempool submission support (Flashbots, Eden, etc.)
/// - Price validation reduces MEV extraction potential
/// - Deadline enforcement on swap transactions
///
/// # Parameters
/// Swap operations use SwapParams struct:
/// - `dex`: DEX router address (Uniswap, Sushiswap, etc.)
/// - `tokenOut`: Destination token address
/// - `minAmountOut`: Minimum acceptable output (slippage limit)
/// - `deadline`: Transaction deadline timestamp
/// - `route`: Encoded swap path (for multi-hop swaps)
/// - `oracle`: Price oracle address for validation
/// - `maxDeviation`: Maximum allowed price deviation (basis points)
///
/// # Implementation Status
/// NOTE: SwapModule is currently a stub implementation. Full DEX integration is planned
/// for future releases. This interface defines the contract for when swaps are implemented.
interface ISwapModule is IActionModule {

    /*//////////////////////////////////////////////////////////////////////////
                        SWAP-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Encode swap parameters into ABI-encoded bytes
    /// @dev Helper function for constructing moduleParams when configuring swap tokens
    ///
    /// # Usage
    /// ```solidity
    /// SwapParams memory params = SwapParams({
    ///     dex: uniswapV2Router,
    ///     tokenOut: DAI,
    ///     minAmountOut: 990e18,  // 1% slippage
    ///     deadline: block.timestamp + 3600,
    ///     route: abi.encodePacked(USDC, DAI),
    ///     oracle: chainlinkOracle,
    ///     maxDeviation: 200  // 2% max deviation
    /// });
    /// bytes memory encoded = swapModule.encodeParams(params);
    /// node.configureToken(USDC, "SWAP", address(swapModule), ..., encoded, true);
    /// ```
    ///
    /// @param params Swap parameters to encode
    /// @return ABI-encoded bytes representation
    function encodeParams(DataTypes.SwapParams calldata params) external pure returns (bytes memory);

    /// @notice Decode ABI-encoded bytes into SwapParams struct
    /// @dev Extracts swap configuration from generic bytes parameter
    ///
    /// # Usage
    /// Called internally by SwapModule to access swap configuration from params bytes.
    ///
    /// @param encoded ABI-encoded parameter bytes
    /// @return params Decoded SwapParams struct
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.SwapParams memory params);

    /// @notice Get current price from oracle for token pair
    /// @dev Queries price oracle (Chainlink, Uniswap TWAP, etc.) for validation
    ///
    /// # Purpose
    /// Provides trusted price reference for validating swap outputs and detecting
    /// price manipulation. Used by validateSwapPrice() to ensure fair execution.
    ///
    /// # Oracle Types
    /// Supports multiple oracle implementations:
    /// - Chainlink Price Feeds (most common)
    /// - Uniswap V3 TWAP
    /// - Custom price aggregators
    ///
    /// # Return Value
    /// Price is returned with appropriate scaling:
    /// - For Chainlink: Usually 8 decimals
    /// - For custom: Documented in oracle contract
    /// - Caller must handle decimal conversion
    ///
    /// Notes:
    /// - May revert if oracle is stale or unavailable
    /// - May revert if token pair not supported
    /// - Should implement fallback logic for oracle failures
    ///
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param oracle Oracle contract address
    /// @return price Price of tokenIn denominated in tokenOut (scaled by oracle decimals)
    function getOraclePrice(
        address tokenIn,
        address tokenOut,
        address oracle
    ) external view returns (uint256 price);

    /// @notice Validate swap output against oracle price with deviation tolerance
    /// @dev Checks if expectedAmountOut is within acceptable range of oracle price
    ///
    /// # Purpose
    /// Prevents executing swaps at unfavorable prices due to:
    /// - Price manipulation attacks
    /// - Front-running / sandwich attacks
    /// - Stale pool reserves
    /// - Flash loan price impacts
    ///
    /// # Validation Logic
    /// 1. Query oracle price for token pair
    /// 2. Calculate expected output based on oracle price
    /// 3. Compare actual expectedAmountOut vs oracle-based amount
    /// 4. Reject if deviation > maxDeviation threshold
    ///
    /// # Example
    /// ```
    /// Oracle price: 1 USDC = 1.00 DAI
    /// Input: 1000 USDC
    /// Expected output: 980 DAI
    /// Oracle-based output: 1000 DAI
    /// Deviation: (1000 - 980) / 1000 = 2%
    /// Max deviation: 2%
    /// Result: isValid = true (exactly at threshold)
    /// ```
    ///
    /// # Deviation Tolerance
    /// maxDeviation is specified in basis points:
    /// - 100 = 1%
    /// - 200 = 2%
    /// - 500 = 5%
    ///
    /// Common settings:
    /// - Stablecoins: 50-100 bp (0.5-1%)
    /// - Major pairs: 200-300 bp (2-3%)
    /// - Volatile pairs: 500-1000 bp (5-10%)
    ///
    /// Notes:
    /// - Should be called before executing swap
    /// - May return false for legitimate reasons (low liquidity, high volatility)
    /// - Caller should decide whether to proceed based on risk tolerance
    ///
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Amount of input tokens
    /// @param expectedAmountOut Expected output from DEX quote
    /// @param params Swap parameters containing oracle config and maxDeviation
    /// @return isValid True if price is within acceptable deviation
    /// @return reason Human-readable reason if validation fails
    function validateSwapPrice(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 expectedAmountOut,
        DataTypes.SwapParams calldata params
    ) external view returns (bool isValid, string memory reason);
}
