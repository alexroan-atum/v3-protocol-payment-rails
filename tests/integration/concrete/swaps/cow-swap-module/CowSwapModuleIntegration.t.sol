// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "../../../../shared/mocks/FeeOnTransferERC20.sol";
import { ReentrantSellToken } from "../../../../shared/mocks/ReentrantSellToken.sol";
import { ReentrantExecuteSellToken } from "../../../../shared/mocks/ReentrantExecuteSellToken.sol";
import {
    ReentrantCancelDuringExecuteSellToken
} from "../../../../shared/mocks/ReentrantCancelDuringExecuteSellToken.sol";
import { MockCowSettlement } from "../../../../shared/mocks/MockCowSettlement.sol";
import { MockPaymentRails } from "../../../../shared/mocks/MockPaymentRails.sol";
import { MockChainlinkAggregator } from "../../../../shared/mocks/MockChainlinkAggregator.sol";

/*//////////////////////////////////////////////////////////////////////////
                    INTEGRATION TEST SUITE
//////////////////////////////////////////////////////////////////////////*/

/// @title CowSwapModuleIntegrationTest
/// @notice Integration tests for CowSwapModule with real PaymentRails, collision guard, reentrancy, and security.
contract CowSwapModuleIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed paymentRails,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed paymentRails, address token, uint256 amount);
    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("integration.test.domain.separator.v1");
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant FAILURE_VALUE = 0xffffffff;

    uint256 internal constant SELL_AMOUNT = 1000e18;
    uint256 internal constant MIN_BUY_AMOUNT = 950e18;
    uint32 internal constant VALIDITY_DURATION = 3600;
    bytes32 internal constant APP_DATA = keccak256("receivables-paymentRails-v1");

    uint16 internal constant SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant MAX_STALENESS = 3600;
    int256 internal constant SELL_PRICE = 1e8;
    int256 internal constant BUY_PRICE = 1e8;
    uint8 internal constant FEED_DECIMALS = 8;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    MockCowSettlement internal cowSettlement;
    MockPaymentRails internal mockPaymentRails;
    PaymentRails internal realPaymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    address internal owner;
    address internal keeper;
    address internal attacker;

    /*//////////////////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.warp(1_700_000_000);

        owner = makeAddr("owner");
        keeper = makeAddr("keeper");
        attacker = makeAddr("attacker");

        cowSettlement = new MockCowSettlement(DOMAIN_SEPARATOR, makeAddr("vaultRelayer"));
        module = new CowSwapModule(address(cowSettlement), address(this));
        mockPaymentRails = new MockPaymentRails(address(module));

        vm.prank(owner);
        realPaymentRails = new PaymentRails(owner);

        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");

        sellFeed = new MockChainlinkAggregator(SELL_PRICE, FEED_DECIMALS);
        buyFeed = new MockChainlinkAggregator(BUY_PRICE, FEED_DECIMALS);

        sellToken.mint(address(mockPaymentRails), SELL_AMOUNT * 20);
        sellToken.mint(address(realPaymentRails), SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 1: NODE.SOL INTEGRATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_PaymentRailsIntegration_Configure_ExecuteAction_LocksTokensInModule() public {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        assertEq(realPaymentRails.getTokenConfig(address(sellToken)).actionModule, address(module));

        vm.prank(keeper);
        bool success = realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertTrue(success);
        assertEq(sellToken.balanceOf(address(realPaymentRails)), SELL_AMOUNT * 10 - SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT);
    }

    function test_PaymentRailsIntegration_ActionExecuted_AmountOut_IsZero_AsyncPendingSignal() public {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        vm.expectEmit(true, true, false, true, address(realPaymentRails));
        emit ActionExecuted(address(sellToken), "COWSWAP", SELL_AMOUNT, 0, address(buyToken), keeper);

        vm.prank(keeper);
        realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);
    }

    function test_PaymentRailsIntegration_PreviewExecution_ReturnsOracleExpectedOutput() public {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        (uint256 estimated, address outputToken) = realPaymentRails.previewExecution(address(sellToken));

        assertEq(estimated, SELL_AMOUNT * 10); // oracle expected output at 1:1 prices (full PaymentRails balance)
        assertEq(outputToken, address(buyToken));
    }

    function test_PaymentRailsIntegration_OrderId_AvailableOnly_FromOrderCreatedEvent() public {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        vm.recordLogs();
        vm.prank(keeper);
        realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        bytes32 orderId = _parseOrderCreatedId(vm.getRecordedLogs());
        assertTrue(orderId != bytes32(0), "orderId must be non-zero");

        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(realPaymentRails));
        assertEq(meta.sellToken, address(sellToken));
        assertEq(meta.buyToken, address(buyToken));
        assertFalse(meta.cancelled, "Order must not be cancelled");
    }

    function test_PaymentRailsIntegration_FullLifecycle_Execute_SolverFills_BuyTokenAtPaymentRails() public {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        vm.recordLogs();
        vm.prank(keeper);
        realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);
        bytes32 orderId = _parseOrderCreatedId(vm.getRecordedLogs());

        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), MAGIC_VALUE);

        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);
        buyToken.mint(address(realPaymentRails), MIN_BUY_AMOUNT + 10e18);
        cowSettlement.setFilledAmount(orderId, SELL_AMOUNT);

        assertEq(buyToken.balanceOf(address(realPaymentRails)), MIN_BUY_AMOUNT + 10e18);
        assertEq(buyToken.balanceOf(address(module)), 0);
        assertEq(sellToken.balanceOf(address(module)), 0);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertEq(cowSettlement.filledAmountByDigest(orderId), SELL_AMOUNT);
        assertFalse(module.getOrder(orderId).cancelled);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 2: ORDER ID COLLISION GUARD
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fix_M3_CollisionGuard_SecondCallRejected() public {
        bytes32 orderId1 = _initiateOrder();

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params);

        assertFalse(result.success, "second identical call is rejected");
        assertEq(result.failureReason, "Order ID collision: use unique appData");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT, "only 1x tokens locked");
        assertFalse(module.getOrder(orderId1).cancelled);
    }

    function test_Fix_M3_DifferentAppData_BothOrdersSucceed() public {
        bytes32 orderId1 = _initiateOrder(); // appData = APP_DATA

        bytes memory params2 = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, keccak256("different"));
        DataTypes.ExecutionResult memory r2 = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params2);
        assertTrue(r2.success, "Different appData -> different orderId -> no collision");
        bytes32 orderId2 = abi.decode(r2.data, (bytes32));

        assertTrue(orderId1 != orderId2, "Different appData -> different orderId");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2, "Both deposits landed");
    }

    function test_Fix_H1_TwoOrdersSameToken_MaxApprovalSetOnce() public {
        bytes32 orderId1 = _initiateOrder();

        assertEq(
            sellToken.allowance(address(module), module.vaultRelayer()),
            type(uint256).max,
            "Max approval set after first order"
        );

        bytes memory params2 = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, keccak256("order-2"));
        DataTypes.ExecutionResult memory r2 = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params2);
        assertTrue(r2.success);

        assertEq(
            sellToken.allowance(address(module), module.vaultRelayer()),
            type(uint256).max,
            "Max approval unchanged after second order"
        );

        cowSettlement.setFilledAmount(orderId1, SELL_AMOUNT);
        assertEq(
            sellToken.allowance(address(module), module.vaultRelayer()),
            type(uint256).max,
            "Max approval unchanged after order1 filled"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 3: TWO CONCURRENT ORDERS SAME SELL TOKEN
    //////////////////////////////////////////////////////////////////////////*/

    function test_Fix_H3_TwoConcurrentOrders_SameSellToken_CancelIsIsolated() public {
        MockPaymentRails paymentRails2 = new MockPaymentRails(address(module));
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        bytes32 orderA = _initiateOrder();

        vm.warp(block.timestamp + 1);
        DataTypes.ExecutionResult memory r2 = paymentRails2.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        bytes32 orderB = abi.decode(r2.data, (bytes32));

        assertTrue(orderA != orderB, "Different timestamps -> different orderIds");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2);

        uint256 node1Before = sellToken.balanceOf(address(mockPaymentRails));
        module.cancelOrder(orderA);

        assertEq(sellToken.balanceOf(address(mockPaymentRails)), node1Before + SELL_AMOUNT, "A gets exactly 1x");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT, "B's tokens intact");

        uint256 paymentRails2Before = sellToken.balanceOf(address(paymentRails2));
        module.cancelOrder(orderB);

        assertEq(sellToken.balanceOf(address(paymentRails2)), paymentRails2Before + SELL_AMOUNT, "B gets exactly 1x");
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    function test_Fix_H3_TwoConcurrentOrders_FillOneLeaveOtherIntact() public {
        MockPaymentRails paymentRails2 = new MockPaymentRails(address(module));
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        bytes32 orderA = _initiateOrder();
        vm.warp(block.timestamp + 1);
        DataTypes.ExecutionResult memory r2 = paymentRails2.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        bytes32 orderB = abi.decode(r2.data, (bytes32));

        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2);

        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);

        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT);

        cowSettlement.setFilledAmount(orderA, SELL_AMOUNT);
        assertEq(cowSettlement.filledAmountByDigest(orderA), SELL_AMOUNT);
        assertFalse(module.getOrder(orderA).cancelled);

        uint256 paymentRails2Before = sellToken.balanceOf(address(paymentRails2));
        module.cancelOrder(orderB);

        assertEq(sellToken.balanceOf(address(paymentRails2)), paymentRails2Before + SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 4: FEE-ON-TRANSFER SELL TOKEN LIMITATIONS
    //////////////////////////////////////////////////////////////////////////*/

    function test_FOT_SellToken_ModuleReceivesLessThanAmount_BalanceMismatch() public {
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20();
        fotToken.mint(address(mockPaymentRails), SELL_AMOUNT * 2);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(fotToken), SELL_AMOUNT, params);

        assertTrue(result.success);

        uint256 fee = (SELL_AMOUNT * 100) / 10_000; // 1%
        uint256 actualInModule = fotToken.balanceOf(address(module));

        assertEq(actualInModule, SELL_AMOUNT - fee, "Module received less due to transfer fee");

        uint256 approval = fotToken.allowance(address(module), module.vaultRelayer());
        assertGt(approval, actualInModule, "Approval > actual balance");

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.sellAmount, SELL_AMOUNT);
        assertGt(meta.sellAmount, actualInModule);
    }

    function test_FOT_SellToken_Solver_CanOnlyPull_ActualBalance_NotFullSellAmount() public {
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20();
        fotToken.mint(address(mockPaymentRails), SELL_AMOUNT * 2);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);
        mockPaymentRails.initiateSwap(address(fotToken), SELL_AMOUNT, params);

        uint256 actualBalance = fotToken.balanceOf(address(module));

        vm.prank(module.vaultRelayer());
        vm.expectRevert();
        fotToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);

        vm.prank(module.vaultRelayer());
        fotToken.transferFrom(address(module), address(cowSettlement), actualBalance);
        assertEq(fotToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 5: CEI REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_CEI_ReentrantSellToken_CancelOrder_DoesNotDoubleDrain() public {
        ReentrantSellToken reentrantToken = new ReentrantSellToken(address(module), address(this));
        sellToken.mint(address(this), SELL_AMOUNT); // unrelated — just for setUp

        // Set up an order with the reentrant sellToken
        reentrantToken.mint(address(mockPaymentRails), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        // mockPaymentRails needs to approve the reentrant token
        vm.prank(address(mockPaymentRails));
        reentrantToken.approve(address(module), SELL_AMOUNT);

        // Directly call execute from mockPaymentRails context
        vm.prank(address(mockPaymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(reentrantToken), SELL_AMOUNT, params);
        bytes32 orderId = abi.decode(result.data, (bytes32));

        reentrantToken.setTargetOrder(orderId);

        uint256 nodeBalBefore = reentrantToken.balanceOf(address(mockPaymentRails));
        module.cancelOrder(orderId);

        assertFalse(reentrantToken.doubleClaimSucceeded(), "CEI: double-drain must not succeed");
        assertEq(reentrantToken.balanceOf(address(mockPaymentRails)), nodeBalBefore + SELL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 5b: CEI + REENTRANCY GUARD IN execute()
    //////////////////////////////////////////////////////////////////////////*/

    function test_CEI_ReentrantSellToken_Execute_BlockedByReentrancyGuard() public {
        ReentrantExecuteSellToken reentrantToken = new ReentrantExecuteSellToken(address(module));
        reentrantToken.mint(address(mockPaymentRails), SELL_AMOUNT);
        // Fund the reentrant token contract itself (it becomes msg.sender in the reentrant call)
        reentrantToken.mint(address(reentrantToken), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        reentrantToken.setReentryConfig(SELL_AMOUNT, params);

        vm.prank(address(mockPaymentRails));
        reentrantToken.approve(address(module), SELL_AMOUNT);

        vm.prank(address(mockPaymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(reentrantToken), SELL_AMOUNT, params);

        assertTrue(result.success, "outer execute must succeed");
        assertTrue(reentrantToken.reentryAttempted(), "hook must have fired");
        assertTrue(reentrantToken.reentrancyBlocked(), "reentrant execute must be blocked by nonReentrant");
        assertEq(reentrantToken.balanceOf(address(module)), SELL_AMOUNT, "module holds exactly 1x");

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(mockPaymentRails));
        assertEq(meta.sellAmount, SELL_AMOUNT);
        assertFalse(meta.cancelled);
    }

    function test_CEI_ReentrantSellToken_Execute_FullLifecycle_ExecuteCancelRecover() public {
        ReentrantExecuteSellToken reentrantToken = new ReentrantExecuteSellToken(address(module));
        reentrantToken.mint(address(mockPaymentRails), SELL_AMOUNT * 2);
        reentrantToken.mint(address(reentrantToken), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);
        reentrantToken.setReentryConfig(SELL_AMOUNT, params);

        vm.prank(address(mockPaymentRails));
        reentrantToken.approve(address(module), SELL_AMOUNT);

        vm.prank(address(mockPaymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(reentrantToken), SELL_AMOUNT, params);

        assertTrue(result.success);
        bytes32 orderId = abi.decode(result.data, (bytes32));

        // isValidSignature validates the order
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), MAGIC_VALUE);

        // Cancel recovers tokens cleanly
        uint256 nodeBalBefore = reentrantToken.balanceOf(address(mockPaymentRails));
        module.cancelOrder(orderId);

        assertTrue(module.getOrder(orderId).cancelled);
        assertEq(reentrantToken.balanceOf(address(module)), 0, "module drained after cancel");
        assertEq(reentrantToken.balanceOf(address(mockPaymentRails)), nodeBalBefore + SELL_AMOUNT);

        // isValidSignature rejects after cancel
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), FAILURE_VALUE);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 5c: CROSS-FUNCTION REENTRANCY (execute → cancelOrder)
            During execute()'s transferFrom, a hook-enabled token calls cancelOrder()
            on a pre-existing order. The shared ReentrancyGuard lock blocks it.
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Cross-function reentrancy: during execute(), hook calls cancelOrder() on a
    ///      different pre-existing order. The shared nonReentrant lock blocks it.
    ///      The pre-existing order remains pending and its tokens are untouched.
    function test_CEI_CrossFunctionReentrancy_CancelOrderBlockedDuringExecute() public {
        // Step 1: create a pre-existing order with normal sellToken
        bytes32 existingOrderId = _initiateOrder();
        assertFalse(module.getOrder(existingOrderId).cancelled, "pre-existing order is pending");

        // Step 2: set up the cross-function reentrant token
        ReentrantCancelDuringExecuteSellToken crossToken = new ReentrantCancelDuringExecuteSellToken(address(module));
        crossToken.mint(address(mockPaymentRails), SELL_AMOUNT);

        crossToken.setReentryConfig(existingOrderId);

        bytes memory params =
            _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, keccak256("cross-func-integ"));

        vm.prank(address(mockPaymentRails));
        crossToken.approve(address(module), SELL_AMOUNT);

        vm.prank(address(mockPaymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(crossToken), SELL_AMOUNT, params);

        assertTrue(result.success, "outer execute must succeed");
        assertTrue(crossToken.reentryAttempted(), "hook must have fired");
        assertTrue(crossToken.cancelBlocked(), "cross-function cancelOrder must be blocked");
        assertFalse(module.getOrder(existingOrderId).cancelled, "pre-existing order must remain pending");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT, "pre-existing order tokens intact");

        bytes32 newOrderId = abi.decode(result.data, (bytes32));
        assertFalse(module.getOrder(newOrderId).cancelled);
        assertEq(crossToken.balanceOf(address(module)), SELL_AMOUNT, "new order tokens in module");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 6: SECURITY — ACCESS CONTROL AND GRIEFING
    //////////////////////////////////////////////////////////////////////////*/

    function test_Security_DirectExecute_ByAnyone_CallerOwnsOrder() public {
        sellToken.mint(attacker, SELL_AMOUNT);

        vm.startPrank(attacker);
        sellToken.approve(address(module), SELL_AMOUNT);
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), SELL_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        bytes32 orderId = abi.decode(result.data, (bytes32));

        assertEq(module.getOrder(orderId).paymentRails, attacker);

        // Only the module owner can cancel — attacker cannot
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.cancelOrder(orderId);

        // Cancel returns tokens to meta.paymentRails (the attacker)
        module.cancelOrder(orderId);
        assertEq(sellToken.balanceOf(attacker), SELL_AMOUNT);
    }

    /// @dev receiver=paymentRails means different callers produce different orderIds even with identical params.
    function test_Security_Frontrunning_DifferentSenders_ProduceDifferentOrderIds_NoCollision() public {
        sellToken.mint(attacker, SELL_AMOUNT);
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);

        vm.startPrank(attacker);
        sellToken.approve(address(module), SELL_AMOUNT);
        DataTypes.ExecutionResult memory attackResult = module.execute(address(sellToken), SELL_AMOUNT, params);
        vm.stopPrank();
        bytes32 attackerOrderId = abi.decode(attackResult.data, (bytes32));

        bytes32 nodeOrderId = _initiateOrder();

        assertTrue(attackerOrderId != nodeOrderId, "Different senders -> different receiver -> different orderId");

        assertEq(module.getOrder(attackerOrderId).paymentRails, attacker, "Attacker owns their order");
        assertEq(
            module.getOrder(nodeOrderId).paymentRails, address(mockPaymentRails), "mockPaymentRails owns their order"
        );

        assertFalse(module.getOrder(attackerOrderId).cancelled, "Attacker order not cancelled");
        assertFalse(module.getOrder(nodeOrderId).cancelled, "PaymentRails order not cancelled");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2);

        uint256 nodeBalBefore = sellToken.balanceOf(address(mockPaymentRails));
        module.cancelOrder(nodeOrderId);
        assertEq(
            sellToken.balanceOf(address(mockPaymentRails)),
            nodeBalBefore + SELL_AMOUNT,
            "mockPaymentRails gets exactly 1x"
        );
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT, "Attacker's order untouched");

        uint256 attackerBalBefore = sellToken.balanceOf(attacker);
        module.cancelOrder(attackerOrderId);
        assertEq(sellToken.balanceOf(attacker), attackerBalBefore + SELL_AMOUNT, "Attacker gets exactly 1x");
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    function test_Security_CancelOrder_BlockedWhenOrderAlreadyFilled() public {
        bytes32 orderId = _initiateOrder();

        cowSettlement.setFilledAmount(orderId, SELL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, orderId));
        module.cancelOrder(orderId);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 7: EDGE CASES
    //////////////////////////////////////////////////////////////////////////*/

    function test_EdgeCase_DifferentSellTokens_DistinctOrderIds() public {
        MockERC20 daiToken = new MockERC20("DAI", "DAI");
        daiToken.mint(address(mockPaymentRails), SELL_AMOUNT);

        bytes32 orderA = _initiateOrder(); // USDC → WETH
        bytes32 orderB = _initiateOrderWith(address(daiToken), address(buyToken), SELL_AMOUNT, SLIPPAGE_BPS);

        assertTrue(orderA != orderB, "Different sellTokens must produce distinct orderIds");
    }

    function test_EdgeCase_DifferentTimestamps_DistinctOrderIds() public {
        bytes32 orderId1 = _initiateOrder();
        vm.warp(block.timestamp + 1); // advance 1 second
        bytes32 orderId2 = _initiateOrder();

        assertTrue(orderId1 != orderId2, "Different timestamps = different validTo = different orderId");
    }

    /// @dev M-1 fix: overflow validityDuration rejected gracefully, no tokens locked.
    function test_EdgeCase_M1Fix_MaxValidityDuration_RejectedGracefully() public {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, type(uint32).max, APP_DATA);

        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        assertFalse(result.success, "overflow validity is rejected");
        assertEq(result.failureReason, "Validity duration overflow");
        assertEq(sellToken.balanceOf(address(module)), 0, "no tokens locked on overflow failure");

        bytes4 sig = module.isValidSignature(bytes32(0), abi.encode(bytes32(0)));
        assertTrue(sig == MAGIC_VALUE || sig == FAILURE_VALUE, "isValidSignature never reverts");
    }

    /// @dev Max approval persists after fill — safe because module holds 0 sellToken.
    function test_EdgeCase_AfterSolverFills_MaxApprovalRemains() public {
        bytes32 orderId = _initiateOrder();

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);
        cowSettlement.setFilledAmount(orderId, SELL_AMOUNT);

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /// @dev Max approval persists after cancel — safe because module holds 0 sellToken.
    function test_EdgeCase_AfterCancelOrder_MaxApprovalRemains() public {
        bytes32 orderId = _initiateOrder();

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        module.cancelOrder(orderId);

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(
        address targetToken,
        uint16 maxSlippageBps,
        uint32 validityDuration,
        bytes32 appData
    )
        internal
        view
        returns (bytes memory)
    {
        return module.encodeParams(
            DataTypes.CowSwapParams({
                targetToken: targetToken,
                maxSlippageBps: maxSlippageBps,
                sellTokenPriceFeed: address(sellFeed),
                buyTokenPriceFeed: address(buyFeed),
                maxStaleness: MAX_STALENESS,
                validityDuration: validityDuration,
                appData: appData
            })
        );
    }

    function _initiateOrder() internal returns (bytes32 orderId) {
        bytes memory params = _buildParams(address(buyToken), SLIPPAGE_BPS, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        return abi.decode(result.data, (bytes32));
    }

    function _initiateOrderWith(
        address _sellToken,
        address _buyToken,
        uint256 _sellAmount,
        uint16 _maxSlippageBps
    )
        internal
        returns (bytes32 orderId)
    {
        bytes memory params = _buildParams(_buyToken, _maxSlippageBps, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(_sellToken, _sellAmount, params);
        return abi.decode(result.data, (bytes32));
    }

    function _parseOrderCreatedId(Vm.Log[] memory logs) internal view returns (bytes32 orderId) {
        bytes32 eventSig = keccak256("OrderCreated(bytes32,address,address,address,uint256,uint256,uint32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(module) && logs[i].topics[0] == eventSig) {
                return logs[i].topics[1]; // orderId is topic[1] (first indexed)
            }
        }
        revert("OrderCreated event not found in recorded logs");
    }
}
