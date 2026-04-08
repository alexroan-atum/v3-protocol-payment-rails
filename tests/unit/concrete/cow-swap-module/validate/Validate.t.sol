// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for CowSwapModule.validate()
/// @dev Tree: tests/unit/concrete/cow-swap-module/validate/validate.tree
contract CowSwapModule_Validate_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when params are malformed (L-1 fix — mirrors execute)
    // -----------------------------------------------------------------------

    function test_WhenParamsAreMalformed_ReturnsFalse() external view {
        bytes memory malformedParams = abi.encode(address(buyToken)); // only 1 word instead of 4
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }

    function test_WhenParamsAreMalformed_ReasonMatchesExecute() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        (, string memory validateReason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        DataTypes.ExecutionResult memory result =
            node.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertEq(validateReason, result.failureReason, "validate/execute reason must match for malformed params");
    }

    // -----------------------------------------------------------------------
    // when amount is zero
    // -----------------------------------------------------------------------

    function test_WhenAmountIsZero_ReturnsFalse() external view {
        (bool isValid, string memory reason) = module.validate(address(sellToken), 0, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Zero sell amount");
    }

    function test_WhenAmountIsZero_ReasonMatchesExecute() external {
        // validate() and execute() must agree: both reject zero amounts
        (, string memory validateReason) =
            module.validate(address(sellToken), 0, _buildDefaultParams());
        DataTypes.ExecutionResult memory result =
            node.initiateSwap(address(sellToken), 0, _buildDefaultParams());
        assertEq(validateReason, result.failureReason, "validate/execute reason must match");
    }

    // -----------------------------------------------------------------------
    // when target token is zero address
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(address(0), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero target token");
    }

    // -----------------------------------------------------------------------
    // when target token equals sell token
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenEqualsSellToken_ReturnsFalse() external view {
        bytes memory params =
            _buildParams(address(sellToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Same sell and buy token");
    }

    // -----------------------------------------------------------------------
    // when min buy amount is zero
    // -----------------------------------------------------------------------

    function test_WhenMinBuyAmountIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(address(buyToken), 0, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero minimum buy amount");
    }

    // -----------------------------------------------------------------------
    // when validity duration is zero
    // -----------------------------------------------------------------------

    function test_WhenValidityDurationIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, 0, DEFAULT_APP_DATA);
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero validity duration");
    }

    // -----------------------------------------------------------------------
    // when validity duration overflows uint32 (M-2 fix)
    // -----------------------------------------------------------------------

    function test_WhenValidityDurationOverflows_ReturnsFalse() external {
        bytes memory params = _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, type(uint32).max, DEFAULT_APP_DATA);
        vm.prank(address(node));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Validity duration overflow");
    }

    function test_WhenValidityDurationOverflows_ReasonMatchesExecute() external {
        bytes memory params = _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, type(uint32).max, DEFAULT_APP_DATA);
        vm.prank(address(node));
        (, string memory validateReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        DataTypes.ExecutionResult memory result =
            node.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(validateReason, result.failureReason, "validate/execute reason must match for overflow");
    }

    // -----------------------------------------------------------------------
    // when caller has insufficient balance
    // -----------------------------------------------------------------------

    function test_WhenCallerHasInsufficientBalance_ReturnsFalse() external view {
        // The test contract (msg.sender here) holds no sell tokens
        bytes memory params = _buildDefaultParams();
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }

    // -----------------------------------------------------------------------
    // when all parameters are valid
    // -----------------------------------------------------------------------

    function test_WhenAllParametersAreValid_ReturnsTrue() external {
        bytes memory params = _buildDefaultParams();
        // Node holds 10x DEFAULT_SELL_AMOUNT, so balance check passes
        vm.prank(address(node));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(isValid);
        assertEq(reason, "");
    }

    function test_WhenAllParametersAreValid_ReturnsEmptyReason() external {
        bytes memory params = _buildDefaultParams();
        vm.prank(address(node));
        (, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(bytes(reason).length, 0);
    }
}
