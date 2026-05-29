// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for CowSwapModule.isValidSignature()
/// @dev Tree: tests/unit/concrete/cow-swap-module/is-valid-signature/isValidSignature.tree
contract CowSwapModule_IsValidSignature_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when signature length is not 32 bytes
    // -----------------------------------------------------------------------

    function test_WhenSignatureLengthIsZero_ReturnsFailureValue() external view {
        assertEq(module.isValidSignature(bytes32(0), bytes("")), EIP1271_FAILURE);
    }

    function test_WhenSignatureLengthIs31_ReturnsFailureValue() external givenPendingOrder {
        bytes memory shortSig = new bytes(31);
        assertEq(module.isValidSignature(_orderId, shortSig), EIP1271_FAILURE);
    }

    function test_WhenSignatureLengthIs33_ReturnsFailureValue() external givenPendingOrder {
        bytes memory longSig = new bytes(33);
        assertEq(module.isValidSignature(_orderId, longSig), EIP1271_FAILURE);
    }

    function testFuzz_WhenSignatureLengthIsNot32_ReturnsFailureValue(uint256 length) external view {
        length = bound(length, 0, 100);
        vm.assume(length != 32);
        bytes memory sig = new bytes(length);
        assertEq(module.isValidSignature(bytes32(0), sig), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // when decoded orderId does not match hash
    // -----------------------------------------------------------------------

    function test_WhenOrderIdDoesNotMatchHash_ReturnsFailureValue() external givenPendingOrder {
        bytes32 differentHash = bytes32(uint256(_orderId) ^ 1);
        assertEq(module.isValidSignature(differentHash, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    function test_WhenHashDoesNotMatchEncodedOrderId_ReturnsFailureValue() external givenPendingOrder {
        bytes32 differentOrderId = bytes32(uint256(_orderId) + 1);
        assertEq(module.isValidSignature(_orderId, abi.encode(differentOrderId)), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // when order is unknown
    // -----------------------------------------------------------------------

    function test_WhenOrderIsUnknown_ReturnsFailureValue() external view {
        bytes32 unknownId = keccak256("unknown-order");
        assertEq(module.isValidSignature(unknownId, abi.encode(unknownId)), EIP1271_FAILURE);
    }

    function test_WhenOrderIsZeroHash_ReturnsFailureValue() external view {
        assertEq(module.isValidSignature(bytes32(0), abi.encode(bytes32(0))), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // given order is already filled by a solver (filledAmounts >= sellAmount)
    // -----------------------------------------------------------------------

    function test_GivenOrderIsFilledBySolver_ReturnsFailureValue() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        cowSettlement.setFilledAmount(_orderId, meta.sellAmount);
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    function test_GivenOrderIsPartiallyFilled_ReturnsMagicValue() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        cowSettlement.setFilledAmount(_orderId, meta.sellAmount - 1);
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_MAGIC);
    }

    // -----------------------------------------------------------------------
    // given order status is cancelled
    // -----------------------------------------------------------------------

    function test_GivenOrderStatusIsCancelled_ReturnsFailureValue() external givenCancelledOrder {
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // when order has expired
    // -----------------------------------------------------------------------

    function test_WhenOrderHasExpired_ReturnsFailureValue() external givenPendingOrder {
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    function test_WhenOrderExpiresExactlyAtValidTo_ReturnsFailureValue() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        vm.warp(uint256(meta.validTo) + 1);
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);
    }

    // -----------------------------------------------------------------------
    // given a valid pending non-expired order with matching hash
    // -----------------------------------------------------------------------

    function test_GivenValidPendingNonExpiredOrder_ReturnsMagicValue() external givenPendingOrder {
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_MAGIC);
    }

    function test_GivenValidPendingOrderAtValidTo_ReturnsMagicValue() external givenPendingOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        vm.warp(uint256(meta.validTo));
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_MAGIC);
    }

    function test_GivenValidPendingOrderJustCreated_ReturnsMagicValue() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_MAGIC);
    }

    // -----------------------------------------------------------------------
    // isValidSignature MUST NEVER REVERT (EIP-1271 spec requirement)
    //
    // CowSwap's infrastructure calls isValidSignature() as part of every batch
    // auction. If it reverts for ANY input, the entire CowSwap batch fails.
    // The EIP-1271 spec requires: always return MAGIC_VALUE or FAILURE_VALUE.
    // -----------------------------------------------------------------------

    function testFuzz_isValidSignature_NeverReverts(bytes32 hash, bytes calldata sig) external {
        // EIP-1271: isValidSignature must NEVER revert for any input.
        // try/catch: if the catch block is ever entered, a critical bug is present.
        try module.isValidSignature(hash, sig) returns (bytes4 result) {
            assertTrue(
                result == EIP1271_MAGIC || result == EIP1271_FAILURE,
                "isValidSignature must return MAGIC or FAILURE only"
            );
        } catch {
            fail("CRITICAL: isValidSignature MUST NOT revert - violates EIP-1271 spec");
        }
    }

    function testFuzz_isValidSignature_WithPendingOrder_NeverReverts(
        bytes32 hash,
        bytes calldata sig,
        uint32 validity
    )
        external
    {
        // Bound validity: [1, type(uint32).max - block.timestamp].
        // execute() rejects block.timestamp + validity > type(uint32).max so orders
        // with overflow validity cannot be created. Bound here to stay in the valid range.
        uint256 maxValidity = type(uint32).max - block.timestamp;
        validity = uint32(bound(uint256(validity), 1, maxValidity));

        // Create a pending order with the fuzzed validity duration
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            validity,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(result.success, "Order initiation should succeed (non-overflow validity)");

        bytes32 orderId = abi.decode(result.data, (bytes32));

        // Test with the actual orderId as both hash and sig (the real CowSwap call pattern)
        try module.isValidSignature(orderId, abi.encode(orderId)) returns (bytes4 r1) {
            assertTrue(r1 == EIP1271_MAGIC || r1 == EIP1271_FAILURE, "Must return MAGIC or FAILURE");
        } catch {
            fail("CRITICAL: isValidSignature reverted on real orderId - arithmetic overflow");
        }

        // Also test with arbitrary hash/sig combinations
        try module.isValidSignature(hash, sig) returns (bytes4 r2) {
            assertTrue(r2 == EIP1271_MAGIC || r2 == EIP1271_FAILURE, "Must return MAGIC or FAILURE");
        } catch {
            fail("CRITICAL: isValidSignature reverted on arbitrary inputs");
        }
    }
}
