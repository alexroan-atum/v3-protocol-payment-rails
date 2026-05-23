// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { PaymentRailsBase } from "../PaymentRailsBase.t.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PaymentRailsOwnershipTransferTest is PaymentRailsBase {
    address internal newOwner;

    function setUp() public override {
        super.setUp();
        newOwner = makeAddr("newOwner");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            transferOwnership
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_TransferOwnership_CallerIsNotOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        paymentRails.transferOwnership(newOwner);
    }

    function test_TransferOwnership_SetsPendingOwner() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        assertEq(paymentRails.pendingOwner(), newOwner);
    }

    function test_TransferOwnership_DoesNotChangeCurrentOwner() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        assertEq(paymentRails.owner(), owner);
    }

    function test_TransferOwnership_ToZeroAddress_CancelsPendingTransfer() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);
        assertEq(paymentRails.pendingOwner(), newOwner);

        vm.prank(owner);
        paymentRails.transferOwnership(address(0));
        assertEq(paymentRails.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            acceptOwnership
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_AcceptOwnership_CallerIsNotPendingOwner() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        paymentRails.acceptOwnership();
    }

    function test_AcceptOwnership_UpdatesOwner() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        vm.prank(newOwner);
        paymentRails.acceptOwnership();

        assertEq(paymentRails.owner(), newOwner);
    }

    function test_AcceptOwnership_ResetsPendingOwnerToZero() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        vm.prank(newOwner);
        paymentRails.acceptOwnership();

        assertEq(paymentRails.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_NewOwnerCanCallOnlyOwnerFunctions() external givenTokenConfigured {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        vm.prank(newOwner);
        paymentRails.acceptOwnership();

        vm.prank(newOwner);
        paymentRails.configureToken(address(token), ACTION_TYPE, address(actionModule), 0, _defaultModuleParams(), true);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            renounceOwnership
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RenounceOwnership_CalledByOwner() external {
        vm.expectRevert(Errors.PaymentRails_OwnershipCannotBeRenounced.selector);
        vm.prank(owner);
        paymentRails.renounceOwnership();
    }

    function test_RevertWhen_RenounceOwnership_CalledByNonOwner() external {
        vm.expectRevert(Errors.PaymentRails_OwnershipCannotBeRenounced.selector);
        vm.prank(nonOwner);
        paymentRails.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            full lifecycle
    //////////////////////////////////////////////////////////////////////////*/

    function test_Lifecycle_OldOwnerOperatesUntilAccepted() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        // Old owner can still configure tokens
        vm.prank(owner);
        paymentRails.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );

        assertEq(paymentRails.getTokenConfig(address(token)).actionModule, address(actionModule));
    }

    function test_Lifecycle_OldOwnerBlockedAfterAccepted() external {
        vm.prank(owner);
        paymentRails.transferOwnership(newOwner);

        vm.prank(newOwner);
        paymentRails.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        paymentRails.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );
    }
}
