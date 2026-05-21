// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DexSwapModule } from "../../../../../../src/modules/swaps/DexSwapModule.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";

/// @notice Unit tests for DexSwapModule constructor
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/constructor/constructor.tree
contract DexSwapModule_Constructor_Test is DexSwapModuleBase {
    function test_RevertWhen_RouterIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_ZeroRouter.selector));
        new DexSwapModule(address(0));
    }

    function test_RevertWhen_RouterHasNoCode() external {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_RouterNotContract.selector, noCode));
        new DexSwapModule(noCode);
    }

    function test_WhenRouterIsValid_SetsImmutableRouter() external view {
        assertEq(module.router(), address(router));
    }

    function test_WhenRouterIsValid_ModuleTypeIsSWAP() external view {
        assertEq(module.moduleType(), "SWAP");
    }
}
