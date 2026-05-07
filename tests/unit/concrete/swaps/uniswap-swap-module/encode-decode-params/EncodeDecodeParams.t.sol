// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { UniswapSwapModuleBase } from "../UniswapSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for UniswapSwapModule.encodeParams() / decodeParams()
/// @dev Tree: tests/unit/concrete/swaps/uniswap-swap-module/encode-decode-params/encodeDecodeParams.tree
contract UniswapSwapModule_EncodeDecodeParams_Test is UniswapSwapModuleBase {
    function test_RoundTrips_ValidTargetToken() external view {
        DataTypes.UniswapSwapParams memory input = DataTypes.UniswapSwapParams({ targetToken: address(buyToken) });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.UniswapSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(buyToken));
    }

    function test_RoundTrips_ZeroAddress() external view {
        DataTypes.UniswapSwapParams memory input = DataTypes.UniswapSwapParams({ targetToken: address(0) });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.UniswapSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(0));
    }

    function test_RoundTrips_MaxAddress() external view {
        address maxAddr = address(type(uint160).max);
        DataTypes.UniswapSwapParams memory input = DataTypes.UniswapSwapParams({ targetToken: maxAddr });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.UniswapSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, maxAddr);
    }

    function test_EncodedLength_IsSingleWord() external view {
        DataTypes.UniswapSwapParams memory input = DataTypes.UniswapSwapParams({ targetToken: address(buyToken) });
        bytes memory encoded = module.encodeParams(input);
        assertEq(encoded.length, 32, "should be 32 bytes (single ABI word)");
    }

    function testFuzz_RoundTrips_AnyAddress(address targetToken) external view {
        DataTypes.UniswapSwapParams memory input = DataTypes.UniswapSwapParams({ targetToken: targetToken });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.UniswapSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, targetToken);
    }
}
