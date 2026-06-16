// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../src/modules/swaps/DexSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockRouter } from "../../../shared/mocks/MockRouter.sol";
import { MockChainlinkAggregator } from "../../../shared/mocks/MockChainlinkAggregator.sol";

/// @dev Minimal PaymentRails proxy — holds tokens, approves module, and forwards execute() calls.
contract SwapPaymentRailsProxy is Test {
    DexSwapModule public immutable module;

    constructor(address _module) {
        module = DexSwapModule(_module);
    }

    function executeSwap(
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

/// @title DexSwapModuleHandler
/// @notice Foundry invariant handler for DexSwapModule.
/// @dev Tracks ghost variables to enable invariant assertions.
///
/// Architecture: DexSwapModule has an immutable router (set at construction) and
/// computes amountOutMinimum on-chain from Chainlink oracle prices. No executionData,
/// no router whitelist, no owner.
///
/// Supported invariants:
///   INV-1: Module balance is always zero after any completed action
///   INV-2: Router approval from module is always zero after any completed action
///   INV-3: moduleType() always returns "SWAP"
///   INV-4: View functions never revert on arbitrary inputs
///   INV-5: Token conservation — total sold by paymentRails == total received as buyToken
contract DexSwapModuleHandler is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                MODULE UNDER TEST
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    SwapPaymentRailsProxy internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockRouter internal router;
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    /*//////////////////////////////////////////////////////////////////////////
                                GHOST VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Total sellToken spent by paymentRails across all successful swaps
    uint256 public ghost_totalSellTokenSpent;

    /// @dev Total buyToken received by paymentRails across all successful swaps
    uint256 public ghost_totalBuyTokenReceived;

    /// @dev Total successful swap count
    uint256 public ghost_successfulSwapCount;

    /// @dev Set to true when a view function reverted (invariant violation)
    bool public ghost_viewFunctionReverted;

    /// @dev Set to true if the module's success/failure outcome disagrees with the
    ///      predicted maxAmount gating (invariant violation).
    bool public ghost_gatingInvariantViolated;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint24 internal constant DEFAULT_FEE = 3000;
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600;
    uint256 internal constant DEFAULT_SWAP_DEADLINE = 300;

    int256 internal constant SELL_PRICE = 1e8;
    int256 internal constant BUY_PRICE = 1e8;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        DexSwapModule _module,
        SwapPaymentRailsProxy _paymentRails,
        MockERC20 _sellToken,
        MockERC20 _buyToken,
        MockRouter _router,
        MockChainlinkAggregator _sellFeed,
        MockChainlinkAggregator _buyFeed
    ) {
        module = _module;
        paymentRails = _paymentRails;
        sellToken = _sellToken;
        buyToken = _buyToken;
        router = _router;
        sellFeed = _sellFeed;
        buyFeed = _buyFeed;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SWAP EXECUTION ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Executes a swap with bounded fuzz inputs, fuzzing maxAmount so the module's
    ///      per-call reject ceiling is meaningfully exercised. The handler predicts the
    ///      gating outcome and asserts the module agrees.
    function handler_execute(uint256 sellAmount, uint256 buyAmount, uint256 maxAmount) external {
        // Lower bound keeps the oracle floor strictly positive so the only failure cause
        // is the gating path we model (maxAmount), not floor-rounds-to-zero.
        sellAmount = bound(sellAmount, 1e3, 100_000e18);
        uint256 oracleFloor = sellAmount * (10_000 - uint256(DEFAULT_SLIPPAGE_BPS)) / 10_000;
        buyAmount = bound(buyAmount, oracleFloor, sellAmount * 2);
        maxAmount = bound(maxAmount, 0, 200_000e18);

        sellToken.mint(address(paymentRails), sellAmount);
        buyToken.mint(address(router), buyAmount);

        bytes memory params = _paramsWithLimits(maxAmount);
        router.setShouldRevert(false);
        router.setOutputAmount(buyAmount);

        // Keep oracles fresh after time warps so the only failure cause is the gating
        // path we model (maxAmount), not oracle staleness.
        sellFeed.setUpdatedAt(block.timestamp);
        buyFeed.setUpdatedAt(block.timestamp);

        // Predict the gating outcome: _validateParams rejects when amount exceeds maxAmount.
        bool expectMaxAmountGate = maxAmount != 0 && sellAmount > maxAmount;
        bool expectSuccess = !expectMaxAmountGate;

        uint256 prSellBefore = sellToken.balanceOf(address(paymentRails));
        uint256 prBuyBefore = buyToken.balanceOf(address(paymentRails));

        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(address(sellToken), sellAmount, params);

        if (result.success != expectSuccess) {
            ghost_gatingInvariantViolated = true;
        }
        if (expectMaxAmountGate && !_eq(result.failureReason, "Exceeds max swap amount")) {
            ghost_gatingInvariantViolated = true;
        }

        if (result.success) {
            uint256 sellSpent = prSellBefore - sellToken.balanceOf(address(paymentRails));
            uint256 buyReceived = buyToken.balanceOf(address(paymentRails)) - prBuyBefore;
            ghost_totalSellTokenSpent += sellSpent;
            ghost_totalBuyTokenReceived += buyReceived;
            ghost_successfulSwapCount++;
        } else {
            // A gated swap must move no tokens.
            if (sellToken.balanceOf(address(paymentRails)) != prSellBefore) {
                ghost_gatingInvariantViolated = true;
            }
            if (buyToken.balanceOf(address(paymentRails)) != prBuyBefore) {
                ghost_gatingInvariantViolated = true;
            }
        }
    }

    /// @dev Advances block time so oracle freshness windows are exercised during the fuzz run.
    function handler_warp(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 14_400);
        vm.warp(block.timestamp + secondsForward);
    }

    /// @dev Attempts a swap that should fail (router set to revert).
    function handler_executeFailingSwap(uint256 sellAmount) external {
        sellAmount = bound(sellAmount, 1, 100_000e18);

        sellToken.mint(address(paymentRails), sellAmount);

        router.setShouldRevert(true);

        bytes memory params = _defaultParams();

        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(address(sellToken), sellAmount, params);

        assertFalse(result.success, "Failing swap must not succeed");

        router.setShouldRevert(false);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        VIEW FUNCTION PROBING
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev INV-4: Calls view functions to verify they never revert.
    function handler_callViewFunctions(uint256 amount) external {
        amount = bound(amount, 0, type(uint128).max);
        bytes memory params = _defaultParams();

        try module.validate(address(sellToken), amount, params) returns (bool, string memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        try module.validate(address(buyToken), amount, params) returns (bool, string memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        try module.estimateOutput(address(sellToken), amount, params) returns (uint256, address) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        try module.moduleType() returns (string memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        try module.router() returns (address) { }
        catch {
            ghost_viewFunctionReverted = true;
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultParams() internal view returns (bytes memory) {
        return _paramsWithLimits(0);
    }

    function _paramsWithLimits(uint256 maxAmount) internal view returns (bytes memory) {
        return abi.encode(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE,
            maxAmount
        );
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
