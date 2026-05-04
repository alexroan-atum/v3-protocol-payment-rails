// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract CCTPBridgeModule_SetDomainConfig_Test is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            REVERT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerIsNotOwner() external whenCallerIsNotOwner {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );
    }

    function test_RevertWhen_MintRecipientIsZero() external {
        vm.expectRevert(Errors.CCTPBridgeModule_ZeroMintRecipient.selector);
        module.setDomainConfig(
            DOMAIN_BASE, bytes32(0), DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );
    }

    function test_RevertWhen_FinalityThresholdIsInvalid_Zero() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CCTPBridgeModule_InvalidFinalityThreshold.selector, uint32(0)));
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, 0, DEFAULT_HOOK_DATA
        );
    }

    function test_RevertWhen_FinalityThresholdIsInvalid_500() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CCTPBridgeModule_InvalidFinalityThreshold.selector, uint32(500)));
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, 500, DEFAULT_HOOK_DATA
        );
    }

    function test_RevertWhen_FinalityThresholdIsInvalid_3000() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CCTPBridgeModule_InvalidFinalityThreshold.selector, uint32(3000)));
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, 3000, DEFAULT_HOOK_DATA
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — EMPTY HOOK DATA
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenValidParams_StoresDomainConfig() external {
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertTrue(config.isValid);
        assertEq(config.mintRecipient, DEFAULT_MINT_RECIPIENT);
        assertEq(config.destinationCaller, DEFAULT_DESTINATION_CALLER);
        assertEq(config.maxFee, DEFAULT_MAX_FEE);
        assertEq(config.minFinalityThreshold, FINALITY_FAST);
        assertEq(config.hookData, DEFAULT_HOOK_DATA);
    }

    function test_WhenValidParams_EmitsDomainConfigSet() external {
        vm.expectEmit(true, false, false, true);
        emit DomainConfigSet(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST
        );

        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );
    }

    function test_WhenValidParams_AcceptsFinalityStandard() external {
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            DEFAULT_HOOK_DATA
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.minFinalityThreshold, FINALITY_STANDARD);
    }

    function test_WhenValidParams_AcceptsZeroMaxFee() external {
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, 0, FINALITY_FAST, DEFAULT_HOOK_DATA
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.maxFee, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — WITH HOOK DATA
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenValidParamsWithHookData_StoresHookData() external {
        bytes memory hookData = hex"deadbeef";
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, hookData
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertEq(config.hookData, hookData);
    }

    function test_WhenValidParamsWithHookData_EmitsDomainConfigSet() external {
        vm.expectEmit(true, false, false, true);
        emit DomainConfigSet(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST
        );

        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            hex"deadbeef"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — OVERWRITE EXISTING
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenUpdatingExistingConfig_OverwritesPreviousConfig() external givenDomainConfigured {
        bytes32 newRecipient = bytes32(uint256(uint160(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC)));
        uint256 newMaxFee = 5e6;

        module.setDomainConfig(
            DOMAIN_BASE, newRecipient, DEFAULT_DESTINATION_CALLER, newMaxFee, FINALITY_STANDARD, DEFAULT_HOOK_DATA
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertTrue(config.isValid);
        assertEq(config.mintRecipient, newRecipient);
        assertEq(config.maxFee, newMaxFee);
        assertEq(config.minFinalityThreshold, FINALITY_STANDARD);
    }

    function test_WhenUpdatingExistingConfig_EmitsDomainConfigSetWithNewValues() external givenDomainConfigured {
        bytes32 newRecipient = bytes32(uint256(uint160(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC)));

        vm.expectEmit(true, false, false, true);
        emit DomainConfigSet(DOMAIN_BASE, newRecipient, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST);

        module.setDomainConfig(
            DOMAIN_BASE, newRecipient, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    MULTI-DOMAIN TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenConfiguringMultipleDomains_StoresEachIndependently() external {
        bytes32 recipientBase = DEFAULT_MINT_RECIPIENT;
        bytes32 recipientArb = bytes32(uint256(uint160(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)));

        module.setDomainConfig(
            DOMAIN_BASE, recipientBase, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, DEFAULT_HOOK_DATA
        );
        module.setDomainConfig(
            DOMAIN_ARBITRUM, recipientArb, DEFAULT_DESTINATION_CALLER, 0, FINALITY_STANDARD, DEFAULT_HOOK_DATA
        );

        DataTypes.CCTPDomainConfig memory configBase = module.getDomainConfig(DOMAIN_BASE);
        DataTypes.CCTPDomainConfig memory configArb = module.getDomainConfig(DOMAIN_ARBITRUM);

        assertEq(configBase.mintRecipient, recipientBase);
        assertEq(configBase.maxFee, DEFAULT_MAX_FEE);
        assertEq(configArb.mintRecipient, recipientArb);
        assertEq(configArb.maxFee, 0);
    }
}
