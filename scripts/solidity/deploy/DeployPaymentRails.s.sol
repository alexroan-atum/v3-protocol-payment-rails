// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { PaymentRails } from "../../../src/core/PaymentRails.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployPaymentRails
/// @author Credit Cooperative
/// @notice Deploys the PaymentRails contract. Run once per chain, then attach modules via configureToken().
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployPaymentRails.s.sol \
///          --sig "run(address)" <OWNER_ADDRESS> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployPaymentRails is BaseScript {
    function run(address owner) public broadcast returns (PaymentRails paymentRails) {
        paymentRails = new PaymentRails(owner);

        console2.log("=============================================================");
        console2.log("  DeployPaymentRails - Complete");
        console2.log("=============================================================");
        console2.log("Owner: ", owner);
        console2.log("PaymentRails:  ", address(paymentRails));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  PAYMENT_RAILS_ADDRESS=%s", vm.toString(address(paymentRails)));
        console2.log("=============================================================");
    }
}
