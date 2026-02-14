// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Node } from "../../src/core/Node.sol";
import { ForwardModule } from "../../src/modules/ForwardModule.sol";
import { SwapModule } from "../../src/modules/SwapModule.sol";
import { BridgeModule } from "../../src/modules/BridgeModule.sol";

import { BaseScript } from "./Base.s.sol";

/// @title Deploy
/// @author Credit Cooperative
/// @notice Deployment script for the Receivables Node system
/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract Deploy is BaseScript {
    /// @notice Deploys the Node and action modules
    /// @param owner The address that will own the Node contract
    /// @return node The deployed Node contract instance
    /// @return forwardModule The deployed ForwardModule instance
    /// @return swapModule The deployed SwapModule instance
    /// @return bridgeModule The deployed BridgeModule instance
    function run(address owner)
        public
        broadcast
        returns (Node node, ForwardModule forwardModule, SwapModule swapModule, BridgeModule bridgeModule)
    {
        // Deploy modules first
        forwardModule = new ForwardModule();
        swapModule = new SwapModule();
        bridgeModule = new BridgeModule();

        // Deploy node with owner
        node = new Node(owner);
    }
}
