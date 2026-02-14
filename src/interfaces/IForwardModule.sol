// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";

/// @title IForwardModule
/// @notice Interface for modules that forward tokens to a destination address
/// @dev Implements IActionModule for simple token transfers
interface IForwardModule is IActionModule {
    /// @notice Forward configuration parameters
    /// @dev Encoded into bytes and passed to execute()
    struct ForwardParams {
        address recipient;              // Destination address for tokens
        bool requireSuccessfulReceipt;  // Whether to revert if recipient cannot receive
        uint256 minAmount;              // Minimum amount required to forward (0 = no minimum)
    }

    /// @notice Encode forward parameters into bytes
    /// @param params Forward parameters to encode
    /// @return Encoded parameters
    function encodeParams(ForwardParams calldata params) external pure returns (bytes memory);

    /// @notice Decode forward parameters from bytes
    /// @param encoded Encoded parameters
    /// @return params Decoded forward parameters
    function decodeParams(bytes calldata encoded) external pure returns (ForwardParams memory params);
}
