// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IBridgeModule
/// @notice Interface for modules that bridge tokens cross-chain
/// @dev Implements IActionModule with bridge-specific functionality
interface IBridgeModule is IActionModule {

    /// @notice Encode bridge parameters into bytes
    /// @param params Bridge parameters to encode
    /// @return Encoded parameters
    function encodeParams(DataTypes.BridgeParams calldata params) external pure returns (bytes memory);

    /// @notice Decode bridge parameters from bytes
    /// @param encoded Encoded parameters
    /// @return params Decoded bridge parameters
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.BridgeParams memory params);

    /// @notice Check bridge health status
    /// @dev Queries health oracle if configured
    /// @param bridge Bridge adapter address
    /// @param healthOracle Health oracle address (can be address(0) to skip check)
    /// @return health Bridge health status
    function checkBridgeHealth(
        address bridge,
        address healthOracle
    ) external view returns (DataTypes.BridgeHealth memory health);

    /// @notice Estimate bridge fees
    /// @param token Token to bridge
    /// @param amount Amount to bridge
    /// @param params Bridge parameters (encoded)
    /// @return fee Estimated bridge fee in native token
    function estimateBridgeFee(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view returns (uint256 fee);
}
