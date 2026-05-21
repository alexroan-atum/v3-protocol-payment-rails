// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ForwardModuleBase } from "../ForwardModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract ForwardModuleExecuteTest is ForwardModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenRecipientIsZeroAddress_ReturnsFailedResult() external whenRecipientIsZeroAddress {
        bytes memory params = _buildParams(address(0), false, 0);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero recipient address", "failureReason");
        assertEq(result.amountOut, 0, "amountOut");
        assertEq(result.outputToken, address(token), "outputToken");
        assertEq(result.data.length, 0, "data");
    }

    function test_WhenAmountBelowMinimum_ReturnsFailedResult() external whenAmountBelowMinimum {
        bytes memory params = _buildParams(recipient, false, DEFAULT_MIN_AMOUNT);
        uint256 belowMinAmount = DEFAULT_MIN_AMOUNT - 1;

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), belowMinAmount, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Amount below minimum", "failureReason");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFailedResult() external whenCallerHasInsufficientBalance {
        bytes memory params = _defaultParams();
        address emptyPaymentRails = makeAddr("emptyPaymentRails");

        vm.prank(emptyPaymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Insufficient balance", "failureReason");
    }

    function test_WhenTransferReturnsFalse_ReturnsFailedResult() external whenTransferReturnsFalse {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(failingToken), DEFAULT_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Transfer failed", "failureReason");
    }

    function test_WhenTransferReverts_ReturnsFailedResult() external whenTransferReverts {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(revertingToken), DEFAULT_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Transfer failed", "failureReason");
    }

    function test_WhenMultipleValidationsFail_ReturnsFirstFailure() external {
        bytes memory params = _buildParams(address(0), false, DEFAULT_AMOUNT + 1);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero recipient address", "failureReason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidationsPass_TransfersTokensFromCallerToRecipient() external whenAllValidationsPass {
        bytes memory params = _defaultParams();
        uint256 nodeBefore = token.balanceOf(paymentRails);
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(paymentRails);
        module.execute(address(token), DEFAULT_AMOUNT, params);

        assertEq(token.balanceOf(paymentRails), nodeBefore - DEFAULT_AMOUNT, "paymentRails balance");
        assertEq(token.balanceOf(recipient), recipientBefore + DEFAULT_AMOUNT, "recipient balance");
    }

    function test_WhenAllValidationsPass_ReturnsSuccessWithEmptyFailureReason() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertTrue(result.success, "success");
        assertEq(bytes(result.failureReason).length, 0, "failureReason should be empty");
    }

    function test_WhenAllValidationsPass_ReturnsAmountOutEqualToAmount() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertEq(result.amountOut, DEFAULT_AMOUNT, "amountOut");
    }

    function test_WhenAllValidationsPass_ReturnsOutputTokenEqualToInputToken() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertEq(result.outputToken, address(token), "outputToken");
    }

    function test_WhenAllValidationsPass_ReturnsEncodedRecipientInDataField() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        address decodedRecipient = abi.decode(result.data, (address));
        assertEq(decodedRecipient, recipient, "data recipient");
    }

    function test_WhenAmountEqualsMinimum_Succeeds() external whenAllValidationsPass {
        bytes memory params = _buildParams(recipient, false, DEFAULT_AMOUNT);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), DEFAULT_AMOUNT, params);

        assertTrue(result.success, "success");
        assertEq(result.amountOut, DEFAULT_AMOUNT, "amountOut");
    }

    function test_WhenAllValidationsPass_WorksWithZeroMinAmount() external whenAllValidationsPass {
        bytes memory params = _buildParams(recipient, false, 0);
        uint256 tinyAmount = 1;

        token.mint(paymentRails, tinyAmount);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), tinyAmount, params);

        assertTrue(result.success, "success");
        assertEq(result.amountOut, tinyAmount, "amountOut");
    }

    function test_WhenFeeOnTransferToken_ReportsAmountOutEqualToInput() external whenAllValidationsPass {
        bytes memory params = _buildParams(recipient, false, 0);
        uint256 recipientBefore = feeToken.balanceOf(recipient);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(feeToken), DEFAULT_AMOUNT, params);

        assertTrue(result.success, "success");
        assertEq(result.amountOut, DEFAULT_AMOUNT, "reported amountOut");

        uint256 actualReceived = feeToken.balanceOf(recipient) - recipientBefore;
        assertLt(actualReceived, DEFAULT_AMOUNT, "actual received < reported");
    }

    /// @dev Regression test for Certora finding: non-standard ERC20 tokens (e.g. USDT) that return
    /// no data from transferFrom must be treated as successful, not failed.
    function test_WhenNoReturnToken_TransfersSuccessfully() external whenAllValidationsPass {
        bytes memory params = _buildParams(recipient, false, 0);
        uint256 paymentRailsBefore = noReturnToken.balanceOf(paymentRails);
        uint256 recipientBefore = noReturnToken.balanceOf(recipient);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(noReturnToken), DEFAULT_AMOUNT, params);

        assertTrue(result.success, "success");
        assertEq(result.amountOut, DEFAULT_AMOUNT, "amountOut");
        assertEq(noReturnToken.balanceOf(paymentRails), paymentRailsBefore - DEFAULT_AMOUNT, "paymentRails balance");
        assertEq(noReturnToken.balanceOf(recipient), recipientBefore + DEFAULT_AMOUNT, "recipient balance");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_WhenAllValidationsPass_TransfersCorrectAmount(uint256 amount, uint256 minAmount) external {
        minAmount = bound(minAmount, 0, DEFAULT_AMOUNT * 50);
        amount = bound(amount, minAmount, DEFAULT_AMOUNT * 50);

        bytes memory params = _buildParams(recipient, false, minAmount);
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(paymentRails);
        DataTypes.ExecutionResult memory result = module.execute(address(token), amount, params);

        assertTrue(result.success, "success");
        assertEq(result.amountOut, amount, "amountOut");
        assertEq(token.balanceOf(recipient), recipientBefore + amount, "recipient balance");
    }
}
