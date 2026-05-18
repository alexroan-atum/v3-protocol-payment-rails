// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";

/// @notice Unit tests for DexSwapModule.estimateOutput()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/estimate-output/estimateOutput.tree
contract DexSwapModule_EstimateOutput_Test is DexSwapModuleBase {
    function test_ReturnsZeroAsEstimatedOutput() external view {
        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(estimated, 0, "estimated output should be zero");
    }

    function test_ReturnsTargetTokenAsOutputToken() external view {
        (, address outputToken) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(outputToken, address(buyToken), "output token should be target token");
    }

    function test_IgnoresSellAmount() external view {
        (, address outputA) = module.estimateOutput(address(sellToken), 0, _defaultParams());
        (, address outputB) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        (, address outputC) = module.estimateOutput(address(sellToken), type(uint256).max, _defaultParams());
        assertEq(outputA, address(buyToken));
        assertEq(outputB, address(buyToken));
        assertEq(outputC, address(buyToken));
    }

    function test_IgnoresSellTokenAddress() external view {
        (, address outputA) = module.estimateOutput(address(0), DEFAULT_SELL_AMOUNT, _defaultParams());
        (, address outputB) = module.estimateOutput(address(buyToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(outputA, address(buyToken));
        assertEq(outputB, address(buyToken));
    }

    function testFuzz_AlwaysReturnsZeroAndTargetToken(uint256 amount, address token) external view {
        (uint256 estimated, address outputToken) = module.estimateOutput(token, amount, _defaultParams());
        assertEq(estimated, 0);
        assertEq(outputToken, address(buyToken));
    }
}
