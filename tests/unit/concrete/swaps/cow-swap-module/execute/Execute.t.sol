// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { FailingTransferERC20 } from "../../../../../shared/mocks/FailingTransferERC20.sol";

/// @notice Unit tests for CowSwapModule.execute()
/// @dev Tree: tests/unit/concrete/cow-swap-module/execute/execute.tree
contract CowSwapModule_Execute_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when amount is zero
    // -----------------------------------------------------------------------

    function test_WhenAmountIsZero_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), 0, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero sell amount");
    }

    function test_WhenAmountIsZero_DoesNotCreateOrder() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), 0, _buildDefaultParams());
        assertEq(result.data.length, 0);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    // -----------------------------------------------------------------------
    // when params are malformed
    // -----------------------------------------------------------------------

    function test_WhenParamsAreMalformed_ReturnsFailedResult() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid params encoding");
    }

    function test_WhenParamsAreMalformed_DoesNotCreateOrder() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertEq(result.data.length, 0);
    }

    function test_WhenParamsAreMalformed_DoesNotTransferTokens() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        uint256 moduleBalanceBefore = sellToken.balanceOf(address(module));
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertEq(sellToken.balanceOf(address(module)), moduleBalanceBefore);
    }

    // -----------------------------------------------------------------------
    // when target token is zero address
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(address(0), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero target token");
    }

    function test_WhenTargetTokenIsZero_ReturnsZeroAmountOut() external {
        bytes memory params = _buildParams(address(0), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(result.amountOut, 0);
    }

    // -----------------------------------------------------------------------
    // when target token equals sell token
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenEqualsSellToken_ReturnsFailedResult() external {
        bytes memory params =
            _buildParams(address(sellToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Same sell and buy token");
    }

    // -----------------------------------------------------------------------
    // when min buy amount is zero
    // -----------------------------------------------------------------------

    function test_WhenMinBuyAmountIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(address(buyToken), 0, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero minimum buy amount");
    }

    // -----------------------------------------------------------------------
    // when validity duration is zero
    // -----------------------------------------------------------------------

    function test_WhenValidityDurationIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, 0, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero validity duration");
    }

    // -----------------------------------------------------------------------
    // when validity duration overflows uint32
    // -----------------------------------------------------------------------

    function test_WhenValidityDurationOverflows_ReturnsFailedResult() external {
        uint32 overflowDuration = type(uint32).max;
        bytes memory params =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, overflowDuration, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Validity duration overflow");
    }

    function test_WhenValidityDurationOverflows_DoesNotLockTokens() external {
        uint32 overflowDuration = type(uint32).max;
        bytes memory params =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, overflowDuration, DEFAULT_APP_DATA);
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    // -----------------------------------------------------------------------
    // when paymentRails has insufficient sell token balance
    // -----------------------------------------------------------------------

    function test_WhenPaymentRailsHasInsufficientBalance_ReturnsFailedResult() external {
        uint256 excessiveAmount = DEFAULT_SELL_AMOUNT * 11;
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), excessiveAmount, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Insufficient balance");
    }

    function test_WhenPaymentRailsHasInsufficientBalance_DoesNotTransferTokens() external {
        uint256 moduleBalanceBefore = sellToken.balanceOf(address(module));
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT * 11, _buildDefaultParams());
        assertEq(sellToken.balanceOf(address(module)), moduleBalanceBefore);
    }

    // -----------------------------------------------------------------------
    // when token transfer fails
    // -----------------------------------------------------------------------

    function test_WhenTokenTransferFails_ReturnsFailedResult() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Token transfer failed");
    }

    function test_WhenTokenTransferFails_DoesNotStoreMetadata() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(result.data.length, 0);
    }

    // -----------------------------------------------------------------------
    // when all parameters are valid
    // -----------------------------------------------------------------------

    function test_WhenAllParamsValid_TransfersSellTokenFromPaymentRailsToModule() external {
        uint256 paymentRailsBalanceBefore = sellToken.balanceOf(address(paymentRails));
        _initiateDefaultOrder();
        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBalanceBefore - DEFAULT_SELL_AMOUNT);
    }

    function test_WhenAllParamsValid_ApprovesVaultRelayerForMaxAmount() external {
        _initiateDefaultOrder();
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_WhenAllParamsValid_MaxApprovalSetOnlyOnce() external {
        _initiateDefaultOrder();
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        bytes memory params2 =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, keccak256("order-2"));
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_WhenAllParamsValid_StoresMetadataWithCancelledFalse() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertFalse(module.getOrder(orderId).cancelled);
    }

    function test_WhenAllParamsValid_StoresCorrectPaymentRailsAddress() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).paymentRails, address(paymentRails));
    }

    function test_WhenAllParamsValid_StoresCorrectSellToken() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).sellToken, address(sellToken));
    }

    function test_WhenAllParamsValid_StoresCorrectBuyToken() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).buyToken, address(buyToken));
    }

    function test_WhenAllParamsValid_StoresCorrectSellAmount() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).sellAmount, DEFAULT_SELL_AMOUNT);
    }

    function test_WhenAllParamsValid_StoresCorrectValidTo() external {
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).validTo, expectedValidTo);
    }

    function test_WhenAllParamsValid_EmitsOrderCreated() external {
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        vm.expectEmit(false, true, false, true, address(module));
        emit OrderCreated(
            bytes32(0),
            address(paymentRails),
            address(sellToken),
            address(buyToken),
            DEFAULT_SELL_AMOUNT,
            DEFAULT_MIN_BUY_AMOUNT,
            expectedValidTo,
            DEFAULT_APP_DATA
        );
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
    }

    function test_WhenAllParamsValid_ReturnsSuccessTrue() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertTrue(result.success);
    }

    function test_WhenAllParamsValid_ReturnsAmountOutZero() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(result.amountOut, 0);
    }

    function test_WhenAllParamsValid_ReturnsOutputTokenAsBuyToken() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(result.outputToken, address(buyToken));
    }

    function test_WhenAllParamsValid_ReturnsDataAsEncodedOrderId() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        bytes32 orderId = abi.decode(result.data, (bytes32));
        assertNotEq(orderId, bytes32(0));
    }

    function test_WhenAllParamsValid_TwoOrdersProduceDifferentOrderIds() external {
        bytes32 id1 = _initiateDefaultOrder();
        vm.warp(block.timestamp + 1);
        bytes32 id2 = _initiateDefaultOrder();
        assertNotEq(id1, id2);
    }

    function testFuzz_WhenAllParamsValid_OrderIsStoredCorrectly(
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32 validity
    )
        external
    {
        sellAmount = bound(sellAmount, 1, DEFAULT_SELL_AMOUNT * 9);
        minBuyAmount = bound(minBuyAmount, 1, type(uint256).max / 2);
        uint256 maxValidity = type(uint32).max - block.timestamp;
        validity = uint32(bound(uint256(validity), 1, maxValidity));

        bytes memory params = _buildParams(address(buyToken), minBuyAmount, validity, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result = paymentRails.initiateSwap(address(sellToken), sellAmount, params);

        assertTrue(result.success);
        assertEq(result.amountOut, 0);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(paymentRails));
        assertEq(meta.sellAmount, sellAmount);
        assertEq(meta.validTo, uint32(block.timestamp + uint256(validity)));
        assertFalse(meta.cancelled);
    }

    // -----------------------------------------------------------------------
    // order ID collision guard
    // -----------------------------------------------------------------------

    function test_Execute_TwiceSameBlock_SameParams_SecondCallRejectedWithCollision() external {
        bytes32 id1 = _initiateDefaultOrder();

        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Order ID collision: use unique appData");

        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT);
        assertFalse(module.getOrder(id1).cancelled);
    }

    function test_Execute_TwiceSameBlock_DifferentAppData_ProducesDifferentOrderIds() external {
        bytes32 id1 = _initiateDefaultOrder();

        bytes memory params2 =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, keccak256("different-app-data"));
        DataTypes.ExecutionResult memory result2 =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2);

        assertTrue(result2.success);
        bytes32 id2 = abi.decode(result2.data, (bytes32));
        assertNotEq(id1, id2);
        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT * 2);
    }

    // -----------------------------------------------------------------------
    // Concurrent same-token orders: max approval coverage
    // -----------------------------------------------------------------------

    function test_ConcurrentSameToken_BothOrdersCoveredByMaxApproval() external {
        _initiateDefaultOrder();
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        bytes memory params2 =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, keccak256("order-2"));
        DataTypes.ExecutionResult memory r2 =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2);
        assertTrue(r2.success);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_ConcurrentSameToken_CancelOrder1_Order2ApprovalUnaffected() external {
        bytes32 id1 = _initiateDefaultOrder();
        bytes memory params2 =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, keccak256("order-2"));
        bytes32 id2 =
            abi.decode(paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2).data, (bytes32));

        module.cancelOrder(id1);

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertFalse(module.getOrder(id2).cancelled);
    }

    // -----------------------------------------------------------------------
    // fee-on-transfer sellToken
    // -----------------------------------------------------------------------

    function test_Execute_FeeOnTransferSellToken_ModuleReceivesLessThanAmount() external {
        uint256 expectedReceived = DEFAULT_SELL_AMOUNT - (DEFAULT_SELL_AMOUNT * 100 / 10_000);

        bytes memory params =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(fotSellToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(result.success);

        // module balance < recorded sellAmount due to transfer fee
        uint256 moduleBalance = fotSellToken.balanceOf(address(module));
        assertEq(moduleBalance, expectedReceived);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.sellAmount, DEFAULT_SELL_AMOUNT, "Metadata records full amount (mismatch)");
        assertEq(fotSellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_Execute_FeeOnTransferSellToken_CowSwapCannotPullFullSellAmount() external {
        bytes memory params =
            _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(fotSellToken), DEFAULT_SELL_AMOUNT, params);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        uint256 sellAmount = module.getOrder(orderId).sellAmount;
        uint256 moduleBalance = fotSellToken.balanceOf(address(module));

        assertLt(moduleBalance, sellAmount, "module balance < sellAmount");

        vm.prank(module.vaultRelayer());
        vm.expectRevert();
        fotSellToken.transferFrom(address(module), address(cowSettlement), sellAmount);
    }
}
