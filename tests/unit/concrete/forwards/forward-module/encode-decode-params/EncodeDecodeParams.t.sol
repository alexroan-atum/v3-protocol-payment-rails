// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ForwardModuleBase } from "../ForwardModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract ForwardModuleEncodeDecodeParamsTest is ForwardModuleBase {
    function test_EncodesAndDecodesRecipientCorrectly() external view {
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.recipient, recipient, "recipient");
    }

    function test_EncodesAndDecodesRequireSuccessfulReceiptCorrectly() external view {
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: true, minAmount: 0 });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertTrue(decoded.requireSuccessfulReceipt, "requireSuccessfulReceipt");
    }

    function test_EncodesAndDecodesMinAmountCorrectly() external view {
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient, requireSuccessfulReceipt: false, minAmount: DEFAULT_MIN_AMOUNT
        });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.minAmount, DEFAULT_MIN_AMOUNT, "minAmount");
    }

    function test_RoundtripWithDifferentParameterCombinations() external {
        address alt = makeAddr("altRecipient");

        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: alt, requireSuccessfulReceipt: true, minAmount: 999e18 });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.recipient, alt, "recipient");
        assertTrue(decoded.requireSuccessfulReceipt, "requireSuccessfulReceipt");
        assertEq(decoded.minAmount, 999e18, "minAmount");
    }

    function test_RoundtripWithZeroAddressRecipient() external view {
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: address(0), requireSuccessfulReceipt: false, minAmount: 0 });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.recipient, address(0), "recipient");
    }

    function test_RoundtripWithMaxValues() external view {
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: address(type(uint160).max), requireSuccessfulReceipt: true, minAmount: type(uint256).max
        });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.recipient, address(type(uint160).max), "recipient");
        assertTrue(decoded.requireSuccessfulReceipt, "requireSuccessfulReceipt");
        assertEq(decoded.minAmount, type(uint256).max, "minAmount");
    }

    function test_RevertWhen_EncodedDataIsTooShort() external {
        vm.expectRevert();
        module.decodeParams(hex"deadbeef");
    }

    function test_RevertWhen_EncodedDataIsEmpty() external {
        vm.expectRevert();
        module.decodeParams("");
    }

    function testFuzz_RoundtripWithAnyValues(
        address _recipient,
        bool _requireReceipt,
        uint256 _minAmount
    )
        external
        view
    {
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: _recipient, requireSuccessfulReceipt: _requireReceipt, minAmount: _minAmount
        });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.recipient, _recipient, "recipient");
        assertEq(decoded.requireSuccessfulReceipt, _requireReceipt, "requireSuccessfulReceipt");
        assertEq(decoded.minAmount, _minAmount, "minAmount");
    }
}
