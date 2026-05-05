// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";

contract SwapModuleEstimateOutputTest is SwapModuleBase {
    function test_ReturnsZeroAsEstimatedOutput() external view {
        bytes memory params = _defaultParams();

        (uint256 estimatedOutput,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertEq(estimatedOutput, 0, "estimatedOutput");
    }

    function test_ReturnsTargetTokenAsOutputToken() external view {
        bytes memory params = _defaultParams();

        (, address outputToken) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertEq(outputToken, address(buyToken), "outputToken");
    }

    function testFuzz_AlwaysReturnsZeroEstimate(uint256 amount) external view {
        bytes memory params = _defaultParams();

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(address(sellToken), amount, params);

        assertEq(estimatedOutput, 0, "estimatedOutput");
        assertEq(outputToken, address(buyToken), "outputToken");
    }
}
