// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IAsyncActionModule
/// @author Credit Cooperative
/// @notice Extension of IActionModule for operations whose execution spans multiple transactions
///
/// # Overview
/// Standard IActionModule assumes atomicity: execute() completes the action in one transaction
/// and returns a final ExecutionResult. Some actions — specifically order-book swaps (CowSwap)
/// and cross-chain bridges — are inherently asynchronous: the action is *initiated* in one
/// transaction and *completed* (settled) in a later transaction by an external party.
///
/// This interface extends IActionModule with three additional functions:
///
///   checkSettlement(orderId) — view: has the external party settled our order?
///   claimSettlement(orderId) — state: collect settled tokens and push them back to the Node
///   cancelOrder(orderId)     — state: abort a pending order and recover locked tokens
///
/// # execute() Semantics for Async Modules
/// For modules implementing this interface, execute() means *initiate*, not *complete*:
///   - Tokens are transferred from Node → Module (locked for the duration)
///   - The module registers the pending operation (stores metadata, sets up authorisation)
///   - Returns ExecutionResult{ success: true, amountOut: 0, data: abi.encode(orderId) }
///   - amountOut == 0 is the off-chain signal that settlement is pending
///
/// # Lifecycle
///
///   [Node.executeAction()]
///          │  execute()        → PENDING  (tokens locked in module)
///          │
///   [External settlement — CowSwap solver, bridge relayer, …]
///          │                  → tokens arrive in module
///          │
///   [Anyone calls claimSettlement()]
///          │  claimSettlement()→ SETTLED  (tokens pushed back to Node)
///
///   [Owner calls cancelOrder() if settlement never arrives]
///          │  cancelOrder()   → CANCELLED (tokens returned to Node)
///
/// # Security Model
/// - Only the Node that called execute() may call claimSettlement() or cancelOrder()
///   (enforced via the node address stored in order metadata)
/// - Modules implementing this interface ARE stateful — each Node must deploy its own
///   private instance; modules MUST NOT be shared across Nodes
interface IAsyncActionModule is IActionModule {

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an async order/operation is settled and tokens are returned
    /// @param orderId    Identifier of the settled order
    /// @param node       Node that receives the output tokens
    /// @param outputToken Token returned to the Node
    /// @param amountOut  Amount of outputToken sent to the Node
    event OrderSettled(bytes32 indexed orderId, address indexed node, address outputToken, uint256 amountOut);

    /// @notice Emitted when a pending order is cancelled and sell tokens are returned
    /// @param orderId   Identifier of the cancelled order
    /// @param node      Node that receives the returned sell tokens
    /// @param token     Sell token returned
    /// @param amount    Amount returned
    event OrderCancelled(bytes32 indexed orderId, address indexed node, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            USER-FACING CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Check whether an order has been settled by the external party
    /// @dev Pure view — safe to poll frequently from off-chain keepers.
    ///      Returns (false, 0) for both "not yet settled" and "order unknown".
    ///      Callers should verify the orderId exists before trusting the result.
    ///
    /// @param orderId  Order identifier returned by execute() via ExecutionResult.data
    /// @return isSettled  True if the external settlement has occurred and tokens are claimable
    /// @return amountOut  Amount of buy/output token available to claim (0 if not settled)
    function checkSettlement(bytes32 orderId) external view returns (bool isSettled, uint256 amountOut);

    /// @notice Retrieve the full metadata for a pending or settled order
    /// @param orderId  Order identifier
    /// @return metadata  OrderMetadata struct; all-zero if orderId is unknown
    function getOrder(bytes32 orderId) external view returns (DataTypes.OrderMetadata memory metadata);

    /*//////////////////////////////////////////////////////////////////////////
                        USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Claim output tokens from a settled order and push them back to the Node
    /// @dev
    ///   Permissionless — any caller may trigger the claim. Tokens always transfer to the
    ///   Node address stored in the order metadata, never to msg.sender. This allows keeper
    ///   infrastructure to call claimSettlement directly without Node proxy methods.
    ///
    ///   Requirements:
    ///   - order.status must be PENDING (not already settled or cancelled)
    ///   - checkSettlement(orderId) must return true (module holds >= minBuyAmount)
    ///
    ///   On success:
    ///   - Transfers all buyToken balance held by this module to the stored Node address
    ///   - Sets order.status = SETTLED
    ///   - Emits OrderSettled
    ///
    /// @param orderId  Order identifier returned by execute() via ExecutionResult.data
    /// @return result  ExecutionResult with success=true, amountOut, and outputToken set
    function claimSettlement(bytes32 orderId) external returns (DataTypes.ExecutionResult memory result);

    /// @notice Cancel a pending order and return locked sell tokens to the Node
    /// @dev
    ///   Caller restriction is implementation-defined. Implementations typically restrict
    ///   cancellation to an authorized owner or admin to prevent griefing attacks where
    ///   an adversary cancels a profitable pending order before settlement arrives.
    ///
    ///   Sell tokens always return to the Node address stored in the order metadata —
    ///   never to the caller.
    ///
    ///   Requirements:
    ///   - order.status must be PENDING
    ///   - caller must be authorized per the implementation's access control
    ///
    ///   Intended uses:
    ///   - Order expired without settlement (validTo passed)
    ///   - Owner wants to reconfigure and retry with different params
    ///   - Emergency recovery of locked tokens
    ///
    ///   On success:
    ///   - Returns all sellToken held by the module to the stored Node address
    ///   - Revokes CowSwap Settlement approval for this token
    ///   - Sets order.status = CANCELLED
    ///   - Emits OrderCancelled
    ///
    /// @param orderId  Order identifier to cancel
    function cancelOrder(bytes32 orderId) external;
}
