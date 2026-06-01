// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IDexSwapModule
/// @author Credit Cooperative
/// @notice Interface for the synchronous, oracle-only DEX swap module.
/// @dev Extends {IActionModule} with parameter helpers for executing atomic on-chain swaps
/// through an immutable Uniswap V3 router.
///
/// The module accepts NO caller-controlled execution parameters — the permissionless executor
/// supplies only `(token, amount)` via `PaymentRails.executeAction`. All swap configuration
/// is owner-set in the static {DexSwapParams}:
///
///   - `targetToken`: the required output token.
///   - `fee`: Uniswap V3 pool fee tier.
///   - `maxSlippageBps`: maximum tolerable slippage (mandatory).
///   - `sellTokenPriceFeed` / `buyTokenPriceFeed`: Chainlink oracle feeds (mandatory).
///   - `maxStaleness`: oracle freshness window.
///   - `swapDeadlineSeconds`: added to `block.timestamp` to form the deadline.
///
/// Security model:
///   - **Zero caller influence**: No `executionData` parameter exists. The executor cannot supply
///     router addresses, fee tiers, slippage bounds, or any other swap parameter. The entire
///     Certora output-redirection attack surface is eliminated at the architecture level.
///   - **Immutable router**: Set once at construction — no owner key can whitelist a malicious
///     contract at runtime.
///   - **Hardcoded recipient**: The module builds Uniswap V3 `exactInputSingle` calldata
///     internally with `recipient = address(this)`. After measuring received buyToken via
///     balance diff, the module forwards output to `msg.sender` (PaymentRails).
///   - **Oracle-enforced slippage**: `amountOutMinimum` is computed on-chain from Chainlink
///     prices as `oracleExpected * (10000 - maxSlippageBps) / 10000`. Oracle feeds are mandatory.
///   - **Balance-diff verification**: Output is measured as the module's targetToken balance
///     change — the module never trusts router return values.
///   - **Fee-on-transfer support**: Sell-side pull uses balance-diff for actual received amount.
///   - **No residual state**: Module holds no tokens between executions.
///
/// Deployment model: a single instance may be shared across multiple PaymentRails.
/// The module is fully stateless (no persistent storage writes across transactions).
interface IDexSwapModule is IActionModule {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful swap execution.
    /// @param paymentRails PaymentRails that initiated the swap.
    /// @param sellToken    Input token sold.
    /// @param buyToken     Output token received by the PaymentRails.
    /// @param amountIn     Actual sell amount after fee-on-transfer deduction.
    /// @param amountOut    Actual buy amount received (verified via balance diff).
    event SwapExecuted(
        address indexed paymentRails, address indexed sellToken, address buyToken, uint256 amountIn, uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the immutable Uniswap V3 router address.
    /// @return The router contract address set at construction.
    function router() external view returns (address);

    /// @notice Chainlink L2 sequencer uptime feed; address(0) on L1.
    function sequencerUptimeFeed() external view returns (address);

    /// @notice Seconds after sequencer recovery before trusting oracles.
    function sequencerGracePeriod() external view returns (uint256);

    /// @notice ABI-encodes a {DexSwapParams} struct into bytes for `PaymentRails.configureToken()`.
    /// @param params Typed struct.
    /// @return encoded ABI-encoded bytes.
    function encodeParams(DataTypes.DexSwapParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {DexSwapParams} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeParams()`.
    /// @return params Decoded struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.DexSwapParams memory params);
}
