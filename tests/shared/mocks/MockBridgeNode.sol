// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModule } from "../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Simulates a Node: holds tokens, approves module, and forwards execute() calls.
contract MockBridgeNode {
    CCTPBridgeModule public immutable module;

    constructor(address _module) { module = CCTPBridgeModule(_module); }

    function initiateBridge(
        address token,
        uint256 amount,
        bytes calldata params
    ) external returns (DataTypes.ExecutionResult memory) {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params);
    }
}
