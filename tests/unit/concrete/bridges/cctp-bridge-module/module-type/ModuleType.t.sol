// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";

contract CCTPBridgeModule_ModuleType_Test is CCTPBridgeModuleBase {
    function test_ShouldReturnCCTP_BRIDGE() external view {
        assertEq(module.moduleType(), "CCTP_BRIDGE");
    }
}
