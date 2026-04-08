// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";

/// @notice Unit tests for CowSwapModule.estimateOutput()
/// @dev Tree: tests/unit/concrete/cow-swap-module/estimate-output/estimateOutput.tree
contract CowSwapModule_EstimateOutput_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // it should return minBuyAmount as estimated output
    // -----------------------------------------------------------------------

    function test_ReturnsMinBuyAmountAsEstimatedOutput() external view {
        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(estimated, DEFAULT_MIN_BUY_AMOUNT);
    }

    // -----------------------------------------------------------------------
    // it should return targetToken as output token
    // -----------------------------------------------------------------------

    function test_ReturnsTargetTokenAsOutputToken() external view {
        (, address outputToken) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(outputToken, address(buyToken));
    }

    // -----------------------------------------------------------------------
    // it should ignore the sell amount input
    // -----------------------------------------------------------------------

    function test_IgnoresSellAmount() external view {
        bytes memory params = _buildDefaultParams();
        (uint256 a,) = module.estimateOutput(address(sellToken), 0, params);
        (uint256 b,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        (uint256 c,) = module.estimateOutput(address(sellToken), type(uint256).max, params);
        assertEq(a, DEFAULT_MIN_BUY_AMOUNT);
        assertEq(b, DEFAULT_MIN_BUY_AMOUNT);
        assertEq(c, DEFAULT_MIN_BUY_AMOUNT);
    }

    function testFuzz_AlwaysReturnsMinBuyAmountRegardlessOfSellAmount(uint256 amount) external view {
        (uint256 estimated,) = module.estimateOutput(address(sellToken), amount, _buildDefaultParams());
        assertEq(estimated, DEFAULT_MIN_BUY_AMOUNT);
    }

    function testFuzz_ReturnsConfiguredMinBuyAmount(uint256 minBuyAmount) external view {
        minBuyAmount = bound(minBuyAmount, 1, type(uint256).max);
        bytes memory params = _buildParams(address(buyToken), minBuyAmount, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(estimated, minBuyAmount);
    }
}
