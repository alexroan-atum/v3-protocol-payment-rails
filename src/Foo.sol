// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29;

/// @title Foo
/// @author Credit Cooperative
/// @notice Example contract demonstrating basic functionality
contract Foo {
    /// @notice Returns the input value unchanged
    /// @param value The value to echo
    /// @return The same value that was input
    function echo(uint256 value) external pure returns (uint256) {
        return value;
    }
}
