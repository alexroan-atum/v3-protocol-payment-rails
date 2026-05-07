// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for DexSwapModule.encodeExecutionData() / decodeExecutionData()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/encode-decode-execution-data/encodeDecodeExecutionData.tree
contract DexSwapModule_EncodeDecodeExecutionData_Test is DexSwapModuleBase {
    function test_RoundTrips_ValidExecutionData() external view {
        DataTypes.DexSwapExecutionData memory input = DataTypes.DexSwapExecutionData({
            router: address(router),
            minAmountOut: DEFAULT_MIN_AMOUNT_OUT,
            deadline: DEFAULT_DEADLINE,
            routerCalldata: _defaultRouterCalldata()
        });
        bytes memory encoded = module.encodeExecutionData(input);
        DataTypes.DexSwapExecutionData memory decoded = module.decodeExecutionData(encoded);

        assertEq(decoded.router, address(router), "router");
        assertEq(decoded.minAmountOut, DEFAULT_MIN_AMOUNT_OUT, "minAmountOut");
        assertEq(decoded.deadline, DEFAULT_DEADLINE, "deadline");
        assertEq(keccak256(decoded.routerCalldata), keccak256(_defaultRouterCalldata()), "routerCalldata");
    }

    function test_RoundTrips_EmptyRouterCalldata() external view {
        DataTypes.DexSwapExecutionData memory input = DataTypes.DexSwapExecutionData({
            router: address(router), minAmountOut: 1, deadline: 1000, routerCalldata: ""
        });
        bytes memory encoded = module.encodeExecutionData(input);
        DataTypes.DexSwapExecutionData memory decoded = module.decodeExecutionData(encoded);

        assertEq(decoded.routerCalldata.length, 0, "empty calldata");
    }

    function test_RoundTrips_LargeRouterCalldata() external view {
        bytes memory largeCalldata = new bytes(10_000);
        for (uint256 i; i < 10_000; i++) {
            largeCalldata[i] = bytes1(uint8(i % 256));
        }
        DataTypes.DexSwapExecutionData memory input = DataTypes.DexSwapExecutionData({
            router: address(router), minAmountOut: 1, deadline: 1000, routerCalldata: largeCalldata
        });
        bytes memory encoded = module.encodeExecutionData(input);
        DataTypes.DexSwapExecutionData memory decoded = module.decodeExecutionData(encoded);

        assertEq(keccak256(decoded.routerCalldata), keccak256(largeCalldata), "large calldata preserved");
    }

    function test_RoundTrips_ZeroValues() external view {
        DataTypes.DexSwapExecutionData memory input =
            DataTypes.DexSwapExecutionData({ router: address(0), minAmountOut: 0, deadline: 0, routerCalldata: "" });
        bytes memory encoded = module.encodeExecutionData(input);
        DataTypes.DexSwapExecutionData memory decoded = module.decodeExecutionData(encoded);

        assertEq(decoded.router, address(0));
        assertEq(decoded.minAmountOut, 0);
        assertEq(decoded.deadline, 0);
    }

    function test_RoundTrips_MaxValues() external view {
        DataTypes.DexSwapExecutionData memory input = DataTypes.DexSwapExecutionData({
            router: address(type(uint160).max),
            minAmountOut: type(uint256).max,
            deadline: type(uint256).max,
            routerCalldata: hex"ff"
        });
        bytes memory encoded = module.encodeExecutionData(input);
        DataTypes.DexSwapExecutionData memory decoded = module.decodeExecutionData(encoded);

        assertEq(decoded.router, address(type(uint160).max));
        assertEq(decoded.minAmountOut, type(uint256).max);
        assertEq(decoded.deadline, type(uint256).max);
    }

    function testFuzz_RoundTrips_AnyExecutionData(
        address _router,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata routerCalldata
    )
        external
        view
    {
        DataTypes.DexSwapExecutionData memory input = DataTypes.DexSwapExecutionData({
            router: _router, minAmountOut: minAmountOut, deadline: deadline, routerCalldata: routerCalldata
        });
        bytes memory encoded = module.encodeExecutionData(input);
        DataTypes.DexSwapExecutionData memory decoded = module.decodeExecutionData(encoded);

        assertEq(decoded.router, _router);
        assertEq(decoded.minAmountOut, minAmountOut);
        assertEq(decoded.deadline, deadline);
        assertEq(keccak256(decoded.routerCalldata), keccak256(routerCalldata));
    }
}
