// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { Node } from "../../../../../src/core/Node.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract NodeConstructorTest is Test {
    function test_RevertWhen_InitialOwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Node(address(0));
    }

    function test_WhenInitialOwnerIsValid() external {
        address expectedOwner = makeAddr("owner");
        Node node = new Node(expectedOwner);
        assertEq(node.owner(), expectedOwner);
    }
}
