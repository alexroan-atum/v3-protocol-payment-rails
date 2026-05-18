// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for DexSwapModule.encodeParams() / decodeParams()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/encode-decode-params/encodeDecodeParams.tree
contract DexSwapModule_EncodeDecodeParams_Test is DexSwapModuleBase {
    function _makeParams(address targetToken) internal pure returns (DataTypes.DexSwapParams memory) {
        return DataTypes.DexSwapParams({
            targetToken: targetToken,
            maxSlippageBps: 0,
            sellTokenPriceFeed: address(0),
            buyTokenPriceFeed: address(0),
            maxStaleness: 0
        });
    }

    function _makeParamsWithOracle(
        address targetToken,
        uint16 slippageBps,
        address sellFeed,
        address buyFeed,
        uint256 staleness
    )
        internal
        pure
        returns (DataTypes.DexSwapParams memory)
    {
        return DataTypes.DexSwapParams({
            targetToken: targetToken,
            maxSlippageBps: slippageBps,
            sellTokenPriceFeed: sellFeed,
            buyTokenPriceFeed: buyFeed,
            maxStaleness: staleness
        });
    }

    function test_RoundTrips_ValidTargetToken() external view {
        DataTypes.DexSwapParams memory input = _makeParams(address(buyToken));
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(buyToken));
        assertEq(decoded.maxSlippageBps, 0);
        assertEq(decoded.sellTokenPriceFeed, address(0));
        assertEq(decoded.buyTokenPriceFeed, address(0));
        assertEq(decoded.maxStaleness, 0);
    }

    function test_RoundTrips_ZeroAddress() external view {
        DataTypes.DexSwapParams memory input = _makeParams(address(0));
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(0));
    }

    function test_RoundTrips_MaxAddress() external view {
        address maxAddr = address(type(uint160).max);
        DataTypes.DexSwapParams memory input = _makeParams(maxAddr);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, maxAddr);
    }

    function test_EncodedLength_IsFiveWords() external view {
        DataTypes.DexSwapParams memory input = _makeParams(address(buyToken));
        bytes memory encoded = module.encodeParams(input);
        assertEq(encoded.length, 160, "should be 160 bytes (5 ABI words)");
    }

    function testFuzz_RoundTrips_AnyAddress(address targetToken) external view {
        DataTypes.DexSwapParams memory input = _makeParams(targetToken);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, targetToken);
    }

    function test_RoundTrips_WithOracleConfig() external view {
        address fakeFeed1 = address(0x1111);
        address fakeFeed2 = address(0x2222);
        DataTypes.DexSwapParams memory input = _makeParamsWithOracle(address(buyToken), 200, fakeFeed1, fakeFeed2, 3600);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(buyToken));
        assertEq(decoded.maxSlippageBps, 200);
        assertEq(decoded.sellTokenPriceFeed, fakeFeed1);
        assertEq(decoded.buyTokenPriceFeed, fakeFeed2);
        assertEq(decoded.maxStaleness, 3600);
    }
}
