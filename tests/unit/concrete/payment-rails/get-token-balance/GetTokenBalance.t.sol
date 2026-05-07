// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { PaymentRailsBase } from "../PaymentRailsBase.t.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";

contract PaymentRailsGetTokenBalanceTest is PaymentRailsBase {
    function test_WhenZeroBalance_ReturnsZero() external {
        MockERC20 other = new MockERC20("Other", "OTH");
        assertEq(paymentRails.getTokenBalance(address(other)), 0);
    }

    function test_WhenPositiveBalance_ReturnsCorrectBalance() external view {
        assertEq(paymentRails.getTokenBalance(address(token)), INITIAL_BALANCE);
    }

    function test_WhenBalanceChanges_ReflectsNewBalance() external {
        token.mint(address(paymentRails), 500e18);
        assertEq(paymentRails.getTokenBalance(address(token)), INITIAL_BALANCE + 500e18);
    }
}
