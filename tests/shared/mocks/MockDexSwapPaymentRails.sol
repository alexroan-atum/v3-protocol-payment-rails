// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModule } from "../../../src/modules/swaps/DexSwapModule.sol";
import { DataTypes } from "../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Simulates a PaymentRails: holds tokens, approves module, and forwards execute() calls.
contract MockDexSwapPaymentRails {
    DexSwapModule public immutable module;

    constructor(address _module) {
        module = DexSwapModule(_module);
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
