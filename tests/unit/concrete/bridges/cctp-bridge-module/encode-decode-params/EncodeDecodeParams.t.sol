// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CCTPBridgeModuleBase } from "../CCTPBridgeModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract CCTPBridgeModule_EncodeDecodeParams_Test is CCTPBridgeModuleBase {
    function test_WhenEncodingValidParams() external view {
        DataTypes.CCTPBridgeParams memory params = DataTypes.CCTPBridgeParams({
            destinationDomain: DOMAIN_BASE,
            mintRecipient: DEFAULT_MINT_RECIPIENT,
            destinationCaller: DEFAULT_DESTINATION_CALLER,
            maxFeeBps: DEFAULT_MAX_FEE_BPS,
            minFinalityThreshold: FINALITY_FAST,
            hookData: DEFAULT_HOOK_DATA
        });
        bytes memory encoded = module.encodeParams(params);
        bytes memory expected = abi.encode(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE_BPS,
            FINALITY_FAST,
            DEFAULT_HOOK_DATA
        );
        assertEq(encoded, expected);
    }

    function test_WhenDecodingValidEncodedBytes() external view {
        bytes memory encoded = _encodeParams(
            DOMAIN_ARBITRUM,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE_BPS,
            FINALITY_STANDARD,
            DEFAULT_HOOK_DATA
        );
        DataTypes.CCTPBridgeParams memory decoded = module.decodeParams(encoded);
        assertEq(decoded.destinationDomain, DOMAIN_ARBITRUM);
        assertEq(decoded.mintRecipient, DEFAULT_MINT_RECIPIENT);
        assertEq(decoded.destinationCaller, DEFAULT_DESTINATION_CALLER);
        assertEq(decoded.maxFeeBps, DEFAULT_MAX_FEE_BPS);
        assertEq(decoded.minFinalityThreshold, FINALITY_STANDARD);
        assertEq(decoded.hookData, DEFAULT_HOOK_DATA);
    }

    function test_WhenRoundTrippingEncodeThenDecode() external view {
        DataTypes.CCTPBridgeParams memory original = DataTypes.CCTPBridgeParams({
            destinationDomain: DOMAIN_ETHEREUM,
            mintRecipient: DEFAULT_MINT_RECIPIENT,
            destinationCaller: DEFAULT_DESTINATION_CALLER,
            maxFeeBps: 100,
            minFinalityThreshold: FINALITY_STANDARD,
            hookData: hex"cafebabe"
        });
        bytes memory encoded = module.encodeParams(original);
        DataTypes.CCTPBridgeParams memory recovered = module.decodeParams(encoded);
        assertEq(recovered.destinationDomain, original.destinationDomain);
        assertEq(recovered.mintRecipient, original.mintRecipient);
        assertEq(recovered.destinationCaller, original.destinationCaller);
        assertEq(recovered.maxFeeBps, original.maxFeeBps);
        assertEq(recovered.minFinalityThreshold, original.minFinalityThreshold);
        assertEq(recovered.hookData, original.hookData);
    }

    function testFuzz_RoundTrip(uint32 domain, bytes32 recipient, uint16 maxFeeBps, bool useFast) external view {
        vm.assume(recipient != bytes32(0));
        DataTypes.CCTPBridgeParams memory original = DataTypes.CCTPBridgeParams({
            destinationDomain: domain,
            mintRecipient: recipient,
            destinationCaller: bytes32(0),
            maxFeeBps: maxFeeBps,
            minFinalityThreshold: useFast ? FINALITY_FAST : FINALITY_STANDARD,
            hookData: ""
        });
        bytes memory encoded = module.encodeParams(original);
        DataTypes.CCTPBridgeParams memory recovered = module.decodeParams(encoded);
        assertEq(recovered.destinationDomain, domain);
        assertEq(recovered.mintRecipient, recipient);
        assertEq(recovered.maxFeeBps, maxFeeBps);
        assertEq(recovered.minFinalityThreshold, original.minFinalityThreshold);
    }
}
