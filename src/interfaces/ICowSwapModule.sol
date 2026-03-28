// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ICowSwapModule
/// @author Credit Cooperative
/// @notice Interface for the async CowSwap order-book swap module
///
/// # Overview
/// Extends IActionModule with CowSwap-specific concerns. Implements a CoW Protocol (GPv2)
/// integration using a direct-receiver design: the Node contract is set as the GPv2Order
/// receiver so buyToken flows directly to the Node after solver settlement — this module
/// never holds or stages the buyToken.
///
/// # Lifecycle
///
///   1. execute()          — validates params, pulls sellToken from Node, grants max approval
///                           to GPv2Settlement (once per token), stores order metadata, and
///                           emits OrderCreated. Returns amountOut=0 as the "async pending"
///                           signal; data=abi.encode(orderId).
///
///   2. (off-chain keeper) — reads OrderCreated, reconstructs the GPv2Order, and submits it
///                           to the CowSwap API with signingScheme="eip1271" and
///                           signature=abi.encode(orderId).
///                           IMPORTANT: the receiver field in the submission MUST equal the
///                           Node address stored in order metadata (it is included in the
///                           orderId digest and validated by isValidSignature).
///
///   3. isValidSignature() — CowSwap off-chain infrastructure calls this (EIP-1271) before
///                           including the order in a batch auction. Returns the magic value
///                           iff the order is not cancelled, not expired, not filled, and the
///                           hash matches the stored orderId.
///
///   4. (CowSwap solver)   — GPv2Settlement pulls sellToken from this module (via max approval)
///                           and transfers buyToken directly to the Node (receiver=node).
///                           No further on-chain call is required — settlement is complete.
///
///   5. cancelOrder()      — owner-only recovery path. If settlement never arrives, the module
///                           owner calls cancelOrder() to return the locked sellToken to the
///                           Node. Blocked if the order was already filled (checked via
///                           GPv2Settlement.filledAmounts).
///
/// # Deployment Model
/// Each Node MUST deploy its own private CowSwapModule instance. Modules MUST NOT be shared
/// across Nodes — orders are keyed by GPv2 digest (globally unique per deployment) and assume
/// a single owner (Node).
///
/// # CowSwap Order Parameters
/// - Order kind:        SELL (exact sell amount, minimum buy amount)
/// - Receiver:          Node address — buyToken goes directly to Node, never staged here
/// - partiallyFillable: false — full fill only (CowSwap rejects if it cannot fill 100%;
///                      large orders may miss execution windows — split into smaller orders
///                      if liquidity is thin)
/// - feeAmount:         0 — CowSwap takes fees from surplus
/// - EIP-1271 signature: abi.encode(orderId) (32 bytes)
///
/// # Access Model
/// - execute() is permissionless — any address can call it directly (bypassing Node).
///   The caller becomes meta.node (receiver for buyToken and cancellation refunds).
///   This is safe: the caller supplies their own tokens and the module owner retains
///   exclusive control over cancelOrder().
/// - cancelOrder() is restricted to the module owner (Ownable2Step).
///
/// # Security Model
/// - Max approval to GPv2Settlement is set once per token and never revoked. GPv2Settlement
///   is immutable so it cannot be redirected; ERC20 balance is the hard ceiling on what it
///   can pull.
/// - CEI (Checks-Effects-Interactions) is enforced in all state-changing functions.
/// - amountOut=0 in ExecutionResult signals async pending — never mistaken for real output.
/// - cancelOrder caps the returned amount at meta.sellAmount to protect concurrent orders
///   sharing the same sellToken.
interface ICowSwapModule is IActionModule {

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new CowSwap order is initiated via execute()
    /// @dev Off-chain keepers listen for this event to reconstruct and submit the GPv2Order.
    ///      The keeper must submit to the CowSwap API with:
    ///        signingScheme = "eip1271"
    ///        signature     = abi.encode(orderId)
    ///        from          = address(this module)
    ///        receiver      = node  (MUST match — included in orderId digest)
    ///      All other fields (sellToken, buyToken, amounts, validTo, appData) are recoverable
    ///      from the event parameters.
    /// @param orderId      EIP-712 GPv2Order digest — used as orderId and EIP-1271 hash
    /// @param node         Node contract that initiated the order; also the GPv2Order receiver
    /// @param sellToken    Token being sold (input token)
    /// @param buyToken     Token to be received (output token); sent directly to node by solver
    /// @param sellAmount   Exact amount being sold (locked in this module)
    /// @param minBuyAmount Minimum acceptable buy amount (floor set in CowSwapParams)
    /// @param validTo      Unix timestamp after which CowSwap solvers will not settle
    /// @param appData      CowSwap app data hash registered with the CowSwap AppData API
    event OrderCreated(
        bytes32 indexed orderId,
        address indexed node,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32 validTo,
        bytes32 appData
    );

