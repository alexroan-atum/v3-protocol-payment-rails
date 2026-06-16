// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { CowSwapModule } from "../../../../../../src/modules/swaps/CowSwapModule.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockChainlinkAggregator } from "../../../../../shared/mocks/MockChainlinkAggregator.sol";

/// @notice Unit tests for CowSwapModule constructor
/// @dev Tree: tests/unit/concrete/cow-swap-module/constructor/constructor.tree
contract CowSwapModule_Constructor_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when cow settlement is zero address
    // -----------------------------------------------------------------------

    function test_RevertWhen_CowSettlementIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModule_ZeroCowSettlement.selector);
        new CowSwapModule(address(0), address(this), address(paymentRails), address(0), 0);
    }

    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CowSwapModule(address(cowSettlement), address(0), address(paymentRails), address(0), 0);
    }

    function test_RevertWhen_PaymentRailsIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModule_ZeroPaymentRails.selector);
        new CowSwapModule(address(cowSettlement), address(this), address(0), address(0), 0);
    }

    // -----------------------------------------------------------------------
    // when all parameters are valid
    // -----------------------------------------------------------------------

    function test_WhenAllParamsValid_StoresCowSettlement() external view {
        assertEq(module.cowSettlement(), address(cowSettlement));
    }

    function test_WhenAllParamsValid_CachesCowDomainSeparator() external view {
        assertEq(module.cowDomainSeparator(), DOMAIN_SEPARATOR);
    }

    function test_WhenAllParamsValid_SetsOwner() external view {
        assertEq(module.owner(), address(this));
    }

    function test_WhenAllParamsValid_StoresPaymentRails() external view {
        assertEq(module.paymentRails(), address(paymentRails));
    }

    function test_WhenAllParamsValid_StoresSequencerUptimeFeed() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(paymentRails), address(seqFeed), 3600);
        assertEq(l2Module.sequencerUptimeFeed(), address(seqFeed));
    }

    function test_WhenAllParamsValid_StoresSequencerGracePeriod() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(paymentRails), address(seqFeed), 3600);
        assertEq(l2Module.sequencerGracePeriod(), 3600);
    }
}
