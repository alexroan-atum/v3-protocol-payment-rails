// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModuleBase } from "../UniswapSwapModuleBase.t.sol";
import { UniswapSwapModule } from "../../../../../../src/modules/swaps/UniswapSwapModule.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unit tests for UniswapSwapModule constructor
/// @dev Tree: tests/unit/concrete/swaps/uniswap-swap-module/constructor/constructor.tree
contract UniswapSwapModule_Constructor_Test is UniswapSwapModuleBase {
    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new UniswapSwapModule(address(0));
    }

    function test_WhenOwnerIsValid_SetsOwner() external view {
        assertEq(module.owner(), owner);
    }

    function test_WhenOwnerIsValid_PendingOwnerIsZero() external view {
        assertEq(module.pendingOwner(), address(0));
    }
}
