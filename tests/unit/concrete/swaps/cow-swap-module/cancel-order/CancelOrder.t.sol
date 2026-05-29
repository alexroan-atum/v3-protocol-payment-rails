// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unit tests for CowSwapModule.cancelOrder()
/// @dev Tree: tests/unit/concrete/cow-swap-module/cancel-order/cancelOrder.tree
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        module.cancelOrder(_orderId);
    }

    function test_RevertWhen_CallerIsPaymentRails_NotOwner() external givenPendingOrder {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(paymentRails)));
        vm.prank(address(paymentRails));
        module.cancelOrder(_orderId);
    }

    // -----------------------------------------------------------------------
    // given order is already cancelled
    // -----------------------------------------------------------------------

    function test_RevertGiven_OrderAlreadyCancelled() external givenCancelledOrder {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyCancelled.selector, _orderId));
        module.cancelOrder(_orderId);
    }

    // -----------------------------------------------------------------------
    // given order is already filled by solver
    // -----------------------------------------------------------------------

    function test_RevertGiven_OrderAlreadyFilled() external givenPendingOrder {
        cowSettlement.setFilledAmount(_orderId, DEFAULT_SELL_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, _orderId));
        module.cancelOrder(_orderId);
    }

    function test_RevertGiven_OrderAlreadyFilled_Overfilled() external givenPendingOrder {
        cowSettlement.setFilledAmount(_orderId, DEFAULT_SELL_AMOUNT + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, _orderId));
        module.cancelOrder(_orderId);
    }

    function test_GivenOrderPartiallyFilled_CancelSucceeds() external givenPendingOrder {
        cowSettlement.setFilledAmount(_orderId, DEFAULT_SELL_AMOUNT - 1);
        module.cancelOrder(_orderId);
        assertTrue(module.getOrder(_orderId).cancelled);
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
        emit OrderCancelled(_orderId, address(paymentRails), address(sellToken), 0);
        module.cancelOrder(_orderId);
    }

    function test_GivenSolverAlreadyPulledSellToken_DoesNotTransferAnyTokens()
        external
        givenPendingOrder
        givenSolverPulledSellToken
    {
        uint256 paymentRailsBalanceBefore = sellToken.balanceOf(address(paymentRails));
        module.cancelOrder(_orderId);
        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBalanceBefore);
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

    function test_GivenSellTokenStillInModule_TransfersSellTokensBackToPaymentRails() external givenPendingOrder {
        uint256 paymentRailsBalanceBefore = sellToken.balanceOf(address(paymentRails));
        module.cancelOrder(_orderId);
        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBalanceBefore + DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    function test_GivenSellTokenStillInModule_EmitsOrderCancelled() external givenPendingOrder {
        vm.expectEmit(true, true, false, true, address(module));
        emit OrderCancelled(_orderId, address(paymentRails), address(sellToken), DEFAULT_SELL_AMOUNT);
        module.cancelOrder(_orderId);
    }

    function test_GivenSellTokenStillInModule_IsValidSignatureReturnsFailure() external givenPendingOrder {
        module.cancelOrder(_orderId);
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // full lifecycle: execute -> cancel -> tokens recovered
    // -----------------------------------------------------------------------

    function test_FullLifecycle_ExecuteCancelRecover() external {
        bytes32 orderId = _initiateDefaultOrder();
        uint256 paymentRailsBalanceAfterExecute = sellToken.balanceOf(address(paymentRails));

        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        module.cancelOrder(orderId);

        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBalanceAfterExecute + DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), 0);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertTrue(module.getOrder(orderId).cancelled);

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyCancelled.selector, orderId));
        module.cancelOrder(orderId);
    }
}
