// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title IPaymentRails
/// @notice Interface for the core PaymentRails contract that routes tokens through action modules.
/// @dev PaymentRails is a configurable router: it holds tokens, maintains per-token configurations, and
/// delegates execution to pluggable {IActionModule} implementations (forward, swap, bridge, etc.).
///
/// The system uses a dual-permission model:
/// - Configuration ({configureToken}): owner-only.
/// - Execution ({executeAction}): permissionless — anyone can trigger pre-configured actions.
///
/// Safety mechanisms include minimum-balance thresholds, enable/disable flags, module validation,
/// and reentrancy protection.
interface IPaymentRails {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a token is configured or reconfigured
    /// @dev Emitted by configureToken() after successful configuration
    /// @param token The token address that was configured
    /// @param actionType The action type string (e.g., "FORWARD", "SWAP")
    /// @param actionModule The module contract address
    event TokenConfigured(address indexed token, string actionType, address actionModule);

    /// @notice Emitted when an action is successfully executed
    /// @dev Emitted by executeAction() after module returns success=true
    /// @dev Includes executor address for tracking who triggered the action
    /// @param token The input token address
    /// @param actionType The action type that was executed
    /// @param amountIn The input amount processed
    /// @param amountOut The actual output amount received
    /// @param outputToken The output token address (may differ from input for swaps)
    /// @param executor The address that called executeAction() (keeper, user, etc.)
    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    /*//////////////////////////////////////////////////////////////////////////
                                  CONFIGURATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Configure a token's action module and parameters.
    /// @dev Emits a {TokenConfigured} event. Can be called multiple times to reconfigure a token.
    ///
    /// Notes:
    /// - Setting `actionType` to an empty string clears the configuration.
    /// - When clearing, `actionModule` must be `address(0)`.
    /// - Module is validated by calling {IActionModule.moduleType}, which must return a non-empty string.
    ///
    /// Requirements:
    /// - The caller must be the contract owner.
    /// - `token` must not be `address(0)`.
    /// - If `actionType` is non-empty, `actionModule` must implement {IActionModule}.
    /// - If `actionType` is empty, `actionModule` must be `address(0)`.
    ///
    /// @param token Token address to configure.
    /// @param actionType Action identifier (e.g., "FORWARD", "SWAP", "BRIDGE"). Empty string clears config.
    /// @param actionModule Address of the module contract.
    /// @param minBalance Minimum balance threshold for execution.
    /// @param moduleParams ABI-encoded module-specific parameters.
    /// @param enabled Whether the token action should be enabled.
    function configureToken(
        address token,
        string calldata actionType,
        address actionModule,
        uint256 minBalance,
        bytes calldata moduleParams,
        bool enabled
    )
        external;

    /*//////////////////////////////////////////////////////////////////////////
                                   EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Execute the configured action for a token.
    /// @dev Permissionless. Validates preconditions, approves the module for `amount`, calls
    /// {IActionModule.execute}, and emits {ActionExecuted} on success. Revokes approval on failure.
    ///
    /// Notes:
    /// - The executor's address (`msg.sender`) is recorded in the {ActionExecuted} event.
    /// - Module execution failures return `false` instead of reverting.
    ///
    /// Requirements:
    /// - Token must be configured and enabled.
    /// - `amount` must be > 0 and >= `minBalance`.
    /// - PaymentRails must hold at least `amount` of `token`.
    ///
    /// @param token Token address to execute the action for.
    /// @param amount Amount to process.
    /// @return success True if the module execution succeeded.
    function executeAction(address token, uint256 amount) external returns (bool success);

    /// @notice Execute the configured action for a token with dynamic execution data
    /// @dev Overload of `executeAction(token, amount)` that forwards caller-supplied
    ///      `executionData` to the module. Use this when the module requires per-execution
    ///      data (e.g., DEX aggregator calldata). Static modules ignore the extra bytes.
    /// @param token Token address to execute action for
    /// @param amount Amount to process (must be >= minBalance and <= balance)
    /// @param executionData Dynamic data forwarded to the module's execute() function
    /// @return success True if module execution succeeded, false otherwise
    function executeAction(address token, uint256 amount, bytes calldata executionData) external returns (bool success);

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the full configuration for a token.
    /// @dev Returns a zero-initialized struct if the token is not configured.
    /// @param token Token address to query.
    /// @return config Complete token configuration struct.
    function getTokenConfig(address token) external view returns (DataTypes.TokenConfig memory config);

    /// @notice Returns the current token balance held by this PaymentRails contract.
    /// @param token Token address to check.
    /// @return balance Current balance of the token.
    function getTokenBalance(address token) external view returns (uint256 balance);

    /// @notice Preview the execution outcome for a token action.
    /// @dev Validates all requirements and calls {IActionModule.validate} and {IActionModule.estimateOutput}.
    /// Reverts with specific errors if execution would fail.
    ///
    /// @param token Token address to preview.
    /// @return estimatedOutput Estimated output amount.
    /// @return outputToken Address of the output token.
    function previewExecution(address token) external view returns (uint256 estimatedOutput, address outputToken);
}
