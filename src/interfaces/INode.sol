// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title INode
/// @notice Interface for the core Node contract that routes tokens through action modules
/// @dev Node maintains token configurations and delegates execution to modules
interface INode {

    /// @notice Emitted when a token is configured or reconfigured
    event TokenConfigured(
        address indexed token,
        string actionType,
        address actionModule
    );

    /// @notice Emitted when an action is successfully executed
    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    /// @notice Configure a token's action module and parameters
    /// @dev Only callable by owner - execution is permissionless (public)
    /// @dev Can be called multiple times to reconfigure a token
    /// @param token Token address to configure
    /// @param actionType Type of action (e.g., "FORWARD", "SWAP", "BRIDGE", "STAKE", etc.)
    /// @param actionModule Address of the module contract
    /// @param minBalance Minimum balance threshold for execution
    /// @param cooldownSeconds Cooldown period between executions
    /// @param moduleParams Module-specific parameters (ABI encoded)
    /// @param enabled Whether the token action should be enabled
    function configureToken(
        address token,
        string calldata actionType,
        address actionModule,
        uint256 minBalance,
        uint256 cooldownSeconds,
        bytes calldata moduleParams,
        bool enabled
    ) external;

    /// @notice Execute the configured action for a token with a specific amount
    /// @dev Permissionless - anyone can trigger execution
    /// @dev Amount must meet minBalance threshold to prevent inefficient small swaps
    /// @param token Token address to execute action for
    /// @param amount Amount to process (must be >= minBalance)
    /// @return success Whether execution succeeded
    function executeAction(address token, uint256 amount) external returns (bool success);

    /// @notice Get full configuration for a token
    /// @param token Token address
    /// @return config Token configuration struct
    function getTokenConfig(address token) external view returns (DataTypes.TokenConfig memory config);

    /// @notice Get current token balance held by node
    /// @param token Token address
    /// @return balance Current balance
    function getTokenBalance(address token) external view returns (uint256 balance);

    /// @notice Check if action can be executed for a token
    /// @dev Validates cooldown, balance threshold, module validation
    /// @param token Token address
    /// @return canExecute Whether execution is possible
    /// @return reason Reason if execution not possible (empty if can execute)
    function canExecute(address token) external view returns (bool canExecute, string memory reason);

    /// @notice Estimate output for executing action on a token
    /// @param token Token address
    /// @return estimatedOutput Estimated output amount
    /// @return outputToken Address of output token
    function estimateActionOutput(address token)
        external
        view
        returns (uint256 estimatedOutput, address outputToken);
}
