// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for DexSwapModule.encodeParams() / decodeParams()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/encode-decode-params/encodeDecodeParams.tree
contract DexSwapModule_EncodeDecodeParams_Test is DexSwapModuleBase {
    function _makeParams(
        address targetToken,
        uint24 fee,
        uint16 slippageBps,
        address _sellFeed,
        address _buyFeed,
        uint256 staleness,
        uint256 deadlineSeconds
    )
        internal
        pure
        returns (DataTypes.DexSwapParams memory)
    {
        return DataTypes.DexSwapParams({
            targetToken: targetToken,
            fee: fee,
            maxSlippageBps: slippageBps,
            sellTokenPriceFeed: _sellFeed,
            buyTokenPriceFeed: _buyFeed,
            maxStaleness: staleness,
            swapDeadlineSeconds: deadlineSeconds
        });
    }

    function test_RoundTrips_ValidParams() external view {
        DataTypes.DexSwapParams memory input =
            _makeParams(address(buyToken), 3000, 100, address(sellFeed), address(buyFeed), 3600, 300);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(buyToken));
        assertEq(decoded.fee, 3000);
        assertEq(decoded.maxSlippageBps, 100);
        assertEq(decoded.sellTokenPriceFeed, address(sellFeed));
        assertEq(decoded.buyTokenPriceFeed, address(buyFeed));
        assertEq(decoded.maxStaleness, 3600);
        assertEq(decoded.swapDeadlineSeconds, 300);
    }

    function test_RoundTrips_ZeroAddress() external view {
        DataTypes.DexSwapParams memory input = _makeParams(address(0), 0, 0, address(0), address(0), 0, 0);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, address(0));
        assertEq(decoded.fee, 0);
        assertEq(decoded.maxSlippageBps, 0);
    }

    function test_RoundTrips_MaxAddress() external view {
        address maxAddr = address(type(uint160).max);
        DataTypes.DexSwapParams memory input =
            _makeParams(maxAddr, type(uint24).max, 10_000, maxAddr, maxAddr, type(uint256).max, type(uint256).max);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, maxAddr);
        assertEq(decoded.fee, type(uint24).max);
        assertEq(decoded.maxSlippageBps, 10_000);
        assertEq(decoded.swapDeadlineSeconds, type(uint256).max);
    }

    function test_EncodedLength_IsSevenWords() external view {
        DataTypes.DexSwapParams memory input =
            _makeParams(address(buyToken), 3000, 100, address(sellFeed), address(buyFeed), 3600, 300);
        bytes memory encoded = module.encodeParams(input);
        assertEq(encoded.length, 224, "should be 224 bytes (7 ABI words)");
    }

    function testFuzz_RoundTrips_AnyParams(
        address targetToken,
        uint24 fee,
        uint16 slippageBps,
        address _sellFeed,
        address _buyFeed,
        uint256 staleness,
        uint256 deadlineSeconds
    )
        external
        view
    {
        DataTypes.DexSwapParams memory input =
            _makeParams(targetToken, fee, slippageBps, _sellFeed, _buyFeed, staleness, deadlineSeconds);
        bytes memory encoded = module.encodeParams(input);
        DataTypes.DexSwapParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.targetToken, targetToken);
        assertEq(decoded.fee, fee);
        assertEq(decoded.maxSlippageBps, slippageBps);
        assertEq(decoded.sellTokenPriceFeed, _sellFeed);
        assertEq(decoded.buyTokenPriceFeed, _buyFeed);
        assertEq(decoded.maxStaleness, staleness);
        assertEq(decoded.swapDeadlineSeconds, deadlineSeconds);
    }
}
