// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { PaymentRailsBase } from "../PaymentRailsBase.t.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";

contract PaymentRailsGetTokenConfigTest is PaymentRailsBase {
    /*//////////////////////////////////////////////////////////////////////////
                    DEFAULT / UNCONFIGURED
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenTokenNotConfigured_ReturnsDefault() external view {
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));

        assertEq(bytes(config.actionType).length, 0);
        assertEq(config.actionModule, address(0));
        assertFalse(config.enabled);
        assertEq(config.minBalance, 0);
        assertEq(config.moduleParams.length, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CONFIGURED TOKEN
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenConfigured_ReturnsCorrectActionType() external givenTokenConfigured {
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertEq(config.actionType, ACTION_TYPE);
    }

    function test_WhenConfigured_ReturnsCorrectActionModule() external givenTokenConfigured {
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertEq(config.actionModule, address(actionModule));
    }

    function test_WhenConfigured_ReturnsCorrectEnabled() external givenTokenConfigured {
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertTrue(config.enabled);
    }

    function test_WhenConfigured_ReturnsCorrectMinBalance() external givenTokenConfigured {
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertEq(config.minBalance, MIN_BALANCE);
    }

    function test_WhenConfigured_ReturnsCorrectModuleParams() external givenTokenConfigured {
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertEq(config.moduleParams, _defaultModuleParams());
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CLEARED CONFIGURATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenConfigCleared_ReturnsDefaults() external givenTokenConfigured {
        vm.prank(owner);
        paymentRails.configureToken(address(token), "", address(0), 0, "", false);

        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertEq(bytes(config.actionType).length, 0);
        assertEq(config.actionModule, address(0));
        assertFalse(config.enabled);
        assertEq(config.minBalance, 0);
        assertEq(config.moduleParams.length, 0);
    }
}
