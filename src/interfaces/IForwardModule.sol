// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IForwardModule
/// @notice Interface for modules that forward tokens to a destination address
/// @dev Implements IActionModule for simple token transfers
interface IForwardModule is IActionModule {

    /// @notice Encode forward parameters into bytes
    /// @param params Forward parameters to encode
    /// @return Encoded parameters
    function encodeParams(DataTypes.ForwardParams calldata params) external pure returns (bytes memory);

    /// @notice Decode forward parameters from bytes
    /// @param encoded Encoded parameters
    /// @return params Decoded forward parameters
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.ForwardParams memory params);
}
