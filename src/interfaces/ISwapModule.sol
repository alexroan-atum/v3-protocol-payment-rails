// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ISwapModule
/// @notice Interface for modules that swap tokens via DEXs or other venues
/// @dev Implements IActionModule with swap-specific functionality
interface ISwapModule is IActionModule {

    /// @notice Encode swap parameters into bytes
    /// @param params Swap parameters to encode
    /// @return Encoded parameters
    function encodeParams(DataTypes.SwapParams calldata params) external pure returns (bytes memory);

    /// @notice Decode swap parameters from bytes
    /// @param encoded Encoded parameters
    /// @return params Decoded swap parameters
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.SwapParams memory params);

    /// @notice Get current price from oracle
    /// @dev Used for validating swap outputs
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param oracle Oracle address
    /// @return price Price of tokenIn in terms of tokenOut (scaled appropriately)
    function getOraclePrice(
        address tokenIn,
        address tokenOut,
        address oracle
    ) external view returns (uint256 price);

    /// @notice Validate swap output against oracle/TWAP
    /// @dev Checks if expectedAmountOut is within acceptable deviation
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Amount of input token
    /// @param expectedAmountOut Expected amount of output token
    /// @param params Swap parameters with oracle config
    /// @return isValid Whether the swap price is valid
    /// @return reason Reason if invalid (empty if valid)
    function validateSwapPrice(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 expectedAmountOut,
        DataTypes.SwapParams calldata params
    ) external view returns (bool isValid, string memory reason);
}