    /// @notice Emitted when cancelOrder() returns locked sellToken to the Node
    /// @param orderId GPv2Order digest of the cancelled order
    /// @param node    Node that received the returned sellToken
    /// @param token   sellToken returned to the Node
    /// @param amount  Amount of sellToken returned (capped at meta.sellAmount)
    event OrderCancelled(bytes32 indexed orderId, address indexed node, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Cancel a pending order and return the locked sellToken to the Node
    /// @dev Owner-restricted (Ownable2Step). Blocked if the order is already filled (verified
    ///      via GPv2Settlement.filledAmounts). Returns at most meta.sellAmount of sellToken to
    ///      prevent draining tokens from concurrent orders sharing the same sellToken.
    ///
    ///      After order expiry, CowSwap solvers may free the filledAmounts storage slot to
    ///      reclaim gas. In that edge case the fill-guard may pass on an expired-and-filled
    ///      order; however, the module holds 0 sellToken (the solver already pulled it), so the
    ///      cancel is a harmless no-op.
    ///
    ///      cancelOrder does NOT revoke the max approval to GPv2Settlement. With sellToken
    ///      returned to the Node, this module holds 0 balance — CowSwap cannot pull what is not
    ///      here.
    ///
    ///      Requirements:
    ///      - orderId must exist (node != address(0))
    ///      - msg.sender must be the module owner
    ///      - order must not already be cancelled
    ///      - filledAmounts(orderId) < meta.sellAmount
    ///
    ///      Intended uses:
    ///      - Order expired without solver settlement
    ///      - Owner wants to reconfigure and retry with different params
    ///      - Emergency recovery of locked tokens
    ///
    /// @param orderId GPv2Order digest returned by execute() via ExecutionResult.data
    function cancelOrder(bytes32 orderId) external;

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the full metadata for an order (pending, cancelled, or unknown)
    /// @param orderId   GPv2Order digest returned by execute() via ExecutionResult.data
    /// @return metadata CowOrderMetadata struct; all fields are zero if orderId is unknown
    function getOrder(bytes32 orderId) external view returns (DataTypes.CowOrderMetadata memory metadata);

    /// @notice EIP-1271 signature validation called by CowSwap before settling our order
    /// @dev Must NEVER revert (EIP-1271 requirement). Returns the failure value for all
    ///      invalid cases instead of reverting.
    ///
    ///      Returns EIP1271_MAGIC_VALUE (0x1626ba7e) iff ALL of the following hold:
    ///        1. signature.length == 32
    ///        2. abi.decode(signature, (bytes32)) == hash  (orderId matches CowSwap-computed digest)
    ///        3. _orders[orderId].node != address(0)        (order was created by this module)
    ///        4. !meta.cancelled
    ///        5. block.timestamp <= meta.validTo
    ///        6. filledAmounts(orderId) < meta.sellAmount
    ///
    ///      Returns 0xffffffff otherwise.
    ///
    ///      Gas note: the expiry check (5) is evaluated before filledAmounts (6) to avoid an
    ///      external call for orders that have already expired.
    ///
    /// @param hash      GPv2Order EIP-712 digest computed by CowSwap
    /// @param signature abi.encode(orderId) passed when submitting to the CowSwap API
    /// @return magicValue 0x1626ba7e if valid, 0xffffffff if invalid
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);

    /// @notice Address of the CowSwap GPv2Settlement contract on this chain
    /// @dev Immutable — set in constructor. sellToken approvals are granted to this address.
    function cowSettlement() external view returns (address);

    /// @notice EIP-712 domain separator of the CowSwap settlement contract
    /// @dev Cached at construction time. Used to compute GPv2Order digests that match CowSwap.
    function cowDomainSeparator() external view returns (bytes32);

    /// @notice ABI-encode a CowSwapParams struct into bytes for use in Node.configureToken()
    /// @param params   Typed CowSwapParams struct
    /// @return encoded ABI-encoded bytes to store as moduleParams in Node
    function encodeParams(DataTypes.CowSwapParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decode moduleParams bytes back into a typed CowSwapParams struct
    /// @param encoded ABI-encoded bytes produced by encodeParams()
    /// @return params Decoded CowSwapParams struct
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.CowSwapParams memory params);
}
