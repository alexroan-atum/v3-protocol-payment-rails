// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IBridgeModule
/// @notice Interface for modules that bridge tokens cross-chain
/// @dev Implements IActionModule with bridge-specific functionality
///
/// # Overview
/// IBridgeModule extends IActionModule to support automated cross-chain token transfers
/// through various bridge protocols (LayerZero, Wormhole, Across, Stargate, native bridges).
/// It includes specialized functions for bridge health monitoring, fee estimation, and
/// destination chain validation.
///
/// # Use Cases
/// - Moving stablecoins to low-cost L2s (Arbitrum, Optimism, Base)
/// - Bridging yield tokens to farming opportunities on other chains
/// - Collecting receivables on one chain, forwarding to treasury on another
/// - Multi-chain treasury management and rebalancing
/// - Cross-chain DeFi strategies (deposit on Ethereum, farm on Polygon)
///
/// # Security Considerations
///
/// **Bridge Selection:**
/// - Different bridges have different security models (native, validator set, optimistic)
/// - Choose bridges based on amount size and risk tolerance
/// - Large transfers: Native bridges (slow but secure)
/// - Small transfers: Fast bridges (quick but higher risk)
///
/// **Health Monitoring:**
/// - Check bridge operational status before execution
/// - Detect bridge pauses, exploits, or rate limits
/// - Use health oracles for real-time status
///
/// **Fee Management:**
/// - Bridge fees can vary significantly by:
///   - Source chain
///   - Destination chain
///   - Token type
///   - Network congestion
/// - Estimate fees before execution to ensure profitability
///
/// **Destination Validation:**
/// - Verify recipient address is valid on destination chain
/// - Handle chain-specific address formats (EVM vs non-EVM)
/// - Ensure destination contract addresses are deployed
///
/// # Parameters
/// Bridge operations use BridgeParams struct:
/// - `bridge`: Bridge protocol adapter address
/// - `destinationChainId`: Target chain ID
/// - `recipient`: Recipient address on destination chain
/// - `minAmountOut`: Minimum acceptable amount after fees
/// - `deadline`: Transaction deadline
/// - `adapterParams`: Bridge-specific configuration (gas limits, etc.)
/// - `healthOracle`: Optional health monitoring oracle
///
/// # Supported Bridges
/// The module supports multiple bridge protocols:
/// - LayerZero (Omnichain messaging)
/// - Stargate (Liquidity network)
/// - Across (Optimistic bridge)
/// - Native bridges (Optimism, Arbitrum, Polygon)
/// - Wormhole (Multi-chain bridge)
///
/// # Implementation Status
/// NOTE: BridgeModule is currently a stub implementation. Full bridge integration is
/// planned for future releases. This interface defines the contract for when bridges
/// are implemented.
interface IBridgeModule is IActionModule {

