// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { CowSwapModule } from "../../../src/modules/swaps/CowSwapModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployCowSwapModule
/// @author Credit Cooperative
/// @notice Deploys a CowSwapModule instance. Each PaymentRails needs its own private module.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployCowSwapModule.s.sol \
///          --sig "run(address,address)" <OWNER_ADDRESS> <PAYMENT_RAILS_ADDRESS> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployCowSwapModule is BaseScript {
    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    function run(address owner, address _paymentRails) public broadcast returns (CowSwapModule module) {
        module = new CowSwapModule(GPV2_SETTLEMENT, owner, _paymentRails);

        console2.log("=============================================================");
        console2.log("  DeployCowSwapModule - Complete");
        console2.log("=============================================================");
        console2.log("Owner:            ", owner);
        console2.log("PaymentRails:     ", _paymentRails);
        console2.log("CowSwapModule:    ", address(module));
        console2.log("GPv2Settlement:   ", GPV2_SETTLEMENT);
        console2.log("VaultRelayer:     ", module.vaultRelayer());
        console2.log("Domain Separator: ", vm.toString(module.cowDomainSeparator()));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  MODULE_ADDRESS=%s", vm.toString(address(module)));
        console2.log("");
        console2.log("Then configure on your PaymentRails:");
        console2.log("  cast send $PAYMENT_RAILS_ADDRESS 'configureToken(...)' ...");
        console2.log("=============================================================");
    }
}
