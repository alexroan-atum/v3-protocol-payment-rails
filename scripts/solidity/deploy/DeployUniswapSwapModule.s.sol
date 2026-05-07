// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { UniswapSwapModule } from "../../../src/modules/swaps/UniswapSwapModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployUniswapSwapModule
/// @author Credit Cooperative
/// @notice Deploys the UniswapSwapModule. Stateless — a single instance can be shared across PaymentRails.
///         After deployment, call addRouter() to whitelist each Uniswap router address.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployUniswapSwapModule.s.sol \
///          --sig "run(address)" <OWNER_ADDRESS> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployUniswapSwapModule is BaseScript {
    function run(address owner) public broadcast returns (UniswapSwapModule module) {
        module = new UniswapSwapModule(owner);

        console2.log("=============================================================");
        console2.log("  DeployUniswapSwapModule - Complete");
        console2.log("=============================================================");
        console2.log("Owner:              ", owner);
        console2.log("UniswapSwapModule:  ", address(module));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  UNISWAP_MODULE=%s", vm.toString(address(module)));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Whitelist routers:  cast send $UNISWAP_MODULE 'addRouter(address)' <ROUTER>");
        console2.log("  2. Configure on PaymentRails: cast send $PAYMENT_RAILS_ADDRESS 'configureToken(...)' ...");
        console2.log("=============================================================");
    }
}
