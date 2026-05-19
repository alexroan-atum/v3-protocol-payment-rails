// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { MockRouter } from "../../../../../shared/mocks/MockRouter.sol";
import { ReentrantRouter } from "../../../../../shared/mocks/ReentrantRouter.sol";
import { MockDexSwapPaymentRails } from "../../../../../shared/mocks/MockDexSwapPaymentRails.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Unit tests for DexSwapModule.execute()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/execute/execute.tree
contract DexSwapModule_Execute_Test is DexSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                        VALIDATION FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    // -----------------------------------------------------------------------
    // when params are too short
    // -----------------------------------------------------------------------

    function test_WhenParamsTooShort_ReturnsFailedResult() external {
        bytes memory shortParams = hex"00";
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, shortParams, _defaultExecutionData());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Invalid params encoding", "failureReason");
    }

    function test_WhenParamsTooShort_DoesNotTransferTokens() external {
        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00", _defaultExecutionData());
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "no tokens moved");
    }

    function test_WhenParamsEmpty_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, "", _defaultExecutionData());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Invalid params encoding", "failureReason");
    }

    // -----------------------------------------------------------------------
    // when execution data is empty
    // -----------------------------------------------------------------------

    function test_WhenExecutionDataEmpty_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), "");
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Missing execution data", "failureReason");
    }

    function test_WhenExecutionDataEmpty_DoesNotTransferTokens() external {
        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), "");
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "no tokens moved");
    }

    // -----------------------------------------------------------------------
    // when amount is zero
    // -----------------------------------------------------------------------

    function test_WhenAmountIsZero_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), 0, _defaultParams(), _defaultExecutionData());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero sell amount", "failureReason");
    }

    // -----------------------------------------------------------------------
    // when target token is zero address
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(address(0));
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero target token", "failureReason");
    }

    // -----------------------------------------------------------------------
    // when target token equals sell token
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenEqualsSellToken_ReturnsFailedResult() external {
        bytes memory params = _buildParams(address(sellToken));
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Same input and output token", "failureReason");
    }

    // -----------------------------------------------------------------------
    // when router is not whitelisted
    // -----------------------------------------------------------------------

    function test_WhenRouterNotWhitelisted_ReturnsFailedResult() external {
        MockRouter unlisted = new MockRouter();
        bytes memory execData = _buildExecutionData(
            address(unlisted), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, _defaultRouterCalldata()
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Router not allowed", "failureReason");
    }

    // -----------------------------------------------------------------------
    // when min amount out is zero
    // -----------------------------------------------------------------------

    function test_WhenMinAmountOutIsZero_ReturnsFailedResult() external {
        bytes memory execData = _buildExecutionData(address(router), 0, DEFAULT_DEADLINE, _defaultRouterCalldata());
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero min amount out", "failureReason");
    }

    // -----------------------------------------------------------------------
    // when deadline has expired
    // -----------------------------------------------------------------------

    function test_WhenDeadlineExpired_ReturnsFailedResult() external {
        vm.warp(1000);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, 999, _defaultRouterCalldata());
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Deadline expired", "failureReason");
    }

    function test_WhenDeadlineEqualsTimestamp_Succeeds() external {
        vm.warp(1000);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, 1000, _defaultRouterCalldata());
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
        assertTrue(result.success, "deadline == timestamp should succeed");
    }

    // -----------------------------------------------------------------------
    // when caller has insufficient balance
    // -----------------------------------------------------------------------

    function test_WhenCallerHasInsufficientBalance_ReturnsFailedResult() external {
        uint256 tooMuch = DEFAULT_SELL_AMOUNT * 101;
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), tooMuch, _defaultParams(), _defaultExecutionData());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Insufficient balance", "failureReason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ROUTER CALL FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    // -----------------------------------------------------------------------
    // when router call reverts
    // -----------------------------------------------------------------------

    function test_WhenRouterReverts_ReturnsFailedResult() external {
        router.setShouldRevert(true);
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Router call failed", "failureReason");
    }

    function test_WhenRouterReverts_ReturnsSellTokensToCaller() external {
        router.setShouldRevert(true);
        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "all tokens returned");
    }

    function test_WhenRouterReverts_ModuleHasZeroBalance() external {
        router.setShouldRevert(true);
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertEq(sellToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SLIPPAGE ENFORCEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    // -----------------------------------------------------------------------
    // when output is below minimum (REVERTS — atomic rollback)
    // -----------------------------------------------------------------------

    function test_WhenOutputBelowMinimum_RevertsWithInsufficientOutput() external {
        uint256 tinyBuyAmount = 1;
        bytes memory routerCalldata = _routerCalldataWithAmounts(DEFAULT_SELL_AMOUNT, tinyBuyAmount);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, routerCalldata);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DexSwapModule_InsufficientOutput.selector, tinyBuyAmount, DEFAULT_MIN_AMOUNT_OUT
            )
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
    }

    function test_WhenOutputBelowMinimum_SellTokensNotTransferred() external {
        uint256 tinyBuyAmount = 1;
        bytes memory routerCalldata = _routerCalldataWithAmounts(DEFAULT_SELL_AMOUNT, tinyBuyAmount);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, routerCalldata);

        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        try paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData) { } catch { }

        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "atomic rollback");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ADVERSARIAL ROUTER TESTS
    //////////////////////////////////////////////////////////////////////////*/

    // -----------------------------------------------------------------------
    // when router steals sell tokens but sends no buy tokens
    // -----------------------------------------------------------------------

    function test_WhenRouterStealsTokens_RevertsAtomically() external {
        bytes memory stealCalldata =
            abi.encodeWithSelector(MockRouter.stealTokens.selector, address(sellToken), DEFAULT_SELL_AMOUNT);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, stealCalldata);

        uint256 paymentRailsBefore = sellToken.balanceOf(address(paymentRails));

        vm.expectRevert();
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);

        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBefore, "tokens safe after revert");
    }

    // -----------------------------------------------------------------------
    // when router does nothing (noop)
    // -----------------------------------------------------------------------

    function test_WhenRouterNoops_RevertsWithInsufficientOutput() external {
        bytes memory noopCalldata = abi.encodeWithSelector(MockRouter.noop.selector);
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, noopCalldata);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DexSwapModule_InsufficientOutput.selector, 0, DEFAULT_MIN_AMOUNT_OUT)
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    FEE-ON-TRANSFER TOKEN TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_FeeOnTransferSellToken_UsesBalanceDiff() external {
        uint256 feeTokenAmount = 10_000e18;
        feeToken.mint(address(paymentRails), feeTokenAmount);
        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);

        uint256 expectedReceived = feeTokenAmount - (feeTokenAmount * 100 / 10_000); // 1% fee

        bytes memory params = _buildParams(address(buyToken));
        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(feeToken),
            expectedReceived,
            address(buyToken),
            address(paymentRails),
            DEFAULT_BUY_AMOUNT
        );
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, routerCalldata);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(feeToken), feeTokenAmount, params, execData);
        assertTrue(result.success, "fee-on-transfer swap should succeed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PARTIAL FILL TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_PartialFill_ReturnsUnconsumedSellTokens() external {
        uint256 halfSell = DEFAULT_SELL_AMOUNT / 2;
        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.partialSwap.selector,
            address(sellToken),
            halfSell,
            address(buyToken),
            address(paymentRails),
            DEFAULT_BUY_AMOUNT
        );
        bytes memory execData =
            _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, routerCalldata);

        uint256 paymentRailsBefore = sellToken.balanceOf(address(paymentRails));
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), execData);

        assertTrue(result.success, "partial fill should succeed");
        uint256 paymentRailsAfter = sellToken.balanceOf(address(paymentRails));
        assertEq(paymentRailsBefore - paymentRailsAfter, halfSell, "only half consumed");
        assertEq(sellToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValid_TransfersTokensCorrectly() external whenAllValidationsPass {
        uint256 paymentRailsSellBefore = sellToken.balanceOf(address(paymentRails));
        uint256 paymentRailsBuyBefore = buyToken.balanceOf(address(paymentRails));

        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());

        assertEq(
            sellToken.balanceOf(address(paymentRails)),
            paymentRailsSellBefore - DEFAULT_SELL_AMOUNT,
            "sell tokens debited"
        );
        assertEq(
            buyToken.balanceOf(address(paymentRails)), paymentRailsBuyBefore + DEFAULT_BUY_AMOUNT, "buy tokens credited"
        );
    }

    function test_WhenAllValid_ReturnsSuccessTrue() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );
        assertTrue(result.success, "success");
    }

    function test_WhenAllValid_ReturnsCorrectAmountOut() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );
        assertEq(result.amountOut, DEFAULT_BUY_AMOUNT, "amountOut");
    }

    function test_WhenAllValid_ReturnsOutputTokenAsTargetToken() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );
        assertEq(result.outputToken, address(buyToken), "outputToken");
    }

    function test_WhenAllValid_ReturnsEncodedRouterInData() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );
        address decodedRouter = abi.decode(result.data, (address));
        assertEq(decodedRouter, address(router), "data contains router");
    }

    function test_WhenAllValid_EmitsSwapExecuted() external whenAllValidationsPass {
        vm.expectEmit(true, true, false, true, address(module));
        emit SwapExecuted(
            address(paymentRails),
            address(sellToken),
            address(buyToken),
            DEFAULT_SELL_AMOUNT,
            DEFAULT_BUY_AMOUNT,
            address(router)
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
    }

    function test_WhenAllValid_ModuleRetainsZeroSellToken() external whenAllValidationsPass {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertEq(sellToken.balanceOf(address(module)), 0, "no residual sell token");
    }

    function test_WhenAllValid_ModuleRetainsZeroBuyToken() external whenAllValidationsPass {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertEq(buyToken.balanceOf(address(module)), 0, "no residual buy token");
    }

    function test_WhenAllValid_RouterApprovalRevokedAfterSwap() external whenAllValidationsPass {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertEq(sellToken.allowance(address(module), address(router)), 0, "approval revoked");
    }

    function test_ConsecutiveSwaps_NoResidualState() external {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());

        assertEq(sellToken.balanceOf(address(module)), 0, "zero after swap 1");
        assertEq(buyToken.balanceOf(address(module)), 0, "zero after swap 1");

        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());

        assertEq(sellToken.balanceOf(address(module)), 0, "zero after swap 2");
        assertEq(buyToken.balanceOf(address(module)), 0, "zero after swap 2");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REENTRANCY GUARD TESTS
    //////////////////////////////////////////////////////////////////////////*/

    // -----------------------------------------------------------------------
    // when router re-enters execute during swap callback
    // -----------------------------------------------------------------------

    function test_WhenRouterReenters_RevertsWithReentrancyGuardReentrantCall() external {
        (ReentrantRouter reentrantRouter, MockDexSwapPaymentRails victim,) = _setupReentrancyScenario();

        // Arm the reentrant call — router will try module.execute() mid-swap
        reentrantRouter.setReentrantCall(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );

        bytes memory victimExecData = _buildReentrantVictimExecData(reentrantRouter, victim);
        victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), victimExecData);

        assertTrue(reentrantRouter.reentrancyAttempted(), "router attempted reentrancy");
        assertFalse(reentrantRouter.reentrancySucceeded(), "reentrant call was blocked");

        // Verify the SPECIFIC revert reason is ReentrancyGuardReentrantCall, not an incidental failure
        bytes memory expectedRevert = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(reentrantRouter.revertReasonBytes(), expectedRevert, "reverted with ReentrancyGuardReentrantCall");
    }

    function test_WhenRouterReenters_OriginalSwapCompletesSuccessfully() external {
        (ReentrantRouter reentrantRouter, MockDexSwapPaymentRails victim,) = _setupReentrancyScenario();

        reentrantRouter.setReentrantCall(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );

        bytes memory victimExecData = _buildReentrantVictimExecData(reentrantRouter, victim);

        uint256 victimSellBefore = sellToken.balanceOf(address(victim));
        uint256 victimBuyBefore = buyToken.balanceOf(address(victim));

        DataTypes.ExecutionResult memory result =
            victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), victimExecData);

        assertTrue(result.success, "original swap succeeds");
        assertEq(result.amountOut, DEFAULT_BUY_AMOUNT, "correct output amount");
        assertEq(sellToken.balanceOf(address(victim)), victimSellBefore - DEFAULT_SELL_AMOUNT, "sell tokens debited");
        assertEq(buyToken.balanceOf(address(victim)), victimBuyBefore + DEFAULT_BUY_AMOUNT, "buy tokens credited");
        assertEq(sellToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    function test_WhenRouterReenters_AttackerBalancesUnchanged() external {
        (ReentrantRouter reentrantRouter, MockDexSwapPaymentRails victim, MockDexSwapPaymentRails attackerRails) =
            _setupReentrancyScenario();

        // Give attacker tokens and approval for the reentrant call
        sellToken.mint(address(attackerRails), DEFAULT_SELL_AMOUNT);

        bytes memory attackerRouterCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            DEFAULT_SELL_AMOUNT,
            address(buyToken),
            address(attackerRails),
            DEFAULT_BUY_AMOUNT
        );
        bytes memory attackerExecData =
            abi.encode(address(reentrantRouter), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, attackerRouterCalldata);
        reentrantRouter.setReentrantCall(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), attackerExecData);

        uint256 attackerSellBefore = sellToken.balanceOf(address(attackerRails));
        uint256 attackerBuyBefore = buyToken.balanceOf(address(attackerRails));

        bytes memory victimExecData = _buildReentrantVictimExecData(reentrantRouter, victim);
        victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), victimExecData);

        assertEq(sellToken.balanceOf(address(attackerRails)), attackerSellBefore, "attacker sell tokens unchanged");
        assertEq(buyToken.balanceOf(address(attackerRails)), attackerBuyBefore, "attacker buy tokens unchanged");
    }

    function test_WhenRouterReenters_ModuleRemainsUsableAfterBlockedReentrancy() external {
        (ReentrantRouter reentrantRouter, MockDexSwapPaymentRails victim,) = _setupReentrancyScenario();

        reentrantRouter.setReentrantCall(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );

        bytes memory victimExecData = _buildReentrantVictimExecData(reentrantRouter, victim);
        victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), victimExecData);

        // After reentrancy was blocked, verify the module works normally for a subsequent swap
        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );

        assertTrue(result.success, "module functional after blocked reentrancy");
        assertEq(result.amountOut, DEFAULT_BUY_AMOUNT, "subsequent swap correct output");
        assertEq(sellToken.balanceOf(address(module)), 0, "no residual after subsequent swap");
    }

    function test_WhenDirectCallerReenters_RevertsWithReentrancyGuardReentrantCall() external {
        ReentrantRouter reentrantRouter = new ReentrantRouter(address(module));
        module.addRouter(address(reentrantRouter));

        // Direct caller: an EOA that calls module.execute() directly, bypassing PaymentRails
        address directCaller = makeAddr("directCaller");
        sellToken.mint(directCaller, DEFAULT_SELL_AMOUNT);
        buyToken.mint(address(reentrantRouter), DEFAULT_BUY_AMOUNT);
        vm.prank(directCaller);
        sellToken.approve(address(module), DEFAULT_SELL_AMOUNT);

        // Arm the reentrant call — router will try execute() directly during its callback
        reentrantRouter.setReentrantCall(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );

        bytes memory directRouterCalldata = abi.encodeWithSelector(
            ReentrantRouter.swapAndReenter.selector,
            address(sellToken),
            DEFAULT_SELL_AMOUNT,
            address(buyToken),
            directCaller,
            DEFAULT_BUY_AMOUNT
        );
        bytes memory directExecData =
            abi.encode(address(reentrantRouter), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, directRouterCalldata);

        // Call execute() directly as the EOA (bypassing PaymentRails entirely)
        vm.prank(directCaller);
        DataTypes.ExecutionResult memory result =
            module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), directExecData);

        assertTrue(result.success, "direct call swap succeeds");
        assertTrue(reentrantRouter.reentrancyAttempted(), "direct caller reentrancy attempted");
        assertFalse(reentrantRouter.reentrancySucceeded(), "direct caller reentrancy blocked");

        bytes memory expectedRevert = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(reentrantRouter.revertReasonBytes(), expectedRevert, "reverted with ReentrancyGuardReentrantCall");
    }

    // -----------------------------------------------------------------------
    // Reentrancy test helpers
    // -----------------------------------------------------------------------

    function _setupReentrancyScenario()
        private
        returns (ReentrantRouter reentrantRouter, MockDexSwapPaymentRails victim, MockDexSwapPaymentRails attackerRails)
    {
        reentrantRouter = new ReentrantRouter(address(module));
        module.addRouter(address(reentrantRouter));

        victim = new MockDexSwapPaymentRails(address(module));
        sellToken.mint(address(victim), DEFAULT_SELL_AMOUNT);
        buyToken.mint(address(reentrantRouter), DEFAULT_BUY_AMOUNT);

        attackerRails = new MockDexSwapPaymentRails(address(module));
    }

    function _buildReentrantVictimExecData(
        ReentrantRouter reentrantRouter,
        MockDexSwapPaymentRails victim
    )
        private
        view
        returns (bytes memory)
    {
        bytes memory victimRouterCalldata = abi.encodeWithSelector(
            ReentrantRouter.swapAndReenter.selector,
            address(sellToken),
            DEFAULT_SELL_AMOUNT,
            address(buyToken),
            address(victim),
            DEFAULT_BUY_AMOUNT
        );
        return abi.encode(address(reentrantRouter), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, victimRouterCalldata);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_WhenAllValid_HandlesAnyValidAmounts(
        uint256 sellAmount,
        uint256 _buyAmount,
        uint256 minOut
    )
        external
    {
        sellAmount = bound(sellAmount, 1, DEFAULT_SELL_AMOUNT * 50);
        _buyAmount = bound(_buyAmount, 1, type(uint128).max);
        minOut = bound(minOut, 1, _buyAmount);

        sellToken.mint(address(paymentRails), sellAmount);
        buyToken.mint(address(router), _buyAmount);

        bytes memory routerCalldata = _routerCalldataWithAmounts(sellAmount, _buyAmount);
        bytes memory execData = _buildExecutionData(address(router), minOut, DEFAULT_DEADLINE, routerCalldata);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), sellAmount, _defaultParams(), execData);

        assertTrue(result.success, "success");
        assertEq(result.amountOut, _buyAmount, "amountOut");
        assertEq(sellToken.balanceOf(address(module)), 0, "no residual");
    }

    /*//////////////////////////////////////////////////////////////////////////
                VALIDATION ORDER TESTS (first failure wins)
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidationOrder_ExecutionDataCheckedBeforeParams() external {
        bytes memory shortParams = hex"00";
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, shortParams, "");
        assertEq(result.failureReason, "Missing execution data", "executionData checked before params");
    }

    function test_ValidationOrder_ExecutionDataCheckedBeforeAmount() external {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(address(sellToken), 0, _defaultParams(), "");
        assertEq(result.failureReason, "Missing execution data", "executionData checked before amount");
    }
}
