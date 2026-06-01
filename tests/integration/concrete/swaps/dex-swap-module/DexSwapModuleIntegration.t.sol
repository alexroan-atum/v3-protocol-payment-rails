// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../../src/modules/swaps/DexSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { MockRouter } from "../../../../shared/mocks/MockRouter.sol";
import { MockChainlinkAggregator } from "../../../../shared/mocks/MockChainlinkAggregator.sol";

/*//////////////////////////////////////////////////////////////////////////
                    INTEGRATION TEST SUITE
//////////////////////////////////////////////////////////////////////////*/

/// @title DexSwapModuleIntegrationTest
/// @notice Integration tests covering real PaymentRails + DexSwapModule interaction.
/// @dev Architecture: DexSwapModule has an immutable router and computes amountOutMinimum
///      on-chain from Chainlink oracle prices. There is no caller-supplied executionData.
///      All parameters (fee, slippage, oracle feeds, deadline) are in the static DexSwapParams.
///
///   Test groups:
///   - Full lifecycle: configure → executeAction → swap completes → tokens at paymentRails
///   - Router revert → PaymentRails catches, returns false, tokens safe
///   - Oracle-enforced slippage → insufficient output reverts, PaymentRails catches
///   - Validation failures at PaymentRails level and module level
///   - Multi-paymentRails sharing one module
///   - PaymentRails reconfiguration (disable/re-enable, swap modules)
contract DexSwapModuleIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    event SwapExecuted(
        address indexed paymentRails, address indexed sellToken, address buyToken, uint256 amountIn, uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint256 internal constant SELL_AMOUNT = 1000e18;
    uint256 internal constant BUY_AMOUNT = 995e18;
    uint256 internal constant MIN_BALANCE = 100e18;
    uint24 internal constant DEFAULT_FEE = 3000;
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600;
    uint256 internal constant DEFAULT_SWAP_DEADLINE = 300;

    int256 internal constant SELL_PRICE = 1e8; // $1 per sell token
    int256 internal constant BUY_PRICE = 1e8; // $1 per buy token
    uint8 internal constant FEED_DECIMALS = 8;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    MockRouter internal router;
    PaymentRails internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    address internal owner;
    address internal keeper;

    /*//////////////////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.warp(1_700_000_000);

        owner = makeAddr("owner");
        keeper = makeAddr("keeper");

        router = new MockRouter();
        module = new DexSwapModule(address(router), address(0), 0);

        vm.prank(owner);
        paymentRails = new PaymentRails(owner);

        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");
        sellFeed = new MockChainlinkAggregator(SELL_PRICE, FEED_DECIMALS);
        buyFeed = new MockChainlinkAggregator(BUY_PRICE, FEED_DECIMALS);

        sellToken.mint(address(paymentRails), SELL_AMOUNT * 10);
        buyToken.mint(address(router), BUY_AMOUNT * 20);

        router.setOutputAmount(BUY_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 1: FULL LIFECYCLE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Real PaymentRails: configure → executeAction → swap completes
    function test_FullLifecycle_Configure_ExecuteAction_SwapsTokens() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertTrue(success, "executeAction must succeed");
        assertEq(sellToken.balanceOf(address(paymentRails)), SELL_AMOUNT * 10 - SELL_AMOUNT, "sellToken debited");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT, "buyToken credited to paymentRails");
        assertEq(sellToken.balanceOf(address(module)), 0, "module holds zero sellToken");
    }

    /// @dev ActionExecuted event from PaymentRails reports correct amountOut.
    function test_FullLifecycle_ActionExecuted_EmitsCorrectAmountOut() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        vm.expectEmit(true, true, false, true, address(paymentRails));
        emit ActionExecuted(address(sellToken), "SWAP", SELL_AMOUNT, BUY_AMOUNT, address(buyToken), keeper);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
    }

    /// @dev SwapExecuted event from Module reports correct details.
    function test_FullLifecycle_SwapExecuted_EmitsFromModule() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        vm.expectEmit(true, true, false, true, address(module));
        emit SwapExecuted(address(paymentRails), address(sellToken), address(buyToken), SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
    }

    /// @dev Module approval is revoked after successful swap.
    function test_FullLifecycle_ApprovalRevokedAfterSwap() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertEq(
            sellToken.allowance(address(paymentRails), address(module)),
            0,
            "PaymentRails-to-Module approval must be zero after success"
        );
    }

    /// @dev Anyone can trigger execution (permissionless).
    function test_FullLifecycle_Permissionless_AnyoneCanExecute() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertTrue(success, "Random caller can execute");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 2: ROUTER REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Router revert → PaymentRails catches it, returns false.
    function test_RouterRevert_PaymentRails_ReturnsFalse() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        router.setShouldRevert(true);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertFalse(success, "Must return false when router reverts");
    }

    /// @dev Router revert → PaymentRails revokes approval.
    function test_RouterRevert_PaymentRails_RevokesApproval() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        router.setShouldRevert(true);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertEq(
            sellToken.allowance(address(paymentRails), address(module)),
            0,
            "PaymentRails-to-Module approval must be revoked on router revert"
        );
    }

    /// @dev Router revert → paymentRails balance preserved.
    function test_RouterRevert_PaymentRails_BalancePreserved() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        router.setShouldRevert(true);

        uint256 balBefore = sellToken.balanceOf(address(paymentRails));

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "Balance must be preserved on router revert");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 3: ORACLE-ENFORCED SLIPPAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Oracle floor enforcement: when router output is below oracle floor, module reverts
    ///      and PaymentRails catches it, returns false.
    function test_OracleSlippage_InsufficientOutput_ReturnsFalse() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        // Set router to output very little (below oracle floor)
        uint256 tooLowOutput = 1;
        router.setOutputAmount(tooLowOutput);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertFalse(success, "Must return false when output < oracle floor");
    }

    /// @dev Oracle floor enforcement: approval revoked on slippage revert.
    function test_OracleSlippage_InsufficientOutput_RevokesApproval() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 tooLowOutput = 1;
        router.setOutputAmount(tooLowOutput);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertEq(
            sellToken.allowance(address(paymentRails), address(module)),
            0,
            "Approval must be revoked on slippage revert"
        );
    }

    /// @dev Oracle floor enforcement: paymentRails balance preserved on slippage revert.
    function test_OracleSlippage_InsufficientOutput_BalancePreserved() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 balBefore = sellToken.balanceOf(address(paymentRails));

        uint256 tooLowOutput = 1;
        router.setOutputAmount(tooLowOutput);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "Balance must be preserved on slippage revert");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 4: VALIDATION FAILURES AT PAYMENTRAILS LEVEL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Amount below minBalance → PaymentRails reverts.
    function test_ValidationFailure_BelowMinBalance_Reverts() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_BelowMinimumBalance.selector, MIN_BALANCE / 2, MIN_BALANCE)
        );
        paymentRails.executeAction(address(sellToken), MIN_BALANCE / 2);
    }

    /// @dev Amount exceeds balance → PaymentRails reverts.
    function test_ValidationFailure_ExceedsBalance_Reverts() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 tooMuch = SELL_AMOUNT * 100;

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.PaymentRails_InsufficientBalance.selector, sellToken.balanceOf(address(paymentRails)), tooMuch
            )
        );
        paymentRails.executeAction(address(sellToken), tooMuch);
    }

    /// @dev Token not enabled → PaymentRails reverts.
    function test_ValidationFailure_TokenNotEnabled_Reverts() public {
        bytes memory params = _defaultModuleParams();
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "SWAP", address(module), MIN_BALANCE, params, false);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRails_TokenNotEnabled.selector));
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
    }

    /// @dev Zero amount → PaymentRails reverts.
    function test_ValidationFailure_ZeroAmount_Reverts() public {
        _configurePaymentRails(address(sellToken), 0);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRails_ZeroAmount.selector));
        paymentRails.executeAction(address(sellToken), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 5: VALIDATION FAILURES AT MODULE LEVEL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Target token == sell token → module returns failure → PaymentRails returns false.
    function test_ModuleValidationFailure_SameTokens_ReturnsFalse() public {
        // Configure with targetToken == sellToken
        bytes memory params = abi.encode(
            address(sellToken), // targetToken == sellToken
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "SWAP", address(module), MIN_BALANCE, params, true);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertFalse(success, "Must return false when target == sell token");
    }

    /// @dev Oracle feed returning negative price → module returns failure → PaymentRails returns false.
    function test_ModuleValidationFailure_OracleNegativePrice_ReturnsFalse() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        sellFeed.setAnswer(-1);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertFalse(success, "Must return false when oracle returns negative price");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 6: CONSECUTIVE EXECUTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Multiple consecutive swaps drain paymentRails balance.
    function test_ConsecutiveExecutions_DrainPaymentRails() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 totalBalance = sellToken.balanceOf(address(paymentRails));
        uint256 numSwaps = totalBalance / SELL_AMOUNT;

        for (uint256 i = 0; i < numSwaps; i++) {
            vm.prank(keeper);
            bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
            assertTrue(success, "Each consecutive swap must succeed");
        }

        assertEq(sellToken.balanceOf(address(paymentRails)), 0, "PaymentRails fully drained");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT * numSwaps, "All buyToken received");
        assertEq(sellToken.balanceOf(address(module)), 0, "Module holds zero");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 7: PREVIEW EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev previewExecution returns oracle-estimated output and targetToken.
    function test_PreviewExecution_ReturnsOracleEstimateAndTargetToken() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        (uint256 estimated, address outputToken) = paymentRails.previewExecution(address(sellToken));

        // With 1:1 oracle prices and same-decimal tokens, expected = balance
        uint256 balance = sellToken.balanceOf(address(paymentRails));
        assertEq(estimated, balance, "Oracle estimate should equal balance for 1:1 price pair");
        assertEq(outputToken, address(buyToken), "Output token must be targetToken");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 8: MULTI-PAYMENTRAILS — SHARED MODULE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Two paymentRails share one module — both can swap independently.
    function test_SharedModule_TwoPaymentRails_BothSwap() public {
        PaymentRails paymentRails2 = _createPaymentRails();
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        _configurePaymentRails(address(sellToken), MIN_BALANCE);
        _configurePaymentRailsFor(paymentRails2, address(sellToken), MIN_BALANCE);

        vm.prank(keeper);
        bool s1 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
        assertTrue(s1, "First paymentRails swap must succeed");

        vm.prank(keeper);
        bool s2 = paymentRails2.executeAction(address(sellToken), SELL_AMOUNT);
        assertTrue(s2, "Second paymentRails swap must succeed");

        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT, "PR1 got buyToken");
        assertEq(buyToken.balanceOf(address(paymentRails2)), BUY_AMOUNT, "PR2 got buyToken");
        assertEq(sellToken.balanceOf(address(module)), 0, "Module holds zero");
    }

    /// @dev Interleaved executions from two paymentRails sharing one module.
    function test_SharedModule_InterleavedExecutions() public {
        PaymentRails paymentRails2 = _createPaymentRails();
        sellToken.mint(address(paymentRails2), SELL_AMOUNT * 3);

        _configurePaymentRails(address(sellToken), MIN_BALANCE);
        _configurePaymentRailsFor(paymentRails2, address(sellToken), MIN_BALANCE);

        // PR1 swaps
        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        // PR2 swaps
        vm.prank(keeper);
        paymentRails2.executeAction(address(sellToken), SELL_AMOUNT);

        // PR1 swaps again
        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT * 2, "PR1 received 2x buyToken");
        assertEq(buyToken.balanceOf(address(paymentRails2)), BUY_AMOUNT, "PR2 received 1x buyToken");
        assertEq(sellToken.balanceOf(address(module)), 0, "Module holds zero after interleaved swaps");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 9: PAYMENTRAILS RECONFIGURATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Disable → re-enable → swap works.
    function test_Reconfiguration_DisableThenReEnable() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        // Disable
        bytes memory params = _defaultModuleParams();
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "SWAP", address(module), MIN_BALANCE, params, false);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRails_TokenNotEnabled.selector));
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        // Re-enable
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "SWAP", address(module), MIN_BALANCE, params, true);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);

        assertTrue(success, "Swap must work after re-enable");
    }

    /// @dev Swap modules: reconfigure to a different DexSwapModule with a different router.
    function test_Reconfiguration_SwapToNewModule() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        // First swap with original module
        vm.prank(keeper);
        bool s1 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
        assertTrue(s1, "First swap with old module must succeed");

        // Deploy new module with a new router
        MockRouter newRouter = new MockRouter();
        DexSwapModule newModule = new DexSwapModule(address(newRouter), address(0), 0);
        buyToken.mint(address(newRouter), BUY_AMOUNT * 10);
        newRouter.setOutputAmount(BUY_AMOUNT);

        // Reconfigure paymentRails to use new module
        bytes memory params = abi.encode(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "SWAP", address(newModule), MIN_BALANCE, params, true);

        vm.prank(keeper);
        bool s2 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT);
        assertTrue(s2, "Second swap with new module must succeed");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT * 2, "Both swaps credited buyToken");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultModuleParams() internal view returns (bytes memory) {
        return abi.encode(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
    }

    function _configurePaymentRails(address token, uint256 minBal) internal {
        bytes memory params = _defaultModuleParams();
        vm.prank(owner);
        paymentRails.configureToken(token, "SWAP", address(module), minBal, params, true);
    }

    function _configurePaymentRailsFor(PaymentRails pr, address token, uint256 minBal) internal {
        bytes memory params = _defaultModuleParams();
        vm.prank(owner);
        pr.configureToken(token, "SWAP", address(module), minBal, params, true);
    }

    function _createPaymentRails() internal returns (PaymentRails) {
        vm.prank(owner);
        return new PaymentRails(owner);
    }
}
