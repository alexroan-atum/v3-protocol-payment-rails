// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { MockRouter } from "../../../../../shared/mocks/MockRouter.sol";

/// @notice Unit tests for DexSwapModule.validate()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/validate/validate.tree
contract DexSwapModule_Validate_Test is DexSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsTooShort_ReturnsFalse() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00", _defaultExecutionData());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Invalid params encoding", "reason");
    }

    function test_WhenTargetTokenIsZero_ReturnsFalse() external {
        bytes memory params = _buildParams(address(0));
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero target token", "reason");
    }

    function test_WhenTargetTokenEqualsSellToken_ReturnsFalse() external {
        bytes memory params = _buildParams(address(sellToken));
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Same input and output token", "reason");
    }

    function test_WhenAmountIsZero_ReturnsFalse() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), 0, _defaultParams(), _defaultExecutionData());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero sell amount", "reason");
    }

    function test_WhenExecDataRouterNotWhitelisted_ReturnsFalse() external {
        MockRouter unlisted = new MockRouter();
        bytes memory execData = _buildExecutionData(
            address(unlisted), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, _defaultRouterCalldata()
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Router not allowed", "reason");
    }

    function test_WhenExecDataMinAmountOutZero_ReturnsFalse() external {
        bytes memory execData = _buildExecutionData(address(router), 0, DEFAULT_DEADLINE, _defaultRouterCalldata());
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero min amount out", "reason");
    }

    function test_WhenExecDataDeadlineExpired_ReturnsFalse() external {
        vm.warp(1000);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, 999, _defaultRouterCalldata());
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Deadline expired", "reason");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFalse() external view {
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Insufficient balance", "reason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidWithoutExecData_ReturnsTrue() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), "");
        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }

    function test_WhenAllValidWithExecData_ReturnsTrue() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    VALIDATE / EXECUTE AGREEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidateExecuteAgree_ParamsTooShort() external {
        vm.prank(address(paymentRails));
        (, string memory valReason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00", _defaultExecutionData());
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00", _defaultExecutionData());
        assertEq(valReason, result.failureReason, "reasons must match");
    }

    function test_ValidateExecuteAgree_ZeroTargetToken() external {
        bytes memory params = _buildParams(address(0));
        vm.prank(address(paymentRails));
        (, string memory valReason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());
        assertEq(valReason, result.failureReason, "reasons must match");
    }

    function test_ValidateExecuteAgree_ZeroSellAmount() external {
        vm.prank(address(paymentRails));
        (, string memory valReason) = module.validate(address(sellToken), 0, _defaultParams(), _defaultExecutionData());
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), 0, _defaultParams(), _defaultExecutionData());
        assertEq(valReason, result.failureReason, "reasons must match");
    }
}
