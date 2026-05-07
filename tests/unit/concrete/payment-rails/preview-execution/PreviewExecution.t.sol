// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { PaymentRailsBase } from "../PaymentRailsBase.t.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";

contract PaymentRailsPreviewExecutionTest is PaymentRailsBase {
    /*//////////////////////////////////////////////////////////////////////////
                        REVERT TESTS — validation checks
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_TokenIsZeroAddress() external {
        vm.expectRevert(Errors.PaymentRails_ZeroTokenAddress.selector);
        paymentRails.previewExecution(address(0));
    }

    function test_RevertWhen_NoActionConfigured() external {
        vm.expectRevert(Errors.PaymentRails_NoActionConfigured.selector);
        paymentRails.previewExecution(address(token));
    }

    function test_RevertWhen_TokenNotEnabled() external givenTokenConfiguredDisabled {
        vm.expectRevert(Errors.PaymentRails_TokenNotEnabled.selector);
        paymentRails.previewExecution(address(token));
    }

    function test_RevertWhen_ModuleHasNoCode() external {
        vm.prank(owner);
        paymentRails.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        // Remove the module's code to simulate a destroyed contract.
        vm.etch(address(actionModule), "");

        vm.expectRevert(Errors.PaymentRails_InvalidModule.selector);
        paymentRails.previewExecution(address(token));
    }

    function test_RevertWhen_BalanceIsZero() external givenTokenConfigured {
        // Deploy a fresh token with zero balance in the paymentRails
        MockERC20 emptyToken = new MockERC20("Empty", "EMP");

        vm.prank(owner);
        paymentRails.configureToken(
            address(emptyToken), ACTION_TYPE, address(actionModule), 0, _defaultModuleParams(), true
        );

        vm.expectRevert(Errors.PaymentRails_ZeroAmount.selector);
        paymentRails.previewExecution(address(emptyToken));
    }

    function test_RevertWhen_BalanceBelowMinBalance() external {
        // Configure with minBalance higher than current balance
        uint256 highMinBalance = INITIAL_BALANCE + 1;

        vm.prank(owner);
        paymentRails.configureToken(
            address(token), ACTION_TYPE, address(actionModule), highMinBalance, _defaultModuleParams(), true
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_BelowMinimumBalance.selector, INITIAL_BALANCE, highMinBalance)
        );
        paymentRails.previewExecution(address(token));
    }

    function test_RevertWhen_ModuleValidationFails() external givenTokenConfigured {
        actionModule.setValidationResult(false, "bad params");

        vm.expectRevert("bad params");
        paymentRails.previewExecution(address(token));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — all checks pass
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllChecksPass_ReturnsEstimatedOutput() external givenTokenConfigured {
        (uint256 estimatedOutput,) = paymentRails.previewExecution(address(token));
        assertEq(estimatedOutput, INITIAL_BALANCE);
    }

    function test_WhenAllChecksPass_ReturnsOutputToken() external givenTokenConfigured {
        (, address outputToken) = paymentRails.previewExecution(address(token));
        assertEq(outputToken, address(token));
    }

    function test_WhenMinBalanceIsZero_Succeeds() external {
        vm.prank(owner);
        paymentRails.configureToken(address(token), ACTION_TYPE, address(actionModule), 0, _defaultModuleParams(), true);

        (uint256 estimatedOutput, address outputToken) = paymentRails.previewExecution(address(token));
        assertEq(estimatedOutput, INITIAL_BALANCE);
        assertEq(outputToken, address(token));
    }
}
