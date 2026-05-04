// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { SwapModuleBase } from "../SwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

contract SwapModuleValidateSwapPriceTest is SwapModuleBase {
    function test_ReturnsFalseWithNotImplemented() external view {
        DataTypes.SwapParams memory params = _defaultSwapParams();

        (bool isValid, string memory reason) =
            module.validateSwapPrice(address(sellToken), address(buyToken), DEFAULT_SELL_AMOUNT, 950e18, params);

        assertFalse(isValid, "isValid");
        assertEq(reason, "Price validation not implemented", "reason");
    }
}
