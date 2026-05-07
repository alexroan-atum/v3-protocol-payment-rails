// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModule } from "../../../src/modules/swaps/UniswapSwapModule.sol";
import { DataTypes } from "../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Simulates a PaymentRails: holds tokens, approves module, and forwards execute() calls.
contract MockUniswapPaymentRails {
    UniswapSwapModule public immutable module;

    constructor(address _module) {
        module = UniswapSwapModule(_module);
    }

    function executeSwap(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params, executionData);
    }
}
