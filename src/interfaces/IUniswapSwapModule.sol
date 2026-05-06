// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title IUniswapSwapModule
/// @author Credit Cooperative
/// @notice Interface for the synchronous Uniswap swap module.
/// @dev Extends {IActionModule} with router-whitelisting and parameter helpers for executing
/// atomic on-chain swaps through whitelisted Uniswap routers.
///
/// The module splits configuration into two layers:
///
///   **Static params** ({UniswapSwapParams}, stored in PaymentRails.moduleParams):
///   Define the constraint — which target token the swap must produce.
///
///   **Execution data** ({UniswapSwapExecutionData}, passed per-call via `executionData`):
///   Define the plan — which router, what calldata, minimum output, deadline.
///   Constructed off-chain from a Uniswap router quote.
///
/// Security model:
///   - **Router whitelist**: Only owner-approved router addresses may be called.
///   - **Balance-diff verification**: Output is measured as the PaymentRails's targetToken balance
///     change — the module never trusts router return values.
///   - **Slippage enforcement**: Reverts if output < `minAmountOut` (atomic rollback).
///   - **Fee-on-transfer support**: Sell-side pull uses balance-diff to determine actual received amount.
///   - **No residual state**: Module holds no tokens between executions.
///
/// Deployment model: a single instance may be shared across multiple PaymentRails.
interface IUniswapSwapModule is IActionModule {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a router is added to the whitelist.
    /// @param router The newly allowed router address.
    event RouterAdded(address indexed router);

    /// @notice Emitted when a router is removed from the whitelist.
    /// @param router The removed router address.
    event RouterRemoved(address indexed router);

    /// @notice Emitted after a successful swap execution.
    /// @param paymentRails PaymentRails that initiated the swap.
    /// @param sellToken    Input token sold.
    /// @param buyToken     Output token received by the PaymentRails.
    /// @param amountIn     Actual sell amount after fee-on-transfer deduction.
    /// @param amountOut    Actual buy amount received (verified via balance diff).
    /// @param router       Router that executed the swap.
    event SwapExecuted(
        address indexed paymentRails,
        address indexed sellToken,
        address buyToken,
        uint256 amountIn,
        uint256 amountOut,
        address router
    );

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Adds a router to the whitelist. Only callable by the module owner.
    /// @dev Reverts with {Errors.UniswapSwapModule_ZeroRouter} if `router` is address(0).
    ///      Reverts with {Errors.UniswapSwapModule_RouterNotContract} if `router` has no code.
    ///      Reverts with {Errors.UniswapSwapModule_RouterAlreadyAdded} if already whitelisted.
    /// @param router Address of the router contract to whitelist.
    function addRouter(address router) external;

    /// @notice Removes a router from the whitelist. Only callable by the module owner.
    /// @dev Reverts with {Errors.UniswapSwapModule_RouterNotAllowed} if not whitelisted.
    /// @param router Address of the router contract to remove.
    function removeRouter(address router) external;

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns whether `router` is in the whitelist.
    /// @param router Address to check.
    /// @return allowed True if the router is whitelisted.
    function isRouterAllowed(address router) external view returns (bool allowed);

    /// @notice ABI-encodes a {UniswapSwapParams} struct into bytes for `PaymentRails.configureToken()`.
    /// @param params Typed struct.
    /// @return encoded ABI-encoded bytes.
    function encodeParams(DataTypes.UniswapSwapParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {UniswapSwapParams} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeParams()`.
    /// @return params Decoded struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.UniswapSwapParams memory params);

    /// @notice ABI-encodes a {UniswapSwapExecutionData} struct for passing as `executionData`.
    /// @param data Typed struct.
    /// @return encoded ABI-encoded bytes.
    function encodeExecutionData(DataTypes.UniswapSwapExecutionData calldata data)
        external
        pure
        returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {UniswapSwapExecutionData} struct.
    /// @param encoded ABI-encoded bytes produced by `encodeExecutionData()`.
    /// @return data Decoded struct.
    function decodeExecutionData(bytes calldata encoded)
        external
        pure
        returns (DataTypes.UniswapSwapExecutionData memory data);
}
