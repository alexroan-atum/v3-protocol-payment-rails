// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { Node } from "../../../../src/core/Node.sol";
import { CCTPBridgeModule } from "../../../../src/modules/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../src/libraries/Errors.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockTokenMessengerV2 } from "../../../shared/mocks/MockTokenMessengerV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Integration tests that exercise the full Node → CCTPBridgeModule → TokenMessengerV2 path.
contract CCTPBridgeModuleIntegration_Test is Test {
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
        address indexed node,
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
    bytes32 internal constant MINT_RECIPIENT =
        bytes32(uint256(uint160(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB)));
    uint256 internal constant MAX_FEE = 1e6;
    uint32 internal constant FINALITY_FAST = 1000;
    uint256 internal constant BRIDGE_AMOUNT = 1_000e6;
    uint256 internal constant MIN_BALANCE = 100e6;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    Node internal nodeContract;
    CCTPBridgeModule internal bridgeModule;
    MockTokenMessengerV2 internal tokenMessenger;
    MockERC20 internal usdc;

    address internal nodeOwner;
    address internal moduleOwner;
    address internal executor;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        nodeOwner = makeAddr("nodeOwner");
        moduleOwner = makeAddr("moduleOwner");
        executor = makeAddr("executor");

        tokenMessenger = new MockTokenMessengerV2();
        usdc = new MockERC20("USD Coin", "USDC");

        bridgeModule = new CCTPBridgeModule(address(tokenMessenger), address(usdc), moduleOwner);

        vm.prank(moduleOwner);
        bridgeModule.setDomainConfig(DOMAIN_BASE, MINT_RECIPIENT, bytes32(0), MAX_FEE, FINALITY_FAST, "");

        nodeContract = new Node(nodeOwner);

        bytes memory moduleParams = abi.encode(uint32(DOMAIN_BASE));
        vm.prank(nodeOwner);
        nodeContract.configureToken(address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, moduleParams, true);

        usdc.mint(address(nodeContract), BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_FullBridgeLifecycle() external {
        vm.prank(executor);
        bool success = nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertTrue(success);

        assertEq(tokenMessenger.getDepositCallCount(), 1);

        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            ,
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

    function test_NodeEmitsActionExecuted() external {
        vm.expectEmit(true, false, false, true);
        emit ActionExecuted(
            address(usdc),
            "CCTP_BRIDGE",
            BRIDGE_AMOUNT,
            BRIDGE_AMOUNT - MAX_FEE,
            address(usdc),
            executor
        );

        vm.prank(executor);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
    }

    function test_BridgeModuleEmitsBridgeInitiated() external {
        vm.expectEmit(true, true, false, true);
        emit BridgeInitiated(
            address(nodeContract),
            BRIDGE_AMOUNT,
            DOMAIN_BASE,
            MINT_RECIPIENT,
            MAX_FEE,
            FINALITY_FAST,
            ""
        );

        vm.prank(executor);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
    }

    function test_ApprovalIsConsumedAfterExecution() external {
        vm.prank(executor);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        uint256 moduleAllowance = usdc.allowance(address(bridgeModule), address(tokenMessenger));
        assertEq(moduleAllowance, 0);

        uint256 nodeAllowance = usdc.allowance(address(nodeContract), address(bridgeModule));
        assertEq(nodeAllowance, 0);
    }

    function test_PermissionlessExecution_AnyoneCanCall() external {
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        bool success = nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertTrue(success);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    TOKEN MESSENGER REVERT — NODE CATCHES
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTokenMessengerReverts_NodeReturnsFalse() external {
        tokenMessenger.setRevert(true, "CCTP: paused");

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertFalse(success);

        assertEq(usdc.balanceOf(address(nodeContract)), BRIDGE_AMOUNT);
    }

    function test_WhenTokenMessengerReverts_NodeRevokesApproval() external {
        tokenMessenger.setRevert(true, "CCTP: paused");

        vm.prank(executor);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        uint256 nodeAllowance = usdc.allowance(address(nodeContract), address(bridgeModule));
        assertEq(nodeAllowance, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    VALIDATION FAILURES — NODE BLOCKS EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_BelowMinBalance() external {
        uint256 smallAmount = MIN_BALANCE - 1;

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Node_BelowMinimumBalance.selector, smallAmount, MIN_BALANCE)
        );
        nodeContract.executeAction(address(usdc), smallAmount);
    }

    function test_RevertWhen_AmountExceedsBalance() external {
        uint256 tooMuch = BRIDGE_AMOUNT + 1;

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Node_InsufficientBalance.selector, BRIDGE_AMOUNT, tooMuch)
        );
        nodeContract.executeAction(address(usdc), tooMuch);
    }

    function test_RevertWhen_TokenNotEnabled() external {
        vm.prank(nodeOwner);
        bytes memory moduleParams = abi.encode(uint32(DOMAIN_BASE));
        nodeContract.configureToken(address(usdc), "CCTP_BRIDGE", address(bridgeModule), MIN_BALANCE, moduleParams, false);

        vm.prank(executor);
        vm.expectRevert(Errors.Node_TokenNotEnabled.selector);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    DOMAIN CONFIG CHANGE — IMMEDIATE EFFECT
    //////////////////////////////////////////////////////////////////////////*/

    function test_DomainConfigChangeAffectsNextExecution() external {
        vm.prank(executor);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT / 2);

        bytes32 newRecipient = bytes32(uint256(uint160(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC)));
        vm.prank(moduleOwner);
        bridgeModule.setDomainConfig(DOMAIN_BASE, newRecipient, bytes32(0), 0, FINALITY_FAST, "");

        vm.prank(executor);
        nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT / 2);

        (, , bytes32 recipient1, , , , ,) = tokenMessenger.depositCalls(0);
        (, , bytes32 recipient2, , , uint256 fee2, ,) = tokenMessenger.depositCalls(1);

        assertEq(recipient1, MINT_RECIPIENT);
        assertEq(recipient2, newRecipient);
        assertEq(fee2, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    DOMAIN REMOVAL — EXECUTION FAILS GRACEFULLY
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenDomainRemoved_ExecutionReturnsFalse() external {
        vm.prank(moduleOwner);
        bridgeModule.removeDomainConfig(DOMAIN_BASE);

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);
        assertFalse(success);

        assertEq(usdc.balanceOf(address(nodeContract)), BRIDGE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CONSECUTIVE EXECUTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ConsecutiveExecutions() external {
        uint256 half = BRIDGE_AMOUNT / 2;

        vm.prank(executor);
        bool success1 = nodeContract.executeAction(address(usdc), half);

        vm.prank(executor);
        bool success2 = nodeContract.executeAction(address(usdc), half);

        assertTrue(success1);
        assertTrue(success2);
        assertEq(tokenMessenger.getDepositCallCount(), 2);
        assertEq(usdc.balanceOf(address(nodeContract)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PREVIEW EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_PreviewExecution() external view {
        (uint256 estimatedOutput, address outputToken) = nodeContract.previewExecution(address(usdc));
        assertEq(estimatedOutput, BRIDGE_AMOUNT - MAX_FEE);
        assertEq(outputToken, address(usdc));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    HOOK DATA — INTEGRATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_WithHookData_UsesDepositForBurnWithHook() external {
        vm.prank(moduleOwner);
        bridgeModule.setDomainConfig(DOMAIN_BASE, MINT_RECIPIENT, bytes32(0), MAX_FEE, FINALITY_FAST, hex"cafebabe");

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(usdc), BRIDGE_AMOUNT);

        assertTrue(success);
        assertEq(tokenMessenger.getDepositCallCount(), 0);
        assertEq(tokenMessenger.getDepositWithHookCallCount(), 1);

        (,,,,,,, bytes memory hookData) = tokenMessenger.depositWithHookCalls(0);
        assertEq(hookData, hex"cafebabe");
    }
}
