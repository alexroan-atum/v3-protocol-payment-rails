// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockCowSettlement } from "../../../shared/mocks/MockCowSettlement.sol";
import { MockChainlinkAggregator } from "../../../shared/mocks/MockChainlinkAggregator.sol";

/// @dev Minimal PaymentRails proxy — holds sell tokens and delegates to module.
/// Deploy first, pass address to CowSwapModule constructor, then call setModule().
contract PaymentRailsProxy is Test {
    CowSwapModule public module;

    function setModule(address _module) external {
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
}

/*//////////////////////////////////////////////////////////////////////////
                            HANDLER CONTRACT
//////////////////////////////////////////////////////////////////////////*/

/// @title CowSwapModuleHandler
/// @notice Foundry invariant handler for CowSwapModule.
/// @dev Simplified settlement model: sell tokens leave module ONLY via cancelOrder (not on settlement).
///      SETTLED tokens remain in module, keeping INV-1 and INV-5 tractable.
contract CowSwapModuleHandler is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                MODULE UNDER TEST
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    PaymentRailsProxy internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockCowSettlement internal cowSettlement;
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    /*//////////////////////////////////////////////////////////////////////////
                                GHOST VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    bytes32[] public ghost_allOrderIds;
    mapping(bytes32 => uint256) public ghost_orderSellAmount;
    mapping(bytes32 => address) public ghost_orderSellToken;
    mapping(bytes32 => uint8) public ghost_orderStatus; // 0=PENDING, 1=SETTLED, 2=CANCELLED
    mapping(bytes32 => bool) public ghost_isFilled;
    mapping(address => uint256) public ghost_totalDeposited;
    mapping(address => uint256) public ghost_totalWithdrawn;
    bool public ghost_viewFunctionReverted;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        CowSwapModule _module,
        PaymentRailsProxy _node,
        MockERC20 _sellToken,
        MockERC20 _buyToken,
        MockCowSettlement _cowSettlement,
        MockChainlinkAggregator _sellFeed,
        MockChainlinkAggregator _buyFeed
    ) {
        module = _module;
        paymentRails = _node;
        sellToken = _sellToken;
        buyToken = _buyToken;
        cowSettlement = _cowSettlement;
        sellFeed = _sellFeed;
        buyFeed = _buyFeed;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HANDLER ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev validityDuration unbounded — full uint32 range tested.
    function handler_execute(uint256 sellAmount, uint16 maxSlippageBps, uint32 validityDuration) external {
        sellAmount = bound(sellAmount, 1, 100_000e18);
        maxSlippageBps = uint16(bound(uint256(maxSlippageBps), 1, 10_000));
        vm.assume(validityDuration >= 1);

        sellToken.mint(address(paymentRails), sellAmount);

        DataTypes.CowSwapParams memory params = DataTypes.CowSwapParams({
            targetToken: address(buyToken),
            maxSlippageBps: maxSlippageBps,
            sellTokenPriceFeed: address(sellFeed),
            buyTokenPriceFeed: address(buyFeed),
            maxStaleness: 3600,
            validityDuration: validityDuration,
            appData: keccak256("handler.test")
        });
        bytes memory encodedParams = module.encodeParams(params);

        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), sellAmount, encodedParams);

        if (result.success && result.data.length == 32) {
            bytes32 orderId = abi.decode(result.data, (bytes32));

            ghost_totalDeposited[address(sellToken)] += sellAmount;

            if (ghost_orderSellAmount[orderId] == 0) {
                ghost_allOrderIds.push(orderId);
                ghost_orderSellAmount[orderId] = sellAmount;
                ghost_orderSellToken[orderId] = address(sellToken);
                ghost_orderStatus[orderId] = 0;
            }
        }
    }

    /// @dev Sets filledAmounts in mock — does NOT pull sell tokens (simplified model).
    function handler_simulateSettlement(uint256 orderIndex) external {
        uint256 len = ghost_allOrderIds.length;
        if (len == 0) return;
        orderIndex = bound(orderIndex, 0, len - 1);
        bytes32 orderId = ghost_allOrderIds[orderIndex];

        if (ghost_orderStatus[orderId] != 0) return;

        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        if (meta.cancelled) return;

        cowSettlement.setFilledAmount(orderId, meta.sellAmount);
        ghost_isFilled[orderId] = true;
        ghost_orderStatus[orderId] = 1;
    }

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

    /// @dev INV-3: view functions must never revert.
    function handler_callViewFunctions(bytes32 hash, bytes calldata sig) external {
        try module.isValidSignature(hash, sig) returns (bytes4 result) {
            assertTrue(
                result == 0x1626ba7e || result == 0xffffffff, "isValidSignature must return MAGIC or FAILURE only"
            );
        } catch {
            ghost_viewFunctionReverted = true;
        }

        try module.getOrder(hash) returns (DataTypes.CowOrderMetadata memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }
    }

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
