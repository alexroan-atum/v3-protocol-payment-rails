// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IOrderBookSwapModule } from "../interfaces/IOrderBookSwapModule.sol";
import { IAsyncActionModule } from "../interfaces/IAsyncActionModule.sol";
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
}

/// @title OrderBookSwapModule
/// @author Credit Cooperative
/// @notice Async action module that submits sell orders to the CowSwap order-book protocol
///
/// # Overview
/// Implements the IAsyncActionModule lifecycle for CowSwap (GPv2 / CoW Protocol):
///
///   1. execute()         — locks sellToken in this module, approves CowSwap Settlement,
///                          computes the GPv2Order digest (orderId), persists metadata,
///                          returns amountOut=0 as the off-chain "pending" signal.
///
///   2. (off-chain)       — keeper reads the OrderCreated event, reconstructs the full
///                          GPv2Order, and submits it to the CowSwap API with
///                          signingScheme="eip1271", signature=abi.encode(orderId).
///
///   3. isValidSignature()— CowSwap's off-chain infrastructure calls this (EIP-1271) before
///                          including our order in a batch auction. Returns the magic value
///                          iff the orderId is PENDING and matches the submitted hash.
///
///   4. claimSettlement() — after a CowSwap solver settles the order (buyToken arrives in
///                          this module), the Node calls claimSettlement() to collect tokens.
///
///   5. cancelOrder()     — if settlement never arrives (expired or unwanted), the Node calls
///                          cancelOrder() to recover the locked sellToken.
///
/// # Deployment Model
/// Each Node MUST deploy its own private OrderBookSwapModule instance.
/// Modules MUST NOT be shared across Nodes — _pendingOrders keyed by orderId (GPv2 digest)
/// are globally unique per deployment and assume a single owner (Node).
///
/// # CowSwap Integration Details
/// - GPv2Settlement: immutable address set in constructor
/// - Order kind: SELL (exact sell amount, minimum buy amount)
/// - Receiver: address(this) — buyToken arrives directly in this module
/// - partiallyFillable: false — full fill only
/// - feeAmount: 0 — CowSwap takes fees from surplus
/// - EIP-1271 signature: abi.encode(orderId) (32 bytes)
///
/// # Security Model
/// - claimSettlement() is permissionless — tokens always transfer to meta.node (the creating Node)
/// - cancelOrder() is restricted to the module owner (set at construction via Ownable2Step)
/// - Approval to GPv2Settlement is set per-order and revoked on settle/cancel
/// - CEI (Checks-Effects-Interactions) pattern enforced in all state-changing functions
/// - amountOut=0 in ExecutionResult signals async pending — never mistaken for a real output
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

    /// @notice Pending CowSwap orders keyed by GPv2Order digest (orderId)
    /// @dev Populated in execute(), updated in claimSettlement() and cancelOrder()
    mapping(bytes32 => DataTypes.OrderMetadata) private _pendingOrders;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploys this module and caches the CowSwap domain separator
    /// @dev Deploy one instance per Node — do NOT share across Nodes
    /// @param _cowSettlement Address of the CowSwap GPv2Settlement contract on this chain
    ///   Mainnet Ethereum: 0x9008D19f58AAbD9eD0D60971565AA8510560ab41
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
    /// Unlike synchronous modules, execute() here INITIATES rather than COMPLETES the swap:
    ///   - amountOut == 0 in the returned result signals "pending settlement" off-chain
    ///   - ExecutionResult.data == abi.encode(orderId) for keeper use
    ///   - Settlement is completed later via claimSettlement()
    ///
    /// # Token Flow
    ///   Node (msg.sender)  →[transferFrom]→  this module  →[CowSwap solver]→  buyToken arrives
    ///
    /// # Off-chain Keeper Responsibilities
    /// After execute() emits OrderCreated, a keeper must:
    ///   1. Reconstruct the GPv2Order from event data (sellToken, buyToken, amounts, validTo, appData)
    ///   2. Submit to CowSwap API with signingScheme="eip1271", signature=abi.encode(orderId)
    ///   3. Poll checkSettlement(orderId) until true, then call claimSettlement(orderId)
    ///
    /// # Requirements
    /// - params must decode to valid OrderSwapParams (non-zero targetToken/minBuyAmount/validityDuration)
    /// - sell token != buy token
    /// - Node (msg.sender) must have approved this module for at least `amount`
    /// - Node (msg.sender) must hold at least `amount` of `token`
    ///
    /// @param token   ERC20 token to sell (sellToken)
    /// @param amount  Exact amount to sell (locked in this module until settled or cancelled)
    /// @param params  ABI-encoded OrderSwapParams — use encodeParams() to build
    /// @return result success=true, amountOut=0 (pending), outputToken=buyToken, data=abi.encode(orderId)
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external override(ActionModuleBase, IActionModule) returns (DataTypes.ExecutionResult memory result) {
        DataTypes.OrderSwapParams memory swapParams = decodeParams(params);

        // --- Validate parameters ---

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

        // --- Approve GPv2Settlement to pull sellToken ---
        // CowSwap solver will call settlement.settle() which transfersFrom this module.
        // forceApprove resets to 0 first (handles USDT-style approve restrictions).
        IERC20(token).forceApprove(cowSettlement, amount);

        // --- Compute validTo and GPv2Order digest ---
        uint32 validTo = uint32(block.timestamp + uint256(swapParams.validityDuration));
        bytes32 orderId = _computeOrderDigest(
            token,
            swapParams.targetToken,
            amount,
            swapParams.minBuyAmount,
            validTo,
            swapParams.appData
        );

        // --- Persist order metadata ---
        _pendingOrders[orderId] = DataTypes.OrderMetadata({
            node: msg.sender,
            sellToken: token,
            buyToken: swapParams.targetToken,
            sellAmount: amount,
            minBuyAmount: swapParams.minBuyAmount,
            createdAt: block.timestamp,
            validityDuration: swapParams.validityDuration,
            status: DataTypes.OrderStatus.PENDING
        });

        emit OrderCreated(orderId, msg.sender, token, swapParams.targetToken, amount, swapParams.minBuyAmount, validTo, swapParams.appData);

        // amountOut=0 is the off-chain signal that settlement is pending (not a real output).
        // data=abi.encode(orderId) for keeper to identify the pending order.
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
                        IAsyncActionModule — SETTLEMENT LIFECYCLE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAsyncActionModule
    /// @notice Check whether a CowSwap solver has settled our order
    /// @dev Checks if this module holds at least minBuyAmount of the buyToken.
    ///      Returns (false, 0) for unknown orderIds or non-PENDING orders.
    function checkSettlement(bytes32 orderId) external view returns (bool isSettled, uint256 amountOut) {
        DataTypes.OrderMetadata storage meta = _pendingOrders[orderId];

        if (meta.node == address(0)) return (false, 0);
        if (meta.status != DataTypes.OrderStatus.PENDING) return (false, 0);

        uint256 balance = IERC20(meta.buyToken).balanceOf(address(this));
        if (balance >= meta.minBuyAmount) {
            return (true, balance);
        }
        return (false, 0);
    }

    /// @inheritdoc IAsyncActionModule
    /// @notice Returns the full metadata for any order (pending, settled, cancelled, or unknown)
    function getOrder(bytes32 orderId) external view returns (DataTypes.OrderMetadata memory metadata) {
        return _pendingOrders[orderId];
    }

    /// @inheritdoc IAsyncActionModule
    /// @notice Collect settled buyTokens and push them back to the Node
    ///
    /// # Requirements
    /// - orderId must exist (node != address(0))
    /// - order.status must be PENDING
    /// - This module must hold >= minBuyAmount of buyToken (solver has settled)
    ///
    /// # Permissionless
    /// Any caller may trigger the claim. Tokens ALWAYS transfer to meta.node (the Node that
    /// created the order) — caller identity has no effect on token destination. This enables
    /// keeper infrastructure to call claimSettlement directly without Node proxy methods.
    ///
    /// # Token Flow (after CowSwap settlement)
    ///   CowSwap solver  →[transferred buyToken]→  this module  →[safeTransfer]→  Node
    ///
    /// # CEI Pattern
    /// Checks → state update (SETTLED) → external transfers
    ///
    /// @param orderId GPv2Order digest returned by execute() via ExecutionResult.data
    /// @return result success=true, amountOut=actual buyToken amount transferred, outputToken=buyToken
    function claimSettlement(bytes32 orderId) external returns (DataTypes.ExecutionResult memory result) {
        DataTypes.OrderMetadata storage meta = _pendingOrders[orderId];

        // --- Checks ---
        if (meta.node == address(0)) {
            revert Errors.OrderBookSwapModule_UnknownOrder(orderId);
        }
        if (meta.status != DataTypes.OrderStatus.PENDING) {
            revert Errors.OrderBookSwapModule_OrderNotPending(orderId, uint8(meta.status));
        }

        // Read values needed for checks and interactions before state mutation
        address buyToken = meta.buyToken;
        address sellToken = meta.sellToken;
        address node = meta.node;
        uint256 minBuyAmount = meta.minBuyAmount;

        uint256 buyTokenBalance = IERC20(buyToken).balanceOf(address(this));
        if (buyTokenBalance < minBuyAmount) {
            revert Errors.OrderBookSwapModule_NotSettled(orderId);
        }

        // --- Effects ---
        meta.status = DataTypes.OrderStatus.SETTLED;

        // --- Interactions ---

        // Revoke any residual sellToken approval to GPv2Settlement (cleanup)
        IERC20(sellToken).forceApprove(cowSettlement, 0);

        // Transfer entire buyToken balance to Node (captures any surplus from solver competition)
        IERC20(buyToken).safeTransfer(node, buyTokenBalance);

        emit OrderSettled(orderId, node, buyToken, buyTokenBalance);

        return _successResult(buyTokenBalance, buyToken, abi.encode(orderId));
    }

    /// @inheritdoc IAsyncActionModule
    /// @notice Cancel a pending order and return locked sellToken to the Node
    ///
    /// # Requirements
    /// - orderId must exist (node != address(0))
    /// - msg.sender must be the Node stored in order metadata
    /// - order.status must be PENDING
    ///
    /// # Intended Uses
    /// - Order expired (validTo passed) without solver settlement
    /// - Node owner wants to reconfigure and retry with different params
    /// - Emergency recovery of locked tokens
    ///
    /// # CEI Pattern
    /// Checks → state update (CANCELLED) → external transfers
    ///
    /// @param orderId GPv2Order digest returned by execute() via ExecutionResult.data
    function cancelOrder(bytes32 orderId) external {
        DataTypes.OrderMetadata storage meta = _pendingOrders[orderId];

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

        // Read values before state mutation
        address sellToken = meta.sellToken;
        address node = meta.node;

        // --- Effects ---
        meta.status = DataTypes.OrderStatus.CANCELLED;

        // --- Interactions ---

        // Revoke GPv2Settlement approval — prevents solver from filling a cancelled order
        IERC20(sellToken).forceApprove(cowSettlement, 0);

        // Return all sellToken held by this module back to Node
        uint256 sellBalance = IERC20(sellToken).balanceOf(address(this));
        if (sellBalance > 0) {
            IERC20(sellToken).safeTransfer(node, sellBalance);
        }

        emit OrderCancelled(orderId, node, sellToken, sellBalance);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        IOrderBookSwapModule — EIP-1271 VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderBookSwapModule
    /// @notice EIP-1271 signature validation called by CowSwap before settling our order
    ///
    /// # Called By
    /// CowSwap off-chain infrastructure before including our order in a batch auction.
    /// The call comes from GPv2Settlement (or CowSwap's signing infrastructure).
    ///
    /// # Validation Logic
    /// Returns EIP1271_MAGIC_VALUE (0x1626ba7e) iff ALL of the following hold:
    ///   1. signature is exactly 32 bytes (ABI-encoded bytes32 orderId)
    ///   2. decoded orderId == hash (signature matches the specific order being settled)
    ///   3. _pendingOrders[orderId].node != address(0) (order was created by this module)
    ///   4. order.status == PENDING (not already settled or cancelled)
    ///   5. block.timestamp <= validTo (order has not expired)
    ///
    /// Returns 0xffffffff otherwise — CowSwap will reject the order from the batch.
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

        DataTypes.OrderMetadata storage meta = _pendingOrders[orderId];

        // Order must have been created by this module instance
        if (meta.node == address(0)) {
            return EIP1271_FAILURE_VALUE;
        }

        // Order must still be in PENDING state
        if (meta.status != DataTypes.OrderStatus.PENDING) {
            return EIP1271_FAILURE_VALUE;
        }

        // Order must not have expired
        uint32 validTo = uint32(meta.createdAt) + meta.validityDuration;
        if (block.timestamp > validTo) {
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
    ///        receiver         = address(this)  — buyToken arrives in module, not Node
    ///        feeAmount        = 0              — CowSwap takes fees from surplus
    ///        kind             = KIND_SELL       — exact sell, minimum buy
    ///        partiallyFillable= false           — full fill only
    ///        sellTokenBalance = BALANCE_ERC20   — standard ERC20 (not Balancer vault)
    ///        buyTokenBalance  = BALANCE_ERC20   — standard ERC20 (not Balancer vault)
    /// @param sellToken  ERC20 token being sold
    /// @param buyToken   ERC20 token to receive
    /// @param sellAmount Exact amount being sold
    /// @param buyAmount  Minimum acceptable buy amount
    /// @param validTo    Unix timestamp after which the order expires
    /// @param appData    CowSwap app data hash
    /// @return           EIP-712 GPv2Order digest (used as orderId throughout this module)
    function _computeOrderDigest(
        address sellToken,
        address buyToken,
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
                address(this), // receiver: buyToken sent to this module after settlement
                sellAmount,
                buyAmount,
                validTo,
                appData,
                uint256(0), // feeAmount: 0 — CowSwap deducts fees from surplus
                KIND_SELL,
                false, // partiallyFillable: false — full fill only
                BALANCE_ERC20,
                BALANCE_ERC20
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", cowDomainSeparator, structHash));
    }
}
