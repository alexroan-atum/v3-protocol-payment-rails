// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ForwardModuleBase } from "../ForwardModuleBase.t.sol";

contract ForwardModuleValidateTest is ForwardModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenRecipientIsZeroAddress_ReturnsFalse() external whenRecipientIsZeroAddress {
        bytes memory params = _buildParams(address(0), 0);

        vm.prank(paymentRails);
        (bool isValid, string memory reason) = module.validate(address(token), DEFAULT_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero recipient address", "reason");
    }

    function test_WhenAmountBelowMinimum_ReturnsFalse() external whenAmountBelowMinimum {
        bytes memory params = _buildParams(recipient, DEFAULT_MIN_AMOUNT);
        uint256 belowMinAmount = DEFAULT_MIN_AMOUNT - 1;

        vm.prank(paymentRails);
        (bool isValid, string memory reason) = module.validate(address(token), belowMinAmount, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Amount below minimum", "reason");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFalse() external whenCallerHasInsufficientBalance {
        bytes memory params = _defaultParams();
        address emptyPaymentRails = makeAddr("emptyPaymentRails");

        vm.prank(emptyPaymentRails);
        (bool isValid, string memory reason) = module.validate(address(token), DEFAULT_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Insufficient balance", "reason");
    }

    function test_WhenMultipleValidationsFail_ReturnsFirstFailure() external {
        bytes memory params = _buildParams(address(0), DEFAULT_AMOUNT + 1);

        vm.prank(paymentRails);
        (bool isValid, string memory reason) = module.validate(address(token), DEFAULT_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero recipient address", "reason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidationsPass_ReturnsTrue() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        (bool isValid, string memory reason) = module.validate(address(token), DEFAULT_AMOUNT, params);

        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }

    function test_WhenAmountEqualsMinimum_ReturnsTrue() external whenAllValidationsPass {
        bytes memory params = _buildParams(recipient, DEFAULT_AMOUNT);

        vm.prank(paymentRails);
        (bool isValid,) = module.validate(address(token), DEFAULT_AMOUNT, params);

        assertTrue(isValid, "isValid");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_WhenAllValidationsPass_ReturnsTrue(uint256 amount) external {
        amount = bound(amount, DEFAULT_MIN_AMOUNT, DEFAULT_AMOUNT * 50);
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        (bool isValid, string memory reason) = module.validate(address(token), amount, params);

        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }
}
