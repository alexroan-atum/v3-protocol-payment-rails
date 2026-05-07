// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModuleBase } from "../UniswapSwapModuleBase.t.sol";

/// @notice Unit tests for UniswapSwapModule.moduleType()
/// @dev Tree: tests/unit/concrete/swaps/uniswap-swap-module/module-type/moduleType.tree
contract UniswapSwapModule_ModuleType_Test is UniswapSwapModuleBase {
    function test_ReturnsSwap() external view {
        assertEq(module.moduleType(), "SWAP");
    }
}
