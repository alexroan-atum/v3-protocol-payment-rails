// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { Node } from "../src/core/Node.sol";
import { ForwardModule } from "../src/modules/forwards/ForwardModule.sol";
import { INode } from "../src/interfaces/INode.sol";
import { IForwardModule } from "../src/interfaces/IForwardModule.sol";
import { DataTypes } from "../src/types/DataTypes.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// @title NodeTest
/// @notice Test suite for Node contract
contract NodeTest is Test {
    Node public node;
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
        node = new Node(owner);
        forwardModule = new ForwardModule();
        token = new MockERC20("Test Token", "TEST");

        // Mint tokens to node
        token.mint(address(node), 1000 * 10 ** 18);
    }

    function test_Deployment() public view {
        assertEq(node.owner(), owner);
    }

    function test_ConfigureToken() public {
        // Encode forward params
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });
        bytes memory encodedParams = forwardModule.encodeParams(params);

        // Configure token
        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18, // minBalance
            encodedParams,
            true            // enabled
        );

        // Verify configuration
        DataTypes.TokenConfig memory config = node.getTokenConfig(address(token));
        assertEq(config.actionType, "FORWARD");
        assertEq(config.actionModule, address(forwardModule));
        assertTrue(config.enabled);
    }

    function test_ExecuteForwardAction() public {
        // Setup: Configure token
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });
        bytes memory encodedParams = forwardModule.encodeParams(params);

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            encodedParams,
            true
        );

        // Check initial balances
        uint256 nodeBalanceBefore = token.balanceOf(address(node));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        assertEq(nodeBalanceBefore, 1000 * 10 ** 18);
        assertEq(recipientBalanceBefore, 0);

        // Execute action with full balance
        uint256 amount = token.balanceOf(address(node));
        bool success = node.executeAction(address(token), amount);
        assertTrue(success);

        // Verify balances changed
        uint256 nodeBalanceAfter = token.balanceOf(address(node));
        uint256 recipientBalanceAfter = token.balanceOf(recipient);

        assertEq(nodeBalanceAfter, 0);
        assertEq(recipientBalanceAfter, 1000 * 10 ** 18);
    }

    function test_ExecuteAction_PublicExecution() public {
        // Configure token
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            true
        );

        // Execute from different address (simulating public execution)
        uint256 amount = token.balanceOf(address(node));
        vm.prank(executor);
        bool success = node.executeAction(address(token), amount);
        assertTrue(success);

        // Verify it worked
        assertEq(token.balanceOf(recipient), 1000 * 10 ** 18);
    }

    function test_ExecuteAction_BelowMinimumBalance() public {
        // Configure with minimum balance of 100 tokens
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18, // minBalance
            forwardModule.encodeParams(params),
            true
        );

        // Try to execute with amount below minBalance
        vm.expectRevert(abi.encodeWithSelector(Errors.Node_BelowMinimumBalance.selector, 50 * 10 ** 18, 100 * 10 ** 18));
        node.executeAction(address(token), 50 * 10 ** 18); // Only 50 tokens
    }

    function test_ExecuteAction_PartialAmount() public {
        // Configure token
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18, // minBalance
            forwardModule.encodeParams(params),
            true
        );

        // Node has 1000 tokens, execute only 500
        bool success = node.executeAction(address(token), 500 * 10 ** 18);
        assertTrue(success);

        // Verify partial transfer
        assertEq(token.balanceOf(address(node)), 500 * 10 ** 18);
        assertEq(token.balanceOf(recipient), 500 * 10 ** 18);

        // Can execute again with remaining amount
        success = node.executeAction(address(token), 500 * 10 ** 18);
        assertTrue(success);

        assertEq(token.balanceOf(address(node)), 0);
        assertEq(token.balanceOf(recipient), 1000 * 10 ** 18);
    }

    function test_ExecuteAction_InsufficientBalance() public {
        // Configure token
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            true
        );

        // Try to execute more than balance
        vm.expectRevert(abi.encodeWithSelector(Errors.Node_InsufficientBalance.selector, 1000 * 10 ** 18, 10_000 * 10 ** 18));
        node.executeAction(address(token), 10_000 * 10 ** 18); // Node only has 1000
    }

    function test_PreviewExecution() public {
        // No configuration - should revert
        vm.expectRevert(Errors.Node_NoActionConfigured.selector);
        node.previewExecution(address(token));

        // Configure token
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            true
        );

        // Should be able to execute with estimated output
        (uint256 estimatedOutput, address outputToken) = node.previewExecution(address(token));
        assertEq(estimatedOutput, 1000 * 10 ** 18); // Should estimate full balance
        assertEq(outputToken, address(token)); // Forward returns same token
    }

    function test_PreviewExecution_ZeroAddress() public {
        vm.expectRevert(Errors.Node_ZeroTokenAddress.selector);
        node.previewExecution(address(0));
    }

    function test_PreviewExecution_NotEnabled() public {
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        // Configure but disabled
        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            false // disabled
        );

        vm.expectRevert(Errors.Node_TokenNotEnabled.selector);
        node.previewExecution(address(token));
    }

    function test_DisableToken() public {
        // Configure token as enabled
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            true
        );

        // Reconfigure token as disabled
        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            false
        );

        // Should not be able to execute
        uint256 amount = token.balanceOf(address(node));
        vm.expectRevert(Errors.Node_TokenNotEnabled.selector);
        node.executeAction(address(token), amount);

        // Re-enable
        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            true
        );

        // Should work now
        bool success = node.executeAction(address(token), amount);
        assertTrue(success);
    }

    function test_ReconfigureToken() public {
        // Configure token
        DataTypes.ForwardParams memory params = DataTypes.ForwardParams({
            recipient: recipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(params),
            true
        );

        // Reconfigure with new recipient
        address newRecipient = makeAddr("newRecipient");
        DataTypes.ForwardParams memory newParams = DataTypes.ForwardParams({
            recipient: newRecipient,
            requireSuccessfulReceipt: false,
            minAmount: 0
        });

        node.configureToken(
            address(token),
            "FORWARD",
            address(forwardModule),
            100 * 10 ** 18,
            forwardModule.encodeParams(newParams),
            true
        );

        // Execute and verify new recipient gets tokens
        uint256 amount = token.balanceOf(address(node));
        node.executeAction(address(token), amount);
        assertEq(token.balanceOf(newRecipient), 1000 * 10 ** 18);
        assertEq(token.balanceOf(recipient), 0);
    }
}
