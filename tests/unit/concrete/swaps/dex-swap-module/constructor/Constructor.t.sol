// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DexSwapModule } from "../../../../../../src/modules/swaps/DexSwapModule.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unit tests for DexSwapModule constructor
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/constructor/constructor.tree
contract DexSwapModule_Constructor_Test is DexSwapModuleBase {
    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DexSwapModule(address(0));
    }

    function test_WhenOwnerIsValid_SetsOwner() external view {
        assertEq(module.owner(), owner);
    }

    function test_WhenOwnerIsValid_PendingOwnerIsZero() external view {
        assertEq(module.pendingOwner(), address(0));
    }
}
