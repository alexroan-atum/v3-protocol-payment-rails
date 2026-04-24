// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title ITokenMessengerV2
/// @notice Minimal interface for Circle's TokenMessengerV2 (CCTP V2).
/// @dev Only includes the two functions our CCTPBridgeModule calls: `depositForBurn` and
///      `depositForBurnWithHook`. Full specification lives in Circle's repository:
///      https://github.com/circlefin/evm-cctp-contracts
interface ITokenMessengerV2 {
    /// @notice Burns tokens on the source chain and triggers a mint on the destination domain.
    /// @param amount             Amount of tokens to burn (USDC, 6 decimals).
    /// @param destinationDomain  CCTP domain ID of the destination chain.
    /// @param mintRecipient      Recipient on destination chain, left-padded to bytes32.
    /// @param burnToken          Address of the token to burn on this chain.
    /// @param destinationCaller  Address allowed to call `receiveMessage` on the destination.
    ///                           `bytes32(0)` = anyone.
    /// @param maxFee             Maximum fee in burn-token units. 0 = standard transfer only.
    /// @param minFinalityThreshold 1000 for fast (confirmed), 2000 for standard (finalized).
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /// @notice Burns tokens with hook data for destination-side post-mint automation.
    /// @dev Identical to `depositForBurn` but attaches opaque `hookData` that CCTP delivers to the
    ///      destination chain. Reverts if `hookData` is empty.
    /// @param amount             Amount of tokens to burn.
    /// @param destinationDomain  CCTP domain ID of the destination chain.
    /// @param mintRecipient      Recipient on destination chain, left-padded to bytes32.
    /// @param burnToken          Address of the token to burn on this chain.
    /// @param destinationCaller  Address allowed to call `receiveMessage` on the destination.
    /// @param maxFee             Maximum fee in burn-token units.
    /// @param minFinalityThreshold 1000 for fast, 2000 for standard.
    /// @param hookData           Arbitrary bytes for destination-chain processing. Must be non-empty.
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}
