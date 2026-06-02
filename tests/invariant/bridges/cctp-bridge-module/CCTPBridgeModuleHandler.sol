// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockTokenMessengerV2 } from "../../../shared/mocks/MockTokenMessengerV2.sol";

contract BridgePaymentRailsProxy is Test {
    CCTPBridgeModule public immutable module;

    constructor(address _module) {
        module = CCTPBridgeModule(_module);
    }

    function initiateBridge(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params);
    }
}

contract CCTPBridgeModuleHandler is Test {
    CCTPBridgeModule internal module;
    BridgePaymentRailsProxy internal paymentRails;
    MockERC20 internal usdc;
    MockERC20 internal otherToken;
    MockTokenMessengerV2 internal tokenMessenger;

    uint256 public ghost_totalMintedToPaymentRails;

    bytes32 internal constant MINT_RECIPIENT = bytes32(uint256(uint160(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB)));
    uint16 internal constant MAX_FEE_BPS = 20; // 0.2%
    uint32 internal constant MAX_DOMAIN = 10;

    constructor(
        CCTPBridgeModule _module,
        BridgePaymentRailsProxy _paymentRails,
        MockERC20 _usdc,
        MockERC20 _otherToken,
        MockTokenMessengerV2 _tokenMessenger
    ) {
        module = _module;
        paymentRails = _paymentRails;
        usdc = _usdc;
        otherToken = _otherToken;
        tokenMessenger = _tokenMessenger;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            EXECUTION ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function handler_execute(uint256 amount, uint32 domain, bool useFastFinality) external {
        amount = bound(amount, 2, 100_000e6);
        domain = uint32(bound(domain, 0, MAX_DOMAIN));
        uint32 finality = useFastFinality ? 1000 : 2000;

        usdc.mint(address(paymentRails), amount);
        ghost_totalMintedToPaymentRails += amount;

        bytes memory params = abi.encode(
            domain,
            MINT_RECIPIENT,
            bytes32(0), // destinationCaller — anyone can relay
            uint16(MAX_FEE_BPS),
            finality,
            bytes("") // no hook data
        );

        paymentRails.initiateBridge(address(usdc), amount, params);
    }

    function handler_executeWithHook(uint256 amount, uint32 domain, bool useFastFinality) external {
        amount = bound(amount, 2, 100_000e6);
        domain = uint32(bound(domain, 0, MAX_DOMAIN));
        uint32 finality = useFastFinality ? 1000 : 2000;

        usdc.mint(address(paymentRails), amount);
        ghost_totalMintedToPaymentRails += amount;

        bytes memory params = abi.encode(
            domain,
            MINT_RECIPIENT,
            bytes32(0),
            uint16(MAX_FEE_BPS),
            finality,
            bytes(hex"deadbeef") // non-empty hook data
        );

        paymentRails.initiateBridge(address(usdc), amount, params);
    }

    function handler_executeWithBadParams(uint256 badCase) external {
        badCase = bound(badCase, 0, 3);

        uint256 amount = 1000e6;
        usdc.mint(address(paymentRails), amount);
        ghost_totalMintedToPaymentRails += amount;

        bytes memory params;
        DataTypes.ExecutionResult memory result;

        if (badCase == 0) {
            // Zero mint recipient
            params = abi.encode(
                uint32(0),
                bytes32(0), // invalid: zero recipient
                bytes32(0),
                uint16(MAX_FEE_BPS),
                uint32(1000),
                bytes("")
            );
            result = paymentRails.initiateBridge(address(usdc), amount, params);
            assertFalse(result.success, "Zero recipient should fail");
            assertEq(result.failureReason, "Zero mint recipient");
        } else if (badCase == 1) {
            // Invalid finality threshold (not 1000 or 2000)
            params = abi.encode(
                uint32(0),
                MINT_RECIPIENT,
                bytes32(0),
                uint16(MAX_FEE_BPS),
                uint32(999), // invalid finality
                bytes("")
            );
            result = paymentRails.initiateBridge(address(usdc), amount, params);
            assertFalse(result.success, "Bad finality should fail");
            assertEq(result.failureReason, "Invalid finality threshold");
        } else if (badCase == 2) {
            // maxFeeBps >= 10_000
            params = abi.encode(
                uint32(0),
                MINT_RECIPIENT,
                bytes32(0),
                uint16(10_000), // maxFeeBps == 100%
                uint32(1000),
                bytes("")
            );
            result = paymentRails.initiateBridge(address(usdc), amount, params);
            assertFalse(result.success, "maxFeeBps >= 10_000 should fail");
            assertEq(result.failureReason, "Invalid max fee bps");
        } else {
            // Zero bridge amount
            params = abi.encode(uint32(0), MINT_RECIPIENT, bytes32(0), uint16(MAX_FEE_BPS), uint32(1000), bytes(""));
            result = paymentRails.initiateBridge(address(usdc), 0, params);
            assertFalse(result.success, "Zero amount should fail");
            assertEq(result.failureReason, "Zero bridge amount");
        }
    }

    function handler_executeNonUSDC(uint256 amount, uint32 domain) external {
        amount = bound(amount, 1, 100_000e6);
        domain = uint32(bound(domain, 0, MAX_DOMAIN));

        otherToken.mint(address(paymentRails), amount);

        bytes memory params =
            abi.encode(domain, MINT_RECIPIENT, bytes32(0), uint16(MAX_FEE_BPS), uint32(1000), bytes(""));

        vm.prank(address(paymentRails));
        IERC20(address(otherToken)).approve(address(module), amount);

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(otherToken), amount, params);

        assertFalse(result.success, "Non-USDC should fail");
        assertEq(result.failureReason, "Only USDC supported");
    }
}
