// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ICCTPBridgeModule
/// @author Credit Cooperative
/// @notice Interface for the CCTP V2 bridge module that burns USDC on the source chain for minting
///         on a destination chain.
/// @dev Extends {IActionModule} with Circle CCTP V2 integration for cross-chain USDC transfers using
///      the burn-and-mint mechanism.
///
/// Lifecycle:
///
///   1. Owner calls `setDomainConfig()` to configure one or more destination domains with routing
///      parameters (recipient, fee, speed, optional hook data).
///   2. Node owner calls `Node.configureToken(usdc, "CCTP_BRIDGE", module, ..., encodedDomain, true)`
///      where `encodedDomain` is the ABI-encoded `CCTPBridgeParams` containing only the destination
///      domain ID.
///   3. Anyone calls `Node.executeAction(usdc, amount)`:
///      a. Node approves the module and calls `execute()`.
///      b. Module pulls USDC from Node, approves TokenMessengerV2, and calls `depositForBurn()`
///         (or `depositForBurnWithHook()` when hook data is present).
///      c. USDC is burned atomically. Module emits {BridgeInitiated}.
///   4. Off-chain relay bot fetches the attestation from Circle's Iris API and calls
///      `MessageTransmitterV2.receiveMessage()` on the destination chain.
///   5. Fresh USDC is minted to the configured `mintRecipient` on the destination chain.
///
/// Deployment model: a single instance may be shared across multiple Nodes that bridge to the same
/// destinations, since the module does not store per-Node state.
///
/// Configuration model (two-level):
///   - Node-level:   `moduleParams` encodes only the `destinationDomain` (a uint32 pointer).
///   - Module-level:  `_domainConfigs[domain]` stores full routing parameters, updatable by the
///                    module owner without touching the Node config.
///
/// Access model:
///   - `execute()` is permissionless (called by any address via `Node.executeAction()`).
///   - `setDomainConfig()` and `removeDomainConfig()` are restricted to the module owner
///     (Ownable2Step).
///
/// Security notes:
///   - CCTP is a 1:1 burn-and-mint with no AMM or price curve, so there is no sandwich/MEV risk.
///   - If `depositForBurn` reverts (CCTP paused, burn limit exceeded, etc.), the entire `execute()`
///     reverts atomically — USDC returns to the Node.
///   - The module revokes its TokenMessengerV2 approval after every successful burn.
interface ICCTPBridgeModule is IActionModule {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a CCTP bridge transfer is initiated (USDC burned on source chain).
    /// @param node                 The Node contract that initiated the bridge.
    /// @param amount               The amount of USDC burned.
    /// @param destinationDomain    CCTP domain ID of the destination chain.
    /// @param mintRecipient        Recipient address on the destination chain (bytes32-encoded).
    /// @param maxFee               Maximum fee the module was configured to pay.
    /// @param minFinalityThreshold 1000 (fast) or 2000 (standard).
    /// @param hookData             Hook data passed to destination (empty if no hook).
    event BridgeInitiated(
        address indexed node,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes hookData
    );

    /// @notice Emitted when a domain configuration is set or updated via `setDomainConfig()`.
    /// @param destinationDomain    CCTP domain ID.
    /// @param mintRecipient        Recipient on the destination chain.
    /// @param destinationCaller    Who may relay on the destination (`bytes32(0)` = anyone).
    /// @param maxFee               Maximum USDC fee.
    /// @param minFinalityThreshold 1000 (fast) or 2000 (standard).
    event DomainConfigSet(
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    /// @notice Emitted when a domain configuration is removed via `removeDomainConfig()`.
    /// @param destinationDomain CCTP domain ID that was removed.
    event DomainConfigRemoved(uint32 indexed destinationDomain);

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Sets or updates the routing configuration for a destination domain.
    /// @dev Only callable by the module owner. Emits {DomainConfigSet}.
    ///
    /// Requirements:
    /// - `mintRecipient` must not be `bytes32(0)`.
    /// - `minFinalityThreshold` must be 1000 or 2000.
    ///
    /// @param destinationDomain    CCTP domain ID of the destination chain.
    /// @param mintRecipient        Recipient address on the destination chain (bytes32-encoded).
    /// @param destinationCaller    Who may call `receiveMessage` on destination (`bytes32(0)` = anyone).
    /// @param maxFee               Max USDC fee for fast transfer (0 = standard only).
    /// @param minFinalityThreshold 1000 (fast) or 2000 (standard).
    /// @param hookData             Optional hook data for destination-side automation (empty = no hook).
    function setDomainConfig(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    )
        external;

    /// @notice Removes the routing configuration for a destination domain.
    /// @dev Only callable by the module owner. Emits {DomainConfigRemoved}.
    ///
    /// Requirements:
    /// - The domain must be currently configured (`isValid == true`).
    ///
    /// @param destinationDomain CCTP domain ID to remove.
    function removeDomainConfig(uint32 destinationDomain) external;

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the current routing configuration for a destination domain.
    /// @param destinationDomain CCTP domain ID to query.
    /// @return config The domain config. `isValid == false` if not configured.
    function getDomainConfig(uint32 destinationDomain) external view returns (DataTypes.CCTPDomainConfig memory config);

    /// @notice Address of Circle's TokenMessengerV2 contract on this chain (immutable).
    function tokenMessenger() external view returns (address);

    /// @notice Address of USDC on this chain (immutable).
    function usdc() external view returns (address);

    /// @notice ABI-encodes a {CCTPBridgeParams} struct into bytes for `Node.configureToken()`.
    /// @param params   Typed struct containing `destinationDomain`.
    /// @return encoded ABI-encoded bytes.
    function encodeParams(DataTypes.CCTPBridgeParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {CCTPBridgeParams} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeParams()`.
    /// @return params Decoded struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.CCTPBridgeParams memory params);
}
