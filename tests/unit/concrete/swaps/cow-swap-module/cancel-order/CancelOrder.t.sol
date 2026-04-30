// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";

/// @notice Unit tests for CowSwapModule.cancelOrder()
/// @dev Tree: tests/unit/concrete/cow-swap-module/cancel-order/cancelOrder.tree
///
/// Access model: only the module owner (set at construction, address(this) in tests) may cancel.
/// Tokens always return to meta.node (the Node that placed the order), regardless of caller.
contract CowSwapModule_CancelOrder_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when order is unknown
    // -----------------------------------------------------------------------

    function test_RevertWhen_OrderIsUnknown() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_UnknownOrder.selector, bytes32(0)));
        module.cancelOrder(bytes32(0));
    }

    function test_RevertWhen_OrderIsUnknown_ArbitraryId() external {
        bytes32 fakeId = keccak256("does-not-exist");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_UnknownOrder.selector, fakeId));
        module.cancelOrder(fakeId);
    }

    // -----------------------------------------------------------------------
    // when caller is not the module owner
    // -----------------------------------------------------------------------

    function test_RevertWhen_CallerIsNotOwner() external givenPendingOrder {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_NotOwner.selector, attacker, address(this)));
        vm.prank(attacker);
        module.cancelOrder(_orderId);
    }

    function test_RevertWhen_CallerIsNode_NotOwner() external givenPendingOrder {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_NotOwner.selector, address(node), address(this)));
        vm.prank(address(node));
        module.cancelOrder(_orderId);
    }

    // -----------------------------------------------------------------------
    // given order status is already cancelled
    // -----------------------------------------------------------------------

    function test_RevertGiven_OrderStatusIsCancelled() external givenCancelledOrder {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyCancelled.selector, _orderId));
        module.cancelOrder(_orderId);
    }

    // -----------------------------------------------------------------------
    // given order is pending — solver already pulled sell token
    // -----------------------------------------------------------------------

    function test_GivenSolverAlreadyPulledSellToken_SetsCancelledTrue()
        external
        givenPendingOrder
        givenSolverPulledSellToken
    {
        module.cancelOrder(_orderId);
        assertTrue(module.getOrder(_orderId).cancelled);
    }

    function test_GivenSolverAlreadyPulledSellToken_EmitsOrderCancelledWithZeroAmount()
        external
        givenPendingOrder
        givenSolverPulledSellToken
    {
        vm.expectEmit(true, true, false, true, address(module));
        emit OrderCancelled(_orderId, address(node), address(sellToken), 0);
        module.cancelOrder(_orderId);
    }

    function test_GivenSolverAlreadyPulledSellToken_DoesNotTransferAnyTokens()
        external
        givenPendingOrder
        givenSolverPulledSellToken
    {
        uint256 nodeBalanceBefore = sellToken.balanceOf(address(node));
        module.cancelOrder(_orderId);
        assertEq(sellToken.balanceOf(address(node)), nodeBalanceBefore);
    }

    function test_GivenSolverAlreadyPulledSellToken_DoesNotRevert()
        external
        givenPendingOrder
        givenSolverPulledSellToken
    {
        module.cancelOrder(_orderId);
    }

    // -----------------------------------------------------------------------
    // given order is pending — sell token still in module
    // -----------------------------------------------------------------------

    function test_GivenSellTokenStillInModule_SetsCancelledTrue() external givenPendingOrder {
        module.cancelOrder(_orderId);
        assertTrue(module.getOrder(_orderId).cancelled);
    }

    function test_GivenSellTokenStillInModule_MaxApprovalUnchanged() external givenPendingOrder {
        module.cancelOrder(_orderId);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_GivenSellTokenStillInModule_TransfersSellTokensBackToNode() external givenPendingOrder {
        uint256 nodeBalanceBefore = sellToken.balanceOf(address(node));
        module.cancelOrder(_orderId);
        assertEq(sellToken.balanceOf(address(node)), nodeBalanceBefore + DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    function test_GivenSellTokenStillInModule_EmitsOrderCancelled() external givenPendingOrder {
        vm.expectEmit(true, true, false, true, address(module));
        emit OrderCancelled(_orderId, address(node), address(sellToken), DEFAULT_SELL_AMOUNT);
        module.cancelOrder(_orderId);
    }

    function test_GivenSellTokenStillInModule_IsValidSignatureReturnsFailure() external givenPendingOrder {
        module.cancelOrder(_orderId);
        // EIP-1271 should reject — order is cancelled
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // full lifecycle: execute -> cancel -> tokens recovered
    // -----------------------------------------------------------------------

    function test_FullLifecycle_ExecuteCancelRecover() external {
        // 1. Initiate order
        bytes32 orderId = _initiateDefaultOrder();
        uint256 nodeBalanceAfterExecute = sellToken.balanceOf(address(node));

        // 2. Verify tokens locked in module, max approval set
        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        // 3. Module owner (address(this)) cancels — tokens go to meta.node (node)
        module.cancelOrder(orderId);

        // 4. Verify recovery: tokens returned, cancelled flag set, approval stays max
        assertEq(sellToken.balanceOf(address(node)), nodeBalanceAfterExecute + DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), 0);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertTrue(module.getOrder(orderId).cancelled);

        // 5. Verify can't cancel again
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyCancelled.selector, orderId));
        module.cancelOrder(orderId);
    }
}
