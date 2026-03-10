// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IAsyncActionModule } from "./IAsyncActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IOrderBookSwapModule
/// @author Credit Cooperative
/// @notice Interface for the CowSwap order-book swap module
///
/// # Overview
/// Extends IAsyncActionModule with CowSwap-specific concerns:
///   - EIP-1271 isValidSignature() so CowSwap solvers can verify our orders on-chain
///   - encodeParams / decodeParams for OrderSwapParams ABI encoding
///
/// # EIP-1271 Flow
/// When a keeper submits our order to the CowSwap API with signingScheme "eip1271",
/// CowSwap's off-chain infrastructure calls isValidSignature(orderDigest, signature)
/// on this contract before including the order in a batch auction.
///
///   signature = abi.encode(orderId)   where orderId == orderDigest
///
/// isValidSignature decodes the orderId, verifies it matches the hash, and checks
/// that the order is still PENDING. Returns EIP1271_MAGIC_VALUE on success.
interface IOrderBookSwapModule is IAsyncActionModule {

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new CowSwap order is initiated via execute()
    /// @dev Off-chain keepers listen for this event to submit the order to the CowSwap API.
    ///      The keeper must submit the order with:
    ///        signingScheme = "eip1271"
    ///        signature     = abi.encode(orderId)
    ///        from          = address(this module)
    ///      All other order fields are recoverable from the event parameters.
    /// @param orderId      EIP-712 GPv2Order digest — stored as orderId and used as EIP-1271 hash
    /// @param node         Node contract that initiated the order via execute()
    /// @param sellToken    Token being sold (input token)
    /// @param buyToken     Token to be received (output token)
    /// @param sellAmount   Exact amount being sold (locked in this module)
    /// @param minBuyAmount Minimum acceptable buy amount (floor set in OrderSwapParams)
    /// @param validTo      Unix timestamp after which CowSwap solvers will not settle
    /// @param appData      CowSwap app data hash registered with the CowSwap AppData API
    event OrderCreated(
        bytes32 indexed orderId,
        address indexed node,
        address sellToken,
        
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32  validTo,
        bytes32 appData
    );

    /*//////////////////////////////////////////////////////////////////////////
                            PARAMETER ENCODING
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice ABI-encode an OrderSwapParams struct into bytes for Node.configureToken()
    /// @param params  Typed OrderSwapParams struct
    /// @return encoded  ABI-encoded bytes to store as moduleParams in Node
    function encodeParams(DataTypes.OrderSwapParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decode moduleParams bytes back into a typed OrderSwapParams struct
    /// @param encoded  ABI-encoded bytes from encodeParams()
    /// @return params  Decoded OrderSwapParams struct
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.OrderSwapParams memory params);

    /*//////////////////////////////////////////////////////////////////////////
                            EIP-1271 — COWSWAP ORDER VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice EIP-1271 signature validation called by CowSwap before settling our order
    /// @dev
    ///   CowSwap calls this with:
    ///     hash      = GPv2Order digest (keccak of domain separator + order struct hash)
    ///     signature = abi.encode(orderId) as submitted to the CowSwap API
    ///
    ///   Returns EIP1271_MAGIC_VALUE (0x1626ba7e) iff:
    ///     1. decoded orderId == hash  (signature matches the order being settled)
    ///     2. _pendingOrders[orderId].status == PENDING  (order is still live)
    ///
    ///   Returns 0xffffffff otherwise — CowSwap will reject the order from the batch.
    ///
    /// @param hash       GPv2Order digest computed by CowSwap
    /// @param signature  abi.encode(orderId) passed when submitting to CowSwap API
    /// @return magicValue  0x1626ba7e if valid, 0xffffffff if invalid
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);

    /*//////////////////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Address of the CowSwap GPv2Settlement contract on this chain
    /// @dev Immutable — set in constructor. Tokens are approved to this address.
    function cowSettlement() external view returns (address);

    /// @notice EIP-712 domain separator of the CowSwap settlement contract
    /// @dev Used to compute GPv2Order digests consistently with CowSwap's off-chain code
    function cowDomainSeparator() external view returns (bytes32);
}
