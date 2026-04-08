// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CowSwapModule } from "../../../src/modules/CowSwapModule.sol";

/// @dev Reentrant sell token: re-enters module.cancelOrder() on transfer FROM the module.
///      Used to verify CEI prevents double-drain (status is CANCELLED before transfer fires).
contract ReentrantSellToken is ERC20 {
    CowSwapModule public immutable module;
    bytes32 public targetOrderId;
    bool public doubleClaimSucceeded;
    bool private _reentering;
    address public immutable moduleOwner;

    constructor(address _module, address _owner) ERC20("ReentrantToken", "REENT") {
        module = CowSwapModule(_module);
        moduleOwner = _owner;
    }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function setTargetOrder(bytes32 orderId) external { targetOrderId = orderId; }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == address(module) && !_reentering && targetOrderId != bytes32(0)) {
            _reentering = true;
            try module.cancelOrder(targetOrderId) {
                doubleClaimSucceeded = true;
            } catch { }
            _reentering = false;
        }
    }
}
