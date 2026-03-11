// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IOrderBookSwapModule
/// @author Credit Cooperative
/// @notice Interface for the CowSwap order-book swap module
///
/// # Overview
/// Extends IActionModule with CowSwap-specific concerns:
///   - Direct-receiver design: receiver = Node, buyToken goes straight to Node after settlement
///   - EIP-1271 isValidSignature() so CowSwap can verify our orders on-chain
///   - markFilled() permissionless bookkeeping after solver settles
///   - cancelOrder() owner-restricted recovery of locked sellToken
///   - encodeParams / decodeParams for OrderSwapParams ABI encoding
///
/// # Lifecycle
///   execute()      → PENDING  (sellToken locked, orderId registered)
///   markFilled()   → SETTLED  (permissionless; requires filledAmounts confirmation)
///   cancelOrder()  → CANCELLED (owner only; blocked if already filled)
///
/// # EIP-1271 Flow
/// When a keeper submits our order to the CowSwap API with signingScheme "eip1271",
/// CowSwap's off-chain infrastructure calls isValidSignature(orderDigest, signature)
/// on this contract before including the order in a batch auction.
///
///   signature = abi.encode(orderId)   where orderId == orderDigest
///
/// isValidSignature decodes the orderId, verifies it matches the hash, and checks
/// that the order is PENDING and non-expired. Returns EIP1271_MAGIC_VALUE on success.
interface IOrderBookSwapModule is IActionModule {

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new CowSwap order is initiated via execute()
    /// @dev Off-chain keepers listen for this event to submit the order to the CowSwap API.
    ///      The keeper must submit with:
    ///        signingScheme = "eip1271"
    ///        signature     = abi.encode(orderId)
    ///        from          = address(this module)
    ///        receiver      = node  (MUST match — included in orderId digest)
    ///      All other order fields are recoverable from the event parameters.
    /// @param orderId      EIP-712 GPv2Order digest — used as orderId and EIP-1271 hash
    /// @param node         Node contract that initiated the order; also the GPv2Order receiver
    /// @param sellToken    Token being sold (input token)
    /// @param buyToken     Token to be received (output token); sent directly to node by solver
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

    /// @notice Emitted when markFilled() confirms that a CowSwap solver has filled the order
    /// @dev amountOut is 0 because buyToken was sent directly to the Node (receiver=node);
    ///      the module never held buyToken and cannot report the actual amount received.
    ///      Off-chain systems should query CowSwap's API or events for the exact fill amount.
    /// @param orderId    GPv2Order digest of the settled order
    /// @param node       Node that received the buyToken (directly from CowSwap solver)
    /// @param buyToken   Token that was received by the Node
    /// @param amountOut  Always 0 — actual amount went directly to Node, unknown here
    event OrderSettled(bytes32 indexed orderId, address indexed node, address buyToken, uint256 amountOut);

    /// @notice Emitted when cancelOrder() returns locked sellToken to the Node
    /// @param orderId  GPv2Order digest of the cancelled order
    /// @param node     Node that received the returned sellToken
    /// @param token    SellToken returned to the Node
    /// @param amount   Amount of sellToken returned (capped at meta.sellAmount)
    event OrderCancelled(bytes32 indexed orderId, address indexed node, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            ORDER LIFECYCLE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the full metadata for any order (pending, settled, cancelled, or unknown)
    /// @param orderId  GPv2Order digest returned by execute() via ExecutionResult.data
    /// @return metadata  OrderMetadata struct; all-zero if orderId is unknown
    function getOrder(bytes32 orderId) external view returns (DataTypes.OrderMetadata memory metadata);

    /// @notice Permissionless bookkeeping: mark a CowSwap-filled order as SETTLED on-chain
    /// @dev Does NOT transfer tokens — buyToken already went to Node via receiver=node.
    ///      Verifies the fill via GPv2Settlement.filledAmounts(orderId) >= meta.sellAmount.
    ///      Most reliable when called before order expiry (filledAmounts may be freed post-expiry
    ///      by CowSwap solvers as a gas optimization).
    ///
    ///      Requirements:
    ///      - orderId must exist
    ///      - order.status must be PENDING
    ///      - filledAmounts(orderId) >= meta.sellAmount
    ///
    /// @param orderId  GPv2Order digest returned by execute() via ExecutionResult.data
    function markFilled(bytes32 orderId) external;

    /// @notice Cancel a pending order and return locked sellToken to the Node
    /// @dev Owner-restricted (Ownable2Step). Blocked if the order was already filled
    ///      (verified via filledAmounts). Returns at most meta.sellAmount of sellToken
    ///      to prevent draining tokens from concurrent orders sharing the same sellToken.
    ///
    ///      Requirements:
    ///      - orderId must exist
    ///      - msg.sender must be the module owner
    ///      - order.status must be PENDING
    ///      - filledAmounts(orderId) < meta.sellAmount
    ///
    ///      Intended uses:
    ///      - Order expired without solver settlement
    ///      - Owner wants to reconfigure and retry
    ///      - Emergency recovery of locked tokens
    ///
    /// @param orderId  GPv2Order digest returned by execute() via ExecutionResult.data
    function cancelOrder(bytes32 orderId) external;

    /*//////////////////////////////////////////////////////////////////////////
                            EIP-1271 — COWSWAP ORDER VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice EIP-1271 signature validation called by CowSwap before settling our order
    /// @dev Must NEVER revert (EIP-1271 requirement). Returns failure value for all
    ///      invalid cases instead of reverting.
    ///
    ///   Returns EIP1271_MAGIC_VALUE (0x1626ba7e) iff:
    ///     1. signature.length == 32
    ///     2. decoded orderId == hash
    ///     3. order exists (node != address(0))
    ///     4. order.status == PENDING
    ///     5. block.timestamp <= meta.validTo
    ///
    ///   Returns 0xffffffff otherwise.
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
    /// @dev Cached at construction. Used to compute GPv2Order digests matching CowSwap.
    function cowDomainSeparator() external view returns (bytes32);

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
}
