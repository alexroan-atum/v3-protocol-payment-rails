// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title Errors
/// @notice Centralized error definitions for the Receivables PaymentRails system
/// @dev All custom errors are defined here for gas efficiency and maintainability
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                PAYMENT RAILS ERRORS
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
                            DEX SWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the router address is the zero address in the constructor.
    error DexSwapModule_ZeroRouter();

    /// @notice Thrown when the router address has no deployed code in the constructor.
    /// @param router The EOA address that was rejected.
    error DexSwapModule_RouterNotContract(address router);

    /// @notice Thrown when actual swap output is below the oracle-computed floor.
    /// @param amountOut Actual output from the swap.
    /// @param oracleFloor Oracle-computed minimum after applying `maxSlippageBps`.
    error DexSwapModule_InsufficientOutput(uint256 amountOut, uint256 oracleFloor);

    /*//////////////////////////////////////////////////////////////////////////
                            OWNERSHIP ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when renounceOwnership() is called on PaymentRails.
    /// @dev Ownership renunciation is permanently disabled to prevent locking the contract.
    error PaymentRails_OwnershipCannotBeRenounced();

    /*//////////////////////////////////////////////////////////////////////////
                            COWSWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the CowSwap GPv2Settlement address is the zero address
    error CowSwapModule_ZeroCowSettlement();

    /// @notice Thrown when attempting to act on an orderId that was never created
    /// @param orderId The unknown order digest
    error CowSwapModule_UnknownOrder(bytes32 orderId);

    /// @notice Thrown when cancelOrder is called on an order that is already cancelled
    /// @param orderId The order digest
    error CowSwapModule_OrderAlreadyCancelled(bytes32 orderId);

    /// @notice Thrown when cancelOrder is called on an order already filled by a CowSwap solver
    /// @dev Verified via GPv2Settlement.filledAmounts(orderId) >= meta.sellAmount
    /// @param orderId The order digest
    error CowSwapModule_OrderAlreadyFilled(bytes32 orderId);

    /// @notice Thrown when renounceOwnership() is called on CowSwapModule.
    /// @dev Ownership renunciation is permanently disabled because it would lock
    /// all pending orders' sell tokens with no way to cancel them.
    error CowSwapModule_OwnershipCannotBeRenounced();

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
