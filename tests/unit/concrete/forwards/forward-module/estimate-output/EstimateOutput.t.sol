// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ForwardModuleBase } from "../ForwardModuleBase.t.sol";

contract ForwardModuleEstimateOutputTest is ForwardModuleBase {
    function test_ReturnsAmountAsEstimatedOutput() external view {
        bytes memory params = _defaultParams();

        (uint256 estimatedOutput,) = module.estimateOutput(address(token), DEFAULT_AMOUNT, params);

        assertEq(estimatedOutput, DEFAULT_AMOUNT, "estimatedOutput");
    }

    function test_ReturnsTokenAsOutputToken() external view {
        bytes memory params = _defaultParams();

        (, address outputToken) = module.estimateOutput(address(token), DEFAULT_AMOUNT, params);

        assertEq(outputToken, address(token), "outputToken");
    }

    function test_ReturnsZeroForZeroAmount() external view {
        bytes memory params = _defaultParams();

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(address(token), 0, params);

        assertEq(estimatedOutput, 0, "estimatedOutput");
        assertEq(outputToken, address(token), "outputToken");
    }

    function test_ReturnsSameOutputRegardlessOfParams() external view {
        bytes memory params1 = _buildParams(recipient, 0);
        bytes memory params2 = _buildParams(address(0), type(uint256).max);

        (uint256 output1, address token1) = module.estimateOutput(address(token), DEFAULT_AMOUNT, params1);
        (uint256 output2, address token2) = module.estimateOutput(address(token), DEFAULT_AMOUNT, params2);

        assertEq(output1, output2, "estimatedOutput should match");
        assertEq(token1, token2, "outputToken should match");
    }

    function testFuzz_ReturnsExactInputValues(uint256 amount) external view {
        bytes memory params = _defaultParams();

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(address(token), amount, params);

        assertEq(estimatedOutput, amount, "estimatedOutput");
        assertEq(outputToken, address(token), "outputToken");
    }
}
