// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";

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

    function test_WhenDecodingEncodedParams_DecodesMinBuyAmountCorrectly() external view {
        DataTypes.CowSwapParams memory decoded = module.decodeParams(_buildDefaultParams());
        assertEq(decoded.minBuyAmount, DEFAULT_MIN_BUY_AMOUNT);
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
            minBuyAmount: DEFAULT_MIN_BUY_AMOUNT,
            validityDuration: DEFAULT_VALIDITY,
            appData: DEFAULT_APP_DATA
        });
        DataTypes.CowSwapParams memory decoded = module.decodeParams(module.encodeParams(original));
        assertEq(decoded.targetToken, original.targetToken);
        assertEq(decoded.minBuyAmount, original.minBuyAmount);
        assertEq(decoded.validityDuration, original.validityDuration);
        assertEq(decoded.appData, original.appData);
    }

    function testFuzz_RoundTrip(address targetToken, uint256 minBuyAmount, uint32 validity, bytes32 appData)
        external
        view
    {
        DataTypes.CowSwapParams memory original = DataTypes.CowSwapParams({
            targetToken: targetToken,
            minBuyAmount: minBuyAmount,
            validityDuration: validity,
            appData: appData
        });
        DataTypes.CowSwapParams memory decoded = module.decodeParams(module.encodeParams(original));
        assertEq(decoded.targetToken, original.targetToken);
        assertEq(decoded.minBuyAmount, original.minBuyAmount);
        assertEq(decoded.validityDuration, original.validityDuration);
        assertEq(decoded.appData, original.appData);
    }
}
