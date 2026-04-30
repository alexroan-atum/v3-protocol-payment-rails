// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IForwardModule
/// @notice Interface for modules that forward tokens to a destination address
/// @dev Implements IActionModule for simple token transfers
///
/// # Overview
/// IForwardModule extends IActionModule with forward-specific functionality for encoding
/// and decoding ForwardParams. This interface is implemented by ForwardModule, which
/// performs direct ERC20 token transfers from Node to a configured recipient.
///
/// # Use Cases
/// - Treasury sweeps (forwarding revenue to multisig)
/// - Beneficiary distributions (sending tokens to recipients)
/// - Operational transfers (moving tokens between wallets)
/// - Simple payment flows (automated disbursements)
///
/// # Parameters
/// Forward operations use ForwardParams struct:
/// - `recipient`: Destination address for tokens
/// - `requireSuccessfulReceipt`: Future validation flag (not yet implemented)
/// - `minAmount`: Minimum transfer amount (prevents dust transfers)
///
/// # Encoding/Decoding
/// This interface provides helpers for working with ForwardParams:
/// - encodeParams(): Convert ForwardParams struct to bytes for Node.configureToken()
/// - decodeParams(): Convert bytes back to ForwardParams for module logic
///
/// These functions ensure consistent serialization across integrations.
interface IForwardModule is IActionModule {
    /// @notice Encode forward parameters into ABI-encoded bytes
    /// @dev Helper function for constructing moduleParams when configuring tokens
    ///
    /// # Usage
    /// Call this when configuring a token in Node:
    /// ```solidity
    /// ForwardParams memory params = ForwardParams({
    ///     recipient: treasuryAddress,
    ///     requireSuccessfulReceipt: false,
    ///     minAmount: 100e18
    /// });
    /// bytes memory encoded = forwardModule.encodeParams(params);
    /// node.configureToken(
    ///     tokenAddress,
    ///     "FORWARD",
    ///     address(forwardModule),
    ///     minBalance,
    ///     cooldown,
    ///     encoded,  // ← Use encoded params here
    ///     true
    /// );
    /// ```
    ///
    /// Notes:
    /// - Pure function (no state access)
    /// - Returns ABI-encoded (address, bool, uint256)
    /// - Must match decoding format in decodeParams()
    ///
    /// @param params Forward parameters to encode
    /// @return ABI-encoded bytes representation
    function encodeParams(DataTypes.ForwardParams calldata params) external pure returns (bytes memory);

    /// @notice Decode ABI-encoded bytes into ForwardParams struct
    /// @dev Extracts forward configuration from generic bytes parameter
    ///
    /// # Usage
    /// Called internally by ForwardModule functions to access configuration:
    /// ```solidity
    /// function execute(address token, uint256 amount, bytes calldata params) external {
    ///     ForwardParams memory forwardParams = decodeParams(params);
    ///     // Use forwardParams.recipient, forwardParams.minAmount, etc.
    /// }
    /// ```
    ///
    /// # Error Handling
    /// - Reverts if bytes are not valid ABI-encoded (address, bool, uint256)
    /// - Reverts if bytes length is incorrect
    /// - Caller should handle decode failures gracefully
    ///
    /// Notes:
    /// - Pure function (no state access)
    /// - Public visibility for external tools/integrations
    /// - Inverse of encodeParams()
    ///
    /// @param encoded ABI-encoded parameter bytes
    /// @return params Decoded ForwardParams struct
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.ForwardParams memory params);
}
