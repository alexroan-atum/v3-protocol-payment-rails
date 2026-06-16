// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CowSwapModule } from "../../../src/modules/swaps/CowSwapModule.sol";

/// @dev ERC-777-style reentrant sell token: re-enters module.execute() during transferFrom
///      (triggered by _update when tokens move TO the module). Used to verify that:
///      1. ReentrancyGuard blocks the reentrant execute() call.
///      2. CEI ordering prevents orderId collision even without the guard.
///
///      The reentrant call originates from this contract (msg.sender = address(this)),
///      which is also a token holder. This simulates the ERC-777 tokensToSend hook
///      scenario where the sender regains control during a transferFrom.
contract ReentrantExecuteSellToken is ERC20 {
    CowSwapModule public immutable module;

    bytes public reentrantParams;
    uint256 public reentrantAmount;
    bool public shouldReenter;
    bool public reentryAttempted;
    bool public reentrancyBlocked;
    bool private _reentering;

    constructor(address _module) ERC20("ReentrantExec", "REEXEC") {
        module = CowSwapModule(_module);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentryConfig(uint256 amount, bytes calldata params) external {
        reentrantAmount = amount;
        reentrantParams = params;
        shouldReenter = true;
        reentryAttempted = false;
        reentrancyBlocked = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        if (to == address(module) && shouldReenter && !_reentering) {
            _reentering = true;
            reentryAttempted = true;

            _approve(address(this), address(module), reentrantAmount);

            try module.execute(address(this), reentrantAmount, reentrantParams) {
                reentrancyBlocked = false;
            } catch {
                reentrancyBlocked = true;
            }

            _reentering = false;
        }
    }
}
