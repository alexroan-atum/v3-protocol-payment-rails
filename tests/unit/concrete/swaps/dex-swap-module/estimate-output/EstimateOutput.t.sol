// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";

/// @notice Unit tests for DexSwapModule.estimateOutput()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/estimate-output/estimateOutput.tree
contract DexSwapModule_EstimateOutput_Test is DexSwapModuleBase {
    function test_ReturnsOracleExpectedOutput() external view {
        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        uint256 expectedOutput = _computeExpectedOutput(DEFAULT_SELL_AMOUNT);
        assertEq(estimated, expectedOutput, "estimated output should match oracle computation");
    }

    function test_ReturnsTargetTokenAsOutputToken() external view {
        (, address outputToken) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(outputToken, address(buyToken), "output token should be target token");
    }

    function test_ScalesLinearly() external view {
        (uint256 est1,) = module.estimateOutput(address(sellToken), 1e18, _defaultParams());
        (uint256 est10,) = module.estimateOutput(address(sellToken), 10e18, _defaultParams());
        assertEq(est10, est1 * 10, "Output should scale linearly with input");
    }

    function test_WhenOracleFails_ReturnsZero() external {
        sellFeed.setShouldRevert(true);
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(estimated, 0, "Should return zero when oracle fails");
        assertEq(outputToken, address(buyToken), "Should still return target token");
    }

    function testFuzz_AlwaysReturnsTargetToken(uint256 amount) external view {
        amount = bound(amount, 0, type(uint128).max);
        (, address outputToken) = module.estimateOutput(address(sellToken), amount, _defaultParams());
        assertEq(outputToken, address(buyToken));
    }
}
