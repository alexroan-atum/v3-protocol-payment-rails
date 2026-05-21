// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Controllable router mock for DexSwapModule unit tests.
/// Implements the Uniswap V3 `exactInputSingle` interface that DexSwapModule calls internally.
/// Simulates a DEX router that can succeed, fail, partially fill, or produce zero output.
contract MockRouter {
    bool public shouldRevert;
    bool public shouldSendNothing;
    uint256 public outputAmount;
    uint256 public pullAmountOverride;

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

    function setShouldRevert(bool _val) external {
        shouldRevert = _val;
    }

    function setShouldSendNothing(bool _val) external {
        shouldSendNothing = _val;
    }

    function setOutputAmount(uint256 _amount) external {
        outputAmount = _amount;
    }

    function setPullAmountOverride(uint256 _amount) external {
        pullAmountOverride = _amount;
    }

    /// @dev Uniswap V3 exactInputSingle — the only function DexSwapModule calls.
    /// Pulls sellToken from caller (module), sends buyToken to recipient (module, then forwarded).
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        if (shouldRevert) revert("MockRouter: forced revert");

        uint256 pullAmount = pullAmountOverride > 0 ? pullAmountOverride : params.amountIn;
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), pullAmount);

        if (shouldSendNothing) return 0;

        amountOut = outputAmount;
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }

    receive() external payable { }
}
