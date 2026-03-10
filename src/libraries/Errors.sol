// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Errors
/// @notice Centralized error definitions for the Receivables Node system
/// @dev All custom errors are defined here for gas efficiency and maintainability
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                    NODE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to configure a token with zero address
    error Node_ZeroTokenAddress();

    /// @notice Thrown when clearing a token configuration but providing a non-zero module address
    /// @dev When actionType is empty (clearing config), actionModule must be address(0)
    error Node_NoneActionRequiresZeroModule();

    /// @notice Thrown when configuring a token action with zero module address
    /// @dev When actionType is set, actionModule must be a valid contract address
    error Node_ZeroModuleAddress();

    /// @notice Thrown when the action module contract doesn't implement required interface
    error Node_InvalidModule();

    /// @notice Thrown when module validation call fails
    /// @dev This occurs when moduleType() call reverts or returns invalid data
    error Node_ModuleValidationFailed();

    /// @notice Thrown when attempting to execute action on an unconfigured token
    error Node_TokenNotConfigured();

    /// @notice Thrown when attempting to execute action on a disabled token
    /// @dev Token must have enabled=true in its configuration
    error Node_TokenNotEnabled();

    /// @notice Thrown when attempting to execute but no action is configured
    /// @dev This occurs when actionType is empty string
    error Node_NoActionConfigured();

    /// @notice Thrown when execution amount is below the configured minimum balance threshold
    /// @param amount Attempted execution amount
    /// @param minBalance Required minimum balance
    error Node_BelowMinimumBalance(uint256 amount, uint256 minBalance);

    /// @notice Thrown when attempting to execute with zero amount
    error Node_ZeroAmount();

    /// @notice Thrown when node's token balance is insufficient for the requested amount
    /// @param balance Node's current token balance
    /// @param amount Requested execution amount
    error Node_InsufficientBalance(uint256 balance, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            ACTION MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when module execution fails
    /// @param module Address of the module that failed
    /// @param reason Failure reason from the module
    error Module_ExecutionFailed(address module, string reason);

    /// @notice Thrown when module validation fails
    /// @param module Address of the module that failed validation
    /// @param reason Validation failure reason
    error Module_ValidationFailed(address module, string reason);

    /*//////////////////////////////////////////////////////////////////////////
                            FORWARD MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when forward recipient is zero address
    error ForwardModule_ZeroRecipient();

    /// @notice Thrown when forward amount is below module's minimum
    /// @param amount Attempted forward amount
    /// @param minAmount Required minimum amount
    error ForwardModule_BelowMinimumAmount(uint256 amount, uint256 minAmount);

    /// @notice Thrown when token transfer to recipient fails
    /// @param recipient Recipient address
    /// @param amount Amount that failed to transfer
    error ForwardModule_TransferFailed(address recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            SWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when swap target token is zero address
    error SwapModule_ZeroTargetToken();

    /// @notice Thrown when DEX router address is zero
    error SwapModule_ZeroRouter();

    /// @notice Thrown when swap output is below minimum acceptable (slippage protection)
    /// @param amountOut Actual output amount
    /// @param minAmountOut Minimum acceptable output
    error SwapModule_InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    /// @notice Thrown when swap price deviates too much from oracle price
    /// @param actualPrice Price received from swap
    /// @param oraclePrice Expected price from oracle
    /// @param maxDeviationBps Maximum allowed deviation in basis points
    error SwapModule_PriceDeviationTooHigh(uint256 actualPrice, uint256 oraclePrice, uint256 maxDeviationBps);

    /// @notice Thrown when oracle price data is stale
    /// @param lastUpdate Timestamp of last oracle update
    /// @param currentTime Current block timestamp
    error SwapModule_StalePriceData(uint256 lastUpdate, uint256 currentTime);

    /*//////////////////////////////////////////////////////////////////////////
                        ORDER BOOK SWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when order target (buy) token is zero address
    error OrderBookSwapModule_ZeroTargetToken();

    /// @notice Thrown when minBuyAmount is zero — would accept any output, including dust
    error OrderBookSwapModule_ZeroMinBuyAmount();

    /// @notice Thrown when validityDuration is zero — order would expire immediately
    error OrderBookSwapModule_ZeroValidityDuration();

    /// @notice Thrown when sell and buy token are identical
    /// @param token The token address provided for both sides
    error OrderBookSwapModule_SameToken(address token);

    /// @notice Thrown when trying to claim an order that has not yet been settled by a solver
    /// @param orderId The order digest
    error OrderBookSwapModule_NotSettled(bytes32 orderId);

    /// @notice Thrown when attempting to act on an orderId that was never created
    /// @param orderId The unknown order digest
    error OrderBookSwapModule_UnknownOrder(bytes32 orderId);

    /// @notice Thrown when an operation requires PENDING status but order is in another state
    /// @param orderId Current order id
    /// @param status  Actual status of the order
    error OrderBookSwapModule_OrderNotPending(bytes32 orderId, uint8 status);

    /// @notice Thrown when cancelOrder is called by an address that is not the module owner
    /// @param caller   Address that attempted cancellation
    /// @param owner    Module owner address (set at construction)
    error OrderBookSwapModule_NotOwner(address caller, address owner);

    /// @notice Thrown when settled buy token balance is below the configured minBuyAmount
    /// @param received  Balance of buyToken in module after settlement
    /// @param minimum   Configured minBuyAmount for the order
    error OrderBookSwapModule_InsufficientSettlement(uint256 received, uint256 minimum);

    /*//////////////////////////////////////////////////////////////////////////
                            BRIDGE MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when destination address is zero
    error BridgeModule_ZeroDestinationAddress();

    /// @notice Thrown when bridge adapter address is zero
    error BridgeModule_ZeroAdapter();

    /// @notice Thrown when destination chain ID is invalid
    /// @param chainId Invalid chain ID provided
    error BridgeModule_InvalidChainId(uint256 chainId);

    /// @notice Thrown when bridge health score is below minimum threshold
    /// @param healthScore Current bridge health score
    /// @param minHealth Minimum required health score
    error BridgeModule_UnhealthyBridge(uint8 healthScore, uint256 minHealth);

    /// @notice Thrown when bridge has insufficient liquidity
    /// @param available Available bridge liquidity
    /// @param required Required liquidity for transfer
    error BridgeModule_InsufficientLiquidity(uint256 available, uint256 required);

    /// @notice Thrown when bridge execution fails
    /// @param adapter Bridge adapter address
    /// @param reason Failure reason
    error BridgeModule_BridgeFailed(address adapter, string reason);
}
