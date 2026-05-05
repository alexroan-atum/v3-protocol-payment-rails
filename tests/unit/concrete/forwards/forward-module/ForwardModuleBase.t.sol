// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { ForwardModule } from "../../../../../src/modules/forwards/ForwardModule.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { FailingTransferERC20 } from "../../../../shared/mocks/FailingTransferERC20.sol";
import { RevertingTransferERC20 } from "../../../../shared/mocks/RevertingTransferERC20.sol";
import { FeeOnTransferERC20 } from "../../../../shared/mocks/FeeOnTransferERC20.sol";

abstract contract ForwardModuleBase is Test {
    uint256 internal constant DEFAULT_AMOUNT = 1000e18;
    uint256 internal constant DEFAULT_MIN_AMOUNT = 100e18;

    ForwardModule internal module;
    MockERC20 internal token;
    FailingTransferERC20 internal failingToken;
    RevertingTransferERC20 internal revertingToken;
    FeeOnTransferERC20 internal feeToken;

    address internal node;
    address internal recipient;

    function setUp() public virtual {
        node = makeAddr("node");
        recipient = makeAddr("recipient");

        module = new ForwardModule();
        token = new MockERC20("Test Token", "TST");
        failingToken = new FailingTransferERC20();
        revertingToken = new RevertingTransferERC20();
        feeToken = new FeeOnTransferERC20();

        token.mint(node, DEFAULT_AMOUNT * 100);
        failingToken.mint(node, DEFAULT_AMOUNT * 100);
        revertingToken.mint(node, DEFAULT_AMOUNT * 100);
        feeToken.mint(node, DEFAULT_AMOUNT * 100);

        vm.startPrank(node);
        token.approve(address(module), type(uint256).max);
        failingToken.approve(address(module), type(uint256).max);
        revertingToken.approve(address(module), type(uint256).max);
        feeToken.approve(address(module), type(uint256).max);
        vm.stopPrank();

        vm.label(address(module), "ForwardModule");
        vm.label(address(token), "TestToken");
        vm.label(address(failingToken), "FailingToken");
        vm.label(address(revertingToken), "RevertingToken");
        vm.label(address(feeToken), "FeeToken");
    }

    modifier whenRecipientIsZeroAddress() {
        _;
    }

    modifier whenAmountBelowMinimum() {
        _;
    }

    modifier whenCallerHasInsufficientBalance() {
        _;
    }

    modifier whenTransferReturnsFalse() {
        _;
    }

    modifier whenTransferReverts() {
        _;
    }

    modifier whenAllValidationsPass() {
        _;
    }

    function _defaultParams() internal view returns (bytes memory) {
        return _buildParams(recipient, false, DEFAULT_MIN_AMOUNT);
    }

    function _buildParams(
        address _recipient,
        bool _requireSuccessfulReceipt,
        uint256 _minAmount
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_recipient, _requireSuccessfulReceipt, _minAmount);
    }
}
