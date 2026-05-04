// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title IActionModule
/// @notice Base interface for all action modules (Swap, Bridge, Forward)
/// @dev Modules are called by Node contracts to execute pre-configured actions on tokens
///
/// # Overview
/// IActionModule is the core abstraction that enables the Receivables Node system to support
/// pluggable action modules. Each module implements this interface to provide specialized
/// token operations (swapping, bridging, forwarding, staking, etc.).
///
/// # Architecture
/// The Node contract delegates execution to modules following this pattern:
/// 1. Node validates basic requirements (balance, cooldown, minAmount)
/// 2. Node calls module.validate() to check module-specific preconditions
/// 3. Node approves tokens to module
/// 4. Node calls module.execute() to perform the action
/// 5. Module returns ExecutionResult indicating success/failure
///
/// # Module Lifecycle
/// Modules are:
/// - Deployed independently by developers
/// - Registered in Node via configureToken() by Node owner
/// - Validated by calling moduleType() which must return non-empty string
/// - Called permissionlessly by anyone via Node.executeAction()
///
/// # Security Model
/// Modules operate under these security assumptions:
/// - Modules receive token approval from Node (exact amount only)
/// - Modules should NOT store state (remain stateless)
/// - Modules should validate all inputs in both validate() and execute()
/// - Modules should return ExecutionResult instead of reverting when possible
/// - Modules should revoke unused approvals on failure
///
/// # Implementing a Custom Module
/// To create a new module:
/// 1. Inherit from ActionModuleBase for common utilities
/// 2. Implement all IActionModule functions
/// 3. Define module-specific params struct in DataTypes
/// 4. Add encode/decode functions for params
/// 5. Implement validation logic in validate()
/// 6. Implement execution logic in execute()
/// 7. Implement output estimation in estimateOutput()
/// 8. Return unique string from moduleType()
///
/// Example modules:
/// - ForwardModule: Simple token transfer to recipient
/// - SwapModule: DEX swap with slippage protection (future)
/// - BridgeModule: Cross-chain token bridge (future)
interface IActionModule {
    /// @notice Execute the configured action for a token
    /// @dev Called by Node contract after validation and token approval
    ///
    /// # Execution Context
    /// When this function is called:
    /// - msg.sender is the Node contract
    /// - Node has approved this module to spend `amount` of `token`
    /// - Node has validated: balance, cooldown, minBalance, and called validate()
    /// - This module must transfer tokens from Node (using transferFrom)
    ///
    /// # Error Handling
    /// Modules should prefer returning ExecutionResult with success=false over reverting:
    /// - Reverting causes Node.executeAction() to return false (loses error context)
    /// - Returning success=false allows including reason in logs/monitoring
    /// - Both approaches are acceptable, but structured errors are preferred
    ///
    /// # State Changes
    /// On successful execution:
    /// - Tokens should be transferred from Node to destination/protocol
    /// - Return ExecutionResult with success=true and accurate output data
    ///
    /// On failed execution:
    /// - Revoke any unused token approvals
    /// - Return ExecutionResult with success=false and descriptive reason
    /// - OR revert with descriptive error message
    ///
    /// # Return Value
    /// ExecutionResult contains:
    /// - success: Whether the action completed successfully
    /// - amountOut: Actual output amount received (may differ from estimate)
    /// - outputToken: Address of output token (may differ from input for swaps)
    /// - data: Module-specific data (e.g., recipient address, transaction hash)
    ///
    /// Notes:
    /// - MUST be called by Node contract only (enforce via msg.sender checks if needed)
    /// - MUST NOT store state (modules should be stateless)
    /// - MUST return accurate amountOut and outputToken
    ///
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters (ABI encoded)
    /// @return result Execution result with success status and output details
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        returns (DataTypes.ExecutionResult memory result);

