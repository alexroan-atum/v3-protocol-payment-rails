// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";

contract CCTPBridgeModule_Validate_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE CASES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsLengthLessThan32() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");
        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }

    function test_WhenParamsEmpty() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, "");
        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }

    function test_WhenAmountIsZero() external givenDomainConfigured {
        (bool isValid, string memory reason) = module.validate(address(usdc), 0, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Zero bridge amount");
    }

    function test_WhenTokenIsNotUSDC() external givenDomainConfigured {
        (bool isValid, string memory reason) =
            module.validate(address(otherToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Only USDC supported");
    }

    function test_WhenDomainNotConfigured() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Domain not configured");
    }

    function test_WhenMaxFeeEqualsAmount() external givenDomainConfigured {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_MAX_FEE, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Max fee exceeds amount");
    }

    function test_WhenMaxFeeExceedsAmount() external givenDomainConfigured {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Max fee exceeds amount");
    }

    function test_WhenCallerHasInsufficientBalance() external givenDomainConfigured {
        vm.prank(attacker);
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS CASE
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllChecksPass() external givenDomainConfigured {
        vm.prank(address(node));
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertTrue(isValid);
        assertEq(reason, "");
    }

    function testFuzz_WhenAllChecksPass(uint256 amount) external givenDomainConfigured {
        amount = bound(amount, DEFAULT_MAX_FEE + 1, DEFAULT_BRIDGE_AMOUNT * 10);
        vm.prank(address(node));
        (bool isValid,) = module.validate(address(usdc), amount, _defaultParams());
        assertTrue(isValid);
    }
}
