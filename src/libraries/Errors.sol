// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Errors
/// @notice Centralized error definitions for the Receivables PaymentRails system
/// @dev All custom errors are defined here for gas efficiency and maintainability
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                    NODE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to configure a token with zero address
    error PaymentRails_ZeroTokenAddress();

    /// @notice Thrown when clearing a token configuration but providing a non-zero module address
    /// @dev When actionType is empty (clearing config), actionModule must be address(0)
    error PaymentRails_NoneActionRequiresZeroModule();

    /// @notice Thrown when configuring a token action with zero module address
    /// @dev When actionType is set, actionModule must be a valid contract address
    error PaymentRails_ZeroModuleAddress();

    /// @notice Thrown when the action module contract doesn't implement required interface
    error PaymentRails_InvalidModule();

    /// @notice Thrown when module validation call fails
    /// @dev This occurs when moduleType() call reverts or returns invalid data
    error PaymentRails_ModuleValidationFailed();

    /// @notice Thrown when attempting to execute action on an unconfigured token
    error PaymentRails_TokenNotConfigured();

    /// @notice Thrown when attempting to execute action on a disabled token
    /// @dev Token must have enabled=true in its configuration
    error PaymentRails_TokenNotEnabled();

    /// @notice Thrown when attempting to execute but no action is configured
    /// @dev This occurs when actionType is empty string
    error PaymentRails_NoActionConfigured();

    /// @notice Thrown when execution amount is below the configured minimum balance threshold
    /// @param amount Attempted execution amount
    /// @param minBalance Required minimum balance
    error PaymentRails_BelowMinimumBalance(uint256 amount, uint256 minBalance);

    /// @notice Thrown when attempting to execute with zero amount
    error PaymentRails_ZeroAmount();

    /// @notice Thrown when paymentRails's token balance is insufficient for the requested amount
    /// @param balance PaymentRails's current token balance
    /// @param amount Requested execution amount
    error PaymentRails_InsufficientBalance(uint256 balance, uint256 amount);

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
                        UNISWAP SWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a router address is the zero address (addRouter / executionData).
    error DexSwapModule_ZeroRouter();

    /// @notice Thrown when a router address has no deployed code (is an EOA).
    /// @param router The EOA address that was rejected.
    error DexSwapModule_RouterNotContract(address router);

    /// @notice Thrown when the caller supplies a router that is not whitelisted.
    /// @param router The disallowed router address.
    error DexSwapModule_RouterNotAllowed(address router);

    /// @notice Thrown when the router already exists in the whitelist.
    /// @param router The duplicate router address.
    error DexSwapModule_RouterAlreadyAdded(address router);

    /// @notice Thrown when actual swap output is below the caller-supplied minimum.
    /// @param amountOut Actual output from the swap.
    /// @param minAmountOut Minimum acceptable output.
    error DexSwapModule_InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    /*//////////////////////////////////////////////////////////////////////////
                            COWSWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the CowSwap GPv2Settlement address is the zero address
    error CowSwapModule_ZeroCowSettlement();

    /// @notice Thrown when order target (buy) token is zero address
    error CowSwapModule_ZeroTargetToken();

    /// @notice Thrown when attempting to act on an orderId that was never created
    /// @param orderId The unknown order digest
    error CowSwapModule_UnknownOrder(bytes32 orderId);

    /// @notice Thrown when cancelOrder is called on an order that is already cancelled
    /// @param orderId The order digest
    error CowSwapModule_OrderAlreadyCancelled(bytes32 orderId);

    /// @notice Thrown when cancelOrder is called by an address that is not the module owner
    /// @param caller   Address that attempted cancellation
    /// @param owner    Module owner address (set at construction via Ownable2Step)
    error CowSwapModule_NotOwner(address caller, address owner);

    /// @notice Thrown when cancelOrder is called on an order already filled by a CowSwap solver
    /// @dev Verified via GPv2Settlement.filledAmounts(orderId) >= meta.sellAmount
    /// @param orderId The order digest
    error CowSwapModule_OrderAlreadyFilled(bytes32 orderId);

    /*//////////////////////////////////////////////////////////////////////////
                        CCTP BRIDGE MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the TokenMessengerV2 address is the zero address in the constructor.
    error CCTPBridgeModule_ZeroTokenMessenger();

    /// @notice Thrown when the USDC address is the zero address in the constructor.
    error CCTPBridgeModule_ZeroUSDC();

    /// @notice Thrown when the mint recipient is `bytes32(0)` in `setDomainConfig()`.
    error CCTPBridgeModule_ZeroMintRecipient();

    /// @notice Thrown when `minFinalityThreshold` is not 1000 or 2000.
    /// @param threshold The invalid finality threshold value.
    error CCTPBridgeModule_InvalidFinalityThreshold(uint32 threshold);

    /// @notice Thrown when attempting to remove a domain config that does not exist.
    /// @param destinationDomain The CCTP domain ID that is not configured.
    error CCTPBridgeModule_DomainNotConfigured(uint32 destinationDomain);
}
