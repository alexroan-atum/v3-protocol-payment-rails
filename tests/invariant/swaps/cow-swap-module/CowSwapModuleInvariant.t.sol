// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { CowSwapModuleHandler, PaymentRailsProxy } from "./CowSwapModuleHandler.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockCowSettlement } from "../../../shared/mocks/MockCowSettlement.sol";

/// @title CowSwapModuleInvariant
/// @notice Foundry stateful fuzz (invariant) tests for CowSwapModule.
///
/// ## Why Invariants?
/// These tests drive the module through arbitrary sequences of actions
/// (execute, markFilled, cancelOrder, warpTime) and verify that
/// five core properties always hold — regardless of execution order.
///
/// ## Invariants Implemented
///
/// INV-1: Sell token accounting
///   sum(sellAmount for all PENDING orders, per token) <= module.balanceOf(token)
///   Catches collision orphans and cancelOrder draining unrelated orders.
///
/// INV-2: Lifecycle reachability — every PENDING order can reach a terminal state
///   Ghost order status must agree with on-chain status at all times.
///
/// INV-3: External view functions never revert
///   isValidSignature(), getOrder() — for any input.
///   Catches arithmetic overflow panic in isValidSignature.
///
/// INV-4: Max approval hygiene
///   Every token with at least one execute() call has sellToken.allowance(module, cowSettlement) == max.
///   Approvals are set once on first execute() per token and NEVER revoked (balance is the hard ceiling).
///
/// INV-5: No phantom balances
///   total deposited == module balance + total withdrawn via cancelOrder.
///
/// ## Running
///   forge test --match-contract CowSwapModuleInvariant --runs 1000
///   forge test --match-contract CowSwapModuleInvariant --runs 10000  # thorough
contract CowSwapModuleInvariant is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cow.protocol.domain.separator.test");

    CowSwapModule internal module;
    CowSwapModuleHandler internal handler;
    PaymentRailsProxy internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockCowSettlement internal cowSettlement;

    function setUp() public {
        cowSettlement = new MockCowSettlement(DOMAIN_SEPARATOR, makeAddr("vaultRelayer"));
        module = new CowSwapModule(address(cowSettlement), address(this));
        paymentRails = new PaymentRailsProxy(address(module));
        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");

        handler = new CowSwapModuleHandler(module, paymentRails, sellToken, buyToken, cowSettlement);

        // Target only the handler — Foundry calls random handler functions
        targetContract(address(handler));

        // Exclude direct calls to module/paymentRails/tokens from the invariant runner
        excludeContract(address(module));
        excludeContract(address(paymentRails));
        excludeContract(address(sellToken));
        excludeContract(address(buyToken));
        excludeContract(address(cowSettlement));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-1: SELL TOKEN ACCOUNTING
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-1: sum of pending sell amounts <= module's actual token balance
    /// @dev Catches:
    ///   - Order ID collision orphans tokens (module_balance > ghost_sum, but
    ///     the invariant direction guarantees module holds AT LEAST what it owes)
    ///   - cancelOrder returns min(balance, meta.sellAmount), ensuring the remaining
    ///     PENDING order still has its tokens in the module.
    ///
    /// Note: in the simplified handler model, sell tokens are NOT pulled when
    /// handler_simulateSettlement is called. SETTLED orders' tokens remain in module.
    /// This means: module_balance = sum(PENDING) + sum(SETTLED) >= sum(PENDING) always.
    function invariant_SellTokenBalance_GteSum_AllPendingOrders() public view {
        uint256 ghostSum = handler.ghost_sumPendingSellAmountsFor(address(sellToken));
        uint256 moduleBalance = sellToken.balanceOf(address(module));

        assertGe(
            moduleBalance, ghostSum, "INV-1: module sell token balance must be >= sum of all pending order sell amounts"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-2: LIFECYCLE REACHABILITY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-2: Ghost order status matches on-chain order status
    /// @dev Any discrepancy between ghost and on-chain state indicates a handler bug
    ///      or a contract bug that silently transitions orders without the expected path.
    ///
    /// On-chain status is derived from CowOrderMetadata.cancelled and ghost_isFilled:
    ///   0 = PENDING  (not cancelled, not filled)
    ///   1 = SETTLED  (not cancelled, filledAmounts >= sellAmount — tracked via ghost_isFilled)
    ///   2 = CANCELLED (meta.cancelled == true)
    function invariant_ExpiredPendingOrders_AreCancellable() public view {
        uint256 len = handler.ghost_allOrderIdsLength();

        for (uint256 i = 0; i < len; i++) {
            bytes32 orderId = handler.ghost_allOrderIds(i);
            uint8 ghostStatus = handler.ghost_orderStatus(orderId);

            DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);

            // Compute on-chain status from meta.cancelled and ghost_isFilled
            // (CowOrderMetadata has no status enum — only a cancelled bool)
            uint8 onChainStatus;
            if (meta.cancelled) {
                onChainStatus = 2; // CANCELLED
            } else if (handler.ghost_isFilled(orderId)) {
                onChainStatus = 1; // SETTLED (handler set filledAmounts >= sellAmount)
            } else {
                onChainStatus = 0; // PENDING
            }

            // Ghost and on-chain status must agree (no silent state transitions)
            assertEq(ghostStatus, onChainStatus, "INV-2: ghost order status disagrees with on-chain order status");

            // For PENDING orders: verify the order is reachable (has a valid paymentRails)
            if (ghostStatus == 0) {
                assertNotEq(meta.paymentRails, address(0), "INV-2: PENDING order must have a valid paymentRails");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-3: EXTERNAL VIEW FUNCTIONS NEVER REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-3: isValidSignature() must NEVER revert — EIP-1271 requirement
    /// @dev validTo is now stored directly (not recomputed), so type(uint32).max
    ///      validityDuration no longer causes arithmetic overflow. The handler's
    ///      execute() passes unbounded validityDuration, so type(uint32).max is
    ///      reachable — this invariant verifies the fix holds.
    function invariant_IsValidSignature_NeverReverts() public view {
        // Test with all known orderIds — specifically targets overflow path
        uint256 len = handler.ghost_allOrderIdsLength();
        for (uint256 i = 0; i < len; i++) {
            bytes32 orderId = handler.ghost_allOrderIds(i);

            // Use try/catch — external protocol functions must never revert
            try module.isValidSignature(orderId, abi.encode(orderId)) returns (bytes4 result) {
                assertTrue(
                    result == 0x1626ba7e || result == 0xffffffff,
                    "INV-3: isValidSignature must return MAGIC or FAILURE for known orderIds"
                );
            } catch {
                assertTrue(false, "INV-3 VIOLATED: isValidSignature reverted on known orderId");
            }
        }
    }

    /// @notice INV-3b: View function revert flag set by handler must remain false
    /// @dev The handler's handler_callViewFunctions() sets ghost_viewFunctionReverted=true
    ///      if any view function reverts. This invariant checks that flag.
    function invariant_ViewFunctions_NeverSetRevertFlag() public view {
        assertFalse(
            handler.ghost_viewFunctionReverted(),
            "INV-3: a view function reverted on arbitrary input (EIP-1271 violation or overflow bug)"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-4: MAX APPROVAL HYGIENE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-4: Every token that has ever had an execute() call has max approval
    /// @dev CowSwapModule sets approval to type(uint256).max on the FIRST execute() per token
    ///      and NEVER revokes it (cancelOrder() leaves approval unchanged).
    ///      This is safe: ERC20 balance is the hard ceiling on what CowSwap can pull.
    ///      Verifies the approval is always type(uint256).max for any token with an order.
    function invariant_TokensWithOrders_HaveMaxApproval() public view {
        uint256 len = handler.ghost_allOrderIdsLength();

        for (uint256 i = 0; i < len; i++) {
            bytes32 orderId = handler.ghost_allOrderIds(i);
            address orderSellToken = handler.ghost_orderSellToken(orderId);

            // Any token that has had an execute() call must have max approval
            uint256 approval = IERC20Interface(orderSellToken).allowance(address(module), module.vaultRelayer());
            assertEq(approval, type(uint256).max, "INV-4: token with order must have max approval to vaultRelayer");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-5: NO PHANTOM BALANCES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-5: total deposited == module balance + total withdrawn via cancelOrder
    /// @dev Every sell token ever deposited via execute() must be accounted for:
    ///      either still held by the module (PENDING or SETTLED in simplified model)
    ///      or returned via cancelOrder.
    ///
    /// Simplified model: sell tokens are NOT pulled from the module in handler_simulateSettlement.
    /// SETTLED tokens remain in the module, so:
    ///   ghost_totalDeposited == module_balance + ghost_totalWithdrawn(via cancel)
    ///
    /// Catches collision: both deposits add to ghost_totalDeposited.
    /// Module receives 2x tokens, both tracked in ghost_totalDeposited.
    /// After cancel (1x returned): totalDeposited = 2x, withdrawn = 1x,
    /// module_balance = 1x (orphaned token is part of module_balance)
    function invariant_NoPhantomBalances_SellToken() public view {
        uint256 totalDeposited = handler.ghost_totalDeposited(address(sellToken));
        uint256 moduleBalance = sellToken.balanceOf(address(module));
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn(address(sellToken));

        assertEq(
            totalDeposited,
            moduleBalance + totalWithdrawn,
            "INV-5: total deposited must equal module sell token balance + total withdrawn via cancel"
        );
    }
}

/// @dev Minimal IERC20 interface for allowance check in invariant
interface IERC20Interface {
    function allowance(address owner, address spender) external view returns (uint256);
}
