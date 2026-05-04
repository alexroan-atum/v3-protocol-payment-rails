// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ForwardModuleBase } from "../ForwardModuleBase.t.sol";

/// @notice Unit tests for ForwardModule.moduleType()
/// @dev Tree: tests/unit/concrete/forwards/forward-module/module-type/moduleType.tree
contract ForwardModuleModuleTypeTest is ForwardModuleBase {
    function test_ReturnsForward() external view {
        assertEq(module.moduleType(), "FORWARD");
    }
}
