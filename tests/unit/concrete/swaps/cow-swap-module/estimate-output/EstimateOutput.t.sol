// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";

/// @notice Unit tests for CowSwapModule.estimateOutput()
/// @dev Tree: tests/unit/concrete/cow-swap-module/estimate-output/estimateOutput.tree
contract CowSwapModule_EstimateOutput_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // it should return oracle-expected output as estimated output
    // -----------------------------------------------------------------------

    function test_ReturnsOracleExpectedOutputAsEstimatedOutput() external view {
        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        // 1:1 prices, 18-decimal tokens → expected output equals sell amount
        assertEq(estimated, DEFAULT_SELL_AMOUNT);
    }

    // -----------------------------------------------------------------------
    // it should return targetToken as output token
    // -----------------------------------------------------------------------

    function test_ReturnsTargetTokenAsOutputToken() external view {
        (, address outputToken) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(outputToken, address(buyToken));
    }

    // -----------------------------------------------------------------------
    // it should scale proportionally with sell amount
    // -----------------------------------------------------------------------

    function test_ScalesProportionallyWithSellAmount() external view {
        bytes memory params = _buildDefaultParams();
        (uint256 a,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        (uint256 b,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT / 2, params);
        // 1:1 oracle → output scales linearly with sell amount
        assertEq(a, DEFAULT_SELL_AMOUNT);
        assertEq(b, DEFAULT_SELL_AMOUNT / 2);
    }

    function testFuzz_ScalesLinearlyWithSellAmount(uint256 amount) external view {
        amount = bound(amount, 1, DEFAULT_SELL_AMOUNT * 9);
        (uint256 estimated,) = module.estimateOutput(address(sellToken), amount, _buildDefaultParams());
        // 1:1 oracle with equal decimals → expected output equals sell amount
        assertEq(estimated, amount);
    }
}
