// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "../../../../shared/mocks/FeeOnTransferERC20.sol";
import { ReentrantSellToken } from "../../../../shared/mocks/ReentrantSellToken.sol";
import { MockCowSettlement } from "../../../../shared/mocks/MockCowSettlement.sol";
import { MockPaymentRails } from "../../../../shared/mocks/MockPaymentRails.sol";

/*//////////////////////////////////////////////////////////////////////////
                    INTEGRATION TEST SUITE
//////////////////////////////////////////////////////////////////////////*/

/// @title CowSwapModuleIntegrationTest
/// @notice Integration tests covering:
///   - Real PaymentRails.sol integration (configure, executeAction, events)
///   - Order ID collision (same params same block → orphaned sellToken)
///   - cancelOrder caps return at meta.sellAmount (two concurrent orders)
///   - Fee-on-transfer sell token limitations
///   - CEI reentrancy protection in cancelOrder
///   - Security: access control, frontrunning griefing
///   - Edge cases: expiry, overflow guard, approval hygiene
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
        uint256 minBuyAmount,
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

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    MockCowSettlement internal cowSettlement;
    MockPaymentRails internal mockPaymentRails;
    PaymentRails internal realPaymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal owner;
    address internal keeper;
    address internal attacker;

    /*//////////////////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
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

        sellToken.mint(address(mockPaymentRails), SELL_AMOUNT * 20);
        sellToken.mint(address(realPaymentRails), SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 1: NODE.SOL INTEGRATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Real PaymentRails.sol: configure → executeAction → tokens locked in module
    function test_PaymentRailsIntegration_Configure_ExecuteAction_LocksTokensInModule() public {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        assertEq(realPaymentRails.getTokenConfig(address(sellToken)).actionModule, address(module));

        vm.prank(keeper);
        bool success = realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertTrue(success);
        assertEq(sellToken.balanceOf(address(realPaymentRails)), SELL_AMOUNT * 10 - SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT);
    }

    /// @dev ActionExecuted event from PaymentRails reports amountOut=0 — the async pending signal.
    ///      This is expected: actual output is unknown until CowSwap settles.
    function test_PaymentRailsIntegration_ActionExecuted_AmountOut_IsZero_AsyncPendingSignal() public {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        // ActionExecuted must emit with amountOut=0 (async signal — settlement not yet happened)
        vm.expectEmit(true, true, false, true, address(realPaymentRails));
        emit ActionExecuted(address(sellToken), "COWSWAP", SELL_AMOUNT, 0, address(buyToken), keeper);

        vm.prank(keeper);
        realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);
    }

    /// @dev previewExecution returns minBuyAmount as the safe lower-bound estimate.
    function test_PaymentRailsIntegration_PreviewExecution_ReturnsMinBuyAmount() public {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        (uint256 estimated, address outputToken) = realPaymentRails.previewExecution(address(sellToken));

        assertEq(estimated, MIN_BUY_AMOUNT);
        assertEq(outputToken, address(buyToken));
    }

    /// @dev orderId is only accessible via the module's OrderCreated event, not from executeAction().
    function test_PaymentRailsIntegration_OrderId_AvailableOnly_FromOrderCreatedEvent() public {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

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

    /// @dev Full lifecycle through real PaymentRails: configure → executeAction → solver fills →
    ///      buyToken goes directly to PaymentRails via receiver=paymentRails. No further call needed.
    function test_PaymentRailsIntegration_FullLifecycle_Execute_SolverFills_BuyTokenAtPaymentRails() public {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        vm.prank(owner);
        realPaymentRails.configureToken(address(sellToken), "COWSWAP", address(module), 0, params, true);

        // Step 1: Keeper triggers execution via PaymentRails
        vm.recordLogs();
        vm.prank(keeper);
        realPaymentRails.executeAction(address(sellToken), SELL_AMOUNT);
        bytes32 orderId = _parseOrderCreatedId(vm.getRecordedLogs());

        // Step 2: EIP-1271 validates order
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), MAGIC_VALUE);

        // Step 3: CowSwap solver settles:
        //   a) Solver pulls sellToken from module via max approval
        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);
        //   b) buyToken goes DIRECTLY to realPaymentRails (receiver=paymentRails in GPv2Order) — no staging
        buyToken.mint(address(realPaymentRails), MIN_BUY_AMOUNT + 10e18);
        //   c) GPv2Settlement records the fill
        cowSettlement.setFilledAmount(orderId, SELL_AMOUNT);

        // Step 4: PaymentRails already has buyToken — no further call needed
        assertEq(buyToken.balanceOf(address(realPaymentRails)), MIN_BUY_AMOUNT + 10e18);
        assertEq(buyToken.balanceOf(address(module)), 0, "buyToken never staged in module");
        assertEq(sellToken.balanceOf(address(module)), 0, "sellToken pulled by solver");

        // Max approval persists — module holds 0 sellToken so CowSwap cannot over-pull
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        // Settled state: filledAmounts confirms fill; module metadata still exists (cancelled=false)
        assertEq(cowSettlement.filledAmountByDigest(orderId), SELL_AMOUNT);
        assertFalse(module.getOrder(orderId).cancelled, "Order was settled, not cancelled");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 2: ORDER ID COLLISION GUARD
            Identical params in the same block produce the same GPv2Order digest.
            Second execute() with same digest is rejected — first order protected.
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Second call with identical params returns failure; first order is safe.
    function test_Fix_M3_CollisionGuard_SecondCallRejected() public {
        bytes32 orderId1 = _initiateOrder();

        // Same params, same block → same orderId → collision guard rejects
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params);

        assertFalse(result.success, "second identical call is rejected");
        assertEq(result.failureReason, "Order ID collision: use unique appData");
        // Module holds only 1x — second transfer never happened
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT, "only 1x tokens locked");
        // First order is still pending and untouched
        assertFalse(module.getOrder(orderId1).cancelled, "First order must not be cancelled");
    }

    /// @dev Different appData in the same block produces a different orderId — both succeed.
    function test_Fix_M3_DifferentAppData_BothOrdersSucceed() public {
        bytes32 orderId1 = _initiateOrder(); // appData = APP_DATA

        bytes memory params2 =
            _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, keccak256("different"));
        DataTypes.ExecutionResult memory r2 = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params2);
        assertTrue(r2.success, "Different appData -> different orderId -> no collision");
        bytes32 orderId2 = abi.decode(r2.data, (bytes32));

        assertTrue(orderId1 != orderId2, "Different appData -> different orderId");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2, "Both deposits landed");
    }

    /// @dev Two successful orders both succeed; max approval set once and never changed.
    function test_Fix_H1_TwoOrdersSameToken_MaxApprovalSetOnce() public {
        bytes32 orderId1 = _initiateOrder();

        // First execute sets max approval
        assertEq(
            sellToken.allowance(address(module), module.vaultRelayer()),
            type(uint256).max,
            "Max approval set after first order"
        );

        bytes memory params2 = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, keccak256("order-2"));
        DataTypes.ExecutionResult memory r2 = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params2);
        assertTrue(r2.success);

        // Second execute: approval unchanged (already at max — condition skips forceApprove)
        assertEq(
            sellToken.allowance(address(module), module.vaultRelayer()),
            type(uint256).max,
            "Max approval unchanged after second order"
        );

        // Solver fills order1 — approval still max (GPv2Settlement doesn't decrement max allowances)
        cowSettlement.setFilledAmount(orderId1, SELL_AMOUNT);
        assertEq(
            sellToken.allowance(address(module), module.vaultRelayer()),
            type(uint256).max,
            "Max approval unchanged after order1 filled"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 3: TWO CONCURRENT ORDERS SAME SELL TOKEN
            cancelOrder is capped at meta.sellAmount, each cancel is safe.
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Two concurrent PENDING orders from different nodes sharing the same sellToken.
    ///      Cancelling the first order returns exactly SELL_AMOUNT (not 2x).
    ///      The second order's tokens remain available for its own cancel.
    function test_Fix_H3_TwoConcurrentOrders_SameSellToken_CancelIsIsolated() public {
        MockPaymentRails paymentRails2 = new MockPaymentRails(address(module));
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        // Order A: from mockPaymentRails
        bytes32 orderA = _initiateOrder();

        // Order B: from paymentRails2 (different timestamp → different orderId)
        vm.warp(block.timestamp + 1);
        DataTypes.ExecutionResult memory r2 = paymentRails2.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        bytes32 orderB = abi.decode(r2.data, (bytes32));

        assertTrue(orderA != orderB, "Different timestamps -> different orderIds");

        // Module holds 2x SELL_AMOUNT
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2);

        // Cancel order A — must return exactly 1x, leaving 1x for order B
        uint256 node1Before = sellToken.balanceOf(address(mockPaymentRails));
        module.cancelOrder(orderA);

        assertEq(sellToken.balanceOf(address(mockPaymentRails)), node1Before + SELL_AMOUNT, "A gets exactly 1x");
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT, "B's tokens intact");

        // Cancel order B — returns exactly 1x to paymentRails2
        uint256 paymentRails2Before = sellToken.balanceOf(address(paymentRails2));
        module.cancelOrder(orderB);

        assertEq(sellToken.balanceOf(address(paymentRails2)), paymentRails2Before + SELL_AMOUNT, "B gets exactly 1x");
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /// @dev If solver fills order A while order B is pending (same sellToken),
    ///      order B's tokens are protected — markFilled for A does not transfer sellToken.
    function test_Fix_H3_TwoConcurrentOrders_FillOneLeaveOtherIntact() public {
        MockPaymentRails paymentRails2 = new MockPaymentRails(address(module));
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        bytes32 orderA = _initiateOrder();
        vm.warp(block.timestamp + 1);
        DataTypes.ExecutionResult memory r2 = paymentRails2.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        bytes32 orderB = abi.decode(r2.data, (bytes32));

        // Module holds 2x
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2);

        // Solver A fills order A — pulls sellToken from module
        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);

        // Module still holds order B's tokens
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT);

        // Record fill in GPv2Settlement (solver already pulled tokens above)
        cowSettlement.setFilledAmount(orderA, SELL_AMOUNT);

        // Order A is now settled: filledAmounts confirms it, metadata still exists (cancelled=false)
        assertEq(cowSettlement.filledAmountByDigest(orderA), SELL_AMOUNT, "Order A settled in CowSwap");
        assertFalse(module.getOrder(orderA).cancelled, "Order A settled, not cancelled");

        // Order B can still be cancelled — its tokens are untouched
        uint256 paymentRails2Before = sellToken.balanceOf(address(paymentRails2));
        module.cancelOrder(orderB);

        assertEq(sellToken.balanceOf(address(paymentRails2)), paymentRails2Before + SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 4: FEE-ON-TRANSFER SELL TOKEN LIMITATIONS
            execute() reports success, but the module receives less than `amount`.
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev FOT LIMITATION: Module receives less than `amount` due to transfer fee.
    ///      execute() still returns success — the balance check passes (paymentRails held enough).
    ///      But order metadata records the full (inflated) sellAmount.
    function test_FOT_SellToken_ModuleReceivesLessThanAmount_BalanceMismatch() public {
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20();
        fotToken.mint(address(mockPaymentRails), SELL_AMOUNT * 2);

        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(fotToken), SELL_AMOUNT, params);

        // execute() returns success (balance check passed before fee deduction)
        assertTrue(result.success);

        uint256 fee = (SELL_AMOUNT * 100) / 10_000; // 1%
        uint256 actualInModule = fotToken.balanceOf(address(module));

        assertEq(actualInModule, SELL_AMOUNT - fee, "Module received less due to transfer fee");

        // MISMATCH: approval set to full SELL_AMOUNT, but module holds only (amount - fee)
        uint256 approval = fotToken.allowance(address(module), module.vaultRelayer());
        assertGt(approval, actualInModule, "Approval > actual balance: solver approval mismatch");

        // Order metadata records full SELL_AMOUNT — overstates actual sellable balance
        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.sellAmount, SELL_AMOUNT, "Metadata overstates sellAmount");
        assertGt(meta.sellAmount, actualInModule, "Metadata sellAmount > actual tokens held");
    }

    /// @dev FOT LIMITATION: Solver can only pull actualModuleBalance (< stated sellAmount).
    ///      The GPv2Order digest includes the full sellAmount, but the module can only settle
    ///      a smaller fill — the order will be rejected or partially filled by CowSwap.
    function test_FOT_SellToken_Solver_CanOnlyPull_ActualBalance_NotFullSellAmount() public {
        FeeOnTransferERC20 fotToken = new FeeOnTransferERC20();
        fotToken.mint(address(mockPaymentRails), SELL_AMOUNT * 2);

        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);
        mockPaymentRails.initiateSwap(address(fotToken), SELL_AMOUNT, params);

        uint256 actualBalance = fotToken.balanceOf(address(module)); // SELL_AMOUNT - fee

        // Solver attempting to pull the full SELL_AMOUNT will revert (insufficient balance)
        vm.prank(module.vaultRelayer());
        vm.expectRevert(); // ERC20 insufficient balance
        fotToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);

        // Solver can only pull the actual module balance (less than stated in order)
        vm.prank(module.vaultRelayer());
        fotToken.transferFrom(address(module), address(cowSettlement), actualBalance);
        assertEq(fotToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 5: CEI REENTRANCY PROTECTION
            Checks-Effects-Interactions: status is set to CANCELLED before sellToken
            transfer in cancelOrder(). A reentrant call finds CANCELLED and reverts.
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev CEI protection in cancelOrder: outer cancel succeeds, reentrant inner call
    ///      finds status=CANCELLED (set before transfer) and silently fails.
    ///      PaymentRails receives tokens exactly once — no double-drain.
    function test_CEI_ReentrantSellToken_CancelOrder_DoesNotDoubleDrain() public {
        ReentrantSellToken reentrantToken = new ReentrantSellToken(address(module), address(this));
        sellToken.mint(address(this), SELL_AMOUNT); // unrelated — just for setUp

        // Set up an order with the reentrant sellToken
        reentrantToken.mint(address(mockPaymentRails), SELL_AMOUNT);

        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        // mockPaymentRails needs to approve the reentrant token
        vm.prank(address(mockPaymentRails));
        reentrantToken.approve(address(module), SELL_AMOUNT);

        // Directly call execute from mockPaymentRails context
        vm.prank(address(mockPaymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(reentrantToken), SELL_AMOUNT, params, "");
        bytes32 orderId = abi.decode(result.data, (bytes32));

        reentrantToken.setTargetOrder(orderId);

        uint256 nodeBalBefore = reentrantToken.balanceOf(address(mockPaymentRails));

        // Outer cancelOrder succeeds (module owner = address(this))
        module.cancelOrder(orderId);

        // CEI protection: inner reentrant cancel FAILED (status=CANCELLED before transfer fired)
        assertFalse(reentrantToken.doubleClaimSucceeded(), "CEI: double-drain must not succeed");

        // PaymentRails received tokens exactly once
        assertEq(reentrantToken.balanceOf(address(mockPaymentRails)), nodeBalBefore + SELL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 6: SECURITY — ACCESS CONTROL AND GRIEFING
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Anyone can call module.execute() directly without going through PaymentRails.
    ///      The caller becomes meta.paymentRails and owns the resulting order.
    function test_Security_DirectExecute_ByAnyone_CallerOwnsOrder() public {
        sellToken.mint(attacker, SELL_AMOUNT);

        vm.startPrank(attacker);
        sellToken.approve(address(module), SELL_AMOUNT);
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = module.execute(address(sellToken), SELL_AMOUNT, params, "");
        vm.stopPrank();

        assertTrue(result.success);
        bytes32 orderId = abi.decode(result.data, (bytes32));

        // Attacker is recorded as meta.paymentRails (token beneficiary for any future cancel)
        assertEq(module.getOrder(orderId).paymentRails, attacker);

        // Attacker CANNOT cancel — only the module owner (address(this)) can cancel
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_NotOwner.selector, attacker, address(this)));
        module.cancelOrder(orderId);

        // Module owner cancels — sell tokens return to meta.paymentRails (the attacker)
        module.cancelOrder(orderId);
        assertEq(sellToken.balanceOf(attacker), SELL_AMOUNT);
    }

    /// @dev SECURITY IMPROVEMENT: With receiver=paymentRails design, frontrunners cannot collide with
    ///      legitimate orders. Each caller is recorded as receiver (meta.paymentRails) in the GPv2Order
    ///      digest — so attacker's orderId differs from mockPaymentRails's orderId even with identical
    ///      params in the same block. The collision only occurs when the SAME sender
    ///      calls execute() twice with the same params.
    function test_Security_Frontrunning_DifferentSenders_ProduceDifferentOrderIds_NoCollision() public {
        sellToken.mint(attacker, SELL_AMOUNT);
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);

        // Attacker frontruns: calls execute() before mockPaymentRails in the same block
        vm.startPrank(attacker);
        sellToken.approve(address(module), SELL_AMOUNT);
        DataTypes.ExecutionResult memory attackResult = module.execute(address(sellToken), SELL_AMOUNT, params, "");
        vm.stopPrank();
        bytes32 attackerOrderId = abi.decode(attackResult.data, (bytes32));

        // mockPaymentRails executes with same params in the same block
        bytes32 nodeOrderId = _initiateOrder();

        // SECURITY FIX: receiver=paymentRails means different senders produce different orderIds
        // Attacker's order has receiver=attacker; mockPaymentRails's order has receiver=mockPaymentRails
        assertTrue(attackerOrderId != nodeOrderId, "Different senders -> different receiver -> different orderId");

        // Both orders are independent — no collision, no metadata overwrite
        assertEq(module.getOrder(attackerOrderId).paymentRails, attacker, "Attacker owns their order");
        assertEq(
            module.getOrder(nodeOrderId).paymentRails, address(mockPaymentRails), "mockPaymentRails owns their order"
        );

        // Both are pending and each can be cancelled independently
        assertFalse(module.getOrder(attackerOrderId).cancelled, "Attacker order not cancelled");
        assertFalse(module.getOrder(nodeOrderId).cancelled, "PaymentRails order not cancelled");

        // Module holds 2x but they are properly attributed to separate orders
        assertEq(sellToken.balanceOf(address(module)), SELL_AMOUNT * 2);

        // Owner can cancel both orders independently (each returns exactly 1x)
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

    /// @dev cancelOrder is blocked if GPv2Settlement confirms the order was already filled.
    function test_Security_CancelOrder_BlockedWhenOrderAlreadyFilled() public {
        bytes32 orderId = _initiateOrder();

        // Simulate: solver filled the order
        cowSettlement.setFilledAmount(orderId, SELL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, orderId));
        module.cancelOrder(orderId);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 7: EDGE CASES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Two orders with different sell tokens produce distinct orderIds.
    function test_EdgeCase_DifferentSellTokens_DistinctOrderIds() public {
        MockERC20 daiToken = new MockERC20("DAI", "DAI");
        daiToken.mint(address(mockPaymentRails), SELL_AMOUNT);

        bytes32 orderA = _initiateOrder(); // USDC → WETH
        bytes32 orderB = _initiateOrderWith(address(daiToken), address(buyToken), SELL_AMOUNT, MIN_BUY_AMOUNT);

        assertTrue(orderA != orderB, "Different sellTokens must produce distinct orderIds");
    }

    /// @dev Orders created in different blocks always have unique orderIds.
    function test_EdgeCase_DifferentTimestamps_DistinctOrderIds() public {
        bytes32 orderId1 = _initiateOrder();
        vm.warp(block.timestamp + 1); // advance 1 second
        bytes32 orderId2 = _initiateOrder();

        assertTrue(orderId1 != orderId2, "Different timestamps = different validTo = different orderId");
    }

    /// @dev validityDuration = type(uint32).max is rejected by execute() with a
    ///      graceful failure result — no tokens locked, no order created.
    ///      isValidSignature() reads stored validTo directly —
    ///      it never recomputes validityDuration, so it can never overflow.
    function test_EdgeCase_M1Fix_MaxValidityDuration_RejectedGracefully() public {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, type(uint32).max, APP_DATA);

        // execute() rejects overflow validity before any transfer
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        assertFalse(result.success, "overflow validity is rejected");
        assertEq(result.failureReason, "Validity duration overflow");

        // No tokens locked — no order created
        assertEq(sellToken.balanceOf(address(module)), 0, "no tokens locked on overflow failure");

        // isValidSignature still never reverts (reads stored validTo directly)
        bytes4 sig = module.isValidSignature(bytes32(0), abi.encode(bytes32(0)));
        assertTrue(sig == MAGIC_VALUE || sig == FAILURE_VALUE, "isValidSignature never reverts");
    }

    /// @dev After solver fills, max approval remains — safe because module holds 0 sellToken.
    ///      ERC20 balance is the hard ceiling: CowSwap cannot pull what isn't there.
    function test_EdgeCase_AfterSolverFills_MaxApprovalRemains() public {
        bytes32 orderId = _initiateOrder();

        // Max approval set during execute()
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        // Solver pulls tokens and records fill
        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), SELL_AMOUNT);
        cowSettlement.setFilledAmount(orderId, SELL_AMOUNT);

        // Approval unchanged at max — module holds 0, so nothing can be pulled
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /// @dev After cancelOrder, max approval remains — safe because module no longer holds the token.
    function test_EdgeCase_AfterCancelOrder_MaxApprovalRemains() public {
        bytes32 orderId = _initiateOrder();

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        module.cancelOrder(orderId);

        // Approval NOT revoked — module holds 0 sellToken after cancel, CowSwap cannot pull anything
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(
        address targetToken,
        uint256 minBuyAmount,
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
                minBuyAmount: minBuyAmount,
                validityDuration: validityDuration,
                appData: appData
            })
        );
    }

    function _initiateOrder() internal returns (bytes32 orderId) {
        bytes memory params = _buildParams(address(buyToken), MIN_BUY_AMOUNT, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(address(sellToken), SELL_AMOUNT, params);
        return abi.decode(result.data, (bytes32));
    }

    function _initiateOrderWith(
        address _sellToken,
        address _buyToken,
        uint256 _sellAmount,
        uint256 _minBuyAmount
    )
        internal
        returns (bytes32 orderId)
    {
        bytes memory params = _buildParams(_buyToken, _minBuyAmount, VALIDITY_DURATION, APP_DATA);
        DataTypes.ExecutionResult memory result = mockPaymentRails.initiateSwap(_sellToken, _sellAmount, params);
        return abi.decode(result.data, (bytes32));
    }

    /// @dev Parse the orderId (first indexed topic) from the first OrderCreated event in logs.
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
