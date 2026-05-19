// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CowSwapModule } from "../../../src/modules/swaps/CowSwapModule.sol";

/// @dev Cross-function reentrancy mock: during execute()'s transferFrom, attempts to
///      call cancelOrder() on a pre-existing order. Verifies that the shared
///      ReentrancyGuard lock blocks execute→cancelOrder cross-function reentrancy.
contract ReentrantCancelDuringExecuteSellToken is ERC20 {
    CowSwapModule public immutable module;

    bytes32 public cancelTargetOrderId;
    bool public shouldReenter;
    bool public reentryAttempted;
    bool public cancelBlocked;
    bool private _reentering;

    constructor(address _module) ERC20("ReentrantCancel", "RECANCEL") {
        module = CowSwapModule(_module);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentryConfig(bytes32 _cancelTargetOrderId) external {
        cancelTargetOrderId = _cancelTargetOrderId;
        shouldReenter = true;
        reentryAttempted = false;
        cancelBlocked = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        if (to == address(module) && shouldReenter && !_reentering) {
            _reentering = true;
            reentryAttempted = true;

            try module.cancelOrder(cancelTargetOrderId) {
                cancelBlocked = false;
            } catch {
                cancelBlocked = true;
            }

            _reentering = false;
        }
    }
}
