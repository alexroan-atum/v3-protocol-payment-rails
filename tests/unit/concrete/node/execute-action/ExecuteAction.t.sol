// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { NodeBase } from "../NodeBase.t.sol";
import { INode } from "../../../../../src/interfaces/INode.sol";
import { IActionModule } from "../../../../../src/interfaces/IActionModule.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/src/Vm.sol";

/// @dev Mock module that attempts to re-enter Node.executeAction during execute().
contract ReentrantModule is IActionModule {
    INode public immutable targetNode;
    address public immutable targetToken;
    uint256 public immutable targetAmount;
    bool public reentrancyBlocked;

    constructor(address _node, address _token, uint256 _amount) {
        targetNode = INode(_node);
        targetToken = _token;
        targetAmount = _amount;
    }

    function execute(
        address tkn,
        uint256 amount,
        bytes calldata
    )
        external
        override
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(tkn).transferFrom(msg.sender, address(this), amount);

        try targetNode.executeAction(targetToken, targetAmount) {
            reentrancyBlocked = false;
        } catch {
            reentrancyBlocked = true;
        }

        return
            DataTypes.ExecutionResult({
                success: true, amountOut: amount, outputToken: tkn, data: "", failureReason: ""
            });
    }

    function validate(address, uint256, bytes calldata) external pure override returns (bool, string memory) {
        return (true, "");
    }

    function estimateOutput(
        address tkn,
        uint256 amount,
        bytes calldata
    )
        external
        pure
        override
        returns (uint256, address)
    {
        return (amount, tkn);
    }

    function moduleType() external pure override returns (string memory) {
        return "REENTRANT";
    }
}

