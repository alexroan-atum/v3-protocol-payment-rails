// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { ForwardModule } from "../../../src/modules/forwards/ForwardModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployForwardModule
/// @author Credit Cooperative
/// @notice Deploys the ForwardModule. Stateless — a single instance can be shared across PaymentRails.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployForwardModule.s.sol \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployForwardModule is BaseScript {
    function run() public broadcast returns (ForwardModule module) {
        module = new ForwardModule();

        console2.log("=============================================================");
        console2.log("  DeployForwardModule - Complete");
        console2.log("=============================================================");
        console2.log("ForwardModule: ", address(module));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  FORWARD_MODULE=%s", vm.toString(address(module)));
        console2.log("");
        console2.log("Then configure on your PaymentRails:");
        console2.log("  cast send $PAYMENT_RAILS_ADDRESS 'configureToken(...)' ...");
        console2.log("=============================================================");
    }
}
