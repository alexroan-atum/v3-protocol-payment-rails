// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModuleBase } from "../UniswapSwapModuleBase.t.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockRouter } from "../../../../../shared/mocks/MockRouter.sol";

/// @notice Unit tests for UniswapSwapModule.addRouter()
/// @dev Tree: tests/unit/concrete/swaps/uniswap-swap-module/add-router/addRouter.tree
contract UniswapSwapModule_AddRouter_Test is UniswapSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerIsNotOwner() external whenCallerIsNotOwner {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.addRouter(address(router));
    }

    function test_RevertWhen_RouterIsZeroAddress() external whenRouterIsZeroAddress {
        vm.expectRevert(Errors.UniswapSwapModule_ZeroRouter.selector);
        module.addRouter(address(0));
    }

    function test_RevertWhen_RouterHasNoCode() external whenRouterHasNoCode {
        address eoa = makeAddr("eoaRouter");
        vm.expectRevert(abi.encodeWithSelector(Errors.UniswapSwapModule_RouterNotContract.selector, eoa));
        module.addRouter(eoa);
    }

    function test_RevertWhen_RouterAlreadyAdded() external whenRouterIsAlreadyAdded {
        vm.expectRevert(abi.encodeWithSelector(Errors.UniswapSwapModule_RouterAlreadyAdded.selector, address(router)));
        module.addRouter(address(router));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidationsPass_WhitelistsRouter() external whenAllValidationsPass {
        MockRouter newRouter = new MockRouter();
        module.addRouter(address(newRouter));
        assertTrue(module.isRouterAllowed(address(newRouter)));
    }

    function test_WhenAllValidationsPass_EmitsRouterAdded() external whenAllValidationsPass {
        MockRouter newRouter = new MockRouter();
        vm.expectEmit(true, false, false, false, address(module));
        emit RouterAdded(address(newRouter));
        module.addRouter(address(newRouter));
    }

    function test_AddingMultipleRouters_AllAreIndependent() external {
        MockRouter routerA = new MockRouter();
        MockRouter routerB = new MockRouter();
        module.addRouter(address(routerA));
        module.addRouter(address(routerB));
        assertTrue(module.isRouterAllowed(address(routerA)));
        assertTrue(module.isRouterAllowed(address(routerB)));
    }
}
