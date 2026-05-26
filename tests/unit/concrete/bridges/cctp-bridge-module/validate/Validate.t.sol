// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract CCTPBridgeModule_Validate_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE CASES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsLengthLessThanMinimum() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");
        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }

    function test_WhenParamsEmpty() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, "");
        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }

    function test_WhenAmountIsZero() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), 0, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Zero bridge amount");
    }

    function test_WhenTokenIsNotUSDC() external view {
        (bool isValid, string memory reason) =
            module.validate(address(otherToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Only USDC supported");
    }

    function test_WhenMintRecipientIsZero() external view {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, bytes32(0), DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero mint recipient");
    }

    function test_WhenFinalityThresholdIsInvalid() external view {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, 500, DEFAULT_HOOK_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Invalid finality threshold");
    }

    function test_WhenMaxFeeEqualsAmount() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_MAX_FEE, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Max fee exceeds amount");
    }

    function test_WhenMaxFeeExceedsAmount() external view {
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Max fee exceeds amount");
    }

    function test_WhenCallerHasInsufficientBalance() external {
        vm.prank(attacker);
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS CASE
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllChecksPass() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertTrue(isValid);
        assertEq(reason, "");
    }

    function testFuzz_WhenAllChecksPass(uint256 amount) external {
        amount = bound(amount, DEFAULT_MAX_FEE + 1, DEFAULT_BRIDGE_AMOUNT * 10);
        vm.prank(address(paymentRails));
        (bool isValid,) = module.validate(address(usdc), amount, _defaultParams());
        assertTrue(isValid);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    VALIDATE / EXECUTE AGREEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidateExecuteAgree_InvalidParams() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");

        assertFalse(isValid);
        assertFalse(result.success);
        assertEq(valReason, result.failureReason);
    }

    function test_ValidateExecuteAgree_ZeroBridgeAmount() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(usdc), 0, _defaultParams());

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), 0, _defaultParams());

        assertFalse(isValid);
        assertFalse(result.success);
        assertEq(valReason, result.failureReason);
    }

    function test_ValidateExecuteAgree_WrongToken() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) =
            module.validate(address(otherToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result =
            module.execute(address(otherToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());

        assertFalse(isValid);
        assertFalse(result.success);
        assertEq(valReason, result.failureReason);
    }

    function test_ValidateExecuteAgree_ZeroMintRecipient() external {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, bytes32(0), DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertFalse(result.success);
        assertEq(valReason, result.failureReason);
    }

    function test_ValidateExecuteAgree_MaxFeeExceedsAmount() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());

        assertFalse(isValid);
        assertFalse(result.success);
        assertEq(valReason, result.failureReason);
    }

    function testFuzz_ValidateExecuteAgreeOnSharedChecks(uint256 amount) external {
        amount = bound(amount, 0, DEFAULT_BRIDGE_AMOUNT * 200);

        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(usdc), amount, _defaultParams());

        try paymentRails.initiateBridge(address(usdc), amount, _defaultParams()) returns (
            DataTypes.ExecutionResult memory result
        ) {
            if (!isValid && !result.success) {
                assertEq(valReason, result.failureReason, "shared validator reasons must match");
            }
        } catch { }
    }
}
