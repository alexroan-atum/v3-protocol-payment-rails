// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title DataTypes
/// @notice Centralized type definitions for the Receivables Node system
/// @dev This library contains all struct definitions used across Node, modules, and interfaces
library DataTypes {
    /*//////////////////////////////////////////////////////////////////////////
                                    NODE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Configuration for a token's action in the Node
    /// @dev Stored per token address in the node's configuration mapping
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
    /// @param requireSuccessfulReceipt Whether to revert if recipient cannot receive tokens
    /// @param minAmount Minimum amount required to forward (0 = no minimum)
    struct ForwardParams {
        address recipient;
        bool requireSuccessfulReceipt;
        uint256 minAmount;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SWAP MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Swap configuration parameters
    /// @dev Used by SwapModule to configure DEX swaps with oracle validation
    /// @param targetToken Token to swap into
    /// @param dexRouter DEX router address (Uniswap, Sushiswap, etc.)
    /// @param path Swap path encoded for the specific DEX
    /// @param poolFee Pool fee tier for Uniswap V3 (in hundredths of bips)
    /// @param slippageBps Slippage tolerance in basis points (e.g., 50 = 0.5%)
    /// @param priceOracle Price oracle address for validation (e.g., Chainlink)
    /// @param maxPriceDeviationBps Maximum allowed deviation from oracle price (e.g., 500 = 5%)
    /// @param useTwap Whether to use time-weighted average price for validation
    /// @param twapPeriod TWAP period in seconds (only used if useTwap = true)
    struct SwapParams {
        address targetToken;
        address dexRouter;
        bytes path;
        uint24 poolFee;
        uint256 slippageBps;
        address priceOracle;
        uint256 maxPriceDeviationBps;
        bool useTwap;
        uint32 twapPeriod;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            COWSWAP MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Parameters for configuring a CowSwap order-book swap
    /// @dev Stored in Node's moduleParams and decoded by CowSwapModule
    /// @param targetToken Token to receive (buy token)
    /// @param minBuyAmount Absolute floor on output — order rejected if CowSwap cannot
    ///        meet this. Not a per-execution slippage; set conservatively.
    /// @param validityDuration Seconds from block.timestamp the order remains valid.
    ///        CowSwap solvers will not settle an expired order. Typical: 1800–3600.
    /// @param appData CowSwap app data hash. Use keccak256("receivables-node-v1")
    ///        or a custom hash registered via the CowSwap AppData API.
    struct CowSwapParams {
        address targetToken;
        uint256 minBuyAmount;
        uint32 validityDuration;
        bytes32 appData;
    }

    /// @notice On-chain metadata stored per CowSwap order
    /// @dev Keyed by orderId (= GPv2Order digest) in CowSwapModule._orders
    /// @param node         Node contract that initiated the order via execute()
    /// @param sellToken    Token sold (input token); returned on cancel
    /// @param buyToken     Token bought (output token); goes directly to Node via receiver=node
    /// @param sellAmount   Exact sell amount locked in the module; used to cap cancelOrder return
    /// @param validTo      Unix timestamp after which the order has expired (stored directly to
    ///                     avoid uint32 recomputation overflow)
    /// @param cancelled    True if the owner explicitly cancelled this order via cancelOrder().
    ///                     SETTLED state is derived live from GPv2Settlement.filledAmounts().
    struct CowOrderMetadata {
        address node;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint32 validTo;
        bool cancelled;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        CCTP BRIDGE MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Parameters stored in Node's moduleParams for a CCTP bridge action.
    /// @dev Intentionally minimal — just a domain pointer. All routing details live in the
    ///      module's per-domain config ({CCTPDomainConfig}).
    /// @param destinationDomain CCTP domain ID of the destination chain (NOT an EVM chain ID).
    ///        Ethereum = 0, Avalanche = 1, OP Mainnet = 2, Arbitrum = 3, Base = 6, Polygon = 7.
    struct CCTPBridgeParams {
        uint32 destinationDomain;
    }

    /// @notice Per-domain routing configuration stored in the CCTPBridgeModule.
    /// @dev Set by the module owner via `setDomainConfig()`. Looked up during `execute()` using the
    ///      `destinationDomain` decoded from the Node's moduleParams.
    /// @param isValid        Whether this domain config is active. Set to true by `setDomainConfig()`,
    ///                       cleared by `removeDomainConfig()`.
    /// @param mintRecipient  Recipient address on the destination chain, left-padded to bytes32.
    ///                       For EVM chains: `bytes32(uint256(uint160(addr)))`. Typically another Node.
    /// @param destinationCaller Who may call `receiveMessage` on the destination chain.
    ///                          `bytes32(0)` = anyone can relay (recommended).
    /// @param maxFee         Maximum USDC fee the module is willing to pay per transfer.
    ///                       0 = standard transfer only (free, ~15-19 min).
    ///                       > 0 = enables fast transfer (~8-20 s); fee is deducted on destination.
    /// @param minFinalityThreshold 1000 = fast (confirmed), 2000 = standard (finalized).
    /// @param hookData       Optional bytes for destination-chain post-mint automation (CCTP V2 hooks).
    ///                       Empty = `depositForBurn()`. Non-empty = `depositForBurnWithHook()`.
    struct CCTPDomainConfig {
        bool isValid;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ATUM PAYMENT MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Parameters stored in Node's moduleParams for an Atum payment action.
    /// @dev These fields are emitted for the off-chain Atum keeper. The module does
    ///      not interpret Atum Escrow routes or witness formats.
    /// @param destinationChain CAIP-2 destination chain identifier, e.g. `eip155:8453`.
    /// @param destinationAccount Destination account identifier for the Atum payment request.
    /// @param destinationAsset CAIP-19 destination asset identifier for the Atum payment request.
    struct AtumPaymentParams {
        string destinationChain;
        string destinationAccount;
        string destinationAsset;
    }
}
