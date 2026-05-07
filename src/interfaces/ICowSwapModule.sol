// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ICowSwapModule
/// @author Credit Cooperative
/// @notice Interface for the async CowSwap order-book swap module.
/// @dev Extends {IActionModule} with CoW Protocol (GPv2) integration using a direct-receiver design:
/// the PaymentRails is set as the GPv2Order receiver so buyToken flows directly to it after settlement — this
/// module never holds or stages the buyToken.
///
/// Lifecycle:
///
///   1. `execute()`          — Pulls sellToken from PaymentRails, stores order metadata, and emits
///                             {OrderCreated}. Returns `amountOut = 0` (async pending signal).
///   2. Off-chain keeper     — Reads {OrderCreated}, reconstructs the GPv2Order, and submits it to
///                             the CowSwap API with `signingScheme = "eip1271"` and
///                             `signature = abi.encode(orderId)`.
///   3. `isValidSignature()` — Called by CowSwap (EIP-1271) before including the order in a batch.
///   4. CowSwap solver       — Pulls sellToken via GPv2VaultRelayer and transfers buyToken directly
///                             to the PaymentRails. No further on-chain call required.
///   5. `cancelOrder()`      — Owner-only recovery: returns locked sellToken to the PaymentRails.
///
/// Deployment model: each PaymentRails MUST deploy its own private instance. Do NOT share across PaymentRails.
///
/// Order parameters (fixed by this module):
///   - kind:              SELL (exact sell amount, minimum buy amount)
///   - receiver:          PaymentRails address
///   - partiallyFillable: false
///   - feeAmount:         0 (CowSwap takes fees from surplus)
///   - EIP-1271 signature: `abi.encode(orderId)` (32 bytes)
///
/// Access model:
///   - `execute()` is callable by any address (caller becomes the receiver).
///   - `cancelOrder()` is restricted to the module owner (Ownable2Step).
///
/// Security notes:
///   - Max approval to GPv2VaultRelayer is set once per token and never revoked. The relayer is
///     immutable, so ERC-20 balance is the hard ceiling on what it can pull.
///   - `cancelOrder()` caps the returned amount at `meta.sellAmount` to protect concurrent orders.
interface ICowSwapModule is IActionModule {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new CowSwap order is created via `execute()`.
    /// @param orderId      EIP-712 GPv2Order digest (used as orderId and EIP-1271 hash).
    /// @param paymentRails         PaymentRails that initiated the order; also the GPv2Order receiver.
    /// @param sellToken    Token being sold.
    /// @param buyToken     Token to receive (sent directly to `paymentRails` by solver).
    /// @param sellAmount   Exact amount being sold (locked in this module).
    /// @param minBuyAmount Minimum acceptable buy amount.
    /// @param validTo      Unix timestamp after which the order expires.
    /// @param appData      CowSwap app-data hash.
    event OrderCreated(
        bytes32 indexed orderId,
        address indexed paymentRails,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32 validTo,
        bytes32 appData
    );

    /// @notice Emitted when an order is cancelled via `cancelOrder()`.
    /// @param orderId GPv2Order digest of the cancelled order.
    /// @param paymentRails    PaymentRails that received the returned sellToken.
    /// @param token   The sellToken returned.
    /// @param amount  Amount returned (capped at `meta.sellAmount`).
    event OrderCancelled(bytes32 indexed orderId, address indexed paymentRails, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Cancels a pending order and returns the locked sellToken to the PaymentRails.
    /// @dev Restricted to the module owner (Ownable2Step). Blocked if the order is already filled
    /// (verified via `GPv2Settlement.filledAmount`). Returns at most `meta.sellAmount` to prevent
    /// draining tokens from concurrent orders sharing the same sellToken.
    ///
    /// After order expiry, CowSwap solvers may free the `filledAmount` storage slot to reclaim gas.
    /// In that edge case the fill-guard may pass on an expired-and-filled order; however, the module
    /// holds zero sellToken (the solver already pulled it), so the cancel is a harmless no-op.
    ///
    /// Requirements:
    /// - `orderId` must exist (`paymentRails != address(0)`).
    /// - Caller must be the module owner.
    /// - Order must not already be cancelled.
    /// - `filledAmount(orderId) < meta.sellAmount`.
    ///
    /// @param orderId GPv2Order digest returned by `execute()` via `ExecutionResult.data`.
    function cancelOrder(bytes32 orderId) external;

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the full metadata for an order.
    /// @param orderId   GPv2Order digest.
    /// @return metadata Struct with order details; all fields zero if `orderId` is unknown.
    function getOrder(bytes32 orderId) external view returns (DataTypes.CowOrderMetadata memory metadata);

    /// @notice EIP-1271 signature validation called by CowSwap before settling an order.
    /// @dev Returns `0x1626ba7e` iff ALL conditions hold:
    ///   1. `signature.length == 32`
    ///   2. `abi.decode(signature) == hash`
    ///   3. Order exists and is not cancelled
    ///   4. `block.timestamp <= meta.validTo`
    ///   5. `filledAmount(orderId) < meta.sellAmount`
    ///
    /// Returns `0xffffffff` otherwise. Must never revert (EIP-1271 requirement).
    ///
    /// @param hash      GPv2Order EIP-712 digest computed by CowSwap.
    /// @param signature `abi.encode(orderId)` (32 bytes).
    /// @return magicValue `0x1626ba7e` if valid, `0xffffffff` if invalid.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);

    /// @notice Address of the CowSwap GPv2Settlement contract (immutable).
    function cowSettlement() external view returns (address);

    /// @notice EIP-712 domain separator of the CowSwap settlement contract (cached at construction).
    function cowDomainSeparator() external view returns (bytes32);

    /// @notice ABI-encodes a {CowSwapParams} struct into bytes for `PaymentRails.configureToken()`.
    /// @param params   Typed struct.
    /// @return encoded ABI-encoded bytes.
    function encodeParams(DataTypes.CowSwapParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {CowSwapParams} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeParams()`.
    /// @return params Decoded struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.CowSwapParams memory params);
}
