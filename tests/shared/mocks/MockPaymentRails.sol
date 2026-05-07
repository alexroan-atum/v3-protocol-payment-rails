// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModule } from "../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Simulates a PaymentRails: holds tokens, approves module, and forwards execute() calls.
contract MockPaymentRails {
    CowSwapModule public immutable module;

    constructor(address _module) {
        module = CowSwapModule(_module);
    }

    function initiateSwap(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params, "");
    }
}
