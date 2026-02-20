// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title IActionModule
/// @notice Base interface for all action modules (Swap, Bridge, Forward)
/// @dev Modules are called by Node contracts to execute pre-configured actions on tokens
interface IActionModule {

    /// @notice Execute the configured action for a token
    /// @dev Should revert on failure or return ExecutionResult with success=false
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters (ABI encoded)
    /// @return result Execution result with success status and output details
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external returns (DataTypes.ExecutionResult memory result);

    /// @notice Validate if execution is safe/possible without executing
    /// @dev View function to check if execute() would succeed
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters
    /// @return isValid Whether execution would succeed
    /// @return reason Reason if invalid (empty string if valid)
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view returns (bool isValid, string memory reason);

    /// @notice Estimate output amount for an action
    /// @dev Provides expected output for off-chain monitoring
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters
    /// @return estimatedOutput Estimated output amount
    /// @return outputToken Address of output token
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view returns (uint256 estimatedOutput, address outputToken);

    /// @notice Get human-readable description of this module
    /// @return Module type identifier (e.g., "SWAP", "BRIDGE", "FORWARD")
    function moduleType() external pure returns (string memory);
}
