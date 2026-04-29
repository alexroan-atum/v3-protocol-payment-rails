// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";

contract CCTPBridgeModule_EncodeDecodeParams_Test is CCTPBridgeModuleBase {
    function test_WhenEncodingValidParams() external view {
        DataTypes.CCTPBridgeParams memory params =
            DataTypes.CCTPBridgeParams({ destinationDomain: DOMAIN_BASE });
        bytes memory encoded = module.encodeParams(params);
        assertEq(encoded, abi.encode(uint32(DOMAIN_BASE)));
    }

    function test_WhenDecodingValidEncodedBytes() external view {
        bytes memory encoded = abi.encode(uint32(DOMAIN_ARBITRUM));
        DataTypes.CCTPBridgeParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.destinationDomain, DOMAIN_ARBITRUM);
    }

    function test_WhenRoundTrippingEncodeThenDecode() external view {
        DataTypes.CCTPBridgeParams memory original =
            DataTypes.CCTPBridgeParams({ destinationDomain: DOMAIN_ETHEREUM });
        bytes memory encoded = module.encodeParams(original);
        DataTypes.CCTPBridgeParams memory recovered = module.decodeParams(encoded);
        assertEq(recovered.destinationDomain, original.destinationDomain);
    }

    function testFuzz_RoundTrip(uint32 domain) external view {
        DataTypes.CCTPBridgeParams memory original =
            DataTypes.CCTPBridgeParams({ destinationDomain: domain });
        bytes memory encoded = module.encodeParams(original);
        DataTypes.CCTPBridgeParams memory recovered = module.decodeParams(encoded);
        assertEq(recovered.destinationDomain, domain);
    }
}
