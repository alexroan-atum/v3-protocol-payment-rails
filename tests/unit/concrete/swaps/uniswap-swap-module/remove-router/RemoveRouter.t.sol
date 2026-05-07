// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModuleBase } from "../UniswapSwapModuleBase.t.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockRouter } from "../../../../../shared/mocks/MockRouter.sol";

/// @notice Unit tests for UniswapSwapModule.removeRouter()
/// @dev Tree: tests/unit/concrete/swaps/uniswap-swap-module/remove-router/removeRouter.tree
contract UniswapSwapModule_RemoveRouter_Test is UniswapSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerIsNotOwner() external whenCallerIsNotOwner {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.removeRouter(address(router));
    }

    function test_RevertWhen_RouterNotInWhitelist() external whenRouterIsNotInWhitelist {
        address unknownRouter = makeAddr("unknownRouter");
        vm.expectRevert(abi.encodeWithSelector(Errors.UniswapSwapModule_RouterNotAllowed.selector, unknownRouter));
        module.removeRouter(unknownRouter);
    }

    function test_RevertWhen_RemovingAlreadyRemovedRouter() external {
        module.removeRouter(address(router));
        vm.expectRevert(abi.encodeWithSelector(Errors.UniswapSwapModule_RouterNotAllowed.selector, address(router)));
        module.removeRouter(address(router));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidationsPass_RemovesRouter() external whenAllValidationsPass {
        module.removeRouter(address(router));
        assertFalse(module.isRouterAllowed(address(router)));
    }

    function test_WhenAllValidationsPass_EmitsRouterRemoved() external whenAllValidationsPass {
        vm.expectEmit(true, false, false, false, address(module));
        emit RouterRemoved(address(router));
        module.removeRouter(address(router));
    }

    function test_WhenAllValidationsPass_CanReAddAfterRemoval() external {
        module.removeRouter(address(router));
        assertFalse(module.isRouterAllowed(address(router)));
        module.addRouter(address(router));
        assertTrue(module.isRouterAllowed(address(router)));
    }

    function test_RemovingOneRouter_DoesNotAffectOthers() external {
        MockRouter otherRouter = new MockRouter();
        module.addRouter(address(otherRouter));

        module.removeRouter(address(router));

        assertFalse(module.isRouterAllowed(address(router)));
        assertTrue(module.isRouterAllowed(address(otherRouter)));
    }
}
