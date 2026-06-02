// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ICCTPBridgeModule
/// @author Credit Cooperative
/// @notice Interface for the CCTP V2 bridge module that burns USDC on the source chain for minting
///         on a destination chain.
/// @dev Stateless module — all routing parameters live in PaymentRails's `moduleParams`. A single
///      instance may be shared across multiple PaymentRails without cross-contamination.
///
///      Lifecycle:
///        1. PaymentRails owner calls `configureToken(usdc, "CCTP_BRIDGE", module, ..., encodedParams, true)`.
///        2. Anyone calls `PaymentRails.executeAction(usdc, amount)` → module pulls USDC, calls
///           `depositForBurn` (or `depositForBurnWithHook`), USDC is burned atomically.
///        3. Off-chain relay fetches attestation from Circle's Iris API and calls
///           `MessageTransmitterV2.receiveMessage()` on the destination chain.
///        4. USDC is minted to the configured `mintRecipient` on the destination chain.
interface ICCTPBridgeModule is IActionModule {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a CCTP bridge transfer is initiated (USDC burned on source chain).
    /// @param paymentRails         The PaymentRails contract that initiated the bridge.
    /// @param amount               The amount of USDC burned.
    /// @param destinationDomain    CCTP domain ID of the destination chain.
    /// @param mintRecipient        Recipient address on the destination chain (bytes32-encoded).
    /// @param maxFee               Computed fee ceiling passed to Circle (amount × maxFeeBps / 10_000).
    /// @param minFinalityThreshold 1000 (fast) or 2000 (standard).
    /// @param hookData             Hook data passed to destination (empty if no hook).
    event BridgeInitiated(
        address indexed paymentRails,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes hookData
    );

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Address of Circle's TokenMessengerV2 contract on this chain.
    function tokenMessenger() external view returns (address);

    /// @notice Address of USDC on this chain.
    function usdc() external view returns (address);

    /// @notice ABI-encodes a {CCTPBridgeParams} struct into bytes for `PaymentRails.configureToken()`.
    /// @param params   Typed struct containing all routing parameters.
    /// @return encoded ABI-encoded bytes.
    function encodeParams(DataTypes.CCTPBridgeParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {CCTPBridgeParams} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeParams()`.
    /// @return params Decoded struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.CCTPBridgeParams memory params);
}
