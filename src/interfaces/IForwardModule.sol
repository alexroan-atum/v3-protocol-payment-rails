// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IForwardModule
/// @notice Interface for modules that forward tokens to a destination address.
/// @dev Extends {IActionModule} with forward-specific helpers for encoding and decoding
/// {DataTypes.ForwardParams}. Implemented by ForwardModule, which performs direct ERC-20 transfers
/// from PaymentRails to a configured recipient.
interface IForwardModule is IActionModule {
    /// @notice ABI-encodes a {DataTypes.ForwardParams} struct into bytes for
    /// {IPaymentRails.configureToken}.
    ///
    /// Notes:
    /// - Pure function (no state access).
    /// - Inverse of {decodeParams}.
    ///
    /// @param params Forward parameters to encode.
    /// @return ABI-encoded bytes representation.
    function encodeParams(DataTypes.ForwardParams calldata params) external pure returns (bytes memory);

    /// @notice Decodes ABI-encoded bytes into a {DataTypes.ForwardParams} struct.
    ///
    /// Notes:
    /// - Pure function (no state access).
    /// - Inverse of {encodeParams}.
    /// - Reverts if the bytes are not valid ABI-encoded `(address, uint256)`.
    ///
    /// @param encoded ABI-encoded parameter bytes.
    /// @return params Decoded ForwardParams struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.ForwardParams memory params);
}
