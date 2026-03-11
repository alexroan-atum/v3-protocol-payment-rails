// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IOrderBookSwapModule } from "../interfaces/IOrderBookSwapModule.sol";
import { IActionModule } from "../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { Errors } from "../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Minimal interface for the CowSwap GPv2Settlement contract
interface IGPv2Settlement {
    /// @notice Returns the EIP-712 domain separator used to hash CowSwap orders
    function domainSeparator() external view returns (bytes32);

    /// @notice Returns how much of an order has been filled
    /// @dev For SELL orders, returns the cumulative sellAmount filled by solvers.
    ///      Returns 0 for unknown orders. NOTE: CowSwap solvers may free this storage slot
    ///      after order expiry to reclaim gas — do not rely on it for post-expiry history.
    function filledAmounts(bytes32 orderDigest) external view returns (uint256);
}

/// @title OrderBookSwapModule
/// @author Credit Cooperative
/// @notice Async action module that submits sell orders to the CowSwap order-book protocol
///
/// # Overview
/// Implements a CowSwap (GPv2 / CoW Protocol) integration with a direct-receiver design:
///
///   1. execute()         — locks sellToken in this module, approves CowSwap Settlement,
///                          computes the GPv2Order digest (orderId), persists metadata.
///                          Returns amountOut=0 as the off-chain "pending" signal.
///
///   2. (off-chain)       — keeper reads the OrderCreated event, reconstructs the full
///                          GPv2Order, and submits it to the CowSwap API with
///                          signingScheme="eip1271", signature=abi.encode(orderId).
///                          IMPORTANT: receiver in the API submission must equal the Node
///                          address stored in order metadata.
///
///   3. isValidSignature()— CowSwap's off-chain infrastructure calls this (EIP-1271) before
///                          including our order in a batch auction. Returns the magic value
///                          iff the orderId is PENDING, non-expired, and hash matches.
///
///   4. (CowSwap solver)  — GPv2Settlement pulls sellToken from this module (via approval),
///                          and sends buyToken directly to the Node (receiver = node).
///                          No staging in this module — buyToken bypasses it entirely.
///
///   5. markFilled()      — permissionless bookkeeping: any caller (typically a keeper) may
///                          call this after the solver settles to transition status to SETTLED.
///                          Verifies via GPv2Settlement.filledAmounts(). Optional — tokens
///                          are already safe at the Node regardless of whether this is called.
///
///   6. cancelOrder()     — if settlement never arrives, the module owner calls cancelOrder()
///                          to recover the locked sellToken. Blocked if the order was already
///                          filled (verified via filledAmounts).
///
/// # Deployment Model
/// Each Node MUST deploy its own private OrderBookSwapModule instance.
/// Modules MUST NOT be shared across Nodes — _orders keyed by orderId (GPv2 digest)
/// are globally unique per deployment and assume a single owner (Node).
///
/// # CowSwap Integration Details
/// - GPv2Settlement: immutable address set in constructor
/// - Order kind: SELL (exact sell amount, minimum buy amount)
/// - Receiver: Node address — buyToken goes directly to Node, not to this module
/// - partiallyFillable: false — full fill only
/// - feeAmount: 0 — CowSwap takes fees from surplus
/// - EIP-1271 signature: abi.encode(orderId) (32 bytes)
///
/// # Security Model
/// - markFilled() is permissionless — only updates state, no token transfers
/// - cancelOrder() is restricted to the module owner (Ownable2Step)
/// - Approval to GPv2Settlement is set per-order and revoked on markFilled/cancelOrder
/// - CEI (Checks-Effects-Interactions) pattern enforced in all state-changing functions
/// - amountOut=0 in ExecutionResult signals async pending — never mistaken for a real output
/// - cancelOrder caps returned amount at meta.sellAmount (prevents draining unrelated orders)
contract OrderBookSwapModule is IOrderBookSwapModule, ActionModuleBase, Ownable2Step {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice EIP-1271 magic value — returned by isValidSignature() for valid orders
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @notice EIP-1271 failure value — returned by isValidSignature() for invalid orders
    bytes4 internal constant EIP1271_FAILURE_VALUE = 0xffffffff;

    /// @notice EIP-712 type hash for GPv2Order.Data
    /// @dev Computed as:
    ///   keccak256("Order(address sellToken,address buyToken,address receiver,"
    ///             "uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,"
    ///             "uint256 feeAmount,bytes32 kind,bool partiallyFillable,"
    ///             "bytes32 sellTokenBalance,bytes32 buyTokenBalance)")
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(
        "Order("
        "address sellToken,"
        "address buyToken,"
        "address receiver,"
        "uint256 sellAmount,"
        "uint256 buyAmount,"
        "uint32 validTo,"
        "bytes32 appData,"
        "uint256 feeAmount,"
        "bytes32 kind,"
        "bool partiallyFillable,"
        "bytes32 sellTokenBalance,"
        "bytes32 buyTokenBalance"
        ")"
    );

    /// @notice CowSwap order kind: sell an exact amount of sellToken
    bytes32 internal constant KIND_SELL = keccak256("sell");

    /// @notice CowSwap balance type: standard ERC20 balances (not Balancer vault)
    bytes32 internal constant BALANCE_ERC20 = keccak256("erc20");

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBookSwapModule
    address public immutable override cowSettlement;

    /// @inheritdoc IOrderBookSwapModule
    bytes32 public immutable override cowDomainSeparator;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice CowSwap orders keyed by GPv2Order digest (orderId)
    /// @dev Populated in execute(), status updated in markFilled() and cancelOrder()
    mapping(bytes32 => DataTypes.OrderMetadata) private _orders;

    /// @notice Cumulative sell amount approved to cowSettlement per sell token
    /// @dev Tracks the sum of sellAmount across all PENDING orders for a given token.
    ///      Incremented in execute(), decremented in markFilled() and cancelOrder().
    ///      Ensures that settling or cancelling one order does not revoke the approval
    ///      that concurrent orders sharing the same sell token depend on (fixes H-1).
    mapping(address => uint256) private _pendingApprovalAmount;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploys this module and caches the CowSwap domain separator
    /// @dev Deploy one instance per Node — do NOT share across Nodes
    /// @param _cowSettlement Address of the CowSwap GPv2Settlement contract on this chain
    ///   Mainnet Ethereum: 0x9008D19f58AAbD9eD0D60971565AA8510560ab41
    /// @param _owner Address that will own this module (can call cancelOrder)
    constructor(address _cowSettlement, address _owner) Ownable(_owner) {
        if (_cowSettlement == address(0)) revert Errors.OrderBookSwapModule_ZeroTargetToken();
        cowSettlement = _cowSettlement;
        cowDomainSeparator = IGPv2Settlement(_cowSettlement).domainSeparator();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            IActionModule — INITIATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    /// @notice Initiates a CowSwap sell order — locks sellToken, stores metadata, returns orderId
    ///
    /// # Async Semantics
    /// execute() INITIATES rather than COMPLETES the swap:
    ///   - amountOut == 0 in the returned result signals "pending settlement" off-chain
    ///   - ExecutionResult.data == abi.encode(orderId) for keeper use
    ///   - buyToken flows directly to the Node via receiver=node in the GPv2Order
    ///
    /// # Token Flow
    ///   Node (msg.sender) →[transferFrom]→ this module →[CowSwap solver]→ Node receives buyToken
    ///
    /// # Off-chain Keeper Responsibilities
    /// After execute() emits OrderCreated, a keeper must:
    ///   1. Reconstruct the GPv2Order from event data
    ///      (sellToken, buyToken, sellAmount, minBuyAmount, validTo, appData, receiver=node)
    ///   2. Submit to CowSwap API:
    ///      signingScheme="eip1271", signature=abi.encode(orderId), from=address(this module)
    ///   3. After solver fills: optionally call markFilled(orderId) to update on-chain state
    ///
    /// # Requirements
    /// - targetToken must be non-zero and differ from sell token
    /// - minBuyAmount must be non-zero
    /// - validityDuration must be non-zero
    /// - Node (msg.sender) must hold at least `amount` of `token`
    /// - Node (msg.sender) must have approved this module for at least `amount`
    ///
    /// @param token   ERC20 token to sell (sellToken)
    /// @param amount  Exact amount to sell (locked in this module until filled or cancelled)
    /// @param params  ABI-encoded OrderSwapParams — use encodeParams() to build
    /// @return result success=true, amountOut=0 (pending), outputToken=buyToken, data=abi.encode(orderId)
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external override(ActionModuleBase, IActionModule) returns (DataTypes.ExecutionResult memory result) {
        DataTypes.OrderSwapParams memory swapParams = decodeParams(params);

        // --- Validate parameters (all checks before any state change or interaction) ---

        // [L-1] Reject zero-amount orders — they lock no tokens but pollute state
        if (amount == 0) {
            return _failedResult(token, "Zero sell amount");
        }
        if (swapParams.targetToken == address(0)) {
            return _failedResult(token, "Zero target token");
        }
        if (swapParams.targetToken == token) {
            return _failedResult(token, "Same sell and buy token");
        }
        if (swapParams.minBuyAmount == 0) {
            return _failedResult(token, "Zero minimum buy amount");
        }
        if (swapParams.validityDuration == 0) {
            return _failedResult(token, "Zero validity duration");
        }

        // [M-1] Guard against silent uint32 overflow in the validTo downcast.
        // Solidity 0.8+ protects arithmetic but NOT explicit casts — a large
        // validityDuration would silently wrap validTo to a past timestamp,
        // making isValidSignature() return FAILURE immediately and locking tokens.
        uint256 rawValidTo = block.timestamp + uint256(swapParams.validityDuration);
        if (rawValidTo > type(uint32).max) {
            return _failedResult(token, "Validity duration overflow");
        }
        uint32 validTo = uint32(rawValidTo);

        // --- Compute GPv2Order digest before transfer so we can guard on collision ---
        // receiver = msg.sender (Node): buyToken goes directly to Node after solver fills.
        bytes32 orderId = _computeOrderDigest(
            token,
            swapParams.targetToken,
            msg.sender,
            amount,
            swapParams.minBuyAmount,
            validTo,
            swapParams.appData
        );

        // [M-3] Reject if an order with this digest already exists.
        // Without this guard, a second call with identical params in the same block would
        // silently overwrite the existing metadata while depositing a second sellAmount,
        // permanently orphaning the first deposit. Use a unique appData to disambiguate.
        if (_orders[orderId].node != address(0)) {
            return _failedResult(token, "Order ID collision: use unique appData");
        }

        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        // --- Transfer sellToken from Node to this module ---
        // Node pre-approves this module for `amount` before calling execute().
        // _safeTransferFrom wraps transferFrom in try/catch for graceful failure.
        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            return _failedResult(token, "Token transfer failed");
        }

        // --- Approve GPv2Settlement to pull sellToken (cumulative, H-1 fix) ---
        // Track the total pending sell amount across all concurrent orders for this token.
        // Using forceApprove(cumulative) instead of forceApprove(amount) ensures that
        // creating a second order for the same sellToken does not overwrite the approval
        // needed for the first order, and settling/cancelling one order does not revoke
        // the approval needed for other concurrent orders.
        _pendingApprovalAmount[token] += amount;
        IERC20(token).forceApprove(cowSettlement, _pendingApprovalAmount[token]);

        // --- Persist order metadata ---
        _orders[orderId] = DataTypes.OrderMetadata({
            node: msg.sender,
            sellToken: token,
            buyToken: swapParams.targetToken,
            sellAmount: amount,
            validTo: validTo,
            status: DataTypes.OrderStatus.PENDING
        });

        emit OrderCreated(
            orderId, msg.sender, token, swapParams.targetToken, amount, swapParams.minBuyAmount, validTo, swapParams.appData
        );

        // amountOut=0 signals async pending (not a real output).
        // data=abi.encode(orderId) for the off-chain keeper to track this order.
        return _successResult(0, swapParams.targetToken, abi.encode(orderId));
    }

    /// @inheritdoc IActionModule
    /// @notice Validates whether a CowSwap order can be initiated
    /// @dev Pure parameter and balance checks — does not verify CowSwap liquidity
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view override(ActionModuleBase, IActionModule) returns (bool isValid, string memory reason) {
        DataTypes.OrderSwapParams memory swapParams = decodeParams(params);

        if (swapParams.targetToken == address(0)) {
            return (false, "Zero target token");
        }
        if (swapParams.targetToken == token) {
            return (false, "Same sell and buy token");
        }
        if (swapParams.minBuyAmount == 0) {
            return (false, "Zero minimum buy amount");
        }
        if (swapParams.validityDuration == 0) {
            return (false, "Zero validity duration");
        }
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    /// @inheritdoc IActionModule
    /// @notice Estimates output — returns minBuyAmount as the floor guarantee
    /// @dev Actual CowSwap output will be >= minBuyAmount due to solver competition.
    ///      True output is unknowable before settlement; minBuyAmount is the safe lower bound.
    function estimateOutput(
        address, /* token */
        uint256, /* amount */
        bytes calldata params
    ) external pure override(ActionModuleBase, IActionModule) returns (uint256 estimatedOutput, address outputToken) {
        DataTypes.OrderSwapParams memory swapParams = decodeParams(params);
        return (swapParams.minBuyAmount, swapParams.targetToken);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "ORDER_SWAP";
    }

    /*//////////////////////////////////////////////////////////////////////////
                        IOrderBookSwapModule — ORDER LIFECYCLE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBookSwapModule
    /// @notice Returns the full metadata for any order (pending, settled, cancelled, or unknown)
    function getOrder(bytes32 orderId) external view returns (DataTypes.OrderMetadata memory metadata) {
        return _orders[orderId];
    }

    /// @inheritdoc IOrderBookSwapModule
    /// @notice Permissionless bookkeeping: mark a CowSwap-filled order as SETTLED on-chain
    ///
    /// # Purpose
    /// After a CowSwap solver fills the order, buyToken goes directly to the Node (receiver=node).
    /// This module never holds buyToken. markFilled() only updates on-chain state — it does NOT
    /// transfer any tokens. Tokens are safe at the Node regardless of whether this is called.
    ///
    /// # When to call
    /// Keepers should call this after observing the CowSwap settlement event. Calling it:
    ///   - transitions status PENDING → SETTLED
    ///   - makes isValidSignature() return FAILURE (no residual MAGIC after fill)
    ///   - revokes any residual GPv2Settlement approval (cleanup)
    ///
    /// # filledAmounts reliability
    /// GPv2Settlement.filledAmounts(orderId) is the on-chain proof of fill. NOTE: CowSwap
    /// solvers may free this storage slot after order expiry to reclaim gas. markFilled() is
    /// therefore most reliable when called before the order expires.
    ///
    /// # Requirements
    /// - orderId must exist (node != address(0))
    /// - order.status must be PENDING
    /// - GPv2Settlement.filledAmounts(orderId) >= meta.sellAmount
    ///
    /// @param orderId GPv2Order digest returned by execute() via ExecutionResult.data
    function markFilled(bytes32 orderId) external {
        DataTypes.OrderMetadata storage meta = _orders[orderId];

        // --- Checks ---
        if (meta.node == address(0)) {
            revert Errors.OrderBookSwapModule_UnknownOrder(orderId);
        }
        if (meta.status != DataTypes.OrderStatus.PENDING) {
            revert Errors.OrderBookSwapModule_OrderNotPending(orderId, uint8(meta.status));
        }
        if (IGPv2Settlement(cowSettlement).filledAmounts(orderId) < meta.sellAmount) {
            revert Errors.OrderBookSwapModule_NotFilled(orderId);
        }

        address sellToken = meta.sellToken;
        address node = meta.node;
        address buyToken = meta.buyToken;
        uint256 sellAmount = meta.sellAmount;

        // --- Effects ---
        meta.status = DataTypes.OrderStatus.SETTLED;

        // [H-1 fix] Decrement cumulative approval rather than zeroing it.
        // forceApprove(0) would revoke approval for ALL concurrent orders sharing
        // this sellToken. Subtract only this order's sellAmount to preserve the
        // approval that other PENDING orders for the same token depend on.
        uint256 newPendingApproval = _pendingApprovalAmount[sellToken] >= sellAmount
            ? _pendingApprovalAmount[sellToken] - sellAmount
            : 0;
        _pendingApprovalAmount[sellToken] = newPendingApproval;

        // --- Interactions ---
        IERC20(sellToken).forceApprove(cowSettlement, newPendingApproval);

        // amountOut=0: buyToken went directly to Node via receiver=node; amount unknown here.
        emit OrderSettled(orderId, node, buyToken, 0);
    }

    /// @inheritdoc IOrderBookSwapModule
    /// @notice Cancel a pending order and return locked sellToken to the Node
    ///
    /// # Requirements
    /// - orderId must exist (node != address(0))
    /// - msg.sender must be the module owner (Ownable2Step)
    /// - order.status must be PENDING
    /// - GPv2Settlement.filledAmounts(orderId) < meta.sellAmount (not already filled)
    ///
    /// # Intended Uses
    /// - Order expired (validTo passed) without solver settlement
    /// - Module owner wants to reconfigure and retry with different params
    /// - Emergency recovery of locked tokens
    ///
    /// # filledAmounts guard
    /// Blocks cancellation of already-filled orders to prevent owner confusion. Note that
    /// after order expiry, solvers may free the filledAmounts slot (CowSwap gas optimization).
    /// In that edge case, the guard may pass on an expired-and-filled order; however, the
    /// module would hold 0 sellToken (solver already took it), so the cancel is a harmless no-op.
    ///
    /// # CEI Pattern
    /// Checks → state update (CANCELLED) → external transfers
    ///
    /// @param orderId GPv2Order digest returned by execute() via ExecutionResult.data
    function cancelOrder(bytes32 orderId) external {
        DataTypes.OrderMetadata storage meta = _orders[orderId];

        // --- Checks ---
        if (meta.node == address(0)) {
            revert Errors.OrderBookSwapModule_UnknownOrder(orderId);
        }
        if (msg.sender != owner()) {
            revert Errors.OrderBookSwapModule_NotOwner(msg.sender, owner());
        }
        if (meta.status != DataTypes.OrderStatus.PENDING) {
            revert Errors.OrderBookSwapModule_OrderNotPending(orderId, uint8(meta.status));
        }
        // Block cancellation if the order was already filled by a solver.
        // filledAmounts is reliable while the order is active; see NatSpec for expiry caveat.
        if (IGPv2Settlement(cowSettlement).filledAmounts(orderId) >= meta.sellAmount) {
            revert Errors.OrderBookSwapModule_OrderAlreadyFilled(orderId);
        }

        address sellToken = meta.sellToken;
        address node = meta.node;
        uint256 sellAmount = meta.sellAmount;

        // --- Effects ---
        meta.status = DataTypes.OrderStatus.CANCELLED;

        // [H-1 fix] Decrement cumulative approval rather than zeroing it.
        // See markFilled() for the same pattern and rationale.
        uint256 newPendingApproval = _pendingApprovalAmount[sellToken] >= sellAmount
            ? _pendingApprovalAmount[sellToken] - sellAmount
            : 0;
        _pendingApprovalAmount[sellToken] = newPendingApproval;

        // --- Interactions ---

        // Update GPv2Settlement approval to reflect the remaining pending orders.
        // If newPendingApproval == 0, this fully revokes approval (no concurrent orders remain).
        IERC20(sellToken).forceApprove(cowSettlement, newPendingApproval);

        // Return sellToken to Node, capped at this order's sellAmount.
        // Using min(balance, sellAmount) prevents draining tokens belonging to other
        // concurrent orders that share the same sellToken (fixes H-3).
        uint256 sellBalance = IERC20(sellToken).balanceOf(address(this));
        uint256 returnAmount = sellBalance < sellAmount ? sellBalance : sellAmount;
        if (returnAmount > 0) {
            IERC20(sellToken).safeTransfer(node, returnAmount);
        }

        emit OrderCancelled(orderId, node, sellToken, returnAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        IOrderBookSwapModule — EIP-1271 VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBookSwapModule
    /// @notice EIP-1271 signature validation called by CowSwap before settling our order
    ///
    /// # Called By
    /// CowSwap off-chain infrastructure before including our order in a batch auction.
    ///
    /// # Validation Logic
    /// Returns EIP1271_MAGIC_VALUE (0x1626ba7e) iff ALL of the following hold:
    ///   1. signature is exactly 32 bytes (ABI-encoded bytes32 orderId)
    ///   2. decoded orderId == hash (signature matches the specific order being settled)
    ///   3. _orders[orderId].node != address(0) (order was created by this module)
    ///   4. order.status == PENDING (not already marked SETTLED or CANCELLED)
    ///   5. block.timestamp <= meta.validTo (order has not expired)
    ///
    /// Returns 0xffffffff otherwise — CowSwap will reject the order from the batch.
    ///
    /// # Note on post-fill behaviour
    /// If markFilled() has not been called yet, a filled order still shows status=PENDING
    /// and isValidSignature() returns MAGIC_VALUE. This is safe: GPv2Settlement independently
    /// tracks filledAmounts and will not re-fill an already-filled order regardless of
    /// what isValidSignature returns. The order expires naturally or markFilled() is called.
    ///
    /// # Must never revert (EIP-1271 requirement)
    ///
    /// @param hash       GPv2Order EIP-712 digest computed by CowSwap
    /// @param signature  abi.encode(orderId) submitted to the CowSwap API
    /// @return magicValue 0x1626ba7e if valid, 0xffffffff if invalid
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        // Signature must be exactly 32 bytes: abi.encode(bytes32 orderId)
        if (signature.length != 32) {
            return EIP1271_FAILURE_VALUE;
        }

        bytes32 orderId = abi.decode(signature, (bytes32));

        // The signature's orderId must match the hash CowSwap computed for this order
        if (orderId != hash) {
            return EIP1271_FAILURE_VALUE;
        }

        DataTypes.OrderMetadata storage meta = _orders[orderId];

        // Order must have been created by this module instance
        if (meta.node == address(0)) {
            return EIP1271_FAILURE_VALUE;
        }

        // Order must still be in PENDING state (not marked SETTLED or CANCELLED)
        if (meta.status != DataTypes.OrderStatus.PENDING) {
            return EIP1271_FAILURE_VALUE;
        }

        // Order must not have expired — reads stored validTo directly (fixes C-1 overflow)
        if (block.timestamp > meta.validTo) {
            return EIP1271_FAILURE_VALUE;
        }

        return EIP1271_MAGIC_VALUE;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        IOrderBookSwapModule — PARAMETER ENCODING
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBookSwapModule
    /// @notice ABI-encode an OrderSwapParams struct for use in Node.configureToken()
    function encodeParams(DataTypes.OrderSwapParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params.targetToken, params.minBuyAmount, params.validityDuration, params.appData);
    }

    /// @inheritdoc IOrderBookSwapModule
    /// @notice Decode ABI-encoded bytes back into a typed OrderSwapParams struct
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.OrderSwapParams memory params) {
        (params.targetToken, params.minBuyAmount, params.validityDuration, params.appData) =
            abi.decode(encoded, (address, uint256, uint32, bytes32));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Computes the EIP-712 GPv2Order digest used as orderId
    /// @dev Must match CowSwap's off-chain order hashing exactly for isValidSignature() to work.
    ///      Uses the cached cowDomainSeparator and ORDER_TYPE_HASH constants.
    ///      Fields fixed by this module:
    ///        receiver         = node      — buyToken goes directly to the Node (not this module)
    ///        feeAmount        = 0         — CowSwap takes fees from surplus
    ///        kind             = KIND_SELL  — exact sell, minimum buy
    ///        partiallyFillable= false      — full fill only
    ///        sellTokenBalance = BALANCE_ERC20 — standard ERC20 (not Balancer vault)
    ///        buyTokenBalance  = BALANCE_ERC20 — standard ERC20 (not Balancer vault)
    /// @param sellToken  ERC20 token being sold
    /// @param buyToken   ERC20 token to receive
    /// @param node       Node address — used as receiver so buyToken goes directly to Node
    /// @param sellAmount Exact amount being sold
    /// @param buyAmount  Minimum acceptable buy amount
    /// @param validTo    Unix timestamp after which the order expires
    /// @param appData    CowSwap app data hash
    /// @return           EIP-712 GPv2Order digest (used as orderId throughout this module)
    function _computeOrderDigest(
        address sellToken,
        address buyToken,
        address node,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                sellToken,
                buyToken,
                node,           // receiver: buyToken sent directly to Node after settlement
                sellAmount,
                buyAmount,
                validTo,
                appData,
                uint256(0),     // feeAmount: 0 — CowSwap deducts fees from surplus
                KIND_SELL,
                false,          // partiallyFillable: false — full fill only
                BALANCE_ERC20,
                BALANCE_ERC20
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", cowDomainSeparator, structHash));
    }
}
