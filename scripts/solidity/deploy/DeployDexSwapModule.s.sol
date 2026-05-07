// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { DexSwapModule } from "../../../src/modules/swaps/DexSwapModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployDexSwapModule
/// @author Credit Cooperative
/// @notice Deploys the DexSwapModule. Stateless — a single instance can be shared across PaymentRails.
///         After deployment, call addRouter() to whitelist each DEX router address.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployDexSwapModule.s.sol \
///          --sig "run(address)" <OWNER_ADDRESS> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployDexSwapModule is BaseScript {
    function run(address owner) public broadcast returns (DexSwapModule module) {
        module = new DexSwapModule(owner);

        console2.log("=============================================================");
        console2.log("  DeployDexSwapModule - Complete");
        console2.log("=============================================================");
        console2.log("Owner:              ", owner);
        console2.log("DexSwapModule:  ", address(module));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  DEX_SWAP_MODULE=%s", vm.toString(address(module)));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Whitelist routers:  cast send $DEX_SWAP_MODULE 'addRouter(address)' <ROUTER>");
        console2.log("  2. Configure on PaymentRails: cast send $PAYMENT_RAILS_ADDRESS 'configureToken(...)' ...");
        console2.log("=============================================================");
    }
}
