// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ISwapModule
/// @author Credit Cooperative
/// @notice Interface for modules that swap tokens via synchronous DEX routers.
/// @dev Extends {IActionModule} with swap-specific parameter encoding and price validation.
///
/// NOTE: {SwapModule} is currently a stub. Full DEX integration is planned for a future release.
interface ISwapModule is IActionModule {
    /// @notice ABI-encodes a {SwapParams} struct into bytes for `Node.configureToken()`.
    /// @param params Swap parameters to encode.
    /// @return ABI-encoded bytes representation.
    function encodeParams(DataTypes.SwapParams calldata params) external pure returns (bytes memory);

    /// @notice Decodes ABI-encoded bytes into a {SwapParams} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeParams()`.
    /// @return params Decoded struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.SwapParams memory params);

    /// @notice Queries a price oracle for the current rate of a token pair.
    /// @param tokenIn  Input token address.
    /// @param tokenOut Output token address.
    /// @param oracle   Price oracle contract address (e.g., Chainlink).
    /// @return price   Price of `tokenIn` denominated in `tokenOut` (scaled by oracle decimals).
    function getOraclePrice(
        address tokenIn,
        address tokenOut,
        address oracle
    )
        external
        view
        returns (uint256 price);

    /// @notice Validates swap output against an oracle price with a deviation tolerance.
    /// @param tokenIn           Input token address.
    /// @param tokenOut          Output token address.
    /// @param amountIn          Amount of input tokens.
    /// @param expectedAmountOut Expected output from DEX quote.
    /// @param params            Swap parameters containing oracle config and `maxPriceDeviationBps`.
    /// @return isValid          True if price is within acceptable deviation.
    /// @return reason           Human-readable reason if validation fails.
    function validateSwapPrice(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 expectedAmountOut,
        DataTypes.SwapParams calldata params
    )
        external
        view
        returns (bool isValid, string memory reason);
}
