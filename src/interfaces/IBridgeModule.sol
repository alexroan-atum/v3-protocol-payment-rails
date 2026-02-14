// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";

/// @title IBridgeModule
/// @notice Interface for modules that bridge tokens cross-chain
/// @dev Implements IActionModule with bridge-specific functionality
interface IBridgeModule is IActionModule {
    /// @notice Bridge configuration parameters
    /// @dev Encoded into bytes and passed to execute()
    struct BridgeParams {
        uint256 destinationChainId;         // Target chain ID
        address destinationAddress;         // Recipient on destination chain (often another Node)
        address bridgeAdapter;              // Bridge protocol adapter (CCTP, LayerZero, etc.)
        bytes bridgeData;                   // Bridge-specific data (varies by adapter)
        address healthOracle;               // Oracle to check bridge health (can be address(0))
        uint256 minBridgeHealth;            // Minimum health score to execute (0-100)
        bool requireDestinationConfirmation;// Whether to wait for cross-chain confirmation
    }

    /// @notice Bridge health status
    struct BridgeHealth {
        bool isOperational;      // Is bridge accepting transfers?
        uint256 liquidity;       // Available liquidity in bridge
        uint256 avgFee;          // Average fee (for anomaly detection)
        uint256 lastUpdate;      // Oracle data freshness timestamp
        uint8 healthScore;       // Composite health score (0-100)
    }

    /// @notice Encode bridge parameters into bytes
    /// @param params Bridge parameters to encode
    /// @return Encoded parameters
    function encodeParams(BridgeParams calldata params) external pure returns (bytes memory);

    /// @notice Decode bridge parameters from bytes
    /// @param encoded Encoded parameters
    /// @return params Decoded bridge parameters
    function decodeParams(bytes calldata encoded) external pure returns (BridgeParams memory params);

    /// @notice Check bridge health status
    /// @dev Queries health oracle if configured
    /// @param bridge Bridge adapter address
    /// @param healthOracle Health oracle address (can be address(0) to skip check)
    /// @return health Bridge health status
    function checkBridgeHealth(
        address bridge,
        address healthOracle
    ) external view returns (BridgeHealth memory health);

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
