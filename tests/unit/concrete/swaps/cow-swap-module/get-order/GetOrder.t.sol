// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for CowSwapModule.getOrder()
/// @dev Tree: tests/unit/concrete/cow-swap-module/get-order/getOrder.tree
contract CowSwapModule_GetOrder_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when order id is unknown
    // -----------------------------------------------------------------------

    function test_WhenOrderIdIsUnknown_ReturnsEmptyMetadataWithZeroNodeAddress() external view {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(bytes32(0));
        assertEq(meta.node, address(0));
    }

    function test_WhenOrderIdIsUnknown_ReturnsZeroSellToken() external view {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(keccak256("nonexistent"));
        assertEq(meta.sellToken, address(0));
    }

    function test_WhenOrderIdIsUnknown_ReturnsZeroAmounts() external view {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(keccak256("nonexistent"));
        assertEq(meta.sellAmount, 0);
        assertEq(meta.validTo, 0);
    }

    // -----------------------------------------------------------------------
    // given an existing order
    // -----------------------------------------------------------------------

    function test_GivenExistingOrder_ReturnsCorrectNodeAddress() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.node, address(node));
    }

    function test_GivenExistingOrder_ReturnsCorrectSellToken() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.sellToken, address(sellToken));
    }

    function test_GivenExistingOrder_ReturnsCorrectBuyToken() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.buyToken, address(buyToken));
    }

    function test_GivenExistingOrder_ReturnsCorrectSellAmount() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.sellAmount, DEFAULT_SELL_AMOUNT);
    }

    function test_GivenExistingOrder_ReturnsCorrectValidTo() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.validTo, uint32(block.timestamp + DEFAULT_VALIDITY));
    }

    function test_GivenExistingOrder_ReturnsCancelledFalse() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertFalse(meta.cancelled);
    }

    function test_GivenCancelledOrder_ReturnsCancelledTrue() external givenCancelledOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertTrue(meta.cancelled);
    }
}
