// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract CCTPBridgeModule_GetDomainConfig_Test is CCTPBridgeModuleBase {
    function test_WhenDomainIsNotConfigured() external view {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertFalse(config.isValid);
    }

    function test_GivenDomainIsConfigured_ReturnsIsValidTrue() external givenDomainConfigured {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertTrue(config.isValid);
    }

    function test_GivenDomainIsConfigured_ReturnsCorrectMintRecipient() external givenDomainConfigured {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.mintRecipient, DEFAULT_MINT_RECIPIENT);
    }

    function test_GivenDomainIsConfigured_ReturnsCorrectDestinationCaller() external givenDomainConfigured {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.destinationCaller, DEFAULT_DESTINATION_CALLER);
    }

    function test_GivenDomainIsConfigured_ReturnsCorrectMaxFee() external givenDomainConfigured {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.maxFee, DEFAULT_MAX_FEE);
    }

    function test_GivenDomainIsConfigured_ReturnsCorrectMinFinalityThreshold() external givenDomainConfigured {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.minFinalityThreshold, FINALITY_FAST);
    }

    function test_GivenDomainIsConfigured_ReturnsCorrectHookData() external givenDomainConfigured {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.hookData, DEFAULT_HOOK_DATA);
    }

    function test_GivenDomainConfiguredWithHook_ReturnsHookData() external givenDomainConfiguredWithHook {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.hookData, hex"deadbeef");
    }
}
