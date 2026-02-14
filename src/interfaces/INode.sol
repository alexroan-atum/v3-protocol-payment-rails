// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title INode
/// @notice Interface for the core Node contract that routes tokens through action modules
/// @dev Node maintains token configurations and delegates execution to modules
interface INode {
    /// @notice Action types supported by the node
    enum ActionType {
        NONE,       // No action configured (default state)
        FORWARD,    // Send to address on same chain
        SWAP,       // Swap to different token
        BRIDGE      // Bridge to different chain
    }

    /// @notice Configuration for a token's action
    /// @dev Stored per token address in the node
    struct TokenConfig {
        ActionType actionType;        // Which action to perform
        address actionModule;         // Address of the action module contract
        bool enabled;                 // Master switch for this token
        uint256 minBalance;           // Minimum balance to trigger execution
        uint256 cooldownSeconds;      // Minimum time between executions
        uint256 lastExecuted;         // Timestamp of last execution
        bytes moduleParams;           // Module-specific parameters (ABI encoded)
    }

    /// @notice Emitted when a token is configured or reconfigured
    event TokenConfigured(
        address indexed token,
        ActionType actionType,
        address actionModule
    );

    /// @notice Emitted when an action is successfully executed
    event ActionExecuted(
        address indexed token,
        ActionType actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    /// @notice Configure a token's action module and parameters
    /// @dev Only callable by owner - execution is permissionless (public)
    /// @param token Token address to configure
    /// @param actionType Type of action (SWAP, BRIDGE, FORWARD)
    /// @param actionModule Address of the module contract
    /// @param minBalance Minimum balance threshold for execution
    /// @param cooldownSeconds Cooldown period between executions
    /// @param moduleParams Module-specific parameters (ABI encoded)
    function configureToken(
        address token,
        ActionType actionType,
        address actionModule,
        uint256 minBalance,
        uint256 cooldownSeconds,
        bytes calldata moduleParams
    ) external;

    /// @notice Update module parameters for a configured token
    /// @dev Only callable by owner
    /// @param token Token address
    /// @param newParams New module-specific parameters
    function updateModuleParams(address token, bytes calldata newParams) external;

    /// @notice Enable or disable a token's action
    /// @dev Only callable by owner
    /// @param token Token address
    /// @param enabled Whether the token action should be enabled
    function setTokenEnabled(address token, bool enabled) external;

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
    function getTokenConfig(address token) external view returns (TokenConfig memory config);

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
