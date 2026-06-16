// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PaymentRailsConstructorTest is Test {
    function test_RevertWhen_InitialOwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PaymentRails(address(0));
    }

    function test_WhenInitialOwnerIsValid() external {
        address expectedOwner = makeAddr("owner");
        PaymentRails paymentRails = new PaymentRails(expectedOwner);
        assertEq(paymentRails.owner(), expectedOwner);
    }

    function test_WhenInitialOwnerIsValid_PendingOwnerIsZero() external {
        address expectedOwner = makeAddr("owner");
        PaymentRails paymentRails = new PaymentRails(expectedOwner);
        assertEq(paymentRails.pendingOwner(), address(0));
    }
}
