// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";

contract SwapModuleValidateTest is SwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTargetTokenIsZeroAddress_ReturnsFalse() external whenTargetTokenIsZeroAddress {
        bytes memory params = _buildParams(address(0), dexRouter);

        vm.prank(caller);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero target token", "reason");
    }

    function test_WhenDexRouterIsZeroAddress_ReturnsFalse() external whenDexRouterIsZeroAddress {
        bytes memory params = _buildParams(address(buyToken), address(0));

        vm.prank(caller);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero DEX router", "reason");
    }

    function test_WhenInputEqualsOutputToken_ReturnsFalse() external whenInputEqualsOutputToken {
        bytes memory params = _buildParams(address(sellToken), dexRouter);

        vm.prank(caller);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Same input and output token", "reason");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFalse() external whenCallerHasInsufficientBalance {
        bytes memory params = _defaultParams();
        address emptyCallerAddr = makeAddr("emptyCaller");

        vm.prank(emptyCallerAddr);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Insufficient balance", "reason");
    }

    function test_WhenMultipleValidationsFail_ReturnsFirstFailure() external {
        bytes memory params = _buildParams(address(0), address(0));

        vm.prank(caller);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero target token", "reason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValidationsPass_ReturnsTrue() external whenAllValidationsPass {
        bytes memory params = _defaultParams();

        vm.prank(caller);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }

    function test_WhenBalanceEqualsAmount_ReturnsTrue() external whenAllValidationsPass {
        address exactCaller = makeAddr("exactCaller");
        sellToken.mint(exactCaller, DEFAULT_SELL_AMOUNT);
        bytes memory params = _defaultParams();

        vm.prank(exactCaller);
        (bool isValid,) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(isValid, "isValid");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_WhenAllValidationsPass_ReturnsTrue(uint256 amount) external {
        amount = bound(amount, 1, DEFAULT_SELL_AMOUNT * 50);
        bytes memory params = _defaultParams();

        vm.prank(caller);
        (bool isValid, string memory reason) = module.validate(address(sellToken), amount, params);

        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }
}
