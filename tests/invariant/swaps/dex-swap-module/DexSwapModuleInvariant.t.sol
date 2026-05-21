// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../src/modules/swaps/DexSwapModule.sol";
import { DexSwapModuleHandler, SwapPaymentRailsProxy } from "./DexSwapModuleHandler.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockRouter } from "../../../shared/mocks/MockRouter.sol";
import { MockChainlinkAggregator } from "../../../shared/mocks/MockChainlinkAggregator.sol";

/// @title DexSwapModuleInvariant
/// @notice Foundry stateful fuzz (invariant) tests for DexSwapModule.
///
/// ## Architecture Note
/// DexSwapModule now has an immutable router and no owner/whitelist. Oracle feeds
/// are mandatory. All parameters are in the static DexSwapParams.
///
/// ## Invariants Implemented
///
/// INV-1: Module balance always zero
///   After any completed action, the module holds zero sell/buy tokens.
///   DexSwapModule is stateless — no token residuals.
///
/// INV-2: Router approval always zero
///   After any completed action, the module's approval to the router is zero.
///   The module uses approve-call-revoke pattern.
///
/// INV-3: moduleType() always returns "SWAP"
///   A constant — must never change regardless of state transitions.
///
/// INV-4: View functions never revert
///   validate(), estimateOutput(), moduleType(), router() — for any input.
///
/// INV-5: Token conservation
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
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    function setUp() public {
        vm.warp(1_700_000_000);

        router = new MockRouter();
        module = new DexSwapModule(address(router));
        paymentRails = new SwapPaymentRailsProxy(address(module));
        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");
        sellFeed = new MockChainlinkAggregator(1e8, 8); // $1
        buyFeed = new MockChainlinkAggregator(1e8, 8); // $1

        handler = new DexSwapModuleHandler(module, paymentRails, sellToken, buyToken, router, sellFeed, buyFeed);

        targetContract(address(handler));
        excludeContract(address(module));
        excludeContract(address(paymentRails));
        excludeContract(address(sellToken));
        excludeContract(address(buyToken));
        excludeContract(address(router));
        excludeContract(address(sellFeed));
        excludeContract(address(buyFeed));
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

    /// @notice INV-2: Module approval to the immutable router must be zero after any action.
    /// @dev The module uses approve-call-revoke: forceApprove(actualIn) before call,
    ///      forceApprove(0) after call. No lingering approval.
    function invariant_RouterApproval_AlwaysZero() public view {
        uint256 allowance = sellToken.allowance(address(module), address(router));
        assertEq(allowance, 0, "INV-2: module approval to router must be zero after any action");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-3: MODULE TYPE IS CONSTANT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-3: moduleType() must always return "SWAP".
    function invariant_ModuleType_AlwaysSWAP() public view {
        assertEq(module.moduleType(), "SWAP", "INV-3: moduleType must always return SWAP");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-4: VIEW FUNCTIONS NEVER REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-4: View function revert flag set by handler must remain false.
    /// @dev The handler's handler_callViewFunctions() sets ghost_viewFunctionReverted=true
    ///      if any view function reverts. This invariant checks that flag.
    function invariant_ViewFunctions_NeverRevert() public view {
        assertFalse(handler.ghost_viewFunctionReverted(), "INV-4: a view function reverted on arbitrary input");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-5: TOKEN CONSERVATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-5: All successful swaps must produce buyToken equal to what was configured.
    /// @dev In the handler, buyAmount is bounded to [1, sellAmount] and the router is configured
    ///      to output exactly buyAmount. So paymentRails's buyToken balance must match the ghost.
    function invariant_TokenConservation() public view {
        uint256 prBuyBalance = buyToken.balanceOf(address(paymentRails));
        assertEq(
            prBuyBalance,
            handler.ghost_totalBuyTokenReceived(),
            "INV-5: paymentRails buyToken balance must equal ghost total received"
        );
    }
}
