// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DexSwapModule } from "../../../src/modules/swaps/DexSwapModule.sol";

/// @dev Router that re-enters DexSwapModule.execute() during a swap.
/// Used to verify that the nonReentrant guard on execute() blocks reentrancy
/// through a malicious router callback.
contract ReentrantRouter {
    DexSwapModule public immutable module;

    bytes public reentrantCallParams;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    bytes public revertReasonBytes;

    uint256 public outputAmount;

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

    constructor(address _module) {
        module = DexSwapModule(_module);
    }

    function setOutputAmount(uint256 _amount) external {
        outputAmount = _amount;
    }

    function setReentrantCall(address token, uint256 amount, bytes calldata params) external {
        reentrantCallParams = abi.encode(token, amount, params);
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        if (reentrantCallParams.length > 0) {
            (address token, uint256 amount, bytes memory moduleParams) =
                abi.decode(reentrantCallParams, (address, uint256, bytes));

            reentrancyAttempted = true;
            (bool success, bytes memory returnData) =
                address(module).call(abi.encodeCall(module.execute, (token, amount, moduleParams)));
            reentrancySucceeded = success;
            if (!success) {
                revertReasonBytes = returnData;
            }
        }

        amountOut = outputAmount;
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}
