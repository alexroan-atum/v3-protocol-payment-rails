// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { CCTPBridgeModule } from "../../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { MockBridgePaymentRails } from "../../../../../shared/mocks/MockBridgePaymentRails.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CCTPBridgeModuleExecuteTest is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                        FAILED-RESULT TESTS (no revert, returns failure)
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsLengthLessThanMinimum() external {
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid params encoding");
    }

    function test_WhenParamsEmpty() external {
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, "");
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid params encoding");
    }

    function test_WhenAmountIsZero() external {
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), 0, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero bridge amount");
    }

    function test_WhenTokenIsNotUSDC() external {
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result =
            module.execute(address(otherToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Only USDC supported");
    }

    function test_WhenMintRecipientIsZero() external {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, bytes32(0), DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero mint recipient");
    }

    function test_WhenFinalityThresholdIsInvalid() external {
        bytes memory params = _encodeParams(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, 500, DEFAULT_HOOK_DATA
        );
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid finality threshold");
    }

    function test_WhenMaxFeeEqualsAmount() external {
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_MAX_FEE, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Max fee exceeds amount");
    }

    function test_WhenMaxFeeExceedsAmount() external {
        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Max fee exceeds amount");
    }

    function test_WhenCallerHasInsufficientBalance() external {
        vm.prank(attacker);
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Insufficient balance");
    }

    function test_WhenTokenTransferFails() external {
        CCTPBridgeModule failModule = new CCTPBridgeModule(address(tokenMessenger), address(failToken));
        bytes memory params = _encodeParams(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );

        vm.startPrank(address(paymentRails));
        IERC20(address(failToken)).approve(address(failModule), DEFAULT_BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = failModule.execute(address(failToken), DEFAULT_BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Token transfer failed");
    }

    /// @dev Regression test for Certora finding: non-standard ERC20 tokens that return no data
    /// from transferFrom must be treated as successful, not failed.
    function test_WhenNoReturnToken_SucceedsAndBridges() external {
        CCTPBridgeModule nrtModule = new CCTPBridgeModule(address(tokenMessenger), address(noReturnToken));
        bytes memory params = _encodeParams(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );

        MockBridgePaymentRails nrtPaymentRails = new MockBridgePaymentRails(address(nrtModule));
        noReturnToken.mint(address(nrtPaymentRails), DEFAULT_BRIDGE_AMOUNT * 10);

        DataTypes.ExecutionResult memory result =
            nrtPaymentRails.initiateBridge(address(noReturnToken), DEFAULT_BRIDGE_AMOUNT, params);

        assertTrue(result.success, "should succeed with no-return token");
        assertEq(result.amountOut, DEFAULT_BRIDGE_AMOUNT - DEFAULT_MAX_FEE, "amountOut");
        assertEq(tokenMessenger.getDepositCallCount(), 1, "depositForBurn called");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — depositForBurn (no hook)
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenNoHook_CallsDepositForBurn() external {
        _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        assertEq(tokenMessenger.getDepositCallCount(), 1);
        assertEq(tokenMessenger.getDepositWithHookCallCount(), 0);
    }

    function test_GivenNoHook_PassesCorrectArguments() external {
        _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold,
        ) = tokenMessenger.depositCalls(0);

        assertEq(amount, DEFAULT_BRIDGE_AMOUNT);
        assertEq(destinationDomain, DOMAIN_BASE);
        assertEq(mintRecipient, DEFAULT_MINT_RECIPIENT);
        assertEq(burnToken, address(usdc));
        assertEq(destinationCaller, DEFAULT_DESTINATION_CALLER);
        assertEq(maxFee, DEFAULT_MAX_FEE);
        assertEq(minFinalityThreshold, FINALITY_FAST);
    }

    function test_GivenNoHook_RevokesApprovalAfterBurn() external {
        _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        uint256 allowance = usdc.allowance(address(module), address(tokenMessenger));
        assertEq(allowance, 0);
    }

    function test_GivenNoHook_EmitsBridgeInitiated() external {
        vm.expectEmit(true, true, false, true);
        emit BridgeInitiated(
            address(paymentRails),
            DEFAULT_BRIDGE_AMOUNT,
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );

        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
    }

    function test_GivenNoHook_ReturnsSuccessResult() external {
        DataTypes.ExecutionResult memory result = _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(result.amountOut, DEFAULT_BRIDGE_AMOUNT - DEFAULT_MAX_FEE);
        assertEq(result.outputToken, address(usdc));
        assertEq(result.failureReason, "");
    }

    function test_GivenNoHook_ReturnsEncodedDomainAndRecipientInData() external {
        DataTypes.ExecutionResult memory result = _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        (uint32 decodedDomain, bytes32 decodedRecipient) = abi.decode(result.data, (uint32, bytes32));
        assertEq(decodedDomain, DOMAIN_BASE);
        assertEq(decodedRecipient, DEFAULT_MINT_RECIPIENT);
    }

    function test_GivenNoHook_TransfersUSDCFromCallerToModule() external {
        uint256 paymentRailsBalanceBefore = usdc.balanceOf(address(paymentRails));

        _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        uint256 paymentRailsBalanceAfter = usdc.balanceOf(address(paymentRails));
        assertEq(paymentRailsBalanceBefore - paymentRailsBalanceAfter, DEFAULT_BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — depositForBurnWithHook
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenHookData_CallsDepositForBurnWithHook() external {
        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParamsWithHook());

        assertEq(tokenMessenger.getDepositCallCount(), 0);
        assertEq(tokenMessenger.getDepositWithHookCallCount(), 1);
    }

    function test_GivenHookData_PassesHookDataToTokenMessenger() external {
        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParamsWithHook());

        (,,,,,,, bytes memory hookData) = tokenMessenger.depositWithHookCalls(0);
        assertEq(hookData, hex"deadbeef");
    }

    function test_GivenHookData_EmitsBridgeInitiatedWithHookData() external {
        vm.expectEmit(true, true, false, true);
        emit BridgeInitiated(
            address(paymentRails),
            DEFAULT_BRIDGE_AMOUNT,
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            hex"deadbeef"
        );

        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParamsWithHook());
    }

    function test_GivenHookData_ReturnsSuccessResult() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParamsWithHook());

        assertTrue(result.success);
        assertEq(result.amountOut, DEFAULT_BRIDGE_AMOUNT - DEFAULT_MAX_FEE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — standard finality (2000)
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenStandardFinality_PassesFinalityThreshold2000() external {
        bytes memory params = _encodeParams(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            DEFAULT_HOOK_DATA
        );

        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);

        (,,,,,, uint32 minFinalityThreshold,) = tokenMessenger.depositCalls(0);
        assertEq(minFinalityThreshold, FINALITY_STANDARD);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REVERT TESTS — tokenMessenger reverts
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTokenMessengerReverts_PropagatesRevert() external {
        tokenMessenger.setRevert(true, "CCTP: burn limit exceeded");

        vm.expectRevert("CCTP: burn limit exceeded");
        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_Execute_SuccessPath(uint256 amount) external {
        amount = bound(amount, DEFAULT_MAX_FEE + 1, DEFAULT_BRIDGE_AMOUNT * 10);
        usdc.mint(address(paymentRails), amount);

        DataTypes.ExecutionResult memory result = _executeBridgeFromPaymentRails(amount);

        assertTrue(result.success);
        assertEq(result.amountOut, amount - DEFAULT_MAX_FEE);
        assertEq(tokenMessenger.getDepositCallCount(), 1);
    }

    function testFuzz_Execute_ZeroMaxFee(uint256 amount) external {
        amount = bound(amount, 1, DEFAULT_BRIDGE_AMOUNT * 10);
        usdc.mint(address(paymentRails), amount);

        bytes memory params = _encodeParams(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, 0, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        DataTypes.ExecutionResult memory result = paymentRails.initiateBridge(address(usdc), amount, params);

        assertTrue(result.success);
        assertEq(result.amountOut, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CONSECUTIVE EXECUTION TEST
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenExecutedConsecutively_EachSucceeds() external {
        DataTypes.ExecutionResult memory result1 = _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result2 = _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);

        assertTrue(result1.success);
        assertTrue(result2.success);
        assertEq(tokenMessenger.getDepositCallCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    DIFFERENT DOMAIN EXECUTION TEST
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenBridgingToDifferentDomains() external {
        bytes32 recipientArb = bytes32(uint256(uint160(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)));
        bytes memory arbParams = _encodeParams(
            DOMAIN_ARBITRUM, recipientArb, DEFAULT_DESTINATION_CALLER, 0, FINALITY_STANDARD, DEFAULT_HOOK_DATA
        );

        _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);
        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, arbParams);

        assertEq(tokenMessenger.getDepositCallCount(), 2);

        (, uint32 domain1,,,,,,) = tokenMessenger.depositCalls(0);
        (, uint32 domain2, bytes32 recipient2,,,,,) = tokenMessenger.depositCalls(1);

        assertEq(domain1, DOMAIN_BASE);
        assertEq(domain2, DOMAIN_ARBITRUM);
        assertEq(recipient2, recipientArb);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    DESTINATION CALLER TEST
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenDestinationCallerIsSet_PassesItToTokenMessenger() external {
        bytes32 specificCaller = bytes32(uint256(uint160(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF)));
        bytes memory params = _encodeParams(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, specificCaller, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        paymentRails.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, params);

        (,,,, bytes32 destinationCaller,,,) = tokenMessenger.depositCalls(0);
        assertEq(destinationCaller, specificCaller);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PERMISSIONLESS EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenCalledByNonOwner_Succeeds() external {
        DataTypes.ExecutionResult memory result = _executeBridgeFromPaymentRails(DEFAULT_BRIDGE_AMOUNT);
        assertTrue(result.success);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    BOUNDARY CONDITION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAmountEqualsMaxFeePlusOne_SucceedsWithAmountOutOne() external {
        uint256 amount = DEFAULT_MAX_FEE + 1;
        usdc.mint(address(paymentRails), amount);

        DataTypes.ExecutionResult memory result = _executeBridgeFromPaymentRails(amount);

        assertTrue(result.success);
        assertEq(result.amountOut, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _executeBridgeFromPaymentRails(uint256 amount) internal returns (DataTypes.ExecutionResult memory) {
        return paymentRails.initiateBridge(address(usdc), amount, _defaultParams());
    }
}
