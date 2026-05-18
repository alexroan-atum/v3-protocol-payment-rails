// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { ICowSwapModule } from "../../interfaces/ICowSwapModule.sol";
import { IGPv2Settlement } from "../../interfaces/IGPv2Settlement.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CowSwapModule
/// @author Credit Cooperative
/// @notice Async action module that submits sell orders to the CowSwap order-book protocol.
/// @dev See {ICowSwapModule} for the full lifecycle, deployment model, and security model.
/// Each PaymentRails must deploy its own private instance — do NOT share across PaymentRails.
contract CowSwapModule is ICowSwapModule, ActionModuleBase, Ownable2Step {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev EIP-1271 magic value returned for valid orders.
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev EIP-1271 failure value returned for invalid orders.
    bytes4 internal constant EIP1271_FAILURE_VALUE = 0xffffffff;

    /// @dev EIP-712 type hash for GPv2Order.Data.
    /// See: https://github.com/cowprotocol/contracts/blob/main/src/contracts/libraries/GPv2Order.sol
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(
        "Order(" "address sellToken," "address buyToken," "address receiver," "uint256 sellAmount," "uint256 buyAmount,"
        "uint32 validTo," "bytes32 appData," "uint256 feeAmount," "string kind," "bool partiallyFillable,"
        "string sellTokenBalance," "string buyTokenBalance" ")"
    );

    /// @dev CowSwap order kind: sell an exact amount of sellToken.
    bytes32 internal constant KIND_SELL = keccak256("sell");

    /// @dev CowSwap balance type: standard ERC-20 balances (not Balancer vault).
    bytes32 internal constant BALANCE_ERC20 = keccak256("erc20");

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICowSwapModule
    address public immutable override cowSettlement;

    /// @notice Address of the GPv2VaultRelayer that pulls sellToken during settlement.
    address public immutable vaultRelayer;

    /// @inheritdoc ICowSwapModule
    bytes32 public immutable override cowDomainSeparator;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Order metadata keyed by GPv2Order digest.
    mapping(bytes32 orderId => DataTypes.CowOrderMetadata metadata) private _orders;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Emits no events. Reverts with {Errors.CowSwapModule_ZeroCowSettlement} if
    /// `_cowSettlement` is the zero address.
    /// @param _cowSettlement Address of the GPv2Settlement contract on this chain.
    /// @param _owner Address that will own this module (can call `cancelOrder`).
    constructor(address _cowSettlement, address _owner) Ownable(_owner) {
        if (_cowSettlement == address(0)) revert Errors.CowSwapModule_ZeroCowSettlement();

        cowSettlement = _cowSettlement;
        cowDomainSeparator = IGPv2Settlement(_cowSettlement).domainSeparator();
        vaultRelayer = IGPv2Settlement(_cowSettlement).vaultRelayer();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function execute(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata /* executionData */
    )
        external
        override(ActionModuleBase, IActionModule)
        returns (DataTypes.ExecutionResult memory result)
    {
        DataTypes.CowSwapParams memory swapParams;
        uint32 validTo;

        {
            bool valid;
            string memory reason;
            (valid, reason, swapParams, validTo) = _validateSwapParams(token, amount, params);
            if (!valid) {
                return _failedResult(token, reason);
            }
        }

        bytes32 orderId = _computeOrderDigest(
            token, swapParams.targetToken, msg.sender, amount, swapParams.minBuyAmount, validTo, swapParams.appData
        );

        if (_orders[orderId].paymentRails != address(0)) {
            return _failedResult(token, "Order ID collision: use unique appData");
        }

        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        // --- Interactions ---

        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            return _failedResult(token, "Token transfer failed");
        }

        if (IERC20(token).allowance(address(this), vaultRelayer) < type(uint256).max) {
            IERC20(token).forceApprove(vaultRelayer, type(uint256).max);
        }

        // --- Effects ---

        _orders[orderId] = DataTypes.CowOrderMetadata({
            paymentRails: msg.sender,
            sellToken: token,
            buyToken: swapParams.targetToken,
            sellAmount: amount,
            validTo: validTo,
            cancelled: false
        });

        emit OrderCreated(
            orderId,
            msg.sender,
            token,
            swapParams.targetToken,
            amount,
            swapParams.minBuyAmount,
            validTo,
            swapParams.appData
        );

        return _successResult(0, swapParams.targetToken, abi.encode(orderId));
    }

    /// @inheritdoc ICowSwapModule
    function cancelOrder(bytes32 orderId) external {
        DataTypes.CowOrderMetadata storage meta = _orders[orderId];

        if (meta.paymentRails == address(0)) {
            revert Errors.CowSwapModule_UnknownOrder(orderId);
        }
        if (msg.sender != owner()) {
            revert Errors.CowSwapModule_NotOwner(msg.sender, owner());
        }
        if (meta.cancelled) {
            revert Errors.CowSwapModule_OrderAlreadyCancelled(orderId);
        }
        if (IGPv2Settlement(cowSettlement).filledAmount(_orderUid(orderId, meta.validTo)) >= meta.sellAmount) {
            revert Errors.CowSwapModule_OrderAlreadyFilled(orderId);
        }

        address sellToken = meta.sellToken;
        address paymentRails = meta.paymentRails;
        uint256 sellAmount = meta.sellAmount;

        meta.cancelled = true;

        // Cap return at this order's sellAmount to protect concurrent orders sharing the same token.
        uint256 sellBalance = IERC20(sellToken).balanceOf(address(this));
        uint256 returnAmount = sellBalance < sellAmount ? sellBalance : sellAmount;
        if (returnAmount > 0) {
            IERC20(sellToken).safeTransfer(paymentRails, returnAmount);
        }

        emit OrderCancelled(orderId, paymentRails, sellToken, returnAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata /* executionData */
    )
        external
        view
        override(ActionModuleBase, IActionModule)
        returns (bool isValid, string memory reason)
    {
        (isValid, reason,,) = _validateSwapParams(token, amount, params);
        if (!isValid) {
            return (false, reason);
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
        if (signature.length != 32) {
            return EIP1271_FAILURE_VALUE;
        }

        bytes32 orderId = abi.decode(signature, (bytes32));

        if (orderId != hash) {
            return EIP1271_FAILURE_VALUE;
        }

        DataTypes.CowOrderMetadata storage meta = _orders[orderId];

        if (meta.paymentRails == address(0)) {
            return EIP1271_FAILURE_VALUE;
        }
        if (meta.cancelled) {
            return EIP1271_FAILURE_VALUE;
        }

        // Check expiry before filledAmount to save the external call for expired orders.
        if (block.timestamp > meta.validTo) {
            return EIP1271_FAILURE_VALUE;
        }
        if (IGPv2Settlement(cowSettlement).filledAmount(_orderUid(orderId, meta.validTo)) >= meta.sellAmount) {
            return EIP1271_FAILURE_VALUE;
        }

        return EIP1271_MAGIC_VALUE;
    }

    /// @inheritdoc IActionModule
    function estimateOutput(
        address, /* token */
        uint256, /* amount */
        bytes calldata params
    )
        external
        pure
        override(ActionModuleBase, IActionModule)
        returns (uint256 estimatedOutput, address outputToken)
    {
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

    /// @dev Shared parameter validation for `execute` and `validate`. Decodes and checks all swap
    ///      parameters without touching storage, so callers avoid duplicated logic.
    function _validateSwapParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (bool valid, string memory reason, DataTypes.CowSwapParams memory swapParams, uint32 validTo)
    {
        if (params.length < 128) {
            return (false, "Invalid params encoding", swapParams, 0);
        }

        swapParams = decodeParams(params);

        if (amount == 0) {
            return (false, "Zero sell amount", swapParams, 0);
        }
        if (swapParams.targetToken == address(0)) {
            return (false, "Zero target token", swapParams, 0);
        }
        if (swapParams.targetToken == token) {
            return (false, "Same sell and buy token", swapParams, 0);
        }
        if (swapParams.minBuyAmount == 0) {
            return (false, "Zero minimum buy amount", swapParams, 0);
        }
        if (swapParams.validityDuration == 0) {
            return (false, "Zero validity duration", swapParams, 0);
        }

        uint256 rawValidTo = block.timestamp + uint256(swapParams.validityDuration);
        if (rawValidTo > type(uint32).max) {
            return (false, "Validity duration overflow", swapParams, 0);
        }

        return (true, "", swapParams, uint32(rawValidTo));
    }

    /// @dev Computes the EIP-712 GPv2Order digest used as orderId throughout this module.
    /// Fixed fields: receiver=paymentRails, feeAmount=0, kind=SELL, partiallyFillable=false,
    /// sellTokenBalance=erc20, buyTokenBalance=erc20.
    function _computeOrderDigest(
        address sellToken,
        address buyToken,
        address paymentRails,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                sellToken,
                buyToken,
                paymentRails,
                sellAmount,
                buyAmount,
                validTo,
                appData,
                uint256(0),
                KIND_SELL,
                false,
                BALANCE_ERC20,
                BALANCE_ERC20
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", cowDomainSeparator, structHash));
    }

    /// @dev Constructs the 56-byte GPv2 order UID: digest (32) ++ owner (20) ++ validTo (4).
    /// The "owner" is this module (the EIP-1271 signer), NOT the PaymentRails.
    function _orderUid(bytes32 orderId, uint32 validTo) internal view returns (bytes memory uid) {
        return abi.encodePacked(orderId, address(this), validTo);
    }
}
