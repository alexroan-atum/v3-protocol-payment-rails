// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title ISwapRouter
/// @notice Minimal Uniswap V3 SwapRouter interface used by DexSwapModule.
/// @dev Only `exactInputSingle` is needed — the module builds calldata internally
/// with a hardcoded `recipient = address(this)` to prevent output-redirection attacks.
/// All parameters are typed values; the caller never supplies raw bytes.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams`.
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
