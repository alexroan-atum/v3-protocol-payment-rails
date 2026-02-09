// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { Foo } from "../../src/Foo.sol";

import { BaseScript } from "./Base.s.sol";

/// @title Deploy
/// @author Credit Cooperative
/// @notice Deployment script for the Foo contract
/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/guides/scripting-with-solidity
contract Deploy is BaseScript {
    /// @notice Deploys the Foo contract
    /// @return foo The deployed Foo contract instance
    function run() public broadcast returns (Foo foo) {
        foo = new Foo();
    }
}
