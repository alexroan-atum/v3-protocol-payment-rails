// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";

/// @notice Unit tests for CowSwapModule.moduleType()
/// @dev Tree: tests/unit/concrete/cow-swap-module/module-type/moduleType.tree
contract CowSwapModule_ModuleType_Test is CowSwapModuleBase {
    function test_ReturnsOrderSwap() external view {
        assertEq(module.moduleType(), "COWSWAP");
    }
}
