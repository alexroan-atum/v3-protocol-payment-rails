// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { CowSwapModule } from "../../../../../../src/modules/swaps/CowSwapModule.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unit tests for CowSwapModule constructor
/// @dev Tree: tests/unit/concrete/cow-swap-module/constructor/constructor.tree
contract CowSwapModule_Constructor_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when cow settlement is zero address
    // -----------------------------------------------------------------------

    function test_RevertWhen_CowSettlementIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModule_ZeroCowSettlement.selector);
        new CowSwapModule(address(0), address(this));
    }

    function test_RevertWhen_OwnerIsZeroAddress() external {
        // OZ Ownable rejects address(0) before our constructor body with OwnableInvalidOwner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CowSwapModule(address(cowSettlement), address(0));
    }

    // -----------------------------------------------------------------------
    // when cow settlement is valid
    // -----------------------------------------------------------------------

    function test_WhenCowSettlementIsValid_StoresCowSettlement() external view {
        assertEq(module.cowSettlement(), address(cowSettlement));
    }

    function test_WhenCowSettlementIsValid_CachesCowDomainSeparator() external view {
        assertEq(module.cowDomainSeparator(), DOMAIN_SEPARATOR);
    }

    function test_WhenOwnerIsValid_SetsOwner() external view {
        assertEq(module.owner(), address(this));
    }
}
