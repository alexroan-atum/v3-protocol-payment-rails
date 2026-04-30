// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract CCTPBridgeModule_RemoveDomainConfig_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            REVERT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerIsNotOwner() external givenDomainConfigured whenCallerIsNotOwner {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.removeDomainConfig(DOMAIN_BASE);
    }

    function test_RevertWhen_DomainNotConfigured() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CCTPBridgeModule_DomainNotConfigured.selector, DOMAIN_BASE));
        module.removeDomainConfig(DOMAIN_BASE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenDomainConfigured_DeletesDomainConfig() external givenDomainConfigured {
        module.removeDomainConfig(DOMAIN_BASE);

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertFalse(config.isValid);
        assertEq(config.mintRecipient, bytes32(0));
        assertEq(config.destinationCaller, bytes32(0));
        assertEq(config.maxFee, 0);
        assertEq(config.minFinalityThreshold, 0);
        assertEq(config.hookData, "");
    }

    function test_GivenDomainConfigured_EmitsDomainConfigRemoved() external givenDomainConfigured {
        vm.expectEmit(true, false, false, false);
        emit DomainConfigRemoved(DOMAIN_BASE);

        module.removeDomainConfig(DOMAIN_BASE);
    }

    function test_GivenDomainConfigured_DoesNotAffectOtherDomains() external givenDomainConfigured {
        module.setDomainConfig(
            DOMAIN_ARBITRUM,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            DEFAULT_HOOK_DATA
        );

        module.removeDomainConfig(DOMAIN_BASE);

        DataTypes.CCTPDomainConfig memory configBase = module.getDomainConfig(DOMAIN_BASE);
        DataTypes.CCTPDomainConfig memory configArb = module.getDomainConfig(DOMAIN_ARBITRUM);

        assertFalse(configBase.isValid);
        assertTrue(configArb.isValid);
    }

    function test_GivenDomainRemoved_CanReconfigure() external givenDomainConfigured {
        module.removeDomainConfig(DOMAIN_BASE);

        bytes32 newRecipient = bytes32(uint256(uint160(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd)));
        module.setDomainConfig(
            DOMAIN_BASE, newRecipient, DEFAULT_DESTINATION_CALLER, 0, FINALITY_STANDARD, DEFAULT_HOOK_DATA
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertTrue(config.isValid);
        assertEq(config.mintRecipient, newRecipient);
    }
}
