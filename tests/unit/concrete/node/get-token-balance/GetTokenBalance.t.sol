// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { NodeBase } from "../NodeBase.t.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";

contract NodeGetTokenBalanceTest is NodeBase {
    function test_WhenZeroBalance_ReturnsZero() external {
        MockERC20 other = new MockERC20("Other", "OTH");
        assertEq(node.getTokenBalance(address(other)), 0);
    }

    function test_WhenPositiveBalance_ReturnsCorrectBalance() external view {
        assertEq(node.getTokenBalance(address(token)), INITIAL_BALANCE);
    }

    function test_WhenBalanceChanges_ReflectsNewBalance() external {
        token.mint(address(node), 500e18);
        assertEq(node.getTokenBalance(address(token)), INITIAL_BALANCE + 500e18);
    }
}
