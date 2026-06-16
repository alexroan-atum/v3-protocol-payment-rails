// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";

contract CCTPBridgeModule_EstimateOutput_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            ZERO-OUTPUT CASES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsLengthLessThanMinimum() external view {
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMintRecipientIsZero() external view {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, bytes32(0), DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE_BPS, FINALITY_FAST, DEFAULT_HOOK_DATA
        );
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMaxFeeBpsEquals10000() external view {
        bytes memory params = _encodeParams(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            uint16(10_000),
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMaxFeeBpsExceeds10000() external view {
        bytes memory params = _encodeParams(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            uint16(15_000),
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertEq(estimated, 0);
        assertEq(outputToken, address(usdc));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS CASE
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllChecksPass() external {
        vm.prank(address(paymentRails));
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertEq(estimated, DEFAULT_BRIDGE_AMOUNT - _computeMaxFee(DEFAULT_BRIDGE_AMOUNT, DEFAULT_MAX_FEE_BPS));
        assertEq(outputToken, address(usdc));
    }

    function test_WhenMaxFeeBpsIsZero() external {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, uint16(0), FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        vm.prank(address(paymentRails));
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertEq(estimated, DEFAULT_BRIDGE_AMOUNT);
        assertEq(outputToken, address(usdc));
    }

    function testFuzz_WhenAllChecksPass(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        usdc.mint(address(paymentRails), amount);
        vm.prank(address(paymentRails));
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), amount, _defaultParams());
        assertEq(estimated, amount - _computeMaxFee(amount, DEFAULT_MAX_FEE_BPS));
        assertEq(outputToken, address(usdc));
    }
}
