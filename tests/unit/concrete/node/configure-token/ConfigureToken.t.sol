// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { NodeBase } from "../NodeBase.t.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { MockActionModule } from "../../../../shared/mocks/MockActionModule.sol";
import { EmptyModuleTypeMock } from "../../../../shared/mocks/MockActionModule.sol";
import { RevertingModuleMock } from "../../../../shared/mocks/MockActionModule.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract NodeConfigureTokenTest is NodeBase {
    /*//////////////////////////////////////////////////////////////////////////
                        REVERT TESTS — access control & validation
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerIsNotOwner() external whenCallerIsNotOwner {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );
    }

    function test_RevertWhen_TokenIsZeroAddress() external whenCallerIsOwner {
        vm.expectRevert(Errors.Node_ZeroTokenAddress.selector);
        node.configureToken(address(0), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        CLEARING CONFIGURATION (empty actionType)
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_EmptyActionType_NonZeroModule() external whenCallerIsOwner {
        vm.expectRevert(Errors.Node_NoneActionRequiresZeroModule.selector);
        node.configureToken(address(token), "", address(actionModule), 0, "", false);
    }

    function test_WhenEmptyActionType_ZeroModule_StoresCleared() external whenCallerIsOwner {
        node.configureToken(address(token), "", address(0), 0, "", false);

        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertEq(bytes(config.actionType).length, 0);
        assertEq(config.actionModule, address(0));
        assertFalse(config.enabled);
    }

    function test_WhenEmptyActionType_ZeroModule_EmitsTokenConfigured() external whenCallerIsOwner {
        vm.expectEmit(true, false, false, true);
        emit TokenConfigured(address(token), "", address(0));

        node.configureToken(address(token), "", address(0), 0, "", false);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REVERT TESTS — non-empty actionType, invalid module
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ActionModuleIsZeroAddress() external whenCallerIsOwner {
        vm.expectRevert(Errors.Node_ZeroModuleAddress.selector);
        node.configureToken(address(token), ACTION_TYPE, address(0), MIN_BALANCE, _defaultModuleParams(), true);
    }

    function test_RevertWhen_ActionModuleHasNoCode() external whenCallerIsOwner {
        address eoa = makeAddr("eoa");
        // Solidity's extcodesize check reverts with empty data before try/catch can catch it.
        vm.expectRevert();
        node.configureToken(address(token), ACTION_TYPE, eoa, MIN_BALANCE, _defaultModuleParams(), true);
    }

    function test_RevertWhen_ActionModuleRevertsOnModuleType() external whenCallerIsOwner {
        RevertingModuleMock revertingModule = new RevertingModuleMock();

        vm.expectRevert(Errors.Node_ModuleValidationFailed.selector);
        node.configureToken(
            address(token), ACTION_TYPE, address(revertingModule), MIN_BALANCE, _defaultModuleParams(), true
        );
    }

    function test_RevertWhen_ActionModuleReturnsEmptyModuleType() external whenCallerIsOwner {
        EmptyModuleTypeMock emptyTypeModule = new EmptyModuleTypeMock();

        vm.expectRevert(Errors.Node_InvalidModule.selector);
        node.configureToken(
            address(token), ACTION_TYPE, address(emptyTypeModule), MIN_BALANCE, _defaultModuleParams(), true
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    SUCCESS TESTS — valid configuration
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenValid_StoresTokenConfiguration() external whenCallerIsOwner {
        bytes memory params = _defaultModuleParams();
        node.configureToken(address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, params, true);

        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertEq(config.actionType, ACTION_TYPE);
        assertEq(config.actionModule, address(actionModule));
        assertTrue(config.enabled);
        assertEq(config.minBalance, MIN_BALANCE);
        assertEq(config.moduleParams, params);
    }

    function test_WhenValid_SetsEnabledFalse() external whenCallerIsOwner {
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), false
        );

        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertFalse(config.enabled);
    }

    function test_WhenValid_EmitsTokenConfigured() external whenCallerIsOwner {
        vm.expectEmit(true, false, false, true);
        emit TokenConfigured(address(token), ACTION_TYPE, address(actionModule));

        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    RECONFIGURATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenReconfiguring_OverwritesPreviousConfig() external whenCallerIsOwner {
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        MockActionModule newModule = new MockActionModule();
        uint256 newMinBalance = 500e18;
        bytes memory newParams = abi.encode(uint256(42));

        node.configureToken(address(token), "NEW_TYPE", address(newModule), newMinBalance, newParams, false);

        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertEq(config.actionType, "NEW_TYPE");
        assertEq(config.actionModule, address(newModule));
        assertFalse(config.enabled);
        assertEq(config.minBalance, newMinBalance);
        assertEq(config.moduleParams, newParams);
    }

    function test_WhenReconfiguring_EmitsTokenConfiguredWithNewValues() external whenCallerIsOwner {
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        MockActionModule newModule = new MockActionModule();

        vm.expectEmit(true, false, false, true);
        emit TokenConfigured(address(token), "NEW_TYPE", address(newModule));

        node.configureToken(address(token), "NEW_TYPE", address(newModule), 0, "", true);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CLEAR PREVIOUSLY CONFIGURED TOKEN
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenClearingPreviouslyConfiguredToken_ResetsToDefaults() external whenCallerIsOwner {
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        node.configureToken(address(token), "", address(0), 0, "", false);

        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertEq(bytes(config.actionType).length, 0);
        assertEq(config.actionModule, address(0));
        assertFalse(config.enabled);
        assertEq(config.minBalance, 0);
    }

    function test_WhenClearingPreviouslyConfiguredToken_BlocksExecution() external whenCallerIsOwner {
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        node.configureToken(address(token), "", address(0), 0, "", false);

        vm.stopPrank();
        vm.expectRevert(Errors.Node_TokenNotEnabled.selector);
        node.executeAction(address(token), INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    MULTIPLE TOKEN INDEPENDENCE
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenConfiguringMultipleTokens_ConfigsAreIndependent() external whenCallerIsOwner {
        MockERC20 tokenB = new MockERC20("Token B", "TOKB");
        MockActionModule moduleB = new MockActionModule();
        uint256 minBalB = 200e18;

        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );
        node.configureToken(address(tokenB), "OTHER", address(moduleB), minBalB, abi.encode(uint256(1)), false);

        DataTypes.TokenConfig memory configA = node.getTokenConfig(address(token));
        DataTypes.TokenConfig memory configB = node.getTokenConfig(address(tokenB));

        assertEq(configA.actionType, ACTION_TYPE);
        assertEq(configB.actionType, "OTHER");
        assertEq(configA.actionModule, address(actionModule));
        assertEq(configB.actionModule, address(moduleB));
        assertTrue(configA.enabled);
        assertFalse(configB.enabled);
        assertEq(configA.minBalance, MIN_BALANCE);
        assertEq(configB.minBalance, minBalB);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_ConfigureToken_StoresArbitraryMinBalance(uint256 minBalance) external whenCallerIsOwner {
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), minBalance, _defaultModuleParams(), true
        );

        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertEq(config.minBalance, minBalance);
    }
}
