// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract CCTPBridgeModuleOwnershipTest is CCTPBridgeModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    address internal newOwner;

    function setUp() public override {
        super.setUp();
        newOwner = makeAddr("newOwner");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        transferOwnership
    //////////////////////////////////////////////////////////////////////////*/

    function test_TransferOwnership_RevertWhen_CallerIsNotOwner() external whenCallerIsNotOwner {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.transferOwnership(newOwner);
    }

    function test_TransferOwnership_SetsPendingOwner() external {
        module.transferOwnership(newOwner);
        assertEq(module.pendingOwner(), newOwner);
    }

    function test_TransferOwnership_EmitsOwnershipTransferStarted() external {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferStarted(owner, newOwner);

        module.transferOwnership(newOwner);
    }

    function test_TransferOwnership_DoesNotChangeCurrentOwner() external {
        module.transferOwnership(newOwner);
        assertEq(module.owner(), owner);
    }

    function test_TransferOwnership_ToZeroAddress_SetsPendingOwnerToZero() external {
        module.transferOwnership(newOwner);
        assertEq(module.pendingOwner(), newOwner);

        module.transferOwnership(address(0));
        assertEq(module.pendingOwner(), address(0));
    }

    function test_TransferOwnership_ToZeroAddress_EmitsEvent() external {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferStarted(owner, address(0));

        module.transferOwnership(address(0));
    }

    function test_TransferOwnership_ToZeroAddress_CancelledPendingOwnerCannotAccept() external {
        module.transferOwnership(newOwner);
        module.transferOwnership(address(0));

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        module.acceptOwnership();
    }

    function test_TransferOwnership_ReplacePendingTransfer() external {
        address anotherOwner = makeAddr("anotherOwner");

        module.transferOwnership(newOwner);
        assertEq(module.pendingOwner(), newOwner);

        module.transferOwnership(anotherOwner);
        assertEq(module.pendingOwner(), anotherOwner);
    }

    function test_TransferOwnership_ReplacedPendingOwnerCannotAccept() external {
        address anotherOwner = makeAddr("anotherOwner");

        module.transferOwnership(newOwner);
        module.transferOwnership(anotherOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        module.acceptOwnership();
    }

    function test_TransferOwnership_ToSelf() external {
        module.transferOwnership(owner);
        assertEq(module.pendingOwner(), owner);
        assertEq(module.owner(), owner);

        module.acceptOwnership();
        assertEq(module.owner(), owner);
        assertEq(module.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                        acceptOwnership
    //////////////////////////////////////////////////////////////////////////*/

    function test_AcceptOwnership_RevertWhen_CallerIsNotPendingOwner() external {
        module.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.acceptOwnership();
    }

    function test_AcceptOwnership_RevertWhen_NoPendingTransfer() external {
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        module.acceptOwnership();
    }

    function test_AcceptOwnership_RevertWhen_OldOwnerTriesToAccept() external {
        module.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        module.acceptOwnership();
    }

    function test_AcceptOwnership_TransfersOwnership() external {
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        assertEq(module.owner(), newOwner);
    }

    function test_AcceptOwnership_ClearsPendingOwner() external {
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        assertEq(module.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_EmitsOwnershipTransferred() external {
        module.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();
    }

    function test_AcceptOwnership_NewOwnerCanCallOnlyOwnerFunctions() external givenDomainConfigured {
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        vm.prank(newOwner);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );

        assertEq(module.getDomainConfig(DOMAIN_ARBITRUM).isValid, true);
    }

    function test_AcceptOwnership_OldOwnerCannotCallOnlyOwnerFunctions() external givenDomainConfigured {
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );
    }

    function test_AcceptOwnership_ExecuteStillWorksAfterTransfer() external givenDomainConfigured {
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        usdc.mint(address(this), DEFAULT_BRIDGE_AMOUNT);
        usdc.approve(address(module), DEFAULT_BRIDGE_AMOUNT);

        DataTypes.ExecutionResult memory result = module.execute(address(usdc), DEFAULT_BRIDGE_AMOUNT, _defaultParams());
        assertTrue(result.success);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        renounceOwnership
    //////////////////////////////////////////////////////////////////////////*/

    function test_RenounceOwnership_RevertWhen_CallerIsNotOwner() external whenCallerIsNotOwner {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.renounceOwnership();
    }

    function test_RenounceOwnership_SetsOwnerToZero() external {
        module.renounceOwnership();
        assertEq(module.owner(), address(0));
    }

    function test_RenounceOwnership_EmitsOwnershipTransferred() external {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(owner, address(0));

        module.renounceOwnership();
    }

    function test_RenounceOwnership_BlocksSetDomainConfig() external {
        module.renounceOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );
    }

    function test_RenounceOwnership_BlocksRemoveDomainConfig() external givenDomainConfigured {
        module.renounceOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        module.removeDomainConfig(DOMAIN_BASE);
    }

    function test_RenounceOwnership_BlocksTransferOwnership() external {
        module.renounceOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        module.transferOwnership(newOwner);
    }

    function test_RenounceOwnership_ClearsPendingOwner() external {
        module.transferOwnership(newOwner);
        assertEq(module.pendingOwner(), newOwner);

        module.renounceOwnership();

        assertEq(module.pendingOwner(), address(0));
        assertEq(module.owner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                        pendingOwner
    //////////////////////////////////////////////////////////////////////////*/

    function test_PendingOwner_ReturnsZeroWhenNoPending() external view {
        assertEq(module.pendingOwner(), address(0));
    }

    function test_PendingOwner_ReturnsCorrectAddressWhenPending() external {
        module.transferOwnership(newOwner);
        assertEq(module.pendingOwner(), newOwner);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FULL LIFECYCLE
    //////////////////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_TwoConsecutiveOwnershipTransfers() external {
        address secondOwner = makeAddr("secondOwner");
        address thirdOwner = makeAddr("thirdOwner");

        module.transferOwnership(secondOwner);
        vm.prank(secondOwner);
        module.acceptOwnership();
        assertEq(module.owner(), secondOwner);

        vm.prank(secondOwner);
        module.transferOwnership(thirdOwner);
        vm.prank(thirdOwner);
        module.acceptOwnership();
        assertEq(module.owner(), thirdOwner);

        vm.prank(thirdOwner);
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );
        assertEq(module.getDomainConfig(DOMAIN_BASE).isValid, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, secondOwner));
        vm.prank(secondOwner);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );
    }
}
