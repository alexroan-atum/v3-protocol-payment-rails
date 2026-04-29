// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";

contract CCTPBridgeModule_EstimateOutput_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            ZERO-OUTPUT CASES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsLengthLessThan32() external view {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenDomainNotConfigured() external view {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMaxFeeEqualsAmount() external givenDomainConfigured {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_MAX_FEE, _defaultParams());
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMaxFeeExceedsAmount() external givenDomainConfigured {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS CASE
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllChecksPass() external givenDomainConfigured {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertEq(estimated, DEFAULT_BRIDGE_AMOUNT - DEFAULT_MAX_FEE);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMaxFeeIsZero() external {
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, 0, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertEq(estimated, DEFAULT_BRIDGE_AMOUNT);
        assertEq(outputToken, address(usdc));
    }

    function testFuzz_WhenAllChecksPass(uint256 amount) external givenDomainConfigured {
        amount = bound(amount, DEFAULT_MAX_FEE + 1, type(uint128).max);
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), amount, _defaultParams());
        assertEq(estimated, amount - DEFAULT_MAX_FEE);
        assertEq(outputToken, address(usdc));
    }
}
