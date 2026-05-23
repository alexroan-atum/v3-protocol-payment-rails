// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";

contract CowSwapModuleRenounceOwnershipTest is CowSwapModuleBase {
    function test_RevertWhen_RenounceOwnership_CalledByOwner() external {
        vm.expectRevert(Errors.CowSwapModule_OwnershipCannotBeRenounced.selector);
        module.renounceOwnership();
    }

    function test_RevertWhen_RenounceOwnership_CalledByNonOwner() external {
        vm.expectRevert(Errors.CowSwapModule_OwnershipCannotBeRenounced.selector);
        vm.prank(attacker);
        module.renounceOwnership();
    }

    /// @dev Verifies that pending orders remain cancellable after a failed renounce attempt.
    function test_RenounceOwnership_Reverts_PendingOrderStillCancellable() external givenPendingOrder {
        vm.expectRevert(Errors.CowSwapModule_OwnershipCannotBeRenounced.selector);
        module.renounceOwnership();

        module.cancelOrder(_orderId);
        assertTrue(module.getOrder(_orderId).cancelled);
    }
}
