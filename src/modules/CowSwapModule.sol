// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ICowSwapModule } from "../interfaces/ICowSwapModule.sol";
import { IActionModule } from "../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { Errors } from "../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Minimal interface for the CowSwap GPv2Settlement contract.
interface IGPv2Settlement {
    /// @notice Returns the EIP-712 domain separator used to hash CowSwap orders.
    function domainSeparator() external view returns (bytes32);

    /// @notice Returns how much of an order has been filled.
    /// @dev For SELL orders, returns the cumulative sellAmount filled by solvers.
    ///      Returns 0 for unknown orders. CowSwap solvers may free this storage slot after
    ///      order expiry to reclaim gas — do not rely on it for post-expiry history.
    /// @param orderUid The 56-byte order UID: orderDigest (32) ++ owner (20) ++ validTo (4).
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

/// @title CowSwapModule
/// @author Credit Cooperative
/// @notice Async action module that submits sell orders to the CowSwap order-book protocol.
/// @dev See {ICowSwapModule} for the full lifecycle, deployment model, and security model.
///      Each Node must deploy its own private instance — do NOT share across Nodes.
contract CowSwapModule is ICowSwapModule, ActionModuleBase, Ownable2Step {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev EIP-1271 magic value returned by isValidSignature() for valid orders.
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev EIP-1271 failure value returned by isValidSignature() for invalid orders.
    bytes4 internal constant EIP1271_FAILURE_VALUE = 0xffffffff;

    /// @dev EIP-712 type hash for GPv2Order.Data. Computed as:
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

    /// @dev CowSwap order kind: sell an exact amount of sellToken.
    bytes32 internal constant KIND_SELL = keccak256("sell");

    /// @dev CowSwap balance type: standard ERC20 balances (not Balancer vault).
    bytes32 internal constant BALANCE_ERC20 = keccak256("erc20");

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICowSwapModule
    address public immutable override cowSettlement;

    /// @inheritdoc ICowSwapModule
    bytes32 public immutable override cowDomainSeparator;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev CowSwap orders keyed by GPv2Order digest (orderId). Populated in execute();
    ///      cancelled flag set in cancelOrder().
    mapping(bytes32 => DataTypes.CowOrderMetadata) private _orders;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploys this module and caches the CowSwap domain separator.
    /// @dev Reverts with {CowSwapModule_ZeroCowSettlement} if _cowSettlement is the zero address.
    ///      Deploy one instance per Node — do NOT share across Nodes.
    /// @param _cowSettlement Address of the CowSwap GPv2Settlement contract on this chain
    ///        (Mainnet: 0x9008D19f58AAbD9eD0D60971565AA8510560ab41).
    /// @param _owner Address that will own this module (permitted to call cancelOrder).
    constructor(address _cowSettlement, address _owner) Ownable(_owner) {
        if (_cowSettlement == address(0)) revert Errors.CowSwapModule_ZeroCowSettlement();
        cowSettlement = _cowSettlement;
        cowDomainSeparator = IGPv2Settlement(_cowSettlement).domainSeparator();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    /// @dev Initiates a CowSwap sell order — async semantics: amountOut=0 signals pending.
    ///
    ///      Token flow:
    ///        Node (msg.sender) →[transferFrom]→ this module →[CowSwap solver]→ Node (buyToken)
    ///
    ///      After this function emits {OrderCreated}, an off-chain keeper must:
    ///        1. Reconstruct the GPv2Order from event data.
    ///        2. Submit to the CowSwap API with signingScheme="eip1271",
    ///           signature=abi.encode(orderId), from=address(this module).
    ///        3. After the solver fills: done — buyToken is at the Node, no further call needed.
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external override(ActionModuleBase, IActionModule) returns (DataTypes.ExecutionResult memory result) {
        // [L-1] Reject malformed params early — params must be at least 128 bytes (4 ABI words)
        // to successfully decode (address, uint256, uint32, bytes32).
        if (params.length < 128) {
            return _failedResult(token, "Invalid params encoding");
        }

        DataTypes.CowSwapParams memory swapParams = decodeParams(params);

        // --- Validate parameters (all checks before any state change or interaction) ---

        // [L-1] Reject zero-amount orders — they lock no tokens but pollute state.
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
        // Solidity 0.8+ protects arithmetic but NOT explicit casts — a large validityDuration
        // would silently wrap validTo to a past timestamp, making isValidSignature() return
        // FAILURE immediately and locking tokens permanently.
        uint256 rawValidTo = block.timestamp + uint256(swapParams.validityDuration);
        if (rawValidTo > type(uint32).max) {
            return _failedResult(token, "Validity duration overflow");
        }
        uint32 validTo = uint32(rawValidTo);

        // Compute GPv2Order digest before the transfer so we can guard on collision.
        // receiver = msg.sender (Node): buyToken goes directly to Node after solver settles.
        bytes32 orderId = _computeOrderDigest(
            token,
            swapParams.targetToken,
            msg.sender,
            amount,
            swapParams.minBuyAmount,
            validTo,
            swapParams.appData
        );

        // [M-3] Reject if an order with this digest already exists. Without this guard a
        // second call with identical params in the same block would silently overwrite metadata
        // while depositing a second sellAmount, permanently orphaning the first deposit.
        // Use a unique appData to disambiguate.
        if (_orders[orderId].node != address(0)) {
            return _failedResult(token, "Order ID collision: use unique appData");
        }

        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        // Transfer sellToken from Node to this module.
        // Node pre-approves this module for `amount` before calling execute().
        // _safeTransferFrom wraps transferFrom in try/catch for graceful failure.
        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            return _failedResult(token, "Token transfer failed");
        }

        // Approve GPv2Settlement to pull sellToken (max, once per token).
        // GPv2Settlement address is immutable in its bytecode but is controlled by CoW Protocol governance
        // (https://etherscan.io/address/0x9008D19f58AAbD9eD0D60971565AA8510560ab41). ERC20 balance is
        // the hard ceiling on what it can pull. Setting max approval once avoids per-order
        // approval management and eliminates concurrent-order interference entirely.
        if (IERC20(token).allowance(address(this), cowSettlement) < type(uint256).max) {
            IERC20(token).forceApprove(cowSettlement, type(uint256).max);
        }

        // Persist order metadata.
        _orders[orderId] = DataTypes.CowOrderMetadata({
            node: msg.sender,
            sellToken: token,
            buyToken: swapParams.targetToken,
            sellAmount: amount,
            validTo: validTo,
            cancelled: false
        });

        emit OrderCreated(
            orderId, msg.sender, token, swapParams.targetToken, amount, swapParams.minBuyAmount, validTo, swapParams.appData
        );

        // amountOut=0 signals async pending (not a real output).
        // data=abi.encode(orderId) for the off-chain keeper to track this order.
        return _successResult(0, swapParams.targetToken, abi.encode(orderId));
    }

    /// @inheritdoc ICowSwapModule
    function cancelOrder(bytes32 orderId) external {
        DataTypes.CowOrderMetadata storage meta = _orders[orderId];

        // --- Checks ---
        if (meta.node == address(0)) {
            revert Errors.CowSwapModule_UnknownOrder(orderId);
        }
        // Manual owner check with custom error to provide context (msg.sender, owner) in the error.
        // This is preferred over an onlyOwner modifier to deliver better diagnostics.
        if (msg.sender != owner()) {
            revert Errors.CowSwapModule_NotOwner(msg.sender, owner());
        }
        if (meta.cancelled) {
            revert Errors.CowSwapModule_OrderAlreadyCancelled(orderId);
        }
        // Block cancellation if the order was already filled by a solver.
        // filledAmount is reliable while the order is active; see {ICowSwapModule} for the
        // post-expiry slot-clearing caveat.
        if (IGPv2Settlement(cowSettlement).filledAmount(_orderUid(orderId, meta.validTo)) >= meta.sellAmount) {
            revert Errors.CowSwapModule_OrderAlreadyFilled(orderId);
        }

        address sellToken = meta.sellToken;
        address node = meta.node;
        uint256 sellAmount = meta.sellAmount;

        // --- Effects ---
        meta.cancelled = true;

        // --- Interactions ---

        // Return sellToken to Node, capped at this order's sellAmount.
        // min(balance, sellAmount) prevents draining tokens belonging to other concurrent
        // orders that share the same sellToken (H-3 fix). Max approval to GPv2Settlement stays:
        // balance is zero after this transfer, so CowSwap cannot pull anything for this order.
        uint256 sellBalance = IERC20(sellToken).balanceOf(address(this));
        uint256 returnAmount = sellBalance < sellAmount ? sellBalance : sellAmount;
        if (returnAmount > 0) {
            IERC20(sellToken).safeTransfer(node, returnAmount);
        }

        emit OrderCancelled(orderId, node, sellToken, returnAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view override(ActionModuleBase, IActionModule) returns (bool isValid, string memory reason) {
        // [L-1] Reject malformed params early — mirrors execute()'s check.
        if (params.length < 128) {
            return (false, "Invalid params encoding");
        }

        if (amount == 0) {
            return (false, "Zero sell amount");
        }

        DataTypes.CowSwapParams memory swapParams = decodeParams(params);

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
        // [M-2] Guard against silent uint32 overflow — mirrors execute()'s check.
        uint256 rawValidTo = block.timestamp + uint256(swapParams.validityDuration);
        if (rawValidTo > type(uint32).max) {
            return (false, "Validity duration overflow");
        }
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    /// @inheritdoc ICowSwapModule
    function getOrder(bytes32 orderId) external view returns (DataTypes.CowOrderMetadata memory metadata) {
        return _orders[orderId];
    }

    /// @inheritdoc ICowSwapModule
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        // Signature must be exactly 32 bytes: abi.encode(bytes32 orderId).
        if (signature.length != 32) {
            return EIP1271_FAILURE_VALUE;
        }

        bytes32 orderId = abi.decode(signature, (bytes32));

        // The signature's orderId must match the hash CowSwap computed for this order.
        if (orderId != hash) {
            return EIP1271_FAILURE_VALUE;
        }

        DataTypes.CowOrderMetadata storage meta = _orders[orderId];

        // Order must have been created by this module instance.
        if (meta.node == address(0)) {
            return EIP1271_FAILURE_VALUE;
        }

        // Cancelled orders are never valid.
        if (meta.cancelled) {
            return EIP1271_FAILURE_VALUE;
        }

        // Check expiry BEFORE filledAmounts — saves the external call for expired orders.
        // Reads stored validTo directly (C-1 fix: no uint32 recomputation overflow).
        if (block.timestamp > meta.validTo) {
            return EIP1271_FAILURE_VALUE;
        }

        // Order must not already be filled by a solver.
        // Reliable before expiry: CowSwap only frees the slot post-expiry, and the check
        // above already returned FAILURE for expired orders.
        if (IGPv2Settlement(cowSettlement).filledAmount(_orderUid(orderId, meta.validTo)) >= meta.sellAmount) {
            return EIP1271_FAILURE_VALUE;
        }

        return EIP1271_MAGIC_VALUE;
    }

    /// @inheritdoc IActionModule
    /// @dev Returns minBuyAmount as the floor guarantee. Actual CowSwap output will be
    ///      >= minBuyAmount due to solver competition; the true amount is unknowable before
    ///      settlement.
    function estimateOutput(
        address, /* token */
        uint256, /* amount */
        bytes calldata params
    ) external pure override(ActionModuleBase, IActionModule) returns (uint256 estimatedOutput, address outputToken) {
        DataTypes.CowSwapParams memory swapParams = decodeParams(params);
        return (swapParams.minBuyAmount, swapParams.targetToken);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "COWSWAP";
    }

    /// @inheritdoc ICowSwapModule
    function encodeParams(DataTypes.CowSwapParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params.targetToken, params.minBuyAmount, params.validityDuration, params.appData);
    }

    /// @inheritdoc ICowSwapModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.CowSwapParams memory params) {
        (params.targetToken, params.minBuyAmount, params.validityDuration, params.appData) =
            abi.decode(encoded, (address, uint256, uint32, bytes32));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Computes the EIP-712 GPv2Order digest used as the orderId throughout this module.
    /// @dev Must match CowSwap's off-chain order hashing exactly for isValidSignature() to work.
    ///      Uses the cached {cowDomainSeparator} and {ORDER_TYPE_HASH} constants.
    ///
    ///      Fields fixed by this module:
    ///        receiver          = node        — buyToken goes directly to the Node
    ///        feeAmount         = 0           — CowSwap takes fees from surplus
    ///        kind              = KIND_SELL   — exact sell, minimum buy
    ///        partiallyFillable = false       — full fill only
    ///        sellTokenBalance  = BALANCE_ERC20 — standard ERC20 (not Balancer vault)
    ///        buyTokenBalance   = BALANCE_ERC20 — standard ERC20 (not Balancer vault)
    ///
    /// @param sellToken  ERC20 token being sold.
    /// @param buyToken   ERC20 token to receive.
    /// @param node       Node address used as receiver — buyToken goes directly to Node.
    /// @param sellAmount Exact amount being sold.
    /// @param buyAmount  Minimum acceptable buy amount.
    /// @param validTo    Unix timestamp after which the order expires.
    /// @param appData    CowSwap app data hash.
    /// @return           EIP-712 GPv2Order digest used as orderId throughout this module.
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
                node, // receiver: buyToken sent directly to Node after settlement
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

    /// @notice Constructs the 56-byte GPv2 order UID used to query filledAmount on GPv2Settlement.
    /// @dev Format: orderDigest (32 bytes) ++ owner (20 bytes) ++ validTo (4 bytes).
    ///      The "owner" in CoW Protocol is the address that signed (or EIP-1271-validates) the
    ///      order — i.e. this module instance, NOT the Node.
    /// @param orderId  EIP-712 GPv2Order digest (the first 32 bytes of the UID).
    /// @param validTo  Order expiry timestamp (the last 4 bytes of the UID).
    /// @return uid     The 56-byte packed order UID.
    function _orderUid(bytes32 orderId, uint32 validTo) internal view returns (bytes memory uid) {
        return abi.encodePacked(orderId, address(this), validTo);
    }
}
