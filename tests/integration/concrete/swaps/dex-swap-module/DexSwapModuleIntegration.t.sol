// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../../src/modules/swaps/DexSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { MockRouter } from "../../../../shared/mocks/MockRouter.sol";

/*//////////////////////////////////////////////////////////////////////////
                    INTEGRATION TEST SUITE
//////////////////////////////////////////////////////////////////////////*/

/// @title DexSwapModuleIntegrationTest
/// @notice Integration tests covering real PaymentRails + DexSwapModule interaction:
///   - Full lifecycle: configure → executeAction → swap completes → tokens at paymentRails
///   - Router revert → PaymentRails catches, returns false, tokens safe
///   - Slippage revert → PaymentRails catches in catch block, returns false
///   - Validation failures at PaymentRails level and module level
///   - Multi-paymentRails sharing one module
///   - Router whitelist changes affecting execution
///   - Module ownership transfer
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
        address indexed paymentRails,
        address indexed sellToken,
        address buyToken,
        uint256 amountIn,
        uint256 amountOut,
        address router
    );

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint256 internal constant SELL_AMOUNT = 1000e18;
    uint256 internal constant BUY_AMOUNT = 950e18;
    uint256 internal constant MIN_AMOUNT_OUT = 900e18;
    uint256 internal constant MIN_BALANCE = 100e18;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    MockRouter internal router;
    PaymentRails internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal owner;
    address internal keeper;

    /*//////////////////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        owner = makeAddr("owner");
        keeper = makeAddr("keeper");

        module = new DexSwapModule(owner);
        router = new MockRouter();

        vm.prank(owner);
        paymentRails = new PaymentRails(owner);

        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");

        vm.prank(owner);
        module.addRouter(address(router));

        sellToken.mint(address(paymentRails), SELL_AMOUNT * 10);
        buyToken.mint(address(router), BUY_AMOUNT * 20);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 1: FULL LIFECYCLE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Real PaymentRails: configure → executeAction with executionData → swap completes
    function test_FullLifecycle_Configure_ExecuteAction_SwapsTokens() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertTrue(success, "executeAction must succeed");
        assertEq(sellToken.balanceOf(address(paymentRails)), SELL_AMOUNT * 10 - SELL_AMOUNT, "sellToken debited");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT, "buyToken credited to paymentRails");
        assertEq(sellToken.balanceOf(address(module)), 0, "module holds zero sellToken");
    }

    /// @dev ActionExecuted event from PaymentRails reports correct amountOut.
    function test_FullLifecycle_ActionExecuted_EmitsCorrectAmountOut() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.expectEmit(true, true, false, true, address(paymentRails));
        emit ActionExecuted(address(sellToken), "DEX_SWAP", SELL_AMOUNT, BUY_AMOUNT, address(buyToken), keeper);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);
    }

    /// @dev SwapExecuted event from Module reports correct details.
    function test_FullLifecycle_SwapExecuted_EmitsFromModule() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.expectEmit(true, true, false, true, address(module));
        emit SwapExecuted(
            address(paymentRails), address(sellToken), address(buyToken), SELL_AMOUNT, BUY_AMOUNT, address(router)
        );

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);
    }

    /// @dev Module approval is revoked after successful swap.
    function test_FullLifecycle_ApprovalRevokedAfterSwap() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertEq(
            sellToken.allowance(address(paymentRails), address(module)),
            0,
            "PaymentRails-to-Module approval must be zero after success"
        );
    }

    /// @dev Anyone can trigger execution (permissionless).
    function test_FullLifecycle_Permissionless_AnyoneCanExecute() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertTrue(success, "Random caller can execute");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 2: ROUTER REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Router revert → PaymentRails catches it, returns false.
    function test_RouterRevert_PaymentRails_ReturnsFalse() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        router.setShouldRevert(true);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertFalse(success, "Must return false when router reverts");
    }

    /// @dev Router revert → PaymentRails revokes approval.
    function test_RouterRevert_PaymentRails_RevokesApproval() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        router.setShouldRevert(true);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

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
        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "Balance must be preserved on router revert");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 3: SLIPPAGE REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Slippage violation → module reverts → PaymentRails catches in catch block, returns false.
    function test_SlippageRevert_PaymentRails_ReturnsFalse() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        // Router outputs 100, but minAmountOut = MIN_AMOUNT_OUT (900e18) → slippage revert
        uint256 tooLowOutput = 100e18;
        bytes memory routerCalldata = _routerCalldata(SELL_AMOUNT, tooLowOutput);
        bytes memory executionData = abi.encode(address(router), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertFalse(success, "Must return false on slippage revert");
    }

    /// @dev Slippage revert → approval revoked.
    function test_SlippageRevert_PaymentRails_RevokesApproval() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 tooLowOutput = 100e18;
        bytes memory routerCalldata = _routerCalldata(SELL_AMOUNT, tooLowOutput);
        bytes memory executionData = abi.encode(address(router), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertEq(
            sellToken.allowance(address(paymentRails), address(module)),
            0,
            "Approval must be revoked on slippage revert"
        );
    }

    /// @dev Slippage revert → paymentRails balance preserved (atomic rollback).
    function test_SlippageRevert_PaymentRails_BalancePreserved() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 balBefore = sellToken.balanceOf(address(paymentRails));

        uint256 tooLowOutput = 100e18;
        bytes memory routerCalldata = _routerCalldata(SELL_AMOUNT, tooLowOutput);
        bytes memory executionData = abi.encode(address(router), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);

        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "Balance must be preserved on slippage revert");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 4: VALIDATION FAILURES AT PAYMENTRAILS LEVEL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Amount below minBalance → PaymentRails reverts.
    function test_ValidationFailure_BelowMinBalance_Reverts() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(MIN_BALANCE / 2, BUY_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PaymentRails_BelowMinimumBalance.selector, MIN_BALANCE / 2, MIN_BALANCE)
        );
        paymentRails.executeAction(address(sellToken), MIN_BALANCE / 2, executionData);
    }

    /// @dev Amount exceeds balance → PaymentRails reverts.
    function test_ValidationFailure_ExceedsBalance_Reverts() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        uint256 tooMuch = SELL_AMOUNT * 100;
        bytes memory executionData = _buildExecutionData(tooMuch, BUY_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.PaymentRails_InsufficientBalance.selector, sellToken.balanceOf(address(paymentRails)), tooMuch
            )
        );
        paymentRails.executeAction(address(sellToken), tooMuch, executionData);
    }

    /// @dev Token not enabled → PaymentRails reverts.
    function test_ValidationFailure_TokenNotEnabled_Reverts() public {
        bytes memory params = abi.encode(address(buyToken), uint16(0), address(0), address(0), uint256(0));

        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "DEX_SWAP", address(module), MIN_BALANCE, params, false);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRails_TokenNotEnabled.selector));
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);
    }

    /// @dev Zero amount → PaymentRails reverts.
    function test_ValidationFailure_ZeroAmount_Reverts() public {
        _configurePaymentRails(address(sellToken), 0);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRails_ZeroAmount.selector));
        paymentRails.executeAction(address(sellToken), 0, executionData);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 5: VALIDATION FAILURES AT MODULE LEVEL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Router not whitelisted → module returns failure → PaymentRails returns false.
    function test_ModuleValidationFailure_RouterNotWhitelisted_ReturnsFalse() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        MockRouter unlistedRouter = new MockRouter();
        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            SELL_AMOUNT,
            address(buyToken),
            address(paymentRails),
            BUY_AMOUNT
        );
        bytes memory executionData =
            abi.encode(address(unlistedRouter), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertFalse(success, "Must return false when router not whitelisted");
    }

    /// @dev Target token == sell token → module returns failure → PaymentRails returns false.
    function test_ModuleValidationFailure_SameTokens_ReturnsFalse() public {
        // Configure with targetToken == sellToken
        bytes memory params = abi.encode(address(sellToken));
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "DEX_SWAP", address(module), MIN_BALANCE, params, true);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertFalse(success, "Must return false when target == sell token");
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
            bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);
            vm.prank(keeper);
            bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);
            assertTrue(success, "Each consecutive swap must succeed");
        }

        assertEq(sellToken.balanceOf(address(paymentRails)), 0, "PaymentRails fully drained");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT * numSwaps, "All buyToken received");
        assertEq(sellToken.balanceOf(address(module)), 0, "Module holds zero");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 7: PREVIEW EXECUTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev previewExecution returns (0, targetToken) for atomic swaps.
    function test_PreviewExecution_ReturnsZeroAndTargetToken() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        (uint256 estimated, address outputToken) = paymentRails.previewExecution(address(sellToken));

        assertEq(estimated, 0, "Atomic swaps cannot pre-estimate output");
        assertEq(outputToken, address(buyToken), "Output token must be targetToken");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 8: EXECUTE WITH EXECUTIONDATA OVERLOAD
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev executeAction(token, amount, executionData) forwards executionData to module.
    function test_ExecuteWithExecutionData_ForwardsToModule() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertTrue(success, "executeAction with executionData must succeed");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT, "buyToken received via executionData path");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 9: MULTI-PAYMENTRAILS — SHARED MODULE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Two paymentRails share one module — both can swap independently.
    function test_SharedModule_TwoPaymentRails_BothSwap() public {
        PaymentRails paymentRails2 = _createPaymentRails();
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        _configurePaymentRails(address(sellToken), MIN_BALANCE);
        _configurePaymentRailsFor(paymentRails2, address(sellToken), MIN_BALANCE);

        bytes memory exec1 = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);
        bytes memory exec2 = _buildExecutionDataForNode(paymentRails2, SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool s1 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, exec1);
        assertTrue(s1, "First paymentRails swap must succeed");

        vm.prank(keeper);
        bool s2 = paymentRails2.executeAction(address(sellToken), SELL_AMOUNT, exec2);
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
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT));

        // PR2 swaps
        vm.prank(keeper);
        paymentRails2.executeAction(
            address(sellToken), SELL_AMOUNT, _buildExecutionDataForNode(paymentRails2, SELL_AMOUNT, BUY_AMOUNT)
        );

        // PR1 swaps again
        vm.prank(keeper);
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT));

        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT * 2, "PR1 received 2x buyToken");
        assertEq(buyToken.balanceOf(address(paymentRails2)), BUY_AMOUNT, "PR2 received 1x buyToken");
        assertEq(sellToken.balanceOf(address(module)), 0, "Module holds zero after interleaved swaps");
    }

    /// @dev Router removal fails both paymentRails.
    function test_SharedModule_RouterRemoval_FailsBoth() public {
        PaymentRails paymentRails2 = _createPaymentRails();
        sellToken.mint(address(paymentRails2), SELL_AMOUNT);

        _configurePaymentRails(address(sellToken), MIN_BALANCE);
        _configurePaymentRailsFor(paymentRails2, address(sellToken), MIN_BALANCE);

        vm.prank(owner);
        module.removeRouter(address(router));

        bytes memory exec1 = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);
        bytes memory exec2 = _buildExecutionDataForNode(paymentRails2, SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool s1 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, exec1);
        assertFalse(s1, "PR1 must fail after router removed");

        vm.prank(keeper);
        bool s2 = paymentRails2.executeAction(address(sellToken), SELL_AMOUNT, exec2);
        assertFalse(s2, "PR2 must fail after router removed");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 10: ROUTER WHITELIST CHANGES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Newly added router works on next execution.
    function test_RouterWhitelist_NewRouterWorksOnNextExecution() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        MockRouter newRouter = new MockRouter();
        buyToken.mint(address(newRouter), BUY_AMOUNT * 10);

        vm.prank(owner);
        module.addRouter(address(newRouter));

        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            SELL_AMOUNT,
            address(buyToken),
            address(paymentRails),
            BUY_AMOUNT
        );
        bytes memory executionData = abi.encode(address(newRouter), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertTrue(success, "New router must work after being added");
    }

    /// @dev Router removed between configure and execute → execution fails.
    function test_RouterWhitelist_RemovedBetweenConfigAndExecute_Fails() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        vm.prank(owner);
        module.removeRouter(address(router));

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertFalse(success, "Must fail after router removed");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 11: MODULE OWNERSHIP — INTEGRATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev New owner can manage routers after ownership transfer.
    function test_Ownership_NewOwnerManagesRouters() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        MockRouter newRouter = new MockRouter();
        vm.prank(newOwner);
        module.addRouter(address(newRouter));

        assertTrue(module.isRouterAllowed(address(newRouter)), "New owner added router");
    }

    /// @dev Old owner blocked after transfer.
    function test_Ownership_OldOwnerBlocked() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        MockRouter newRouter = new MockRouter();
        vm.prank(owner);
        vm.expectRevert();
        module.addRouter(address(newRouter));
    }

    /// @dev Existing router whitelist survives ownership transfer.
    function test_Ownership_ExistingWhitelistSurvivesTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        assertTrue(module.isRouterAllowed(address(router)), "Original router still whitelisted after transfer");

        _configurePaymentRails(address(sellToken), MIN_BALANCE);
        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertTrue(success, "Swap still works with original router after ownership transfer");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GROUP 12: PAYMENTRAILS RECONFIGURATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Disable → re-enable → swap works.
    function test_Reconfiguration_DisableThenReEnable() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        // Disable
        bytes memory params = abi.encode(address(buyToken), uint16(0), address(0), address(0), uint256(0));
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "DEX_SWAP", address(module), MIN_BALANCE, params, false);

        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRails_TokenNotEnabled.selector));
        paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        // Re-enable
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "DEX_SWAP", address(module), MIN_BALANCE, params, true);

        vm.prank(keeper);
        bool success = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);

        assertTrue(success, "Swap must work after re-enable");
    }

    /// @dev Swap modules: reconfigure to a different DexSwapModule.
    function test_Reconfiguration_SwapToNewModule() public {
        _configurePaymentRails(address(sellToken), MIN_BALANCE);

        // First swap with original module
        bytes memory executionData = _buildExecutionData(SELL_AMOUNT, BUY_AMOUNT);
        vm.prank(keeper);
        bool s1 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, executionData);
        assertTrue(s1, "First swap with old module must succeed");

        // Deploy new module and router
        DexSwapModule newModule = new DexSwapModule(owner);
        MockRouter newRouter = new MockRouter();
        buyToken.mint(address(newRouter), BUY_AMOUNT * 10);

        vm.prank(owner);
        newModule.addRouter(address(newRouter));

        // Reconfigure paymentRails to use new module
        bytes memory params = abi.encode(address(buyToken), uint16(0), address(0), address(0), uint256(0));
        vm.prank(owner);
        paymentRails.configureToken(address(sellToken), "DEX_SWAP", address(newModule), MIN_BALANCE, params, true);

        // Build executionData for new router
        bytes memory newRouterCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            SELL_AMOUNT,
            address(buyToken),
            address(paymentRails),
            BUY_AMOUNT
        );
        bytes memory newExecData = abi.encode(address(newRouter), MIN_AMOUNT_OUT, type(uint256).max, newRouterCalldata);

        vm.prank(keeper);
        bool s2 = paymentRails.executeAction(address(sellToken), SELL_AMOUNT, newExecData);
        assertTrue(s2, "Second swap with new module must succeed");
        assertEq(buyToken.balanceOf(address(paymentRails)), BUY_AMOUNT * 2, "Both swaps credited buyToken");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _configurePaymentRails(address token, uint256 minBal) internal {
        bytes memory params = abi.encode(address(buyToken), uint16(0), address(0), address(0), uint256(0));
        vm.prank(owner);
        paymentRails.configureToken(token, "DEX_SWAP", address(module), minBal, params, true);
    }

    function _configurePaymentRailsFor(PaymentRails pr, address token, uint256 minBal) internal {
        bytes memory params = abi.encode(address(buyToken), uint16(0), address(0), address(0), uint256(0));
        vm.prank(owner);
        pr.configureToken(token, "DEX_SWAP", address(module), minBal, params, true);
    }

    function _createPaymentRails() internal returns (PaymentRails) {
        vm.prank(owner);
        return new PaymentRails(owner);
    }

    function _routerCalldata(uint256 sellAmount, uint256 buyAmount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            sellAmount,
            address(buyToken),
            address(paymentRails),
            buyAmount
        );
    }

    function _buildExecutionData(uint256 sellAmount, uint256 buyAmount) internal view returns (bytes memory) {
        bytes memory routerCalldata = _routerCalldata(sellAmount, buyAmount);
        return abi.encode(address(router), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);
    }

    function _buildExecutionDataForNode(
        PaymentRails pr,
        uint256 sellAmount,
        uint256 buyAmount
    )
        internal
        view
        returns (bytes memory)
    {
        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector, address(sellToken), sellAmount, address(buyToken), address(pr), buyAmount
        );
        return abi.encode(address(router), MIN_AMOUNT_OUT, type(uint256).max, routerCalldata);
    }
}
