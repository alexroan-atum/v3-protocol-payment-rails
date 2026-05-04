// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { CCTPBridgeModuleHandler, BridgeNodeProxy } from "./CCTPBridgeModuleHandler.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockTokenMessengerV2 } from "../../../shared/mocks/MockTokenMessengerV2.sol";

contract CCTPBridgeModuleInvariant is Test {
    CCTPBridgeModule internal module;
    CCTPBridgeModuleHandler internal handler;
    BridgeNodeProxy internal node;
    MockERC20 internal usdc;
    MockERC20 internal otherToken;
    MockTokenMessengerV2 internal tokenMessenger;

    address internal moduleOwner;

    function setUp() public {
        moduleOwner = makeAddr("moduleOwner");
        tokenMessenger = new MockTokenMessengerV2();
        usdc = new MockERC20("USD Coin", "USDC");
        otherToken = new MockERC20("Other Token", "OTH");
        module = new CCTPBridgeModule(address(tokenMessenger), address(usdc), moduleOwner);
        node = new BridgeNodeProxy(address(module));

        handler = new CCTPBridgeModuleHandler(module, node, usdc, otherToken, tokenMessenger, moduleOwner);

        targetContract(address(handler));
        excludeContract(address(module));
        excludeContract(address(node));
        excludeContract(address(usdc));
        excludeContract(address(otherToken));
        excludeContract(address(tokenMessenger));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-1: DOMAIN CONFIG INTEGRITY
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_DomainConfigIntegrity() public view {
        uint256 len = handler.ghost_configuredDomainsLength();

        for (uint256 i = 0; i < len; i++) {
            uint32 domain = handler.ghost_configuredDomains(i);
            bool ghostConfigured = handler.ghost_domainIsConfigured(domain);
            DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(domain);

            assertEq(
                config.isValid, ghostConfigured, "INV-1: on-chain isValid must match ghost domain configured state"
            );

            if (ghostConfigured) {
                assertEq(config.maxFee, handler.ghost_domainMaxFee(domain), "INV-1: on-chain maxFee must match ghost");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-2: APPROVAL HYGIENE
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_ApprovalAlwaysZero() public view {
        uint256 allowance = usdc.allowance(address(module), address(tokenMessenger));
        assertEq(allowance, 0, "INV-2: module approval to tokenMessenger must always be zero after any action");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-3: IMMUTABLES NEVER CHANGE
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_ImmutablesNeverChange() public view {
        assertEq(module.tokenMessenger(), address(tokenMessenger), "INV-3: tokenMessenger must never change");
        assertEq(module.usdc(), address(usdc), "INV-3: usdc must never change");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-4: MODULE TYPE IS CONSTANT
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_ModuleTypeConstant() public view {
        assertEq(module.moduleType(), "CCTP_BRIDGE", "INV-4: moduleType must always return CCTP_BRIDGE");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-5: USDC CONSERVATION
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_USDCConservation() public view {
        uint256 totalMinted = handler.ghost_totalMintedToNode();
        uint256 nodeBalance = usdc.balanceOf(address(node));
        uint256 moduleBalance = usdc.balanceOf(address(module));

        assertEq(
            totalMinted,
            nodeBalance + moduleBalance,
            "INV-5: total minted must equal node balance + module balance (mock does not burn)"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-6: OWNERSHIP CONSISTENCY
    //////////////////////////////////////////////////////////////////////////*/

    function invariant_OwnershipConsistency() public view {
        assertEq(module.owner(), handler.ghost_currentOwner(), "INV-6: on-chain owner must match ghost");
        assertEq(module.pendingOwner(), handler.ghost_pendingOwner(), "INV-6: on-chain pendingOwner must match ghost");
    }
}
