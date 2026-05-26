// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../src/modules/bridges/CCTPBridgeModule.sol";

import { CCTPBridgeModuleHandler, BridgePaymentRailsProxy } from "./CCTPBridgeModuleHandler.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockTokenMessengerV2 } from "../../../shared/mocks/MockTokenMessengerV2.sol";

contract CCTPBridgeModuleInvariant is Test {
    CCTPBridgeModule internal module;
    CCTPBridgeModuleHandler internal handler;
    BridgePaymentRailsProxy internal paymentRails;
    MockERC20 internal usdc;
    MockERC20 internal otherToken;
    MockTokenMessengerV2 internal tokenMessenger;

    function setUp() public {
        tokenMessenger = new MockTokenMessengerV2();
        usdc = new MockERC20("USD Coin", "USDC");
        otherToken = new MockERC20("Other Token", "OTH");

        module = new CCTPBridgeModule(address(tokenMessenger), address(usdc));
        paymentRails = new BridgePaymentRailsProxy(address(module));

        handler = new CCTPBridgeModuleHandler(module, paymentRails, usdc, otherToken, tokenMessenger);

        targetContract(address(handler));
        excludeContract(address(module));
        excludeContract(address(paymentRails));
        excludeContract(address(usdc));
        excludeContract(address(otherToken));
        excludeContract(address(tokenMessenger));
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

    // MockTokenMessengerV2 does not burn tokens, so USDC stays in the module after bridge.
    function invariant_USDCConservation() public view {
        uint256 totalMinted = handler.ghost_totalMintedToPaymentRails();
        uint256 paymentRailsBalance = usdc.balanceOf(address(paymentRails));
        uint256 moduleBalance = usdc.balanceOf(address(module));

        assertEq(
            totalMinted,
            paymentRailsBalance + moduleBalance,
            "INV-5: total minted must equal paymentRails balance + module balance (mock does not burn)"
        );
    }
}
