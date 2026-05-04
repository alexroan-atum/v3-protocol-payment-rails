// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { CCTPBridgeModule } from "../../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract CCTPBridgeModule_Constructor_Test is CCTPBridgeModuleBase {
    function test_RevertWhen_TokenMessengerIsZeroAddress() external {
        vm.expectRevert(Errors.CCTPBridgeModule_ZeroTokenMessenger.selector);
        new CCTPBridgeModule(address(0), address(usdc), owner);
    }

    function test_RevertWhen_USDCIsZeroAddress() external {
        vm.expectRevert(Errors.CCTPBridgeModule_ZeroUSDC.selector);
        new CCTPBridgeModule(address(tokenMessenger), address(0), owner);
    }

    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CCTPBridgeModule(address(tokenMessenger), address(usdc), address(0));
    }

    function test_WhenAllParametersAreValid_StoresTokenMessenger() external view {
        assertEq(module.tokenMessenger(), address(tokenMessenger));
    }

    function test_WhenAllParametersAreValid_StoresUSDC() external view {
        assertEq(module.usdc(), address(usdc));
    }

    function test_WhenAllParametersAreValid_SetsOwner() external view {
        assertEq(module.owner(), owner);
    }
}
