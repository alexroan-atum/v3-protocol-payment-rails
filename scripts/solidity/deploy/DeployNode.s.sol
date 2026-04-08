// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { Node } from "../../../src/core/Node.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployNode
/// @author Credit Cooperative
/// @notice Deploys the Node contract. Run once per chain, then attach modules via configureToken().
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployNode.s.sol \
///          --sig "run(address)" <OWNER_ADDRESS> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployNode is BaseScript {
    function run(address owner) public broadcast returns (Node node) {
        node = new Node(owner);

        console2.log("=============================================================");
        console2.log("  DeployNode - Complete");
        console2.log("=============================================================");
        console2.log("Owner: ", owner);
        console2.log("Node:  ", address(node));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  NODE_ADDRESS=%s", vm.toString(address(node)));
        console2.log("=============================================================");
    }
}
