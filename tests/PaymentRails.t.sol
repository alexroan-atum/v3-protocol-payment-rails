// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { PaymentRails } from "../src/core/PaymentRails.sol";
import { ForwardModule } from "../src/modules/forwards/ForwardModule.sol";
import { DataTypes } from "../src/types/DataTypes.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title PaymentRailsTest
/// @notice Test suite for PaymentRails contract
contract PaymentRailsTest is Test {
    PaymentRails public paymentRails;
    ForwardModule public forwardModule;
    MockERC20 public token;

    address public owner;
    address public executor;
    address public recipient;

    function setUp() public {
        owner = address(this);
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");

        // Deploy contracts
        paymentRails = new PaymentRails(owner);
        forwardModule = new ForwardModule();
        token = new MockERC20("Test Token", "TEST");

        // Mint tokens to paymentRails
        token.mint(address(paymentRails), 1000 * 10 ** 18);
    }

    function test_Deployment() public view {
        assertEq(paymentRails.owner(), owner);
    }

    function test_ConfigureToken() public {
        // Encode forward params
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });
        bytes memory encodedParams = forwardModule.encodeParams(params);

        // Configure token
        paymentRails.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18, // minBalance
            encodedParams,
            true // enabled
        );

        // Verify configuration
        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(address(token));
        assertEq(config.actionType, "FORWARD");
        assertEq(config.actionModule, address(forwardModule));
        assertTrue(config.enabled);
    }

    function test_ExecuteForwardAction() public {
        // Setup: Configure token
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });
        bytes memory encodedParams = forwardModule.encodeParams(params);

        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, encodedParams, true
        );

        // Check initial balances
        uint256 paymentRailsBalanceBefore = token.balanceOf(address(paymentRails));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        assertEq(paymentRailsBalanceBefore, 1000 * 10 ** 18);
        assertEq(recipientBalanceBefore, 0);

        // Execute action with full balance
        uint256 amount = token.balanceOf(address(paymentRails));
        bool success = paymentRails.executeAction(address(token), amount);
        assertTrue(success);

        // Verify balances changed
        uint256 paymentRailsBalanceAfter = token.balanceOf(address(paymentRails));
        uint256 recipientBalanceAfter = token.balanceOf(recipient);

        assertEq(paymentRailsBalanceAfter, 0);
        assertEq(recipientBalanceAfter, 1000 * 10 ** 18);
    }

    function test_ExecuteAction_PublicExecution() public {
        // Configure token
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), true
        );

        // Execute from different address (simulating public execution)
        uint256 amount = token.balanceOf(address(paymentRails));
        vm.prank(executor);
        bool success = paymentRails.executeAction(address(token), amount);
        assertTrue(success);

        // Verify it worked
        assertEq(token.balanceOf(recipient), 1000 * 10 ** 18);
    }

    function test_ExecuteAction_BelowMinimumBalance() public {
        // Configure with minimum balance of 100 tokens
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18, // minBalance
            forwardModule.encodeParams(params),
            true
        );

        // Try to execute with amount below minBalance
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_BelowMinimumBalance.selector, 50 * 10 ** 18, 100 * 10 ** 18)
        );
        paymentRails.executeAction(address(token), 50 * 10 ** 18); // Only 50 tokens
    }

    function test_ExecuteAction_PartialAmount() public {
        // Configure token
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18, // minBalance
            forwardModule.encodeParams(params),
            true
        );

        // PaymentRails has 1000 tokens, execute only 500
        bool success = paymentRails.executeAction(address(token), 500 * 10 ** 18);
        assertTrue(success);

        // Verify partial transfer
        assertEq(token.balanceOf(address(paymentRails)), 500 * 10 ** 18);
        assertEq(token.balanceOf(recipient), 500 * 10 ** 18);

        // Can execute again with remaining amount
        success = paymentRails.executeAction(address(token), 500 * 10 ** 18);
        assertTrue(success);

        assertEq(token.balanceOf(address(paymentRails)), 0);
        assertEq(token.balanceOf(recipient), 1000 * 10 ** 18);
    }

    function test_ExecuteAction_InsufficientBalance() public {
        // Configure token
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), true
        );

        // Try to execute more than balance
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_InsufficientBalance.selector, 1000 * 10 ** 18, 10_000 * 10 ** 18)
        );
        paymentRails.executeAction(address(token), 10_000 * 10 ** 18); // PaymentRails only has 1000
    }

    function test_PreviewExecution() public {
        // No configuration - should revert
        vm.expectRevert(Errors.PaymentRails_NoActionConfigured.selector);
        paymentRails.previewExecution(address(token));

        // Configure token
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), true
        );

        // Should be able to execute with estimated output
        (uint256 estimatedOutput, address outputToken) = paymentRails.previewExecution(address(token));
        assertEq(estimatedOutput, 1000 * 10 ** 18); // Should estimate full balance
        assertEq(outputToken, address(token)); // Forward returns same token
    }

    function test_PreviewExecution_ZeroAddress() public {
        vm.expectRevert(Errors.PaymentRails_ZeroTokenAddress.selector);
        paymentRails.previewExecution(address(0));
    }

    function test_PreviewExecution_NotEnabled() public {
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        // Configure but disabled
        paymentRails.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            false // disabled
        );

        vm.expectRevert(Errors.PaymentRails_TokenNotEnabled.selector);
        paymentRails.previewExecution(address(token));
    }

    function test_DisableToken() public {
        // Configure token as enabled
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), true
        );

        // Reconfigure token as disabled
        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), false
        );

        // Should not be able to execute
        uint256 amount = token.balanceOf(address(paymentRails));
        vm.expectRevert(Errors.PaymentRails_TokenNotEnabled.selector);
        paymentRails.executeAction(address(token), amount);

        // Re-enable
        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), true
        );

        // Should work now
        bool success = paymentRails.executeAction(address(token), amount);
        assertTrue(success);
    }

    function test_ReconfigureToken() public {
        // Configure token
        DataTypes.ForwardParams memory params =
            DataTypes.ForwardParams({ recipient: recipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token), "FORWARD", address(forwardModule), 100 * 10 ** 18, forwardModule.encodeParams(params), true
        );

        // Reconfigure with new recipient
        address newRecipient = makeAddr("newRecipient");
        DataTypes.ForwardParams memory newParams =
            DataTypes.ForwardParams({ recipient: newRecipient, requireSuccessfulReceipt: false, minAmount: 0 });

        paymentRails.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(newParams),
            true
        );

        // Execute and verify new recipient gets tokens
        uint256 amount = token.balanceOf(address(paymentRails));
        paymentRails.executeAction(address(token), amount);
        assertEq(token.balanceOf(newRecipient), 1000 * 10 ** 18);
        assertEq(token.balanceOf(recipient), 0);
    }
}
