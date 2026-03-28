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
        uint32  validityDuration;
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
        uint32  validTo;
        bool    cancelled;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            BRIDGE MODULE TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Bridge configuration parameters
    /// @dev Used by BridgeModule to configure cross-chain bridging
    /// @param destinationChainId Target chain ID
    /// @param destinationAddress Recipient on destination chain (often another Node)
    /// @param bridgeAdapter Bridge protocol adapter address (CCTP, LayerZero, etc.)
    /// @param bridgeData Bridge-specific data (varies by adapter)
    /// @param healthOracle Oracle to check bridge health (address(0) to skip check)
    /// @param minBridgeHealth Minimum health score required to execute (0-100)
    /// @param requireDestinationConfirmation Whether to wait for cross-chain confirmation
    struct BridgeParams {
        uint256 destinationChainId;
        address destinationAddress;
        address bridgeAdapter;
        bytes bridgeData;
        address healthOracle;
        uint256 minBridgeHealth;
        bool requireDestinationConfirmation;
    }

    /// @notice Bridge health status
    /// @dev Returned by bridge health oracles to indicate operational status
    /// @param isOperational Whether bridge is accepting transfers
    /// @param liquidity Available liquidity in the bridge
    /// @param avgFee Average bridge fee (for anomaly detection)
    /// @param lastUpdate Timestamp of last oracle data update
    /// @param healthScore Composite health score (0-100)
    struct BridgeHealth {
        bool isOperational;
        uint256 liquidity;
        uint256 avgFee;
        uint256 lastUpdate;
        uint8 healthScore;
    }
}
