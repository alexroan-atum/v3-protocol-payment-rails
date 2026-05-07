// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModuleBase } from "../UniswapSwapModuleBase.t.sol";

/// @notice Unit tests for UniswapSwapModule.isRouterAllowed()
/// @dev Tree: tests/unit/concrete/swaps/uniswap-swap-module/is-router-allowed/isRouterAllowed.tree
contract UniswapSwapModule_IsRouterAllowed_Test is UniswapSwapModuleBase {
    function test_WhenRouterIsUnknown_ReturnsFalse() external view {
        assertFalse(module.isRouterAllowed(address(0xdead)));
    }

    function test_WhenRouterIsUnknown_ZeroAddressReturnsFalse() external view {
        assertFalse(module.isRouterAllowed(address(0)));
    }

    function test_WhenRouterWasAdded_ReturnsTrue() external view {
        assertTrue(module.isRouterAllowed(address(router)));
    }

    function test_WhenRouterWasAddedThenRemoved_ReturnsFalse() external {
        module.removeRouter(address(router));
        assertFalse(module.isRouterAllowed(address(router)));
    }
}
