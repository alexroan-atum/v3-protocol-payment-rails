// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { CCTPBridgeModule } from "../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { MockTokenMessengerV2 } from "../../../../shared/mocks/MockTokenMessengerV2.sol";

contract CCTPBridgeModuleIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    event BridgeInitiated(
        address indexed paymentRails,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes hookData
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint32 internal constant DOMAIN_BASE = 6;
    bytes32 internal constant MINT_RECIPIENT = bytes32(uint256(uint160(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB)));
    uint256 internal constant MAX_FEE = 1e6;
    uint32 internal constant FINALITY_FAST = 1000;
    uint256 internal constant BRIDGE_AMOUNT = 1000e6;
    uint256 internal constant MIN_BALANCE = 100e6;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    PaymentRails internal paymentRailsContract;
    CCTPBridgeModule internal bridgeModule;
    MockTokenMessengerV2 internal tokenMessenger;
    MockERC20 internal usdc;

    address internal paymentRailsOwner;
    address internal executor;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        paymentRailsOwner = makeAddr("paymentRailsOwner");
        executor = makeAddr("executor");

        tokenMessenger = new MockTokenMessengerV2();
        usdc = new MockERC20("USD Coin", "USDC");

        bridgeModule = new CCTPBridgeModule(address(tokenMessenger), address(usdc));

        paymentRailsContract = new PaymentRails(paymentRailsOwner);

        bytes memory moduleParams = _buildModuleParams(DOMAIN_BASE, MINT_RECIPIENT, MAX_FEE, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, moduleParams, true
        );

        usdc.mint(address(paymentRailsContract), BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_FullBridgeLifecycle() external {
        vm.prank(executor);
        bool success = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertTrue(success);

        assertEq(tokenMessenger.getDepositCallCount(), 1);

        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,,
            uint256 maxFee,
            uint32 minFinalityThreshold,
        ) = tokenMessenger.depositCalls(0);

        assertEq(amount, BRIDGE_AMOUNT);
        assertEq(destinationDomain, DOMAIN_BASE);
        assertEq(mintRecipient, MINT_RECIPIENT);
        assertEq(burnToken, address(usdc));
        assertEq(maxFee, MAX_FEE);
        assertEq(minFinalityThreshold, FINALITY_FAST);
    }

    function test_PaymentRailsEmitsActionExecuted() external {
        vm.expectEmit(true, false, false, true);
        emit ActionExecuted(
            address(usdc), "CCTP_BRIDGE", BRIDGE_AMOUNT, BRIDGE_AMOUNT - MAX_FEE, address(usdc), executor
        );

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
    }

    function test_BridgeModuleEmitsBridgeInitiated() external {
        vm.expectEmit(true, true, false, true);
        emit BridgeInitiated(
            address(paymentRailsContract), BRIDGE_AMOUNT, DOMAIN_BASE, MINT_RECIPIENT, MAX_FEE, FINALITY_FAST, ""
        );

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
    }

    function test_ApprovalIsConsumedAfterExecution() external {
        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        uint256 moduleAllowance = usdc.allowance(address(bridgeModule), address(tokenMessenger));
        assertEq(moduleAllowance, 0);

        uint256 nodeAllowance = usdc.allowance(address(paymentRailsContract), address(bridgeModule));
        assertEq(nodeAllowance, 0);
    }

    function test_PermissionlessExecution_AnyoneCanCall() external {
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        bool success = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertTrue(success);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    TOKEN MESSENGER REVERT — NODE CATCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTokenMessengerReverts_PaymentRailsReturnsFalse() external {
        tokenMessenger.setRevert(true, "CCTP: paused");

        vm.prank(executor);
        bool success = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertFalse(success);

        assertEq(usdc.balanceOf(address(paymentRailsContract)), BRIDGE_AMOUNT);
    }

    function test_WhenTokenMessengerReverts_PaymentRailsRevokesApproval() external {
        tokenMessenger.setRevert(true, "CCTP: paused");

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        uint256 nodeAllowance = usdc.allowance(address(paymentRailsContract), address(bridgeModule));
        assertEq(nodeAllowance, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    VALIDATION FAILURES — NODE BLOCKS EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_BelowMinBalance() external {
        uint256 smallAmount = MIN_BALANCE - 1;

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_BelowMinimumBalance.selector, smallAmount, MIN_BALANCE)
        );
        paymentRailsContract.executeAction(address(usdc), smallAmount);
    }

    function test_RevertWhen_AmountExceedsBalance() external {
        uint256 tooMuch = BRIDGE_AMOUNT + 1;

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_InsufficientBalance.selector, BRIDGE_AMOUNT, tooMuch)
        );
        paymentRailsContract.executeAction(address(usdc), tooMuch);
    }

    function test_RevertWhen_TokenNotEnabled() external {
        bytes memory moduleParams = _buildModuleParams(DOMAIN_BASE, MINT_RECIPIENT, MAX_FEE, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, moduleParams, false
        );

        vm.prank(executor);
        vm.expectRevert(Errors.PaymentRails_TokenNotEnabled.selector);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    RECONFIGURE — IMMEDIATE EFFECT
    //////////////////////////////////////////////////////////////////////////*/

    function test_ReconfigureChangesNextExecution() external {
        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT / 2);

        bytes32 newRecipient = bytes32(uint256(uint160(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC)));
        bytes memory newParams = _buildModuleParams(DOMAIN_BASE, newRecipient, 0, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, newParams, true
        );

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT / 2);

        (,, bytes32 recipient1,,,,,) = tokenMessenger.depositCalls(0);
        (,, bytes32 recipient2,,, uint256 fee2,,) = tokenMessenger.depositCalls(1);

        assertEq(recipient1, MINT_RECIPIENT);
        assertEq(recipient2, newRecipient);
        assertEq(fee2, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CONSECUTIVE EXECUTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ConsecutiveExecutions() external {
        uint256 half = BRIDGE_AMOUNT / 2;

        vm.prank(executor);
        bool success1 = paymentRailsContract.executeAction(address(usdc), half);

        vm.prank(executor);
        bool success2 = paymentRailsContract.executeAction(address(usdc), half);

        assertTrue(success1);
        assertTrue(success2);
        assertEq(tokenMessenger.getDepositCallCount(), 2);
        assertEq(usdc.balanceOf(address(paymentRailsContract)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PREVIEW EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_PreviewExecution() external view {
        (uint256 estimatedOutput, address outputToken) = paymentRailsContract.previewExecution(address(usdc));
        assertEq(estimatedOutput, BRIDGE_AMOUNT - MAX_FEE);
        assertEq(outputToken, address(usdc));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    HOOK DATA — INTEGRATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_WithHookData_UsesDepositForBurnWithHook() external {
        bytes memory hookParams = _buildModuleParams(DOMAIN_BASE, MINT_RECIPIENT, MAX_FEE, FINALITY_FAST, hex"cafebabe");
        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, hookParams, true
        );

        vm.prank(executor);
        bool success = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        assertTrue(success);
        assertEq(tokenMessenger.getDepositCallCount(), 0);
        assertEq(tokenMessenger.getDepositWithHookCallCount(), 1);

        (,,,,,,, bytes memory hookData) = tokenMessenger.depositWithHookCalls(0);
        assertEq(hookData, hex"cafebabe");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    MULTI-NODE — SHARED MODULE, INDEPENDENT ROUTING
    //////////////////////////////////////////////////////////////////////////*/

    function test_MultiPaymentRails_TwoPaymentRailsShareOneModule_DifferentRecipients() external {
        bytes32 recipientB = bytes32(uint256(uint160(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)));

        PaymentRails nodeB = new PaymentRails(paymentRailsOwner);
        bytes memory paramsB = _buildModuleParams(DOMAIN_BASE, recipientB, MAX_FEE, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        nodeB.configureToken(address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, paramsB, true);
        usdc.mint(address(nodeB), BRIDGE_AMOUNT);

        vm.prank(executor);
        bool successA = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        vm.prank(executor);
        bool successB = nodeB.executeAction(address(usdc), BRIDGE_AMOUNT);

        assertTrue(successA);
        assertTrue(successB);
        assertEq(tokenMessenger.getDepositCallCount(), 2);

        (,, bytes32 recipient1,,,,,) = tokenMessenger.depositCalls(0);
        (,, bytes32 recipient2,,,,,) = tokenMessenger.depositCalls(1);

        assertEq(recipient1, MINT_RECIPIENT);
        assertEq(recipient2, recipientB);
    }

    function test_MultiPaymentRails_DifferentDomains_RoutesCorrectly() external {
        uint32 domainArbitrum = 3;
        bytes32 recipientArb = bytes32(uint256(uint160(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)));

        PaymentRails nodeB = new PaymentRails(paymentRailsOwner);
        bytes memory paramsB = _buildModuleParams(domainArbitrum, recipientArb, 0, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        nodeB.configureToken(address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, paramsB, true);
        usdc.mint(address(nodeB), BRIDGE_AMOUNT);

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        vm.prank(executor);
        nodeB.executeAction(address(usdc), BRIDGE_AMOUNT);

        (, uint32 domain1, bytes32 recipient1,,,,,) = tokenMessenger.depositCalls(0);
        (, uint32 domain2, bytes32 recipient2,,,,,) = tokenMessenger.depositCalls(1);

        assertEq(domain1, DOMAIN_BASE);
        assertEq(recipient1, MINT_RECIPIENT);
        assertEq(domain2, domainArbitrum);
        assertEq(recipient2, recipientArb);
    }

    function test_MultiPaymentRails_InterleavedExecutions() external {
        PaymentRails nodeB = new PaymentRails(paymentRailsOwner);
        bytes memory paramsB = _buildModuleParams(DOMAIN_BASE, MINT_RECIPIENT, MAX_FEE, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        nodeB.configureToken(address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, paramsB, true);
        usdc.mint(address(nodeB), BRIDGE_AMOUNT);

        uint256 half = BRIDGE_AMOUNT / 2;

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), half);

        vm.prank(executor);
        nodeB.executeAction(address(usdc), half);

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), half);

        vm.prank(executor);
        nodeB.executeAction(address(usdc), half);

        assertEq(tokenMessenger.getDepositCallCount(), 4);
        assertEq(usdc.balanceOf(address(paymentRailsContract)), 0);
        assertEq(usdc.balanceOf(address(nodeB)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    MULTI-DOMAIN — NODE RECONFIGURATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_MultiDomain_ReconfigurePaymentRailsToDifferentDomain() external {
        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT / 2);

        uint32 domainArbitrum = 3;
        bytes32 recipientArb = bytes32(uint256(uint160(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)));
        bytes memory arbParams = _buildModuleParams(domainArbitrum, recipientArb, 0, FINALITY_FAST, "");

        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, arbParams, true
        );

        vm.prank(executor);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT / 2);

        (, uint32 domain1,,,,,,) = tokenMessenger.depositCalls(0);
        (, uint32 domain2,,,,,,) = tokenMessenger.depositCalls(1);
        assertEq(domain1, DOMAIN_BASE);
        assertEq(domain2, domainArbitrum);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    NODE RECONFIGURATION — DISABLE / RE-ENABLE
    //////////////////////////////////////////////////////////////////////////*/

    function test_PaymentRailsDisableThenReEnable_BridgeWorks() external {
        bytes memory moduleParams = _buildModuleParams(DOMAIN_BASE, MINT_RECIPIENT, MAX_FEE, FINALITY_FAST, "");

        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, moduleParams, false
        );

        vm.prank(executor);
        vm.expectRevert(Errors.PaymentRails_TokenNotEnabled.selector);
        paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, moduleParams, true
        );

        vm.prank(executor);
        bool success = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertTrue(success);
    }

    function test_PaymentRailsSwapToNewModule() external {
        MockTokenMessengerV2 tokenMessenger2 = new MockTokenMessengerV2();
        CCTPBridgeModule moduleB = new CCTPBridgeModule(address(tokenMessenger2), address(usdc));

        bytes memory moduleParams = _buildModuleParams(DOMAIN_BASE, MINT_RECIPIENT, 0, FINALITY_FAST, "");
        vm.prank(paymentRailsOwner);
        paymentRailsContract.configureToken(
            address(usdc), "CCTP_BRIDGE", address(moduleB), MIN_BALANCE, moduleParams, true
        );

        vm.prank(executor);
        bool success = paymentRailsContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertTrue(success);

        assertEq(tokenMessenger.getDepositCallCount(), 0);
        assertEq(tokenMessenger2.getDepositCallCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildModuleParams(
        uint32 domain,
        bytes32 recipient,
        uint256 maxFee,
        uint32 finality,
        bytes memory hookData
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(domain, recipient, bytes32(0), maxFee, finality, hookData);
    }
}
