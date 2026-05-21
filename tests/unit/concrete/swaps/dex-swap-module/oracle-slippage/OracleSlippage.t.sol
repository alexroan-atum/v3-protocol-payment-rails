// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { MockChainlinkAggregator } from "../../../../../shared/mocks/MockChainlinkAggregator.sol";
import { MockERC20 } from "../../../../../shared/mocks/MockERC20.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Unit tests for DexSwapModule oracle-enforced slippage protection.
/// @dev Uses an ETH/USDC-like price pair (SELL_PRICE=2000, BUY_PRICE=1) for realistic scenarios.
contract DexSwapModule_OracleSlippage_Test is DexSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////////////////*/

    MockChainlinkAggregator internal ethFeed;
    MockChainlinkAggregator internal usdcFeed;

    int256 internal constant ETH_PRICE = 2000e8;
    int256 internal constant USDC_PRICE = 1e8;
    uint16 internal constant SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant STALENESS = 3600;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();

        ethFeed = new MockChainlinkAggregator(ETH_PRICE, FEED_DECIMALS);
        usdcFeed = new MockChainlinkAggregator(USDC_PRICE, FEED_DECIMALS);

        vm.label(address(ethFeed), "ETH_PriceFeed");
        vm.label(address(usdcFeed), "USDC_PriceFeed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _ethUsdcParams() internal view returns (bytes memory) {
        return _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            SLIPPAGE_BPS,
            address(ethFeed),
            address(usdcFeed),
            STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
    }

    function _ethExpectedOutput(uint256 sellAmount) internal pure returns (uint256) {
        return Math.mulDiv(sellAmount, uint256(ETH_PRICE), uint256(USDC_PRICE));
    }

    function _ethOracleFloor(uint256 sellAmount) internal pure returns (uint256) {
        uint256 expected = _ethExpectedOutput(sellAmount);
        return Math.mulDiv(expected, 10_000 - uint256(SLIPPAGE_BPS), 10_000);
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — FEED FAILURES
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SellFeedNegativePrice_Execute_Fails() external {
        ethFeed.setAnswer(-1);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedNegativePrice_Execute_Fails() external {
        usdcFeed.setAnswer(-1);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedZeroPrice_Execute_Fails() external {
        ethFeed.setAnswer(0);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedNegativePrice_Validate_Fails() external {
        ethFeed.setAnswer(-1);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedNegativePrice_Validate_Fails() external {
        usdcFeed.setAnswer(-1);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — STALENESS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SellFeedStale_Execute_Fails() external {
        ethFeed.setUpdatedAt(block.timestamp - STALENESS - 1);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedStale_Execute_Fails() external {
        usdcFeed.setUpdatedAt(block.timestamp - STALENESS - 1);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedStale_Validate_Fails() external {
        ethFeed.setUpdatedAt(block.timestamp - STALENESS - 1);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — FEED REVERTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_SellFeedReverts_Execute_Fails() external {
        ethFeed.setShouldRevert(true);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_BuyFeedReverts_Execute_Fails() external {
        usdcFeed.setShouldRevert(true);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_SellFeedReverts_Validate_Fails() external {
        ethFeed.setShouldRevert(true);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — decimals() REVERTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_FeedDecimalsReverts_Execute_Fails() external {
        RevertingDecimalsAggregator badFeed = new RevertingDecimalsAggregator(ETH_PRICE);
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            SLIPPAGE_BPS,
            address(badFeed),
            address(usdcFeed),
            STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_Oracle_FeedDecimalsReverts_Validate_Fails() external {
        RevertingDecimalsAggregator badFeed = new RevertingDecimalsAggregator(ETH_PRICE);
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            SLIPPAGE_BPS,
            address(badFeed),
            address(usdcFeed),
            STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
        GIVEN ORACLE IS FULLY CONFIGURED — SLIPPAGE ENFORCEMENT (CORE LOGIC)
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_OutputEqualsFloor_Execute_Succeeds() external {
        uint256 oracleFloor = _ethOracleFloor(DEFAULT_SELL_AMOUNT);

        buyToken.mint(address(router), oracleFloor * 10);
        router.setOutputAmount(oracleFloor);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());

        assertTrue(result.success, "Should succeed when output == oracleFloor");
        assertEq(result.amountOut, oracleFloor);
    }

    function test_Oracle_OutputAboveFloor_Execute_Succeeds() external {
        uint256 oracleFloor = _ethOracleFloor(DEFAULT_SELL_AMOUNT);
        uint256 aboveFloor = oracleFloor + 1;

        buyToken.mint(address(router), aboveFloor * 10);
        router.setOutputAmount(aboveFloor);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());

        assertTrue(result.success, "Should succeed when output > oracleFloor");
    }

    function test_Oracle_OutputBelowFloor_Execute_Reverts() external {
        uint256 oracleFloor = _ethOracleFloor(DEFAULT_SELL_AMOUNT);
        uint256 belowFloor = oracleFloor - 1;

        buyToken.mint(address(router), belowFloor * 10);
        router.setOutputAmount(belowFloor);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DexSwapModule_InsufficientOutput.selector, belowFloor, oracleFloor)
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — DECIMAL NORMALIZATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_DifferentTokenDecimals_6And18() external {
        MockERC20 usdc = new MockERC20("USDC", "USDC");
        MockERC20 weth = new MockERC20("WETH", "WETH");

        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(address(weth), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        MockChainlinkAggregator feed1 = new MockChainlinkAggregator(1e8, 8);
        MockChainlinkAggregator feed2 = new MockChainlinkAggregator(2000e8, 8);

        uint256 sellAmount = 2000e6;

        bytes memory params = _buildParamsCustom(
            address(weth), DEFAULT_FEE, SLIPPAGE_BPS, address(feed1), address(feed2), STALENESS, DEFAULT_SWAP_DEADLINE
        );

        (uint256 estimated, address outputToken) = module.estimateOutput(address(usdc), sellAmount, params);
        assertEq(outputToken, address(weth));
        assertEq(estimated, 1e18, "2000 USDC at $1 should yield 1 ETH at $2000");
    }

    function test_Oracle_DifferentFeedDecimals_8And18() external {
        MockChainlinkAggregator feed8 = new MockChainlinkAggregator(2000e8, 8);
        MockChainlinkAggregator feed18 = new MockChainlinkAggregator(1e18, 18);

        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            SLIPPAGE_BPS,
            address(feed8),
            address(feed18),
            STALENESS,
            DEFAULT_SWAP_DEADLINE
        );

        (uint256 estimated,) = module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(estimated, 2_000_000e18, "Different feed decimals should normalize correctly");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — estimateOutput
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_EstimateOutput_ReturnsNonZero() external view {
        (uint256 estimated, address outputToken) =
            module.estimateOutput(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());

        uint256 expectedOutput = _ethExpectedOutput(DEFAULT_SELL_AMOUNT);
        assertEq(estimated, expectedOutput);
        assertEq(outputToken, address(buyToken));
    }

    function test_Oracle_EstimateOutput_ScalesWithAmount() external view {
        (uint256 est1,) = module.estimateOutput(address(sellToken), 1e18, _ethUsdcParams());
        (uint256 est10,) = module.estimateOutput(address(sellToken), 10e18, _ethUsdcParams());
        assertEq(est10, est1 * 10, "Output should scale linearly with input");
    }

    /*//////////////////////////////////////////////////////////////////////////
            GIVEN ORACLE IS FULLY CONFIGURED — NO RESIDUAL STATE
    //////////////////////////////////////////////////////////////////////////*/

    function test_Oracle_NoResidualAfterOracleReject() external {
        ethFeed.setAnswer(-1);

        uint256 moduleSellBefore = sellToken.balanceOf(address(module));
        uint256 moduleBuyBefore = buyToken.balanceOf(address(module));

        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _ethUsdcParams());

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
        uint16 slippageBps
    )
        external
    {
        sellAmount = bound(sellAmount, 1, type(uint128).max);
        slippageBps = uint16(bound(uint256(slippageBps), 1, 10_000));

        ethFeed.setAnswer(sellPrice);
        usdcFeed.setAnswer(buyPrice);

        sellToken.mint(address(paymentRails), sellAmount);

        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            slippageBps,
            address(ethFeed),
            address(usdcFeed),
            STALENESS,
            DEFAULT_SWAP_DEADLINE
        );

        vm.prank(address(paymentRails));
        (bool isValid,) = module.validate(address(sellToken), sellAmount, params);
        assertTrue(isValid || !isValid);
    }

    function testFuzz_Oracle_EstimateOutputMatchesMulDiv(uint256 sellAmount) external view {
        sellAmount = bound(sellAmount, 1, type(uint128).max);

        (uint256 estimated,) = module.estimateOutput(address(sellToken), sellAmount, _ethUsdcParams());

        uint256 expectedManual = Math.mulDiv(sellAmount, uint256(ETH_PRICE), uint256(USDC_PRICE));
        assertEq(estimated, expectedManual, "Estimate should match manual mulDiv calculation");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        HELPER: REVERTING DECIMALS FEED
//////////////////////////////////////////////////////////////////////////*/

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
