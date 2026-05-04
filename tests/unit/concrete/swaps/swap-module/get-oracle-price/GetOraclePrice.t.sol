// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";

contract SwapModuleGetOraclePriceTest is SwapModuleBase {
    function test_ReturnsZeroForAnyInputs() external view {
        uint256 price = module.getOraclePrice(address(sellToken), address(buyToken), priceOracle);

        assertEq(price, 0, "price");
    }
}
