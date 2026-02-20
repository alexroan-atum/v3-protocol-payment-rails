// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title INode
/// @notice Interface for the core Node contract that routes tokens through action modules
/// @dev Node maintains token configurations and delegates execution to modules
///
/// # Overview
/// INode is the core interface for the Receivables Node system - a flexible framework for
/// automating token operations through pluggable action modules. The Node acts as a router
/// that receives tokens, stores configurations, and delegates execution to specialized modules.
///
/// # Architecture
/// The system follows a hub-and-spoke pattern:
/// - **Node (Hub)**: Holds tokens, validates preconditions, manages configurations
/// - **Modules (Spokes)**: Execute specialized operations (forward, swap, bridge, etc.)
/// - **Configuration**: Owner sets rules, execution is permissionless
///
/// # Key Features
///
/// **Modular Design:**
/// - Support unlimited module types through string-based identification
/// - Hot-swap modules by reconfiguring tokens
/// - Add new capabilities without upgrading Node contract
///
/// **Dual Permission Model:**
/// - Configuration: Only owner can call configureToken()
/// - Execution: Anyone can call executeAction() (permissionless automation)
///
/// **Safety Mechanisms:**
/// - Minimum balance thresholds (prevents dust execution)
/// - Cooldown periods (prevents spam, encourages batching)
/// - Enable/disable flags (emergency stops)
/// - Module validation (ensures valid implementations)
///
/// **Preview Functionality:**
/// - previewExecution() validates all requirements without executing
/// - Follows ERC-4626 pattern for consistency
/// - Returns estimated output for off-chain monitoring
///
/// # Typical Workflow
///
/// **1. Configuration (Owner):**
/// ```solidity
/// node.configureToken(
///     tokenAddress,       // Token to automate
///     "FORWARD",          // Action type
///     moduleAddress,      // Module contract
///     100e18,            // Minimum balance
///     3600,              // Cooldown (1 hour)
///     encodedParams,     // Module config
///     true               // Enabled
/// );
/// ```
///
/// **2. Preview (Anyone):**
/// ```solidity
/// (uint256 output, address outToken) = node.previewExecution(tokenAddress);
/// // Check if execution is profitable/desirable
/// ```
///
/// **3. Execution (Anyone):**
/// ```solidity
/// bool success = node.executeAction(tokenAddress, amount);
/// // Keeper bot, user, or automated system triggers execution
/// ```
///
/// # Use Cases
/// - **Receivables Automation**: Automatically forward invoice payments to treasury
/// - **Treasury Management**: Auto-swap stablecoins, bridge to L2, stake yields
/// - **Revenue Distribution**: Split and forward tokens to multiple beneficiaries
/// - **DeFi Automation**: Compound yields, rebalance portfolios, harvest rewards
/// - **Cross-Chain Operations**: Bridge tokens when thresholds are met
///
/// # Security Model
/// - Owner can configure but cannot steal tokens (modules are validated)
/// - Executors can only trigger pre-configured actions (no arbitrary parameters)
/// - Modules receive limited approvals (exact amount only)
/// - Reentrancy protection on executeAction()
/// - Cooldowns prevent griefing attacks
///
/// # Events
/// - TokenConfigured: Emitted when token configuration changes
/// - ActionExecuted: Emitted when action executes successfully (includes executor)
interface INode {

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a token is configured or reconfigured
    /// @dev Emitted by configureToken() after successful configuration
    /// @param token The token address that was configured
    /// @param actionType The action type string (e.g., "FORWARD", "SWAP")
    /// @param actionModule The module contract address
    event TokenConfigured(
        address indexed token,
        string actionType,
        address actionModule
    );

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

