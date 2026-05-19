// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DexSwapModule } from "../../../src/modules/swaps/DexSwapModule.sol";

/// @dev Router that re-enters DexSwapModule.execute() during a swap.
/// Used to verify that the nonReentrant guard on execute() blocks reentrancy
/// through a whitelisted router callback.
contract ReentrantRouter {
    DexSwapModule public immutable module;

    bytes public reentrantCallParams;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    bytes public revertReasonBytes;

    constructor(address _module) {
        module = DexSwapModule(_module);
    }

    /// @dev Arms the router with params for the reentrant execute() call.
    function setReentrantCall(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
    {
        reentrantCallParams = abi.encode(token, amount, params, executionData);
    }

    /// @dev Standard swap that also re-enters module.execute() mid-execution.
    function swapAndReenter(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        address recipient,
        uint256 buyAmount
    )
        external
    {
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);

        if (reentrantCallParams.length > 0) {
            (address token, uint256 amount, bytes memory params, bytes memory executionData) =
                abi.decode(reentrantCallParams, (address, uint256, bytes, bytes));

            reentrancyAttempted = true;
            (bool success, bytes memory returnData) =
                address(module).call(abi.encodeCall(module.execute, (token, amount, params, executionData)));
            reentrancySucceeded = success;
            if (!success) {
                revertReasonBytes = returnData;
            }
        }

        IERC20(buyToken).transfer(recipient, buyAmount);
    }
}
