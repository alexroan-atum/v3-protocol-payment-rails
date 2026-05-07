// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for DexSwapModule.encodeParams() / decodeParams()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/encode-decode-params/encodeDecodeParams.tree
contract DexSwapModule_EncodeDecodeParams_Test is DexSwapModuleBase {
    function test_RoundTrips_ValidTargetToken() external view {
        DataTypes.DexSwapParams memory input = DataTypes.DexSwapParams({ targetToken: address(buyToken) });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(buyToken));
    }

    function test_RoundTrips_ZeroAddress() external view {
        DataTypes.DexSwapParams memory input = DataTypes.DexSwapParams({ targetToken: address(0) });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(0));
    }

    function test_RoundTrips_MaxAddress() external view {
        address maxAddr = address(type(uint160).max);
        DataTypes.DexSwapParams memory input = DataTypes.DexSwapParams({ targetToken: maxAddr });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, maxAddr);
    }

    function test_EncodedLength_IsSingleWord() external view {
        DataTypes.DexSwapParams memory input = DataTypes.DexSwapParams({ targetToken: address(buyToken) });
        bytes memory encoded = module.encodeParams(input);
        assertEq(encoded.length, 32, "should be 32 bytes (single ABI word)");
    }

    function testFuzz_RoundTrips_AnyAddress(address targetToken) external view {
        DataTypes.DexSwapParams memory input = DataTypes.DexSwapParams({ targetToken: targetToken });
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, targetToken);
    }
}
