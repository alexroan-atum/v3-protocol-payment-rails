// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title IGPv2Settlement
/// @notice Minimal interface for the CoW Protocol GPv2Settlement contract.
/// @dev Only the functions required by {CowSwapModule} are included. For the full interface, see
/// https://github.com/cowprotocol/contracts/blob/main/src/contracts/GPv2Settlement.sol
interface IGPv2Settlement {
    /// @notice Returns the EIP-712 domain separator used to hash CowSwap orders.
    function domainSeparator() external view returns (bytes32);

    /// @notice Returns the address of the GPv2VaultRelayer that pulls tokens during settlement.
    /// @dev ERC-20 approvals must target this address, NOT the settlement contract itself.
    function vaultRelayer() external view returns (address);

    /// @notice Returns how much of an order has been filled.
    /// @dev For SELL orders, returns the cumulative sellAmount filled by solvers. Returns 0 for unknown
    /// orders. CowSwap solvers may free this storage slot after order expiry to reclaim gas.
    /// @param orderUid The 56-byte order UID: digest (32) ++ owner (20) ++ validTo (4).
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}
