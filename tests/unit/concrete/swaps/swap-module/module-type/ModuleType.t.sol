// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";

contract SwapModuleModuleTypeTest is SwapModuleBase {
    function test_ReturnsSwap() external view {
        assertEq(module.moduleType(), "SWAP");
    }
}