    /// @notice Configure a token's action module and parameters
    /// @dev Only callable by owner - execution is permissionless (public)
    /// @dev Can be called multiple times to reconfigure a token
    ///
    /// # Purpose
    /// This function is the primary configuration interface for setting up automated token
    /// actions. The owner defines what should happen when executeAction() is called for a token.
    ///
    /// # Parameters Explained
    ///
    /// **actionType** (string):
    /// - Identifies the type of action (must match module.moduleType())
    /// - Examples: "FORWARD", "SWAP", "BRIDGE", "STAKE"
    /// - Used in events for tracking
    /// - Empty string clears configuration
    ///
    /// **actionModule** (address):
    /// - Contract implementing IActionModule interface
    /// - Validated by calling moduleType() (must return non-empty string)
    /// - Must be address(0) if actionType is empty
    ///
    /// **minBalance** (uint256):
    /// - Minimum token balance required to execute
    /// - Prevents inefficient dust executions
    /// - Checked against `amount` parameter in executeAction()
    /// - Set to 0 to disable this check
    ///
    /// **cooldownSeconds** (uint256):
    /// - Minimum time between consecutive executions
    /// - Prevents spam and encourages batching
    /// - Counted from lastExecuted timestamp
    /// - Set to 0 to disable cooldown
    ///
    /// **moduleParams** (bytes):
    /// - ABI-encoded module-specific configuration
    /// - For ForwardModule: encodeParams(ForwardParams)
    /// - Passed to module's execute() and validate() functions
    /// - Use module's encodeParams() helper to construct
    ///
    /// **enabled** (bool):
    /// - Whether execution is currently allowed
    /// - Provides emergency stop mechanism
    /// - Can be toggled by reconfiguring
    ///
    /// # Usage Examples
    ///
    /// **Configure forward to treasury:**
    /// ```solidity
    /// ForwardParams memory params = ForwardParams({
    ///     recipient: treasuryAddress,
    ///     requireSuccessfulReceipt: false,
    ///     minAmount: 0
    /// });
    /// node.configureToken(
    ///     USDC,
    ///     "FORWARD",
    ///     address(forwardModule),
    ///     1000e6,  // Min 1000 USDC
    ///     3600,    // 1 hour cooldown
    ///     forwardModule.encodeParams(params),
    ///     true
    /// );
    /// ```
    ///
    /// **Disable token (emergency stop):**
    /// ```solidity
    /// node.configureToken(
    ///     USDC,
    ///     "FORWARD",
    ///     address(forwardModule),
    ///     1000e6,
    ///     3600,
    ///     existingParams,
    ///     false  // ← Disabled
    /// );
    /// ```
    ///
    /// # Reconfiguration
    /// - Resets lastExecuted to 0 (cooldown resets)
    /// - Overwrites all previous configuration
    /// - Emits TokenConfigured event
    ///
    /// Requirements:
    /// - Caller must be contract owner
    /// - token must not be address(0)
    /// - If actionType is empty, actionModule must be address(0)
    /// - If actionType is not empty, actionModule must implement IActionModule
    /// - actionModule.moduleType() must return non-empty string
    ///
    /// Emits:
    /// - {TokenConfigured} event
    ///
    /// @param token Token address to configure
    /// @param actionType Type of action (e.g., "FORWARD", "SWAP", "BRIDGE")
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

