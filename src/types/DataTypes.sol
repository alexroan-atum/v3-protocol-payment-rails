// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title DataTypes
/// @notice Centralized type definitions for the Receivables PaymentRails system.
library DataTypes {
    /*//////////////////////////////////////////////////////////////////////////
                                PAYMENT RAILS TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Configuration for a token's action in the PaymentRails.
    struct TokenConfig {
        string actionType;
        address actionModule;
        bool enabled;
        uint256 minBalance;
        bytes moduleParams;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ACTION MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Result of an action execution, returned by all module execute() functions.
    struct ExecutionResult {
        bool success;
        uint256 amountOut;
        address outputToken;
        bytes data;
        string failureReason;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FORWARD MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Forward configuration parameters.
    struct ForwardParams {
        address recipient;
        uint256 minAmount;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        DEX SWAP MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Static configuration for DEX swaps (stored in PaymentRails.moduleParams).
    /// @dev Oracle feeds are mandatory. Both feeds MUST use the same quote currency (e.g., both
    /// TOKEN/USD) — mixing produces a silently incorrect oracle floor.
    struct DexSwapParams {
        address targetToken;
        uint24 fee;
        uint16 maxSlippageBps;
        address sellTokenPriceFeed;
        address buyTokenPriceFeed;
        uint256 maxStaleness;
        uint256 swapDeadlineSeconds;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            COWSWAP MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Parameters for configuring a CowSwap order-book swap.
    /// @dev Oracle feeds are mandatory and MUST share the same quote currency (see DexSwapParams).
    /// buyAmount is computed on-chain: `oracleExpected * (10000 - maxSlippageBps) / 10000`.
    struct CowSwapParams {
        address targetToken;
        uint16 maxSlippageBps;
        address sellTokenPriceFeed;
        address buyTokenPriceFeed;
        uint256 maxStaleness;
        uint32 validityDuration;
        bytes32 appData;
    }

    /// @notice On-chain metadata stored per CowSwap order, keyed by orderId (GPv2Order digest).
    /// @dev validTo stored directly to avoid uint32 recomputation overflow.
    /// SETTLED state is derived live from GPv2Settlement.filledAmount().
    struct CowOrderMetadata {
        address paymentRails;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint32 validTo;
        bool cancelled;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        CCTP BRIDGE MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Routing parameters for a CCTP bridge action, stored in PaymentRails's moduleParams.
    /// @dev destinationDomain is CCTP domain ID (NOT EVM chain ID). maxFeeBps is used to compute
    ///      the maxFee passed to Circle's TokenMessengerV2 at execution time:
    ///      `maxFee = amount * maxFeeBps / 10_000`. This replaces a static maxFee to match Circle's
    ///      percentage-based fee model and scale correctly with any bridge amount.
    struct CCTPBridgeParams {
        /// @dev CCTP domain ID of the destination chain (NOT an EVM chain ID).
        uint32 destinationDomain;
        /// @dev Recipient address on the destination chain, left-padded to bytes32.
        bytes32 mintRecipient;
        /// @dev Address allowed to call `receiveMessage` on the destination. `bytes32(0)` = anyone.
        bytes32 destinationCaller;
        /// @dev Fee ceiling in basis points. `maxFee = amount * maxFeeBps / 10_000`.
        uint16 maxFeeBps;
        /// @dev 1000 for fast (confirmed) or 2000 for standard (finalized) finality.
        uint32 minFinalityThreshold;
        /// @dev Arbitrary bytes for destination-chain post-mint automation. Empty = no hook.
        bytes hookData;
    }
}
