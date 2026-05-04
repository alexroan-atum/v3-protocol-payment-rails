// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract SwapModuleEncodeDecodeParamsTest is SwapModuleBase {
    function test_RoundtripCoreFields() external view {
        DataTypes.SwapParams memory params = _defaultSwapParams();

        bytes memory encoded = module.encodeParams(params);
        DataTypes.SwapParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.targetToken, address(buyToken), "targetToken");
        assertEq(decoded.dexRouter, dexRouter, "dexRouter");
        assertEq(decoded.poolFee, DEFAULT_POOL_FEE, "poolFee");
        assertEq(decoded.slippageBps, DEFAULT_SLIPPAGE_BPS, "slippageBps");
    }

    function test_RoundtripOracleFields() external view {
        DataTypes.SwapParams memory params = _defaultSwapParams();
        params.priceOracle = priceOracle;
        params.maxPriceDeviationBps = DEFAULT_MAX_DEVIATION_BPS;
        params.useTwap = true;
        params.twapPeriod = DEFAULT_TWAP_PERIOD;

        bytes memory encoded = module.encodeParams(params);
        DataTypes.SwapParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.priceOracle, priceOracle, "priceOracle");
        assertEq(decoded.maxPriceDeviationBps, DEFAULT_MAX_DEVIATION_BPS, "maxPriceDeviationBps");
        assertTrue(decoded.useTwap, "useTwap");
        assertEq(decoded.twapPeriod, DEFAULT_TWAP_PERIOD, "twapPeriod");
    }

    function test_RoundtripNonEmptySwapPathBytes() external view {
        DataTypes.SwapParams memory params = _defaultSwapParams();
        params.path = abi.encodePacked(address(sellToken), uint24(3000), address(buyToken));

        bytes memory encoded = module.encodeParams(params);
        DataTypes.SwapParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.path, params.path, "path");
    }

    function test_RoundtripWithMaxBoundaryValues() external view {
        DataTypes.SwapParams memory params = DataTypes.SwapParams({
            targetToken: address(type(uint160).max),
            dexRouter: address(type(uint160).max),
            path: hex"ff",
            poolFee: type(uint24).max,
            slippageBps: type(uint256).max,
            priceOracle: address(type(uint160).max),
            maxPriceDeviationBps: type(uint256).max,
            useTwap: true,
            twapPeriod: type(uint32).max
        });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.SwapParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.targetToken, address(type(uint160).max), "targetToken");
        assertEq(decoded.dexRouter, address(type(uint160).max), "dexRouter");
        assertEq(decoded.poolFee, type(uint24).max, "poolFee");
        assertEq(decoded.slippageBps, type(uint256).max, "slippageBps");
        assertEq(decoded.maxPriceDeviationBps, type(uint256).max, "maxPriceDeviationBps");
        assertEq(decoded.twapPeriod, type(uint32).max, "twapPeriod");
    }

    function test_RevertWhen_EncodedDataIsEmpty() external {
        vm.expectRevert();
        module.decodeParams("");
    }

    function test_RevertWhen_EncodedDataIsTooShort() external {
        vm.expectRevert();
        module.decodeParams(hex"deadbeef");
    }

    function testFuzz_RoundtripWithAnyValues(
        address _targetToken,
        address _dexRouter,
        uint24 _poolFee,
        uint256 _slippageBps,
        address _priceOracle,
        uint256 _maxDeviation,
        bool _useTwap,
        uint32 _twapPeriod
    )
        external
        view
    {
        DataTypes.SwapParams memory params = DataTypes.SwapParams({
            targetToken: _targetToken,
            dexRouter: _dexRouter,
            path: "",
            poolFee: _poolFee,
            slippageBps: _slippageBps,
            priceOracle: _priceOracle,
            maxPriceDeviationBps: _maxDeviation,
            useTwap: _useTwap,
            twapPeriod: _twapPeriod
        });

        bytes memory encoded = module.encodeParams(params);
        DataTypes.SwapParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.targetToken, _targetToken, "targetToken");
        assertEq(decoded.dexRouter, _dexRouter, "dexRouter");
        assertEq(decoded.poolFee, _poolFee, "poolFee");
        assertEq(decoded.slippageBps, _slippageBps, "slippageBps");
        assertEq(decoded.priceOracle, _priceOracle, "priceOracle");
        assertEq(decoded.maxPriceDeviationBps, _maxDeviation, "maxPriceDeviationBps");
        assertEq(decoded.useTwap, _useTwap, "useTwap");
        assertEq(decoded.twapPeriod, _twapPeriod, "twapPeriod");
    }
}
