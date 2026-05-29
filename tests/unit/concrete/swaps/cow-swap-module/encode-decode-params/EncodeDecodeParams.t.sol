// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for CowSwapModule.encodeParams() and decodeParams()
/// @dev Tree: tests/unit/concrete/cow-swap-module/encode-decode-params/encodeDecodeParams.tree
contract CowSwapModule_EncodeDecodeParams_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when encoding params
    // -----------------------------------------------------------------------

    function test_WhenEncodingParams_ProducesNonEmptyBytes() external view {
        bytes memory encoded = _buildDefaultParams();
        assertGt(encoded.length, 0);
    }

    // -----------------------------------------------------------------------
    // when decoding encoded params
    // -----------------------------------------------------------------------

    function test_WhenDecodingEncodedParams_DecodesTargetTokenCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.targetToken, address(buyToken));
    }

    function test_WhenDecodingEncodedParams_DecodesMaxSlippageBpsCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.maxSlippageBps, DEFAULT_SLIPPAGE_BPS);
    }

    function test_WhenDecodingEncodedParams_DecodesSellTokenPriceFeedCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.sellTokenPriceFeed, address(sellFeed));
    }

    function test_WhenDecodingEncodedParams_DecodesBuyTokenPriceFeedCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.buyTokenPriceFeed, address(buyFeed));
    }

    function test_WhenDecodingEncodedParams_DecodesMaxStalenessCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.maxStaleness, DEFAULT_MAX_STALENESS);
    }

    function test_WhenDecodingEncodedParams_DecodesValidityDurationCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.validityDuration, DEFAULT_VALIDITY);
    }

    function test_WhenDecodingEncodedParams_DecodesAppDataCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.appData, DEFAULT_APP_DATA);
    }

    // -----------------------------------------------------------------------
    // given a round-trip encode-decode cycle
    // -----------------------------------------------------------------------

    function test_GivenRoundTripEncodeDecodeCycle_ReconstructsIdenticalParamsStruct() external view {
        DataTypes.CowSwapParams memory original = DataTypes.CowSwapParams({
            targetToken: address(buyToken),
            maxSlippageBps: DEFAULT_SLIPPAGE_BPS,
            sellTokenPriceFeed: address(sellFeed),
            buyTokenPriceFeed: address(buyFeed),
            maxStaleness: DEFAULT_MAX_STALENESS,
            validityDuration: DEFAULT_VALIDITY,
            appData: DEFAULT_APP_DATA
        });
        DataTypes.CowSwapParams memory decoded = module.decodeParams(module.encodeParams(original));
        assertEq(decoded.targetToken, original.targetToken);
        assertEq(decoded.maxSlippageBps, original.maxSlippageBps);
        assertEq(decoded.sellTokenPriceFeed, original.sellTokenPriceFeed);
        assertEq(decoded.buyTokenPriceFeed, original.buyTokenPriceFeed);
        assertEq(decoded.maxStaleness, original.maxStaleness);
        assertEq(decoded.validityDuration, original.validityDuration);
        assertEq(decoded.appData, original.appData);
    }

    function testFuzz_RoundTrip(
        address targetToken,
        uint16 maxSlippageBps,
        address _sellFeed,
        address _buyFeed,
        uint256 maxStaleness,
        uint32 validity,
        bytes32 appData
    )
        external
        view
    {
        DataTypes.CowSwapParams memory original = DataTypes.CowSwapParams({
            targetToken: targetToken,
            maxSlippageBps: maxSlippageBps,
            sellTokenPriceFeed: _sellFeed,
            buyTokenPriceFeed: _buyFeed,
            maxStaleness: maxStaleness,
            validityDuration: validity,
            appData: appData
        });
        DataTypes.CowSwapParams memory decoded = module.decodeParams(module.encodeParams(original));
        assertEq(decoded.targetToken, original.targetToken);
        assertEq(decoded.maxSlippageBps, original.maxSlippageBps);
        assertEq(decoded.sellTokenPriceFeed, original.sellTokenPriceFeed);
        assertEq(decoded.buyTokenPriceFeed, original.buyTokenPriceFeed);
        assertEq(decoded.maxStaleness, original.maxStaleness);
        assertEq(decoded.validityDuration, original.validityDuration);
        assertEq(decoded.appData, original.appData);
    }
}
