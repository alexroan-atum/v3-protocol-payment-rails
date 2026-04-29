// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { CCTPBridgeModule } from "../../../src/modules/CCTPBridgeModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployCCTPBridgeModule
/// @author Credit Cooperative
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployCCTPBridgeModule.s.sol \
///          --sig "run(address,address,address)" <TOKEN_MESSENGER_V2> <USDC> <OWNER> \
///          --rpc-url $SOURCE_RPC_URL --broadcast -vvvv
contract DeployCCTPBridgeModule is BaseScript {
    function run(
        address tokenMessengerV2,
        address usdc,
        address owner
    )
        public
        broadcast
        returns (CCTPBridgeModule module)
    {
        module = new CCTPBridgeModule(tokenMessengerV2, usdc, owner);

        console2.log("=============================================================");
        console2.log("  DeployCCTPBridgeModule");
        console2.log("=============================================================");
        console2.log("Owner:             ", owner);
        console2.log("CCTPBridgeModule:  ", address(module));
        console2.log("TokenMessengerV2:  ", tokenMessengerV2);
        console2.log("USDC:              ", usdc);
        console2.log("");
        console2.log("  BRIDGE_MODULE=%s", vm.toString(address(module)));
        console2.log("=============================================================");
    }
}
