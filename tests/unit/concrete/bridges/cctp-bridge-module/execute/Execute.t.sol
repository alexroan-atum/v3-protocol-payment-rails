// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { CCTPBridgeModule } from "../../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { MockTokenMessengerV2 } from "../../../../../shared/mocks/MockTokenMessengerV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CCTPBridgeModule_Execute_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                        FAILED-RESULT TESTS (no revert, returns failure)
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsLengthLessThan32() external {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, hex"00");
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid params encoding");
    }

    function test_WhenParamsEmpty() external {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, "");
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid params encoding");
    }

    function test_WhenAmountIsZero() external givenDomainConfigured {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), 0, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero bridge amount");
    }

    function test_WhenTokenIsNotUSDC() external givenDomainConfigured {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result =
            module.execute(address(otherToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Only USDC supported");
    }

    function test_WhenDomainNotConfigured() external {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Domain not configured");
    }

    function test_WhenMaxFeeEqualsAmount() external givenDomainConfigured {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_MAX_FEE, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Max fee exceeds amount");
    }

    function test_WhenMaxFeeExceedsAmount() external givenDomainConfigured {
        vm.prank(address(node));
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_MAX_FEE - 1, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Max fee exceeds amount");
    }

    function test_WhenCallerHasInsufficientBalance() external givenDomainConfigured {
        vm.prank(attacker);
        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Insufficient balance");
    }

    function test_WhenTokenTransferFails() external {
        CCTPBridgeModule failModule = new CCTPBridgeModule(address(tokenMessenger), address(failToken), owner);
        failModule.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );

        vm.startPrank(address(node));
        IERC20(address(failToken)).approve(address(failModule), DEFAULT_BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result =
            failModule.execute(address(failToken), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Token transfer failed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — depositForBurn (no hook)
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenNoHook_CallsDepositForBurn() external givenDomainConfigured {
        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        assertEq(tokenMessenger.getDepositCallCount(), 1);
        assertEq(tokenMessenger.getDepositWithHookCallCount(), 0);
    }

    function test_GivenNoHook_PassesCorrectArguments() external givenDomainConfigured {
        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

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

    function test_GivenNoHook_RevokesApprovalAfterBurn() external givenDomainConfigured {
        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        uint256 allowance = usdc.allowance(address(module), address(tokenMessenger));
        assertEq(allowance, 0);
    }

    function test_GivenNoHook_EmitsBridgeInitiated() external givenDomainConfigured {
        vm.expectEmit(true, true, false, true);
        emit BridgeInitiated(
            address(node),
            DEFAULT_BRIDGE_AMOUNT,
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );

        node.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
    }

    function test_GivenNoHook_ReturnsSuccessResult() external givenDomainConfigured {
        DataTypes.ExecutionResult memory result = _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(result.amountOut, DEFAULT_BRIDGE_AMOUNT - DEFAULT_MAX_FEE);
        assertEq(result.outputToken, address(usdc));
        assertEq(result.failureReason, "");
    }

    function test_GivenNoHook_ReturnsEncodedDomainAndRecipientInData() external givenDomainConfigured {
        DataTypes.ExecutionResult memory result = _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        (uint32 decodedDomain, bytes32 decodedRecipient) = abi.decode(result.data, (uint32, bytes32));
        assertEq(decodedDomain, DOMAIN_BASE);
        assertEq(decodedRecipient, DEFAULT_MINT_RECIPIENT);
    }

    function test_GivenNoHook_TransfersUSDCFromCallerToModule() external givenDomainConfigured {
        uint256 nodeBalanceBefore = usdc.balanceOf(address(node));

        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        uint256 nodeBalanceAfter = usdc.balanceOf(address(node));
        assertEq(nodeBalanceBefore - nodeBalanceAfter, DEFAULT_BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — depositForBurnWithHook
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenHookData_CallsDepositForBurnWithHook() external givenDomainConfiguredWithHook {
        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        assertEq(tokenMessenger.getDepositCallCount(), 0);
        assertEq(tokenMessenger.getDepositWithHookCallCount(), 1);
    }

    function test_GivenHookData_PassesHookDataToTokenMessenger() external givenDomainConfiguredWithHook {
        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        (,,,,,,, bytes memory hookData) = tokenMessenger.depositWithHookCalls(0);
        assertEq(hookData, hex"deadbeef");
    }

    function test_GivenHookData_EmitsBridgeInitiatedWithHookData() external givenDomainConfiguredWithHook {
        vm.expectEmit(true, true, false, true);
        emit BridgeInitiated(
            address(node),
            DEFAULT_BRIDGE_AMOUNT,
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            hex"deadbeef"
        );

        node.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
    }

    function test_GivenHookData_ReturnsSuccessResult() external givenDomainConfiguredWithHook {
        DataTypes.ExecutionResult memory result = _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(result.amountOut, DEFAULT_BRIDGE_AMOUNT - DEFAULT_MAX_FEE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — standard finality (2000)
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenStandardFinality_PassesFinalityThreshold2000() external {
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            DEFAULT_HOOK_DATA
        );

        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        (,,,,,, uint32 minFinalityThreshold,) = tokenMessenger.depositCalls(0);
        assertEq(minFinalityThreshold, FINALITY_STANDARD);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REVERT TESTS — tokenMessenger reverts
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTokenMessengerReverts_PropagatesRevert() external givenDomainConfigured {
        tokenMessenger.setRevert(true, "CCTP: burn limit exceeded");

        vm.expectRevert("CCTP: burn limit exceeded");
        node.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_Execute_SuccessPath(uint256 amount) external givenDomainConfigured {
        amount = bound(amount, DEFAULT_MAX_FEE + 1, DEFAULT_BRIDGE_AMOUNT * 10);
        usdc.mint(address(node), amount);

        DataTypes.ExecutionResult memory result = _executeBridgeFromNode(amount);

        assertTrue(result.success);
        assertEq(result.amountOut, amount - DEFAULT_MAX_FEE);
        assertEq(tokenMessenger.getDepositCallCount(), 1);
    }

    function testFuzz_Execute_ZeroMaxFee(uint256 amount) external {
        amount = bound(amount, 1, DEFAULT_BRIDGE_AMOUNT * 10);
        usdc.mint(address(node), amount);

        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, 0, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        DataTypes.ExecutionResult memory result = _executeBridgeFromNode(amount);

        assertTrue(result.success);
        assertEq(result.amountOut, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CONSECUTIVE EXECUTION TEST
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenExecutedConsecutively_EachSucceeds() external givenDomainConfigured {
        DataTypes.ExecutionResult memory result1 = _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result2 = _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        assertTrue(result1.success);
        assertTrue(result2.success);
        assertEq(tokenMessenger.getDepositCallCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    DIFFERENT DOMAIN EXECUTION TEST
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenBridgingToDifferentDomains() external givenDomainConfigured {
        bytes32 recipientArb = bytes32(uint256(uint160(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)));
        module.setDomainConfig(
            DOMAIN_ARBITRUM, recipientArb, DEFAULT_DESTINATION_CALLER, 0, FINALITY_STANDARD, DEFAULT_HOOK_DATA
        );

        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);
        node.initiateBridge(address(usdc), DEFAULT_BRIDGE_AMOUNT, _encodeParams(DOMAIN_ARBITRUM));

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
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, specificCaller, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        _executeBridgeFromNode(DEFAULT_BRIDGE_AMOUNT);

        (,,,, bytes32 destinationCaller,,,) = tokenMessenger.depositCalls(0);
        assertEq(destinationCaller, specificCaller);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _executeBridgeFromNode(uint256 amount) internal returns (DataTypes.ExecutionResult memory) {
        return node.initiateBridge(address(usdc), amount, _defaultParams());
    }
}