    /// @notice Validate if execution is safe/possible without executing
    /// @dev View function to check if execute() would succeed
    ///
    /// # Purpose
    /// This function performs pre-execution validation to determine if execute() would
    /// succeed. It's called by Node.previewExecution() to provide early failure feedback
    /// before attempting on-chain execution.
    ///
    /// # Validation Scope
    /// Modules should validate:
    /// - Module-specific parameters are valid (e.g., recipient not zero address)
    /// - Amount meets module-specific requirements (e.g., minAmount thresholds)
    /// - External conditions are favorable (e.g., sufficient liquidity for swap)
    /// - Any preconditions required for execute() to succeed
    ///
    /// Modules should NOT validate:
    /// - Token balance (Node validates this)
    /// - Cooldown period (Node validates this)
    /// - Token enabled status (Node validates this)
    ///
    /// # Return Values
    /// - isValid=true, reason="" → All module validations passed
    /// - isValid=false, reason="..." → Validation failed with human-readable reason
    ///
    /// # Usage Context
    /// Called by:
    /// - Node.previewExecution() → Provides preview of execution outcome
    /// - Off-chain scripts → Pre-flight checks before submitting transactions
    /// - Keeper bots → Determine if action is executable
    ///
    /// Notes:
    /// - MUST be a view function (no state changes)
    /// - MUST return same validation logic as execute()
    /// - Should return descriptive reasons for off-chain debugging
    /// - May perform external view calls to check conditions (e.g., DEX liquidity)
    ///
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters
    /// @return isValid Whether execution would succeed
    /// @return reason Reason if invalid (empty string if valid)
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        returns (bool isValid, string memory reason);

    /// @notice Estimate output amount for an action
    /// @dev Provides expected output for off-chain monitoring and preview
    ///
    /// # Purpose
    /// This function estimates the output that would be received if execute() were called
    /// with the same parameters. It's used for preview functionality and off-chain monitoring.
    ///
    /// # Estimation Approach
    /// Different module types calculate estimates differently:
    ///
    /// **Forward Module:**
    /// - Output = Input (1:1 transfer, no conversion)
    /// - outputToken = token (same token)
    ///
    /// **Swap Module:**
    /// - Query DEX price oracle for current exchange rate
    /// - Apply slippage tolerance from params
    /// - outputToken = different token from swap pair
    ///
    /// **Bridge Module:**
    /// - Subtract bridge fees from amount
    /// - Account for destination chain gas costs
    /// - outputToken = wrapped/canonical token on destination chain
    ///
    /// # Accuracy Considerations
    /// Estimates may differ from actual execution due to:
    /// - Price slippage (market moves between estimate and execution)
    /// - Network congestion (gas prices affect profitability)
    /// - Liquidity changes (available liquidity decreases)
    /// - Front-running (MEV extractors take value)
    ///
    /// # Usage Context
    /// Called by:
    /// - Node.previewExecution() → Shows expected output to users
    /// - Frontends → Display estimated amounts before execution
    /// - Keeper bots → Calculate profitability and prioritize actions
    ///
    /// Notes:
    /// - Should be view or pure function (no state changes)
    /// - May perform external view calls (e.g., to price oracles)
    /// - Should return best-effort estimate (not guaranteed)
    /// - For constant-output modules (forward), can be pure function
    ///
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters
    /// @return estimatedOutput Estimated output amount
    /// @return outputToken Address of output token
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        returns (uint256 estimatedOutput, address outputToken);

    /// @notice Get human-readable identifier for this module type
    /// @dev Returns a constant string identifying the module implementation
    ///
    /// # Purpose
    /// The module type string serves multiple critical purposes:
    /// 1. **Validation**: Node.configureToken() calls this to verify module is valid
    /// 2. **Identification**: Used in events and logs to track which module executed
    /// 3. **Discovery**: Off-chain indexers use this to categorize actions
    /// 4. **Configuration**: Matches actionType parameter in Node.configureToken()
    ///
    /// # Conventions
    /// - Use UPPERCASE for consistency (e.g., "FORWARD", "SWAP", "BRIDGE")
    /// - Use descriptive single words or abbreviations
    /// - Must return non-empty string (validated by Node)
    /// - Should be constant for the module (never change)
    ///
    /// # Examples
    /// - ForwardModule → "FORWARD"
    /// - SwapModule → "SWAP"
    /// - BridgeModule → "BRIDGE"
    /// - StakingModule → "STAKE"
    /// - CompoundModule → "COMPOUND"
    ///
    /// Notes:
    /// - MUST be pure function (no state access)
    /// - MUST return non-empty string
    /// - Should match actionType used in Node configuration
    ///
    /// @return Module type identifier string (e.g., "FORWARD", "SWAP", "BRIDGE")
    function moduleType() external pure returns (string memory);
}
