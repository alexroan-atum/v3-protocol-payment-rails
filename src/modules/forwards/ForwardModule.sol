// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IForwardModule } from "../../interfaces/IForwardModule.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ForwardModule
/// @author Credit Cooperative
/// @notice Module for forwarding tokens to a destination address
/// @dev Implements simple token transfer functionality using ActionModuleBase
///
/// # Overview
/// The ForwardModule is the simplest action module in the Receivables Node system. It performs
/// direct ERC20 token transfers from the Node contract to a specified recipient address.
///
/// # Use Cases
/// - Forwarding collected receivables to a treasury or multisig
/// - Distributing tokens to beneficiaries
/// - Moving tokens between operational wallets
/// - Sweeping accumulated tokens to a central address
///
/// # Architecture
/// - Inherits from ActionModuleBase for common validation and transfer utilities
/// - Implements IForwardModule for encoding/decoding parameters
/// - Implements IActionModule for execution, validation, and estimation
///
/// # Parameters
/// Forward operations are configured with ForwardParams:
/// - `recipient`: Destination address for forwarded tokens
/// - `requireSuccessfulReceipt`: Flag for validating recipient (future extension)
/// - `minAmount`: Minimum amount required to execute forward (prevents dust)
///
/// # Security Model
/// - Validates recipient is not zero address
/// - Validates amount meets minimum threshold
/// - Validates Node has sufficient token balance
/// - Uses safe transfer pattern from ActionModuleBase
/// - Returns structured results (never reverts) for graceful error handling
///
/// # Gas Optimization
/// - Decodes parameters once per function
/// - Uses pure functions where possible
/// - Minimal storage operations (stateless module)
/// - Direct transfer without intermediate steps
contract ForwardModule is IForwardModule, ActionModuleBase {

    /*//////////////////////////////////////////////////////////////////////////
                        USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ActionModuleBase
    /// @notice Executes a token forward operation from the Node to a recipient
    /// @dev This function performs validation and transfers tokens in a single atomic operation
    ///
    /// # Execution Flow
    /// 1. Decode forward parameters
    /// 2. Validate recipient address (must not be zero)
    /// 3. Validate amount meets minimum threshold
    /// 4. Validate Node has sufficient balance
    /// 5. Transfer tokens from Node (msg.sender) to recipient
    /// 6. Return structured result (success or failure with reason)
    ///
    /// # Security Notes
    /// - Only callable by Node contract (msg.sender is checked via _safeTransferFrom)
    /// - Does NOT revert on failure - returns ExecutionResult with success=false
    /// - Validates all inputs before state changes
    /// - Uses SafeERC20 pattern via ActionModuleBase helpers
    ///
    /// # Return Value
    /// Returns ExecutionResult containing:
    /// - success: Whether transfer completed successfully
    /// - amountOut: Amount transferred (equals amountIn for forward)
    /// - outputToken: Token address (same as input for forward)
    /// - data: ABI-encoded recipient address for tracking
    ///
    /// Requirements:
    /// - `token` must be a valid ERC20 contract
    /// - `amount` must be >= minAmount from params
    /// - Node (msg.sender) must have >= amount balance
    /// - `params.recipient` must not be address(0)
    ///
    /// @param token The ERC20 token address to forward
    /// @param amount The exact amount of tokens to forward
    /// @param params ABI-encoded ForwardParams (recipient, requireSuccessfulReceipt, minAmount)
    /// @return result Execution result with success status, amounts, and recipient data
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external override(ActionModuleBase, IActionModule) returns (DataTypes.ExecutionResult memory result) {
        // Step 1: Decode configuration parameters
        // Convert generic bytes calldata into typed ForwardParams struct
        DataTypes.ForwardParams memory forwardParams = decodeParams(params);

        // Step 2: Validate recipient address
        // Ensures tokens won't be sent to zero address (lost forever)
        // Uses helper from ActionModuleBase for consistent validation
        if (!_isValidAddress(forwardParams.recipient)) {
            return _failedResult(token, "Zero recipient address");
        }

        // Step 3: Validate minimum amount threshold
        // Prevents execution of dust amounts that waste gas
        // minAmount=0 disables this check (allows any amount)
        if (amount < forwardParams.minAmount) {
            return _failedResult(token, "Amount below minimum");
        }

        // Step 4: Verify Node has sufficient token balance
        // Prevents attempting transfer that would fail on-chain
        // Note: msg.sender is the Node contract in this context
        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        // Step 5: Execute token transfer
        // Transfer from Node (msg.sender) to configured recipient
        // Uses SafeERC20 pattern via ActionModuleBase helper
        // Returns false on failure instead of reverting
        bool transferSuccess = _safeTransferFrom(token, msg.sender, forwardParams.recipient, amount);

        // Step 6: Handle transfer failure
        // If transfer failed, return structured error result
        // Node will handle this gracefully (no revert)
        if (!transferSuccess) {
            return _failedResult(token, "Transfer failed");
        }

        // Step 7: Return success result
        // Include recipient in data field for event tracking
        // amountOut = amount (1:1 transfer, no slippage)
        // outputToken = token (same token, no conversion)
        return _successResult(amount, token, abi.encode(forwardParams.recipient));
    }

    /*//////////////////////////////////////////////////////////////////////////
                        USER-FACING CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ActionModuleBase
    /// @notice Validates whether a forward operation can be executed
    /// @dev Performs all pre-execution checks without modifying state
    ///
    /// # Validation Checks
    /// 1. Recipient address is not zero
    /// 2. Amount meets minimum threshold (params.minAmount)
    /// 3. Node has sufficient token balance
    ///
    /// # Usage Context
    /// - Called by Node.previewExecution() to validate before execution
    /// - Called internally during execute() flow
    /// - Can be called off-chain via eth_call for pre-flight checks
    ///
    /// # Return Values
    /// Returns tuple (isValid, reason):
    /// - isValid=true, reason="" → All checks passed, execution will succeed
    /// - isValid=false, reason="..." → Validation failed with human-readable reason
    ///
    /// Notes:
    /// - Pure view function (no state changes)
    /// - Same validation logic as execute()
    /// - Does NOT validate token contract exists (Node's responsibility)
    ///
    /// @param token The ERC20 token address to validate
    /// @param amount The amount to validate
    /// @param params ABI-encoded ForwardParams
    /// @return isValid True if all validations pass, false otherwise
    /// @return reason Human-readable reason if validation fails, empty string if valid
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view override(ActionModuleBase, IActionModule) returns (bool isValid, string memory reason) {
        // Step 1: Decode configuration parameters
        DataTypes.ForwardParams memory forwardParams = decodeParams(params);

        // Step 2: Check recipient is valid (not zero address)
        // Same validation as execute() for consistency
        if (!_isValidAddress(forwardParams.recipient)) {
            return (false, "Zero recipient address");
        }

        // Step 3: Check amount meets minimum threshold
        // Same validation as execute() for consistency
        if (amount < forwardParams.minAmount) {
            return (false, "Amount below minimum");
        }

        // Step 4: Check Node has sufficient balance
        // Same validation as execute() for consistency
        // Note: This checks msg.sender's balance, which is Node when called from previewExecution
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance");
        }

        // All validations passed - execution will succeed
        return (true, "");
    }

    /// @inheritdoc ActionModuleBase
    /// @notice Estimates the output of a forward operation
    /// @dev For forward operations, output always equals input (1:1 transfer ratio)
    ///
    /// # Output Calculation
    /// Unlike swap or bridge modules, forward has no slippage, fees, or conversion:
    /// - estimatedOutput = amount (exact amount)
    /// - outputToken = token (same token)
    ///
    /// # Usage Context
    /// - Called by Node.previewExecution() to show expected output
    /// - Used by frontends to display transfer amounts
    /// - Used by keeper bots to calculate profitability
    ///
    /// Notes:
    /// - Pure function (no state access, maximum gas efficiency)
    /// - Params parameter is not used (forward has no configuration affecting output)
    /// - Always returns exact input values (no estimation error)
    ///
    /// @param token The ERC20 token address
    /// @param amount The input amount
    /// @return estimatedOutput The expected output amount (always equals amount)
    /// @return outputToken The output token address (always equals token)
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata /* params */
    ) external pure override(ActionModuleBase, IActionModule) returns (uint256 estimatedOutput, address outputToken) {
        // For forward, output equals input (1:1 transfer)
        return (amount, token);
    }

    /// @inheritdoc ActionModuleBase
    /// @notice Returns the module type identifier
    /// @dev Returns "FORWARD" constant for this module implementation
    ///
    /// # Module Type System
    /// The module type string serves multiple purposes:
    /// - Identifies the module in Node configuration
    /// - Used in ActionExecuted events for tracking
    /// - Validates module implements required interface
    /// - Enables dynamic module discovery
    ///
    /// Notes:
    /// - Must return non-empty string (validated by Node.configureToken)
    /// - Convention: Use UPPERCASE for module types
    /// - Must match actionType parameter in Node.configureToken()
    ///
    /// @return The module type string "FORWARD"
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "FORWARD";
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FORWARD-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IForwardModule
    /// @notice Encodes forward parameters into ABI-encoded bytes
    /// @dev Encodes in order: recipient, requireSuccessfulReceipt, minAmount
    ///
    /// # Encoding Format
    /// The parameters are ABI-encoded as (address, bool, uint256):
    /// - recipient: Destination address for forwarded tokens
    /// - requireSuccessfulReceipt: Flag for validating receipt (future extension)
    /// - minAmount: Minimum amount required to execute
    ///
    /// # Usage Context
    /// Called when configuring a token in Node:
    /// ```solidity
    /// ForwardParams memory params = ForwardParams({
    ///     recipient: treasuryAddress,
    ///     requireSuccessfulReceipt: false,
    ///     minAmount: 100 * 10**18
    /// });
    /// bytes memory encodedParams = forwardModule.encodeParams(params);
    /// node.configureToken(token, "FORWARD", address(forwardModule), ..., encodedParams, true);
    /// ```
    ///
    /// Notes:
    /// - Pure function (no state access)
    /// - Inverse of decodeParams()
    /// - Must encode in same order as decodeParams expects
    ///
    /// @param params The ForwardParams struct to encode
    /// @return ABI-encoded bytes representation of the parameters
    function encodeParams(DataTypes.ForwardParams calldata params) external pure returns (bytes memory) {
        return abi.encode(params.recipient, params.requireSuccessfulReceipt, params.minAmount);
    }

    /// @inheritdoc IForwardModule
    /// @notice Decodes ABI-encoded bytes into ForwardParams struct
    /// @dev Decodes in order: recipient, requireSuccessfulReceipt, minAmount
    ///
    /// # Decoding Format
    /// Expects ABI-encoded (address, bool, uint256) bytes:
    /// - Position 0: recipient address
    /// - Position 1: requireSuccessfulReceipt boolean
    /// - Position 2: minAmount uint256
    ///
    /// # Usage Context
    /// Called internally by execute(), validate(), and other functions to extract
    /// configuration from the generic bytes parameter.
    ///
    /// # Error Handling
    /// - Will revert if encoded data doesn't match expected types
    /// - Will revert if encoded data is too short
    /// - Caller should handle decode failures gracefully
    ///
    /// Notes:
    /// - Pure function (no state access)
    /// - Inverse of encodeParams()
    /// - Public visibility for external integrations
    ///
    /// @param encoded The ABI-encoded parameter bytes
    /// @return params The decoded ForwardParams struct
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.ForwardParams memory params) {
        (params.recipient, params.requireSuccessfulReceipt, params.minAmount) = abi.decode(
            encoded,
            (address, bool, uint256)
        );
    }
}
