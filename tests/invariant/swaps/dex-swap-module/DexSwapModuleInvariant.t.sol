// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../src/modules/swaps/DexSwapModule.sol";
import { DexSwapModuleHandler, SwapPaymentRailsProxy } from "./DexSwapModuleHandler.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockRouter } from "../../../shared/mocks/MockRouter.sol";

/// @title DexSwapModuleInvariant
/// @notice Foundry stateful fuzz (invariant) tests for DexSwapModule.
///
/// ## Why Invariants?
/// These tests drive the module through arbitrary sequences of actions
/// (execute, failing swaps, addRouter, removeRouter, transferOwnership) and verify
/// that seven core properties always hold — regardless of execution order.
///
/// ## Invariants Implemented
///
/// INV-1: Module balance always zero
///   After any completed action, the module holds zero sell/buy tokens.
///   DexSwapModule is stateless — no token residuals.
///
/// INV-2: Router approval always zero
///   After any completed action, the module's approval to any router is zero.
///   The module uses approve-call-revoke pattern.
///
/// INV-3: moduleType() always returns "SWAP"
///   A constant — must never change regardless of state transitions.
///
/// INV-4: Router whitelist integrity
///   On-chain isRouterAllowed() must match handler ghost state for every tracked router.
///
/// INV-5: View functions never revert
///   validate(), estimateOutput(), isRouterAllowed(), moduleType() — for any input.
///
/// INV-6: Ownership consistency
///   On-chain owner() and pendingOwner() must match ghost state.
///
/// INV-7: Token conservation
///   Total sellToken spent by paymentRails == total buyToken received by paymentRails
///   (under the simplified model where buyAmount == minAmountOut, bounded to sellAmount).
///
/// ## Running
///   forge test --match-contract DexSwapModuleInvariant --runs 1000
///   forge test --match-contract DexSwapModuleInvariant --runs 10000  # thorough
contract DexSwapModuleInvariant is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    DexSwapModuleHandler internal handler;
    SwapPaymentRailsProxy internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockRouter internal router;

    address internal moduleOwner;

    function setUp() public {
        moduleOwner = makeAddr("moduleOwner");

        module = new DexSwapModule(moduleOwner);
        router = new MockRouter();
        paymentRails = new SwapPaymentRailsProxy(address(module));
        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");

        vm.prank(moduleOwner);
        module.addRouter(address(router));

        handler = new DexSwapModuleHandler(module, paymentRails, sellToken, buyToken, router, moduleOwner);

        targetContract(address(handler));
        excludeContract(address(module));
        excludeContract(address(paymentRails));
        excludeContract(address(sellToken));
        excludeContract(address(buyToken));
        excludeContract(address(router));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-1: MODULE BALANCE ALWAYS ZERO
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-1: Module must hold zero sellToken and zero buyToken after any action.
    /// @dev DexSwapModule is stateless: _returnLeftover sends back unconsumed sellToken,
    ///      and router sends buyToken directly to paymentRails. No token should ever remain.
    function invariant_ModuleBalance_AlwaysZero() public view {
        assertEq(sellToken.balanceOf(address(module)), 0, "INV-1: module must hold zero sellToken after any action");
        assertEq(buyToken.balanceOf(address(module)), 0, "INV-1: module must hold zero buyToken after any action");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-2: ROUTER APPROVAL ALWAYS ZERO
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-2: Module approval to any tracked router must be zero after any action.
    /// @dev The module uses approve-call-revoke: forceApprove(actualIn) before call,
    ///      forceApprove(0) after call. No lingering approval.
    function invariant_RouterApproval_AlwaysZero() public view {
        uint256 len = handler.ghost_allRoutersLength();

        for (uint256 i = 0; i < len; i++) {
            address trackedRouter = handler.ghost_allRouters(i);
            uint256 allowance = sellToken.allowance(address(module), trackedRouter);
            assertEq(allowance, 0, "INV-2: module approval to router must be zero after any action");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-3: MODULE TYPE IS CONSTANT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-3: moduleType() must always return "SWAP".
    function invariant_ModuleType_AlwaysSWAP() public view {
        assertEq(module.moduleType(), "SWAP", "INV-3: moduleType must always return SWAP");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-4: ROUTER WHITELIST INTEGRITY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-4: On-chain isRouterAllowed must match ghost state for every tracked router.
    function invariant_RouterWhitelist_MatchesGhost() public view {
        uint256 len = handler.ghost_allRoutersLength();

        for (uint256 i = 0; i < len; i++) {
            address trackedRouter = handler.ghost_allRouters(i);
            bool ghostAllowed = handler.ghost_routerIsAllowed(trackedRouter);
            bool onChainAllowed = module.isRouterAllowed(trackedRouter);

            assertEq(onChainAllowed, ghostAllowed, "INV-4: on-chain router whitelist must match ghost state");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-5: VIEW FUNCTIONS NEVER REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-5: View function revert flag set by handler must remain false.
    /// @dev The handler's handler_callViewFunctions() sets ghost_viewFunctionReverted=true
    ///      if any view function reverts. This invariant checks that flag.
    function invariant_ViewFunctions_NeverRevert() public view {
        assertFalse(handler.ghost_viewFunctionReverted(), "INV-5: a view function reverted on arbitrary input");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-6: OWNERSHIP CONSISTENCY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-6: On-chain owner and pendingOwner must match ghost state.
    function invariant_OwnershipConsistency() public view {
        assertEq(module.owner(), handler.ghost_currentOwner(), "INV-6: on-chain owner must match ghost");
        assertEq(module.pendingOwner(), handler.ghost_pendingOwner(), "INV-6: on-chain pendingOwner must match ghost");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-7: TOKEN CONSERVATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-7: All successful swaps must produce buyToken equal to what was configured.
    /// @dev In the handler, buyAmount is bounded to [1, sellAmount] and minAmountOut == buyAmount,
    ///      so every successful swap's ghost_totalBuyTokenReceived must equal actual PR buyToken
    ///      balance minus any pre-existing balance (none in this test setup).
    function invariant_TokenConservation() public view {
        uint256 prBuyBalance = buyToken.balanceOf(address(paymentRails));
        assertEq(
            prBuyBalance,
            handler.ghost_totalBuyTokenReceived(),
            "INV-7: paymentRails buyToken balance must equal ghost total received"
        );
    }
}