    /*//////////////////////////////////////////////////////////////////////////
                        BRIDGE-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Encode bridge parameters into ABI-encoded bytes
    /// @dev Helper function for constructing moduleParams when configuring bridge tokens
    ///
    /// # Usage
    /// ```solidity
    /// BridgeParams memory params = BridgeParams({
    ///     bridge: layerZeroBridge,
    ///     destinationChainId: 10,  // Optimism
    ///     recipient: treasuryAddressOnOptimism,
    ///     minAmountOut: 995e6,     // Accept 0.5% bridge fee
    ///     deadline: block.timestamp + 3600,
    ///     adapterParams: abi.encodePacked(uint16(1), uint256(200000)),  // Version 1, 200k gas
    ///     healthOracle: bridgeHealthOracle
    /// });
    /// bytes memory encoded = bridgeModule.encodeParams(params);
    /// node.configureToken(USDC, "BRIDGE", address(bridgeModule), ..., encoded, true);
    /// ```
    ///
    /// @param params Bridge parameters to encode
    /// @return ABI-encoded bytes representation
    function encodeParams(DataTypes.BridgeParams calldata params) external pure returns (bytes memory);

    /// @notice Decode ABI-encoded bytes into BridgeParams struct
    /// @dev Extracts bridge configuration from generic bytes parameter
    ///
    /// # Usage
    /// Called internally by BridgeModule to access configuration from params bytes.
    ///
    /// @param encoded ABI-encoded parameter bytes
    /// @return params Decoded BridgeParams struct
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.BridgeParams memory params);

    /// @notice Check operational health status of a bridge
    /// @dev Queries health oracle to determine if bridge is safe to use
    ///
    /// # Purpose
    /// Prevents executing bridges through compromised or paused bridge protocols.
    /// Health checks can detect:
    /// - Bridge pauses (admin actions)
    /// - Active exploits or security incidents
    /// - Rate limit exhaustion
    /// - Liquidity pool depletion
    /// - Validator set issues
    ///
    /// # Health Oracle
    /// If healthOracle is address(0), returns default healthy status.
    /// Otherwise, queries oracle for:
    /// - isOperational: Whether bridge is currently functional
    /// - isPaused: Whether bridge has been paused by admins
    /// - lastIncident: Timestamp of last security incident
    /// - riskLevel: Risk assessment (LOW, MEDIUM, HIGH, CRITICAL)
    ///
    /// # Return Value
    /// BridgeHealth struct contains:
    /// - isOperational: True if bridge is functional
    /// - isPaused: True if bridge is paused
    /// - lastIncident: Timestamp of last security incident (0 if none)
    /// - riskLevel: Current risk assessment level
    /// - message: Human-readable status message
    ///
    /// # Usage
    /// Call before bridge execution to validate safety:
    /// ```solidity
    /// BridgeHealth memory health = checkBridgeHealth(bridge, oracle);
    /// require(health.isOperational && !health.isPaused, "Bridge unhealthy");
    /// require(health.riskLevel <= RiskLevel.MEDIUM, "Risk too high");
    /// ```
    ///
    /// Notes:
    /// - May return stale data if oracle isn't updated frequently
    /// - Caller should implement retry logic for transient issues
    /// - Consider fallback bridges if primary is unhealthy
    ///
    /// @param bridge Bridge adapter contract address
    /// @param healthOracle Health monitoring oracle address (address(0) to skip)
    /// @return health Current bridge health status
    function checkBridgeHealth(
        address bridge,
        address healthOracle
    ) external view returns (DataTypes.BridgeHealth memory health);

    /// @notice Estimate total fees for bridging tokens
    /// @dev Calculates bridge protocol fee plus destination gas costs
    ///
    /// # Purpose
    /// Provides fee estimation for:
    /// - Profitability analysis (is bridge execution profitable?)
    /// - User display (show estimated costs before execution)
    /// - Keeper bot economics (calculate net value after fees)
    ///
    /// # Fee Components
    /// Total bridge fee typically includes:
    /// 1. **Bridge Protocol Fee**: Charged by bridge protocol (usually % or flat fee)
    /// 2. **Destination Gas**: Gas costs on destination chain
    /// 3. **Relayer Fee**: Fee for relayer service (if applicable)
    /// 4. **Liquidity Fee**: Fee for using bridge liquidity pool
    ///
    /// # Fee Calculation Example
    /// ```
    /// Bridge USDC from Ethereum to Optimism:
    /// - Amount: 10,000 USDC
    /// - Protocol fee: 0.1% = 10 USDC
    /// - Destination gas: ~$2 = 2 USDC equivalent
    /// - Total fee: 12 USDC
    /// - User receives: 9,988 USDC on Optimism
    /// ```
    ///
    /// # Return Value
    /// Fee is returned in native token of source chain:
    /// - On Ethereum: wei (ETH)
    /// - On Polygon: wei (MATIC)
    /// - On Arbitrum: wei (ETH)
    ///
    /// Caller must ensure Node has sufficient native balance to cover fees.
    ///
    /// # Fee Variability
    /// Fees can change based on:
    /// - Network congestion
    /// - Bridge liquidity availability
    /// - Token type (native vs wrapped)
    /// - Amount size (volume discounts)
    ///
    /// Notes:
    /// - Estimate may differ from actual fee (use as approximation)
    /// - Query fresh estimate immediately before execution
    /// - Consider setting maxFee limit in params to prevent fee surprises
    ///
    /// @param token Token address to bridge
    /// @param amount Amount of tokens to bridge
    /// @param params ABI-encoded BridgeParams
    /// @return fee Estimated total fee in native token (wei)
    function estimateBridgeFee(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view returns (uint256 fee);
}