contract NodeExecuteActionTest is NodeBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant ACTION_EXECUTED_TOPIC =
        keccak256("ActionExecuted(address,string,uint256,uint256,address,address)");

    /*//////////////////////////////////////////////////////////////////////////
                        REVERT TESTS — validation checks
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_TokenNotEnabled() external givenTokenConfiguredDisabled {
        vm.expectRevert(Errors.Node_TokenNotEnabled.selector);
        node.executeAction(address(token), INITIAL_BALANCE);
    }

    function test_RevertWhen_TokenNeverConfigured() external {
        vm.expectRevert(Errors.Node_TokenNotEnabled.selector);
        node.executeAction(address(token), INITIAL_BALANCE);
    }

    function test_RevertWhen_NoActionConfigured() external {
        vm.prank(owner);
        node.configureToken(address(token), "", address(0), 0, "", true);

        vm.expectRevert(Errors.Node_NoActionConfigured.selector);
        node.executeAction(address(token), INITIAL_BALANCE);
    }

    function test_RevertWhen_AmountIsZero() external givenTokenConfigured {
        vm.expectRevert(Errors.Node_ZeroAmount.selector);
        node.executeAction(address(token), 0);
    }

    function test_RevertWhen_AmountBelowMinBalance() external givenTokenConfigured {
        uint256 tooSmall = MIN_BALANCE - 1;
        vm.expectRevert(abi.encodeWithSelector(Errors.Node_BelowMinimumBalance.selector, tooSmall, MIN_BALANCE));
        node.executeAction(address(token), tooSmall);
    }

    function test_RevertWhen_BalanceInsufficient() external givenTokenConfigured {
        uint256 tooMuch = INITIAL_BALANCE + 1;
        vm.expectRevert(abi.encodeWithSelector(Errors.Node_InsufficientBalance.selector, INITIAL_BALANCE, tooMuch));
        node.executeAction(address(token), tooMuch);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — module succeeds
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenModuleSucceeds_ReturnsTrue() external givenTokenConfigured {
        bool success = node.executeAction(address(token), INITIAL_BALANCE);
        assertTrue(success);
    }

    function test_WhenModuleSucceeds_TransfersTokens() external givenTokenConfigured {
        node.executeAction(address(token), INITIAL_BALANCE);

        assertEq(token.balanceOf(address(node)), 0);
        assertEq(token.balanceOf(address(actionModule)), INITIAL_BALANCE);
    }

    function test_WhenModuleSucceeds_EmitsActionExecuted() external givenTokenConfigured {
        vm.expectEmit(true, true, false, true);
        emit ActionExecuted(
            address(token), ACTION_TYPE, INITIAL_BALANCE, INITIAL_BALANCE, address(token), address(this)
        );

        node.executeAction(address(token), INITIAL_BALANCE);
    }

    function test_WhenModuleSucceeds_RecordsExecutorInEvent() external givenTokenConfigured {
        vm.expectEmit(true, true, false, true);
        emit ActionExecuted(address(token), ACTION_TYPE, INITIAL_BALANCE, INITIAL_BALANCE, address(token), executor);

        vm.prank(executor);
        node.executeAction(address(token), INITIAL_BALANCE);
    }

    function test_WhenModuleSucceeds_PartialAmount() external givenTokenConfigured {
        uint256 half = INITIAL_BALANCE / 2;

        bool success = node.executeAction(address(token), half);
        assertTrue(success);
        assertEq(token.balanceOf(address(node)), INITIAL_BALANCE - half);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    FAILURE TESTS — module returns success=false
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenModuleReturnsFalse_ReturnsFalse() external givenTokenConfigured {
        actionModule.setExecuteSuccess(false);

        bool success = node.executeAction(address(token), INITIAL_BALANCE);
        assertFalse(success);
    }

    function test_WhenModuleReturnsFalse_TokensRemainInNode() external givenTokenConfigured {
        actionModule.setExecuteSuccess(false);

        node.executeAction(address(token), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(node)), INITIAL_BALANCE);
    }

    function test_WhenModuleReturnsFalse_RevokesApproval() external givenTokenConfigured {
        actionModule.setExecuteSuccess(false);

        node.executeAction(address(token), INITIAL_BALANCE);

        uint256 allowance = token.allowance(address(node), address(actionModule));
        assertEq(allowance, 0);
    }

    function test_WhenModuleReturnsFalse_DoesNotEmitActionExecuted() external givenTokenConfigured {
        actionModule.setExecuteSuccess(false);

        vm.recordLogs();
        node.executeAction(address(token), INITIAL_BALANCE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ACTION_EXECUTED_TOPIC, "ActionExecuted should not be emitted on failure");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    FAILURE TESTS — module reverts
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenModuleReverts_ReturnsFalse() external givenTokenConfigured {
        actionModule.setExecuteRevert(true, "internal error");

        bool success = node.executeAction(address(token), INITIAL_BALANCE);
        assertFalse(success);
    }

    function test_WhenModuleReverts_TokensRemainInNode() external givenTokenConfigured {
        actionModule.setExecuteRevert(true, "internal error");

        node.executeAction(address(token), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(node)), INITIAL_BALANCE);
    }

    function test_WhenModuleReverts_RevokesApproval() external givenTokenConfigured {
        actionModule.setExecuteRevert(true, "internal error");

        node.executeAction(address(token), INITIAL_BALANCE);

        uint256 allowance = token.allowance(address(node), address(actionModule));
        assertEq(allowance, 0);
    }

    function test_WhenModuleReverts_DoesNotEmitActionExecuted() external givenTokenConfigured {
        actionModule.setExecuteRevert(true, "internal error");

        vm.recordLogs();
        node.executeAction(address(token), INITIAL_BALANCE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ACTION_EXECUTED_TOPIC, "ActionExecuted should not be emitted on revert");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PERMISSIONLESS EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenCalledByNonOwner_Succeeds() external givenTokenConfigured {
        vm.prank(executor);
        bool success = node.executeAction(address(token), INITIAL_BALANCE);
        assertTrue(success);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CONSECUTIVE EXECUTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenExecutedConsecutively_EachSucceeds() external givenTokenConfigured {
        uint256 half = INITIAL_BALANCE / 2;

        bool success1 = node.executeAction(address(token), half);
        bool success2 = node.executeAction(address(token), half);

        assertTrue(success1);
        assertTrue(success2);
        assertEq(token.balanceOf(address(node)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenModuleAttemptsReentrancy_ReentrancyIsBlocked() external {
        ReentrantModule reentrantModule = new ReentrantModule(address(node), address(token), MIN_BALANCE);

        vm.prank(owner);
        node.configureToken(
            address(token), "REENTRANT", address(reentrantModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        bool success = node.executeAction(address(token), INITIAL_BALANCE);

        assertTrue(success, "First call should succeed");
        assertTrue(reentrantModule.reentrancyBlocked(), "Re-entrant call should have been blocked");
        assertEq(token.balanceOf(address(reentrantModule)), INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    BOUNDARY CONDITION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAmountEqualsMinBalance_Succeeds() external givenTokenConfigured {
        bool success = node.executeAction(address(token), MIN_BALANCE);
        assertTrue(success);
        assertEq(token.balanceOf(address(node)), INITIAL_BALANCE - MIN_BALANCE);
    }

    function test_WhenAmountEqualsBalance_DrainsNode() external givenTokenConfigured {
        bool success = node.executeAction(address(token), INITIAL_BALANCE);
        assertTrue(success);
        assertEq(token.balanceOf(address(node)), 0);
    }

    function test_GivenMinBalanceIsZero_AnyNonZeroAmountSucceeds() external {
        vm.prank(owner);
        node.configureToken(address(token), ACTION_TYPE, address(actionModule), 0, _defaultModuleParams(), true);

        bool success = node.executeAction(address(token), 1);
        assertTrue(success);
        assertEq(token.balanceOf(address(node)), INITIAL_BALANCE - 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_ExecuteAction_SuccessPath(uint256 amount) external givenTokenConfigured {
        amount = bound(amount, MIN_BALANCE, INITIAL_BALANCE);

        bool success = node.executeAction(address(token), amount);
        assertTrue(success);
        assertEq(token.balanceOf(address(node)), INITIAL_BALANCE - amount);
        assertEq(token.balanceOf(address(actionModule)), amount);
    }

    function testFuzz_RevertWhen_AmountBelowMinBalance(uint256 amount) external givenTokenConfigured {
        amount = bound(amount, 1, MIN_BALANCE - 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.Node_BelowMinimumBalance.selector, amount, MIN_BALANCE));
        node.executeAction(address(token), amount);
    }

    function testFuzz_RevertWhen_AmountExceedsBalance(uint256 amount) external givenTokenConfigured {
        amount = bound(amount, INITIAL_BALANCE + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(Errors.Node_InsufficientBalance.selector, INITIAL_BALANCE, amount));
        node.executeAction(address(token), amount);
    }
}
