// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title DataTypes
/// @notice Centralized type definitions for the Receivables PaymentRails system
/// @dev This library contains all struct definitions used across PaymentRails, modules, and interfaces
library DataTypes {
    /*//////////////////////////////////////////////////////////////////////////
                                PAYMENT RAILS TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Configuration for a token's action in the PaymentRails
    /// @dev Stored per token address in the paymentRails's configuration mapping
    /// @param actionType String identifier for the action (e.g., "FORWARD", "SWAP", "BRIDGE")
    /// @param actionModule Address of the action module contract that will handle execution
    /// @param enabled Master switch to enable/disable this token's action
    /// @param minBalance Minimum balance threshold required to trigger execution
    /// @param moduleParams ABI-encoded module-specific parameters
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

    /// @notice Result of an action execution
    /// @dev Returned by all action module execute() functions
    /// @param success Whether the action completed successfully
    /// @param amountOut Amount of output token produced
    /// @param outputToken Address of the output token (may differ from input token)
    /// @param data Additional result data (module-specific, can be empty)
    /// @param failureReason Error message if execution failed (empty if successful)
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

    /// @notice Forward configuration parameters
    /// @dev Used by ForwardModule to configure simple token transfers
    /// @param recipient Destination address for tokens
    /// @param minAmount Minimum amount required to forward (0 = no minimum)
    struct ForwardParams {
        address recipient;
        uint256 minAmount;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        DEX SWAP MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Static configuration for DEX swaps (stored in PaymentRails.moduleParams).
    /// @dev All swap parameters are owner-configured — the permissionless executor supplies nothing.
    ///      The module computes `amountOutMinimum` from Chainlink oracle prices at execution time,
    ///      so oracle feeds are mandatory (not optional).
    /// @param targetToken Required output token — module rejects any swap producing a different token.
    /// @param fee Uniswap V3 pool fee tier in hundredths of a basis point (e.g., 500 = 0.05%,
    ///        3000 = 0.3%, 10000 = 1%). Determines which liquidity pool is used for the swap.
    /// @param maxSlippageBps Owner-configured maximum slippage in basis points (e.g., 200 = 2%).
    ///        Applied to the oracle-expected output to compute the minimum acceptable amount.
    ///        Must be > 0 and <= 10000.
    /// @param sellTokenPriceFeed Chainlink AggregatorV3 address for the sell token's USD price.
    ///        Must be non-zero — oracle enforcement is mandatory.
    /// @param buyTokenPriceFeed Chainlink AggregatorV3 address for the buy token's USD price.
    ///        Must be non-zero — oracle enforcement is mandatory.
    /// @param maxStaleness Maximum acceptable age (in seconds) for oracle price data.
    ///        Reverts if `block.timestamp - updatedAt > maxStaleness`.
    /// @param swapDeadlineSeconds Seconds added to `block.timestamp` to form the swap deadline.
    ///        Typical: 300 (5 minutes). Must be > 0.
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

    /// @notice Parameters for configuring a CowSwap order-book swap
    /// @dev Stored in PaymentRails's moduleParams and decoded by CowSwapModule
    /// @param targetToken Token to receive (buy token)
    /// @param minBuyAmount Absolute floor on output — order rejected if CowSwap cannot
    ///        meet this. Not a per-execution slippage; set conservatively.
    /// @param validityDuration Seconds from block.timestamp the order remains valid.
    ///        CowSwap solvers will not settle an expired order. Typical: 1800–3600.
    /// @param appData CowSwap app data hash. Use keccak256("receivables-paymentRails-v1")
    ///        or a custom hash registered via the CowSwap AppData API.
    struct CowSwapParams {
        address targetToken;
        uint256 minBuyAmount;
        uint32 validityDuration;
        bytes32 appData;
    }

    /// @notice On-chain metadata stored per CowSwap order
    /// @dev Keyed by orderId (= GPv2Order digest) in CowSwapModule._orders
    /// @param paymentRails         PaymentRails contract that initiated the order via execute()
    /// @param sellToken    Token sold (input token); returned on cancel
    /// @param buyToken     Token bought (output token); goes directly to PaymentRails via receiver=paymentRails
    /// @param sellAmount   Exact sell amount locked in the module; used to cap cancelOrder return
    /// @param validTo      Unix timestamp after which the order has expired (stored directly to
    ///                     avoid uint32 recomputation overflow)
    /// @param cancelled    True if the owner explicitly cancelled this order via cancelOrder().
    ///                     SETTLED state is derived live from GPv2Settlement.filledAmounts().
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
    /// @param destinationDomain CCTP domain ID (NOT EVM chain ID).
    ///        Ethereum = 0, Avalanche = 1, OP Mainnet = 2, Arbitrum = 3, Base = 6, Polygon = 7.
    /// @param mintRecipient Recipient on destination chain, left-padded to bytes32.
    ///        For EVM chains: `bytes32(uint256(uint160(addr)))`.
    /// @param destinationCaller Who may call `receiveMessage` on destination. `bytes32(0)` = anyone.
    /// @param maxFee Maximum USDC fee per transfer. 0 = standard (free). > 0 = fast transfer.
    /// @param minFinalityThreshold 1000 = fast (confirmed), 2000 = standard (finalized).
    /// @param hookData Empty = `depositForBurn()`. Non-empty = `depositForBurnWithHook()`.
    struct CCTPBridgeParams {
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
    }
}
