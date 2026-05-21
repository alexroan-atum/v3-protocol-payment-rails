// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { DataTypes } from "../types/DataTypes.sol";

/// @title IActionModule
/// @notice Base interface for all action modules in the PaymentRails system.
/// @dev Modules are called by {PaymentRails} to execute pre-configured token actions (swap, bridge,
/// forward, etc.). The PaymentRails validates preconditions, approves tokens to the module, and calls
/// {execute}. Modules return {DataTypes.ExecutionResult} indicating success or failure.
///
/// All execution parameters are owner-configured in the static `params` — the permissionless
/// executor supplies nothing beyond `(token, amount)`. This design eliminates caller-controlled
/// attack surfaces at the architecture level.
///
/// Synchronous modules (ForwardModule, DexSwapModule) should remain stateless. Asynchronous modules
/// (CowSwapModule) may store order metadata for lifecycle tracking.
///
/// Notes:
/// - Modules receive exact-amount token approval from PaymentRails.
/// - {PaymentRails.previewExecution} calls {validate} for dry-run checks; the {PaymentRails.executeAction}
///   path does NOT call {validate} — only {execute}.
/// - Modules should return {DataTypes.ExecutionResult} with `success = false` instead of reverting
///   when possible.
interface IActionModule {
    /// @notice Execute the configured action for a token.
    /// @dev Called by PaymentRails after validation and token approval. The module must transfer tokens
    /// from PaymentRails (msg.sender) using `transferFrom`.
    ///
    /// Notes:
    /// - `msg.sender` is always the PaymentRails contract.
    /// - PaymentRails has approved this module to spend exactly `amount` of `token`.
    /// - Prefer returning `ExecutionResult` with `success = false` over reverting.
    ///
    /// @param token The input token address.
    /// @param amount The amount of tokens to process.
    /// @param params Module-specific parameters (ABI-encoded via the module's `encodeParams`).
    /// @return result Execution result with success status and output details.
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        returns (DataTypes.ExecutionResult memory result);

    /// @notice Validate whether execution would succeed without modifying state.
    /// @dev Called by {PaymentRails.previewExecution} for pre-flight checks. Modules should validate
    /// their own parameters and preconditions but NOT token balance or enabled status (PaymentRails
    /// handles those).
    ///
    /// Notes:
    /// - Must be a view function.
    /// - Should mirror the validation logic in {execute}.
    ///
    /// @param token The input token address.
    /// @param amount The amount of tokens to process.
    /// @param params Module-specific parameters.
    /// @return isValid Whether execution would succeed.
    /// @return reason Human-readable reason if invalid (empty string if valid).
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        returns (bool isValid, string memory reason);

    /// @notice Estimate the output amount for an action.
    /// @dev Called by {PaymentRails.previewExecution} to show expected output. Estimates may differ from
    /// actual execution due to price slippage, liquidity changes, or fees.
    ///
    /// Notes:
    /// - Should be a view or pure function.
    /// - For constant-output modules (forward), output equals input.
    ///
    /// @param token The input token address.
    /// @param amount The amount of tokens to process.
    /// @param params Module-specific parameters.
    /// @return estimatedOutput Estimated output amount.
    /// @return outputToken Address of the output token.
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        returns (uint256 estimatedOutput, address outputToken);

    /// @notice Returns a human-readable identifier for this module type (e.g., "FORWARD", "SWAP",
    /// "BRIDGE").
    /// @dev Used by {PaymentRails.configureToken} to validate the module. Must return a non-empty string.
    ///
    /// @return Module type identifier string.
    function moduleType() external pure returns (string memory);
}
