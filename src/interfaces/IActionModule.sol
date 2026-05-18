// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title IActionModule
/// @notice Base interface for all action modules (Swap, Bridge, Forward)
/// @dev Modules are called by PaymentRails contracts to execute pre-configured actions on tokens
///
/// # Overview
/// IActionModule is the core abstraction that enables the Receivables PaymentRails system to support
/// pluggable action modules. Each module implements this interface to provide specialized
/// token operations (swapping, bridging, forwarding, staking, etc.).
///
/// # Architecture
/// The PaymentRails contract delegates execution to modules following this pattern:
/// 1. PaymentRails validates basic requirements (balance, cooldown, minAmount)
/// 2. PaymentRails calls module.validate() to check module-specific preconditions
/// 3. PaymentRails approves tokens to module
/// 4. PaymentRails calls module.execute() to perform the action
/// 5. Module returns ExecutionResult indicating success/failure
///
/// # Module Lifecycle
/// Modules are:
/// - Deployed independently by developers
/// - Registered in PaymentRails via configureToken() by PaymentRails owner
/// - Validated by calling moduleType() which must return non-empty string
/// - Called permissionlessly by anyone via PaymentRails.executeAction()
///
/// # Security Model
/// Modules operate under these security assumptions:
/// - Modules receive token approval from PaymentRails (exact amount only)
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
/// - DexSwapModule: Atomic swap via whitelisted DEX routers
/// - CowSwapModule: Async order-book swap via CowSwap
/// - CCTPBridgeModule: Cross-chain USDC bridge via CCTP
interface IActionModule {
    /// @notice Execute the configured action for a token
    /// @dev Called by PaymentRails contract after validation and token approval
    ///
    /// # Execution Context
    /// When this function is called:
    /// - msg.sender is the PaymentRails contract
    /// - PaymentRails has approved this module to spend `amount` of `token`
    /// - PaymentRails has validated: balance, cooldown, minBalance, and called validate()
    /// - This module must transfer tokens from PaymentRails (using transferFrom)
    ///
    /// # Error Handling
    /// Modules should prefer returning ExecutionResult with success=false over reverting:
    /// - Reverting causes PaymentRails.executeAction() to return false (loses error context)
    /// - Returning success=false allows including reason in logs/monitoring
    /// - Both approaches are acceptable, but structured errors are preferred
    ///
    /// # State Changes
    /// On successful execution:
    /// - Tokens should be transferred from PaymentRails to destination/protocol
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
    /// - MUST be called by PaymentRails contract only (enforce via msg.sender checks if needed)
    /// - MUST NOT store state (modules should be stateless)
    /// - MUST return accurate amountOut and outputToken
    ///
    /// @param token The input token address
    /// @param amount The amount of tokens to process
    /// @param params Module-specific parameters (ABI encoded)
    /// @param executionData Dynamic per-execution data (ABI encoded). Modules that only need
    ///        static configuration ignore this field (it will be empty bytes). Modules that
    ///        require fresh data per execution (e.g., swap calldata) decode and
    ///        validate it against the static constraints in `params`.
    /// @return result Execution result with success status and output details
    function execute(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        returns (DataTypes.ExecutionResult memory result);

    /// @notice Validate if execution is safe/possible without executing
    /// @dev View function to check if execute() would succeed
    ///
    /// # Purpose
    /// This function performs pre-execution validation to determine if execute() would
    /// succeed. It's called by PaymentRails.previewExecution() to provide early failure feedback
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
    /// - Token balance (PaymentRails validates this)
    /// - Cooldown period (PaymentRails validates this)
    /// - Token enabled status (PaymentRails validates this)
    ///
    /// # Return Values
    /// - isValid=true, reason="" → All module validations passed
    /// - isValid=false, reason="..." → Validation failed with human-readable reason
    ///
    /// # Usage Context
    /// Called by:
    /// - PaymentRails.previewExecution() → Provides preview of execution outcome
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
    /// @param executionData Dynamic per-execution data (may be empty for preview/pre-flight).
    ///        When non-empty, modules should validate its contents against static constraints.
    /// @return isValid Whether execution would succeed
    /// @return reason Reason if invalid (empty string if valid)
    function validate(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
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
    /// - PaymentRails.previewExecution() → Shows expected output to users
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
    /// 1. **Validation**: PaymentRails.configureToken() calls this to verify module is valid
    /// 2. **Identification**: Used in events and logs to track which module executed
    /// 3. **Discovery**: Off-chain indexers use this to categorize actions
    /// 4. **Configuration**: Matches actionType parameter in PaymentRails.configureToken()
    ///
    /// # Conventions
    /// - Use UPPERCASE for consistency (e.g., "FORWARD", "SWAP", "BRIDGE")
    /// - Use descriptive single words or abbreviations
    /// - Must return non-empty string (validated by PaymentRails)
    /// - Should be constant for the module (never change)
    ///
    /// # Examples
    /// - ForwardModule → "FORWARD"
    /// - DexSwapModule → "SWAP"
    /// - CCTPBridgeModule → "BRIDGE"
    /// - StakingModule → "STAKE"
    /// - CompoundModule → "COMPOUND"
    ///
    /// Notes:
    /// - MUST be pure function (no state access)
    /// - MUST return non-empty string
    /// - Should match actionType used in PaymentRails configuration
    ///
    /// @return Module type identifier string (e.g., "FORWARD", "SWAP", "BRIDGE")
    function moduleType() external pure returns (string memory);
}
