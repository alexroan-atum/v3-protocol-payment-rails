// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { MockBridgePaymentRails } from "../../../../shared/mocks/MockBridgePaymentRails.sol";
import { MockTokenMessengerV2 } from "../../../../shared/mocks/MockTokenMessengerV2.sol";
import { FailingTransferERC20 } from "../../../../shared/mocks/FailingTransferERC20.sol";

/// @dev Base test contract for CCTPBridgeModule unit tests.
///      Provides shared state, constants, mocks, modifiers, and helpers following Sablier BTT style.
abstract contract CCTPBridgeModuleBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event BridgeInitiated(
        address indexed paymentRails,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes hookData
    );

    event DomainConfigSet(
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    event DomainConfigRemoved(uint32 indexed destinationDomain);

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint32 internal constant DOMAIN_BASE = 6;
    uint32 internal constant DOMAIN_ARBITRUM = 3;
    uint32 internal constant DOMAIN_ETHEREUM = 0;

    bytes32 internal constant DEFAULT_MINT_RECIPIENT =
        bytes32(uint256(uint160(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB)));
    bytes32 internal constant DEFAULT_DESTINATION_CALLER = bytes32(0);
    uint256 internal constant DEFAULT_MAX_FEE = 1e6;
    uint32 internal constant FINALITY_FAST = 1000;
    uint32 internal constant FINALITY_STANDARD = 2000;
    bytes internal constant DEFAULT_HOOK_DATA = "";

    uint256 internal constant DEFAULT_BRIDGE_AMOUNT = 1000e6;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CCTPBridgeModule internal module;
    MockTokenMessengerV2 internal tokenMessenger;
    MockBridgePaymentRails internal paymentRails;
    MockERC20 internal usdc;
    MockERC20 internal otherToken;
    FailingTransferERC20 internal failToken;

    address internal owner;
    address internal attacker;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        owner = address(this);
        attacker = makeAddr("attacker");

        tokenMessenger = new MockTokenMessengerV2();
        usdc = new MockERC20("USD Coin", "USDC");
        otherToken = new MockERC20("Other Token", "OTH");
        failToken = new FailingTransferERC20();

        module = new CCTPBridgeModule(address(tokenMessenger), address(usdc), owner);
        paymentRails = new MockBridgePaymentRails(address(module));

        usdc.mint(address(paymentRails), DEFAULT_BRIDGE_AMOUNT * 10);
        otherToken.mint(address(paymentRails), DEFAULT_BRIDGE_AMOUNT * 10);
        failToken.mint(address(paymentRails), DEFAULT_BRIDGE_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier givenDomainConfigured() {
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );
        _;
    }

    modifier givenDomainConfiguredWithHook() {
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_FAST,
            hex"deadbeef"
        );
        _;
    }

    modifier whenCallerIsNotOwner() {
        vm.startPrank(attacker);
        _;
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _encodeParams(uint32 destinationDomain) internal pure returns (bytes memory) {
        return abi.encode(destinationDomain);
    }

    function _defaultParams() internal pure returns (bytes memory) {
        return _encodeParams(DOMAIN_BASE);
    }
}
