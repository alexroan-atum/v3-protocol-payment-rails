// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";

/// @notice Unit tests for DexSwapModule.moduleType()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/module-type/moduleType.tree
contract DexSwapModule_ModuleType_Test is DexSwapModuleBase {
    function test_ReturnsSwap() external view {
        assertEq(module.moduleType(), "SWAP");
    }
}
