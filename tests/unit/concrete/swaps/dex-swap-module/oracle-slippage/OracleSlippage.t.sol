// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { MockChainlinkAggregator } from "../../../../../shared/mocks/MockChainlinkAggregator.sol";
import { MockRouter } from "../../../../../shared/mocks/MockRouter.sol";
import { MockERC20 } from "../../../../../shared/mocks/MockERC20.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Unit tests for DexSwapModule oracle-enforced slippage protection.
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/oracle-slippage/oracleSlippage.tree
contract DexSwapModule_OracleSlippage_Test is DexSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////////////////*/

    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    // 1 sellToken = $2000, 1 buyToken = $1 (simulates ETH/USDC-like pair)
    int256 internal constant SELL_PRICE = 2000e8;
    int256 internal constant BUY_PRICE = 1e8;
    uint8 internal constant FEED_DECIMALS = 8;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant MAX_STALENESS = 3600; // 1 hour

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public override {
        vm.warp(1_700_000_000);
        super.setUp();

        sellFeed = new MockChainlinkAggregator(SELL_PRICE, FEED_DECIMALS);
        buyFeed = new MockChainlinkAggregator(BUY_PRICE, FEED_DECIMALS);

        vm.label(address(sellFeed), "SellPriceFeed");
        vm.label(address(buyFeed), "BuyPriceFeed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _oracleParams() internal view returns (bytes memory) {
        return abi.encode(address(buyToken), MAX_SLIPPAGE_BPS, address(sellFeed), address(buyFeed), MAX_STALENESS);
    }

    function _oracleParamsCustom(
        uint16 slippageBps,
        address _sellFeed,
        address _buyFeed,
        uint256 staleness
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(address(buyToken), slippageBps, _sellFeed, _buyFeed, staleness);
    }

    function _oracleExecutionData(uint256 minAmountOut) internal view returns (bytes memory) {
        bytes memory routerCalldata = _defaultRouterCalldata();
        return abi.encode(address(router), minAmountOut, DEFAULT_DEADLINE, routerCalldata);
    }

    function _computeExpectedOutput(uint256 sellAmount) internal pure returns (uint256) {
        // sellToken 18 dec, buyToken 18 dec, both feeds 8 dec
        // sellExp = 18 + 8 = 26, buyExp = 18 + 8 = 26, equal
        // expected = amount * sellPrice / buyPrice = amount * 2000e8 / 1e8 = amount * 2000
        return Math.mulDiv(sellAmount, uint256(SELL_PRICE), uint256(BUY_PRICE));
    }

    function _computeOracleFloor(uint256 sellAmount) internal pure returns (uint256) {
        uint256 expected = _computeExpectedOutput(sellAmount);
        return expected * (10_000 - uint256(MAX_SLIPPAGE_BPS)) / 10_000;
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS NOT CONFIGURED (feeds are zero addresses)
    //////////////////////////////////////////////////////////////////////////*/

    function test_NoOracle_Execute_SkipsOracleCheck() external {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(
            address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData()
        );

        assertTrue(result.success, "Should succeed without oracle");
    }

    function test_NoOracle_Validate_SkipsOracleCheck() external {
        vm.prank(address(paymentRails));
        (bool isValid,) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams(), _defaultExecutionData());
        assertTrue(isValid, "Should validate without oracle");
    }

    function test_NoOracle_EstimateOutput_ReturnsZero() external view {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(estimated, 0, "No oracle = zero estimate");
        assertEq(outputToken, address(buyToken), "Should still return target token");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS PARTIALLY CONFIGURED
    //////////////////////////////////////////////////////////////////////////*/

    function test_PartialOracle_OnlyOneFeedSet_SkipsOracleCheck() external {
        bytes memory params = _oracleParamsCustom(MAX_SLIPPAGE_BPS, address(sellFeed), address(0), MAX_STALENESS);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());

        assertTrue(result.success, "Should succeed with partial oracle config");
    }

    function test_PartialOracle_ZeroSlippageBps_SkipsOracleCheck() external {
        bytes memory params = _oracleParamsCustom(0, address(sellFeed), address(buyFeed), MAX_STALENESS);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());

        assertTrue(result.success, "Should succeed with zero maxSlippageBps");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — FEED FAILURES
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SellFeedNegativePrice_Execute_Fails() external {
        sellFeed.setAnswer(-1);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success, "Should fail with negative sell price");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedNegativePrice_Execute_Fails() external {
        buyFeed.setAnswer(-1);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success, "Should fail with negative buy price");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedZeroPrice_Execute_Fails() external {
        sellFeed.setAnswer(0);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success, "Should fail with zero sell price");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedNegativePrice_Validate_Fails() external {
        sellFeed.setAnswer(-1);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedNegativePrice_Validate_Fails() external {
        buyFeed.setAnswer(-1);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — STALENESS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SellFeedStale_Execute_Fails() external {
        sellFeed.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedStale_Execute_Fails() external {
        buyFeed.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedStale_Validate_Fails() external {
        sellFeed.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedStale_Validate_Fails() external {
        buyFeed.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — FEED REVERTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SellFeedReverts_Execute_Fails() external {
        sellFeed.setShouldRevert(true);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedReverts_Execute_Fails() external {
        buyFeed.setShouldRevert(true);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedReverts_Validate_Fails() external {
        sellFeed.setShouldRevert(true);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedReverts_Validate_Fails() external {
        buyFeed.setShouldRevert(true);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — decimals() REVERTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_FeedDecimalsReverts_Execute_Fails() external {
        RevertingDecimalsAggregator badFeed = new RevertingDecimalsAggregator(SELL_PRICE);

        bytes memory params = _oracleParamsCustom(MAX_SLIPPAGE_BPS, address(badFeed), address(buyFeed), MAX_STALENESS);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());

        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_FeedDecimalsReverts_Validate_Fails() external {
        RevertingDecimalsAggregator badFeed = new RevertingDecimalsAggregator(SELL_PRICE);

        bytes memory params = _oracleParamsCustom(MAX_SLIPPAGE_BPS, address(badFeed), address(buyFeed), MAX_STALENESS);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — maxSlippageBps > 10000
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SlippageBpsExceeds10000_Execute_Fails() external {
        bytes memory params = _oracleParamsCustom(10_001, address(sellFeed), address(buyFeed), MAX_STALENESS);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());

        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SlippageBpsExceeds10000_Validate_Fails() external view {
        bytes memory params = _oracleParamsCustom(10_001, address(sellFeed), address(buyFeed), MAX_STALENESS);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params, _defaultExecutionData());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
        GIVEN ORACLE IS FULLY CONFIGURED — SLIPPAGE ENFORCEMENT (CORE LOGIC)
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_MinAmountOutBelowFloor_Execute_Reverts() external {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);
        uint256 lowMinAmountOut = oracleFloor - 1;

        bytes memory executionData = _oracleExecutionData(lowMinAmountOut);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DexSwapModule_SlippageExceedsOracleFloor.selector, lowMinAmountOut, oracleFloor
            )
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), executionData);
    }

    function test_Oracle_MinAmountOutBelowFloor_Validate_ReturnsFalse() external view {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);
        uint256 lowMinAmountOut = oracleFloor - 1;

        bytes memory executionData = _oracleExecutionData(lowMinAmountOut);

        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), executionData);

        assertFalse(isValid);
        assertEq(reason, "Slippage below oracle floor");
    }

    function test_Oracle_MinAmountOutEqualsFloor_Execute_Succeeds() external {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);

        // Router must output at least oracleFloor for the swap to succeed
        buyToken.mint(address(router), oracleFloor * 10);

        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            DEFAULT_SELL_AMOUNT,
            address(buyToken),
            address(paymentRails),
            oracleFloor
        );
        bytes memory executionData = abi.encode(address(router), oracleFloor, DEFAULT_DEADLINE, routerCalldata);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), executionData);

        assertTrue(result.success, "Should succeed when minAmountOut == oracleFloor");
        assertEq(result.amountOut, oracleFloor);
    }

    function test_Oracle_MinAmountOutAboveFloor_Execute_Succeeds() external {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);
        uint256 aboveFloor = oracleFloor + 1;

        buyToken.mint(address(router), aboveFloor * 10);

        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            DEFAULT_SELL_AMOUNT,
            address(buyToken),
            address(paymentRails),
            aboveFloor
        );
        bytes memory executionData = abi.encode(address(router), aboveFloor, DEFAULT_DEADLINE, routerCalldata);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), executionData);

        assertTrue(result.success, "Should succeed when minAmountOut > oracleFloor");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — DECIMAL NORMALIZATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_DifferentTokenDecimals_6And18() external {
        // Simulate USDC (6 dec) → ETH (18 dec) pair
        // USDC = $1, ETH = $2000
        // Selling 2000 USDC should yield ~1 ETH (1e18)
        MockERC20 usdc = new MockERC20("USDC", "USDC");
        MockERC20 weth = new MockERC20("WETH", "WETH");

        // Override decimals: USDC=6, WETH=18 (default)
        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(address(weth), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        MockChainlinkAggregator usdcFeed = new MockChainlinkAggregator(1e8, 8); // $1
        MockChainlinkAggregator ethFeed = new MockChainlinkAggregator(2000e8, 8); // $2000

        uint256 sellAmount = 2000e6; // 2000 USDC

        bytes memory params = abi.encode(address(weth), uint16(100), address(usdcFeed), address(ethFeed), uint256(3600));

        // estimateOutput: expected = 2000e6 * 1e8 / 2000e8 but with decimal normalization
        // sellExp = 6 + 8 = 14, buyExp = 18 + 8 = 26
        // buyExp > sellExp, diff = 12
        // expected = mulDiv(2000e6, 1e8 * 10^12, 2000e8) = mulDiv(2000e6, 1e20, 2000e8)
        //          = 2000e6 * 1e20 / 2000e8 = 1e18 (exactly 1 WETH)
        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), sellAmount, params);
        assertEq(outputToken, address(weth));
        assertEq(estimated, 1e18, "2000 USDC at $1 should yield 1 ETH at $2000");
    }

    function test_Oracle_DifferentFeedDecimals_8And18() external {
        // Sell feed has 8 decimals, buy feed has 18 decimals
        MockChainlinkAggregator feed8 = new MockChainlinkAggregator(2000e8, 8);
        MockChainlinkAggregator feed18 = new MockChainlinkAggregator(1e18, 18);

        bytes memory params = abi.encode(address(buyToken), uint16(100), address(feed8), address(feed18), uint256(3600));

        // Both tokens 18 decimals. sellExp = 18+8 = 26, buyExp = 18+18 = 36
        // buyExp > sellExp, diff = 10
        // expected = mulDiv(1000e18, 2000e8 * 10^10, 1e18) = mulDiv(1000e18, 2000e18, 1e18) = 2_000_000e18
        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(estimated, 2_000_000e18, "Different feed decimals should normalize correctly");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — estimateOutput
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_EstimateOutput_ReturnsNonZero() external view {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams());

        uint256 expectedOutput = _computeExpectedOutput(DEFAULT_SELL_AMOUNT);
        assertEq(estimated, expectedOutput, "Should match computed expected output");
        assertEq(outputToken, address(buyToken));
    }

    function test_Oracle_EstimateOutput_ScalesWithAmount() external view {
        (uint256 est1,) = module.estimateOutput(address(sellToken), 1e18, _oracleParams());
        (uint256 est10,) = module.estimateOutput(address(sellToken), 10e18, _oracleParams());

        assertEq(est10, est1 * 10, "Output should scale linearly with input");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — SANDWICH ATTACK PREVENTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SandwichAttack_MaliciousLowSlippage_Reverts() external {
        // Attacker sets minAmountOut = 1 (sandwich-enabling slippage)
        // Oracle floor = expected * (10000 - 100) / 10000 = expected * 0.99
        // For 1000e18 sell, expected = 2_000_000e18, floor = 1_980_000e18
        // minAmountOut = 1 << floor → revert
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);

        bytes memory executionData = _oracleExecutionData(1);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DexSwapModule_SlippageExceedsOracleFloor.selector, 1, oracleFloor)
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), executionData);
    }

    function test_Oracle_SandwichAttack_ModerateButBelowFloor_Reverts() external {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);
        // Set minAmountOut to 50% below floor — attacker trying to extract 50% of value
        uint256 halfFloor = oracleFloor / 2;

        bytes memory executionData = _oracleExecutionData(halfFloor);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DexSwapModule_SlippageExceedsOracleFloor.selector, halfFloor, oracleFloor)
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), executionData);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — MODULE HOLDS NO RESIDUAL STATE
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_NoResidualAfterOracleReject() external {
        sellFeed.setAnswer(-1);

        uint256 moduleSellBefore = sellToken.balanceOf(address(module));
        uint256 moduleBuyBefore = buyToken.balanceOf(address(module));

        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _oracleParams(), _defaultExecutionData());

        assertEq(sellToken.balanceOf(address(module)), moduleSellBefore, "No residual sell tokens");
        assertEq(buyToken.balanceOf(address(module)), moduleBuyBefore, "No residual buy tokens");
    }

    /*//////////////////////////////////////////////////////////////////////////
            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_Oracle_NeverRevertsOnValidateCalls(
        uint256 sellAmount,
        int256 sellPrice,
        int256 buyPrice,
        uint16 slippageBps,
        uint256 minAmountOut
    )
        external
    {
        sellAmount = bound(sellAmount, 1, type(uint128).max);
        minAmountOut = bound(minAmountOut, 1, type(uint128).max);

        sellFeed.setAnswer(sellPrice);
        buyFeed.setAnswer(buyPrice);

        sellToken.mint(address(paymentRails), sellAmount);

        bytes memory params = _oracleParamsCustom(slippageBps, address(sellFeed), address(buyFeed), MAX_STALENESS);

        bytes memory executionData = _oracleExecutionData(minAmountOut);

        // validate() must NEVER revert — it returns (false, reason) on all invalid inputs
        vm.prank(address(paymentRails));
        (bool isValid,) = module.validate(address(sellToken), sellAmount, params, executionData);
        assertTrue(isValid || !isValid);
    }

    function testFuzz_Oracle_FloorEqualsExpectedTimesSlippageFactor(uint256 sellAmount, uint16 slippageBps) external {
        sellAmount = bound(sellAmount, 1, type(uint128).max);
        slippageBps = uint16(bound(uint256(slippageBps), 1, 10_000));

        sellToken.mint(address(paymentRails), sellAmount);

        bytes memory params = _oracleParamsCustom(slippageBps, address(sellFeed), address(buyFeed), MAX_STALENESS);

        (uint256 estimated,) = module.estimateOutput(address(sellToken), sellAmount, params);

        uint256 expectedFloor = estimated * (10_000 - uint256(slippageBps)) / 10_000;

        // Verify by checking validate() passes when minAmountOut >= floor
        // and fails when minAmountOut < floor (if floor > 0)
        if (expectedFloor > 0) {
            bytes memory execAboveFloor = _oracleExecutionData(expectedFloor);
            vm.prank(address(paymentRails));
            (bool validAbove,) = module.validate(address(sellToken), sellAmount, params, execAboveFloor);
            assertTrue(validAbove, "Should validate when minAmountOut >= floor");

            bytes memory execBelowFloor = _oracleExecutionData(expectedFloor - 1);
            vm.prank(address(paymentRails));
            (bool validBelow, string memory reason) =
                module.validate(address(sellToken), sellAmount, params, execBelowFloor);
            assertFalse(validBelow, "Should reject when minAmountOut < floor");
            assertEq(reason, "Slippage below oracle floor");
        }
    }

    function testFuzz_Oracle_EstimateOutputMatchesMulDiv(uint256 sellAmount) external view {
        sellAmount = bound(sellAmount, 1, type(uint128).max);

        (uint256 estimated,) = module.estimateOutput(address(sellToken), sellAmount, _oracleParams());

        // Both tokens 18 dec, both feeds 8 dec → sellExp == buyExp
        // expected = mulDiv(sellAmount, sellPrice, buyPrice)
        uint256 expectedManual = Math.mulDiv(sellAmount, uint256(SELL_PRICE), uint256(BUY_PRICE));
        assertEq(estimated, expectedManual, "Estimate should match manual mulDiv calculation");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        HELPER: REVERTING DECIMALS FEED
//////////////////////////////////////////////////////////////////////////*/

/// @dev Feed where latestRoundData succeeds but decimals() reverts.
contract RevertingDecimalsAggregator {
    int256 private _answer;

    constructor(int256 answer_) {
        _answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        revert("decimals reverted");
    }
}
