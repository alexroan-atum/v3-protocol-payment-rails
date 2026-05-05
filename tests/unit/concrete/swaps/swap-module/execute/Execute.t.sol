// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract SwapModuleExecuteTest is SwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTargetTokenIsZeroAddress_ReturnsFailedResult() external whenTargetTokenIsZeroAddress {
        bytes memory params = _buildParams(address(0), dexRouter);

        vm.prank(caller);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero target token", "failureReason");
        assertEq(result.amountOut, 0, "amountOut");
        assertEq(result.outputToken, address(0), "outputToken");
        assertEq(result.data.length, 0, "data");
    }

    function test_WhenDexRouterIsZeroAddress_ReturnsFailedResult() external whenDexRouterIsZeroAddress {
        bytes memory params = _buildParams(address(buyToken), address(0));

        vm.prank(caller);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero DEX router", "failureReason");
        assertEq(result.outputToken, address(buyToken), "outputToken");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFailedResult() external whenCallerHasInsufficientBalance {
        bytes memory params = _defaultParams();
        address emptyCallerAddr = makeAddr("emptyCaller");

        vm.prank(emptyCallerAddr);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Insufficient balance", "failureReason");
    }

    function test_WhenMultipleValidationsFail_ReturnsFirstFailure() external {
        bytes memory params = _buildParams(address(0), address(0));

        vm.prank(caller);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero target token", "failureReason");
    }

    // execute() has no same-token guard (unlike validate)
    function test_WhenInputEqualsOutputToken_ReturnsSwapNotImplemented() external whenInputEqualsOutputToken {
        bytes memory params = _buildParams(address(sellToken), dexRouter);

        vm.prank(caller);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Swap not implemented", "failureReason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            STUB BEHAVIOR TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidationsPass_ReturnsSwapNotImplemented() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(caller);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Swap not implemented", "failureReason");
        assertEq(result.amountOut, 0, "amountOut");
        assertEq(result.outputToken, address(buyToken), "outputToken");
        assertEq(result.data.length, 0, "data");
    }

    function test_WhenAllValidationsPass_DoesNotTransferTokens() external whenAllValidationsPass {
        bytes memory params = _defaultParams();
        uint256 callerBefore = sellToken.balanceOf(caller);

        vm.prank(caller);
        module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertEq(sellToken.balanceOf(caller), callerBefore, "caller balance unchanged");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_AlwaysReturnsFalse(uint256 amount) external {
        amount = bound(amount, 0, DEFAULT_SELL_AMOUNT * 50);
        bytes memory params = _defaultParams();

        vm.prank(caller);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), amount, params);

        assertFalse(result.success, "success");
    }
}
