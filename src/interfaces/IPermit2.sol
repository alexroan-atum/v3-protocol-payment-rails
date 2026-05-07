// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IPermit2
/// @notice Minimal Permit2 surface required by AtumModule.
interface IPermit2 {
    /// @notice Returns Permit2's EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
