// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { CowSwapModuleHandler, PaymentRailsProxy } from "./CowSwapModuleHandler.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockCowSettlement } from "../../../shared/mocks/MockCowSettlement.sol";
import { MockChainlinkAggregator } from "../../../shared/mocks/MockChainlinkAggregator.sol";

/// @title CowSwapModuleInvariant
/// @notice Stateful fuzz tests verifying five invariants: sell token accounting, lifecycle reachability,
///         view-function safety, max-approval hygiene, and no phantom balances.
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
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    function setUp() public {
        vm.warp(1_700_000_000);

        cowSettlement = new MockCowSettlement(DOMAIN_SEPARATOR, makeAddr("vaultRelayer"));
        paymentRails = new PaymentRailsProxy();
        module = new CowSwapModule(address(cowSettlement), address(this), address(paymentRails), address(0), 0);
        paymentRails.setModule(address(module));
        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");
        sellFeed = new MockChainlinkAggregator(1e8, 8);
        buyFeed = new MockChainlinkAggregator(1e8, 8);

        handler = new CowSwapModuleHandler(module, paymentRails, sellToken, buyToken, cowSettlement, sellFeed, buyFeed);

        targetContract(address(handler));

        excludeContract(address(module));
        excludeContract(address(paymentRails));
        excludeContract(address(sellToken));
        excludeContract(address(buyToken));
        excludeContract(address(cowSettlement));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-1: SELL TOKEN ACCOUNTING
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-1: sum of pending sell amounts <= module's actual token balance.
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

    /// @notice INV-2: Ghost order status matches on-chain order status.
    function invariant_ExpiredPendingOrders_AreCancellable() public view {
        uint256 len = handler.ghost_allOrderIdsLength();

        for (uint256 i = 0; i < len; i++) {
            bytes32 orderId = handler.ghost_allOrderIds(i);
            uint8 ghostStatus = handler.ghost_orderStatus(orderId);

            DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);

            uint8 onChainStatus;
            if (meta.cancelled) {
                onChainStatus = 2;
            } else if (handler.ghost_isFilled(orderId)) {
                onChainStatus = 1;
            } else {
                onChainStatus = 0;
            }

            assertEq(ghostStatus, onChainStatus, "INV-2: ghost order status disagrees with on-chain order status");

            if (ghostStatus == 0) {
                assertNotEq(meta.paymentRails, address(0), "INV-2: PENDING order must have a valid paymentRails");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-3: EXTERNAL VIEW FUNCTIONS NEVER REVERT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-3: isValidSignature() must NEVER revert — EIP-1271 requirement.
    function invariant_IsValidSignature_NeverReverts() public view {
        uint256 len = handler.ghost_allOrderIdsLength();
        for (uint256 i = 0; i < len; i++) {
            bytes32 orderId = handler.ghost_allOrderIds(i);

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

    /// @notice INV-3b: View function revert flag set by handler must remain false.
    function invariant_ViewFunctions_NeverSetRevertFlag() public view {
        assertFalse(
            handler.ghost_viewFunctionReverted(),
            "INV-3: a view function reverted on arbitrary input (EIP-1271 violation or overflow bug)"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-4: MAX APPROVAL HYGIENE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-4: Every token that has ever had an execute() call has max approval.
    function invariant_TokensWithOrders_HaveMaxApproval() public view {
        uint256 len = handler.ghost_allOrderIdsLength();

        for (uint256 i = 0; i < len; i++) {
            bytes32 orderId = handler.ghost_allOrderIds(i);
            address orderSellToken = handler.ghost_orderSellToken(orderId);

            uint256 approval = IERC20Interface(orderSellToken).allowance(address(module), module.vaultRelayer());
            assertEq(approval, type(uint256).max, "INV-4: token with order must have max approval to vaultRelayer");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    INV-5: NO PHANTOM BALANCES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice INV-5: total deposited == module balance + total withdrawn via cancelOrder.
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

interface IERC20Interface {
    function allowance(address owner, address spender) external view returns (uint256);
}
