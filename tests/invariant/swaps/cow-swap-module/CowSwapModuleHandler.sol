// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockCowSettlement } from "../../../shared/mocks/MockCowSettlement.sol";

/// @dev Minimal Node proxy — holds sell tokens and delegates to module
contract NodeProxy is Test {
    CowSwapModule public immutable module;

    constructor(address _module) {
        module = CowSwapModule(_module);
    }

    function initiateSwap(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params);
    }
    // cancelOrder intentionally omitted: only the module owner may cancel
}

/*//////////////////////////////////////////////////////////////////////////
                            HANDLER CONTRACT
//////////////////////////////////////////////////////////////////////////*/

/// @title CowSwapModuleHandler
/// @notice Foundry invariant handler for CowSwapModule.
/// @dev Tracks ghost variables to enable invariant assertions.
///
/// Ghost variables mirror on-chain state so invariant functions can check
/// accounting properties without requiring internal storage access.
///
/// ## Simplified Settlement Model
/// handler_simulateSettlement sets filledAmounts in MockCowSettlement
/// (simulating solver confirmation on-chain) but does NOT pull sell tokens.
/// This simplification keeps INV-1 and INV-5 tractable:
///   - Sell tokens leave module ONLY via cancelOrder in this handler
///   - SETTLED orders' tokens remain in module (simplified)
///   - INV-1 and INV-5 still hold under this model
///
/// Supported invariants:
///   INV-1: sum(pending sellAmounts per token) <= module.balanceOf(token)
///   INV-2: every PENDING order has consistent on-chain state
///   INV-3: view functions never revert
///   INV-4: approval to cowSettlement == 0 after any terminal state
///   INV-5: no phantom balances (deposited == held + withdrawn via cancel)
contract CowSwapModuleHandler is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                MODULE UNDER TEST
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    NodeProxy internal node;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockCowSettlement internal cowSettlement;

    /*//////////////////////////////////////////////////////////////////////////
                                GHOST VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev All orderIds ever created (PENDING, SETTLED, or CANCELLED)
    bytes32[] public ghost_allOrderIds;

    /// @dev Per-orderId: the sellAmount recorded at creation (immutable after creation)
    mapping(bytes32 => uint256) public ghost_orderSellAmount;

    /// @dev Per-orderId: the sellToken recorded at creation
    mapping(bytes32 => address) public ghost_orderSellToken;

    /// @dev Per-orderId: status (0=PENDING, 1=SETTLED, 2=CANCELLED) — mirrors on-chain
    mapping(bytes32 => uint8) public ghost_orderStatus;

    /// @dev Per-orderId: whether handler_simulateSettlement set filledAmounts >= sellAmount
    mapping(bytes32 => bool) public ghost_isFilled;

    /// @dev Total sell tokens deposited (ever) per token address
    mapping(address => uint256) public ghost_totalDeposited;

    /// @dev Total sell tokens recovered (via cancelOrder) per token address
    mapping(address => uint256) public ghost_totalWithdrawn;

    /// @dev Set to true when a view function reverted (invariant violation)
    bool public ghost_viewFunctionReverted;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        CowSwapModule _module,
        NodeProxy _node,
        MockERC20 _sellToken,
        MockERC20 _buyToken,
        MockCowSettlement _cowSettlement
    ) {
        module = _module;
        node = _node;
        sellToken = _sellToken;
        buyToken = _buyToken;
        cowSettlement = _cowSettlement;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HANDLER ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Creates a new order with bounded fuzz inputs.
    ///      validityDuration has NO upper bound — full uint32 range tested.
    function handler_execute(uint256 sellAmount, uint256 minBuyAmount, uint32 validityDuration) external {
        // Bound to realistic values (but validityDuration is unbounded)
        sellAmount = bound(sellAmount, 1, 100_000e18);
        minBuyAmount = bound(minBuyAmount, 1, type(uint128).max);
        // validityDuration: only lower bound (>0), NO upper bound
        vm.assume(validityDuration >= 1);

        // Mint sell tokens to node
        sellToken.mint(address(node), sellAmount);

        DataTypes.CowSwapParams memory params = DataTypes.CowSwapParams({
            targetToken: address(buyToken),
            minBuyAmount: minBuyAmount,
            validityDuration: validityDuration,
            appData: keccak256("handler.test")
        });
        bytes memory encodedParams = module.encodeParams(params);

        DataTypes.ExecutionResult memory result = node.initiateSwap(address(sellToken), sellAmount, encodedParams);

        if (result.success && result.data.length == 32) {
            bytes32 orderId = abi.decode(result.data, (bytes32));

            // Always track totalDeposited — even for collisions (second deposit also transfers tokens)
            ghost_totalDeposited[address(sellToken)] += sellAmount;

            // Only record order metadata once per orderId (first call wins, like the contract)
            if (ghost_orderSellAmount[orderId] == 0) {
                ghost_allOrderIds.push(orderId);
                ghost_orderSellAmount[orderId] = sellAmount;
                ghost_orderSellToken[orderId] = address(sellToken);
                ghost_orderStatus[orderId] = 0;
            }
            // For collision: second deposit adds to ghost_totalDeposited but metadata is NOT
            // updated in ghost (mirrors the contract: metadata overwritten, but both token deposits land)
        }
    }

    /// @dev Simulates CowSwap solver filling the order — records in MockCowSettlement.
    /// @dev Does NOT pull sell tokens and does NOT mint buy tokens to Node.
    ///      Buy token handling is omitted from this handler (receiver=node means direct delivery
    ///      in reality; the simplified model focuses on sell token accounting invariants).
    function handler_simulateSettlement(uint256 orderIndex) external {
        uint256 len = ghost_allOrderIds.length;
        if (len == 0) return;
        orderIndex = bound(orderIndex, 0, len - 1);
        bytes32 orderId = ghost_allOrderIds[orderIndex];

        // Only simulate settlement for PENDING orders
        if (ghost_orderStatus[orderId] != 0) return;

        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        if (meta.cancelled) return;

        // Set filledAmounts to the order's sellAmount (simulates a full fill by solver)
        cowSettlement.setFilledAmount(orderId, meta.sellAmount);
        ghost_isFilled[orderId] = true;
        // Settled state is derived live from filledAmounts — update ghost to SETTLED
        ghost_orderStatus[orderId] = 1;
    }

    /// @dev Cancels a pending order.
    ///      Pranks as the module owner (the invariant test contract) since only the owner may cancel.
    function handler_cancelOrder(uint256 orderIndex) external {
        uint256 len = ghost_allOrderIds.length;
        if (len == 0) return;
        orderIndex = bound(orderIndex, 0, len - 1);
        bytes32 orderId = ghost_allOrderIds[orderIndex];

        if (ghost_orderStatus[orderId] != 0) return;
        if (ghost_isFilled[orderId]) return; // would revert with OrderAlreadyFilled

        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        if (meta.cancelled) return;

        uint256 moduleBalBefore = sellToken.balanceOf(address(module));

        vm.prank(module.owner());
        try module.cancelOrder(orderId) {
            ghost_orderStatus[orderId] = 2;
            uint256 recovered = moduleBalBefore - sellToken.balanceOf(address(module));
            ghost_totalWithdrawn[address(sellToken)] += recovered;
        } catch { }
    }

    /// @dev INV-3: Calls view functions with random inputs to verify they never revert.
    function handler_callViewFunctions(bytes32 hash, bytes calldata sig) external {
        // isValidSignature: EIP-1271 — must NEVER revert
        try module.isValidSignature(hash, sig) returns (bytes4 result) {
            assertTrue(
                result == 0x1626ba7e || result == 0xffffffff, "isValidSignature must return MAGIC or FAILURE only"
            );
        } catch {
            ghost_viewFunctionReverted = true;
        }

        // getOrder: must NEVER revert
        try module.getOrder(hash) returns (DataTypes.CowOrderMetadata memory) {
            // any return value is fine
        } catch {
            ghost_viewFunctionReverted = true;
        }
    }

    /// @dev Advance time to simulate order expiry.
    function handler_warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                GHOST HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function ghost_pendingOrderCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < ghost_allOrderIds.length; i++) {
            if (ghost_orderStatus[ghost_allOrderIds[i]] == 0) {
                count++;
            }
        }
    }

    function ghost_sumPendingSellAmountsFor(address token) external view returns (uint256 sum) {
        for (uint256 i = 0; i < ghost_allOrderIds.length; i++) {
            bytes32 id = ghost_allOrderIds[i];
            if (ghost_orderStatus[id] == 0 && ghost_orderSellToken[id] == token) {
                sum += ghost_orderSellAmount[id];
            }
        }
    }

    function ghost_allOrderIdsLength() external view returns (uint256) {
        return ghost_allOrderIds.length;
    }
}