    /*//////////////////////////////////////////////////////////////////////////
                                   EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Execute the configured action for a token with a specific amount
    /// @dev Permissionless - anyone can trigger execution
    ///
    /// # Purpose
    /// This is the main execution function that triggers the configured action for a token.
    /// It performs validation, delegates to the module, and handles the results.
    ///
    /// # Execution Flow
    /// 1. **Validation Phase:**
    ///    - Check token is enabled
    ///    - Check action is configured
    ///    - Check amount is not zero
    ///    - Check amount >= minBalance
    ///    - Check cooldown has elapsed
    ///    - Check Node has sufficient balance
    ///
    /// 2. **State Update:**
    ///    - Update lastExecuted timestamp
    ///
    /// 3. **Module Execution:**
    ///    - Approve module to spend tokens (exact amount)
    ///    - Call module.execute(token, amount, params)
    ///    - Handle success/failure
    ///    - Revoke approval on failure
    ///
    /// 4. **Result Handling:**
    ///    - If success: Emit ActionExecuted event, return true
    ///    - If failure: Revoke approval, return false (no revert)
    ///
    /// # Permissionless Execution
    /// Anyone can call this function:
    /// - Keeper bots (automated execution services)
    /// - Owner (manual triggers)
    /// - Users (self-service execution)
    /// - Smart contracts (composed automations)
    ///
    /// The executor address is recorded in ActionExecuted event for tracking.
    ///
    /// # Amount Parameter
    /// The `amount` parameter allows partial executions:
    /// - Can execute less than full balance
    /// - Must be >= minBalance (prevents dust)
    /// - Must be <= Node balance (validated)
    /// - Enables batching strategies (execute 50% now, 50% later)
    ///
    /// # Error Handling
    /// This function uses custom errors (reverts) for validation failures:
    /// - Node_TokenNotEnabled: Token is disabled
    /// - Node_NoActionConfigured: No configuration exists
    /// - Node_ZeroAmount: Amount is zero
    /// - Node_BelowMinimumBalance: Amount < minBalance
    /// - Node_CooldownNotElapsed: Cooldown period not finished
    /// - Node_InsufficientBalance: Node balance < amount
    ///
    /// Module execution failures return false instead of reverting.
    ///
    /// # Gas Considerations
    /// - Validation checks are optimized for early exit
    /// - Storage updates are minimized (only lastExecuted)
    /// - Module execution gas varies by module type
    /// - Failed executions consume less gas (no token transfers)
    ///
    /// # Reentrancy Protection
    /// - Function has nonReentrant modifier
    /// - Follows Check-Effects-Interactions pattern
    /// - State updates before external calls
    ///
    /// Requirements:
    /// - Token must be configured and enabled
    /// - amount must be > 0 and >= minBalance
    /// - Cooldown must have elapsed since lastExecuted
    /// - Node must have >= amount token balance
    ///
    /// Emits:
    /// - {ActionExecuted} if module execution succeeds
    ///
    /// @param token Token address to execute action for
    /// @param amount Amount to process (must be >= minBalance and <= balance)
    /// @return success True if module execution succeeded, false otherwise
    function executeAction(address token, uint256 amount) external returns (bool success);

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get full configuration for a token
    /// @dev Returns the complete TokenConfig struct with all parameters
    ///
    /// # Purpose
    /// Allows off-chain tools and contracts to query token configuration without parsing
    /// events. Useful for:
    /// - Frontends displaying configuration
    /// - Keeper bots checking if token is configured
    /// - Monitoring tools tracking configuration changes
    /// - Integration contracts validating settings
    ///
    /// # Return Value
    /// TokenConfig struct contains:
    /// - actionType (string): The action type identifier
    /// - actionModule (address): The module contract address
    /// - enabled (bool): Whether execution is allowed
    /// - minBalance (uint256): Minimum balance threshold
    /// - cooldownSeconds (uint256): Cooldown period
    /// - lastExecuted (uint256): Timestamp of last execution
    /// - moduleParams (bytes): ABI-encoded module parameters
    ///
    /// # Unconfigured Tokens
    /// If token is not configured, returns empty struct:
    /// - actionType = ""
    /// - actionModule = address(0)
    /// - enabled = false
    /// - All numeric fields = 0
    ///
    /// @param token Token address to query
    /// @return config Complete token configuration struct
    function getTokenConfig(address token) external view returns (DataTypes.TokenConfig memory config);

    /// @notice Get current token balance held by the Node contract
    /// @dev Convenience function that calls token.balanceOf(address(this))
    ///
    /// # Purpose
    /// Provides easy access to Node's token balance without requiring callers to:
    /// - Import IERC20 interface
    /// - Know Node contract address
    /// - Handle potential revert from malicious tokens
    ///
    /// # Usage
    /// Common use cases:
    /// - Check if balance >= minBalance before execution
    /// - Monitor Node holdings for accounting
    /// - Calculate how much can be executed
    /// - Verify tokens were received after transfer
    ///
    /// Notes:
    /// - This calls external token contract (may revert)
    /// - Malicious tokens could return fake balance
    /// - Assumes token implements ERC20.balanceOf() correctly
    ///
    /// @param token Token address to check balance of
    /// @return balance Current balance of token held by this Node
    function getTokenBalance(address token) external view returns (uint256 balance);

    /// @notice Preview execution outcome for a token action
    /// @dev Validates all execution requirements and estimates output in a single call
    /// @dev Follows ERC-4626 preview pattern for consistency with DeFi standards
    /// @dev Reverts with specific errors if execution would fail (see Errors.sol)
    /// @dev Returns estimated output and token address on success
    ///
    /// Reverts:
    /// - {Node_ZeroTokenAddress} if token is address(0)
    /// - {Node_NoActionConfigured} if no action configured for token
    /// - {Node_TokenNotEnabled} if token action is disabled
    /// - {Node_InvalidModule} if module is not a deployed contract
    /// - {Node_CooldownNotElapsed} if cooldown period has not elapsed
    /// - {Node_InsufficientBalance} if node balance is insufficient
    /// - {Node_BelowMinimumBalance} if balance is below minimum threshold
    ///
    /// @param token Token address to preview
    /// @return estimatedOutput Estimated output amount if execution succeeds
    /// @return outputToken Address of output token
    function previewExecution(address token)
        external
        view
        returns (uint256 estimatedOutput, address outputToken);
}
