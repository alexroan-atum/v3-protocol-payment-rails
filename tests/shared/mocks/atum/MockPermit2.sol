// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPermit2 } from "../../../../src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal Permit2 mock for AtumModule accounting tests.
contract MockPermit2 is IPermit2 {
    using SafeERC20 for IERC20;

    bytes32 public immutable override DOMAIN_SEPARATOR;

    constructor(bytes32 domainSeparator) {
        DOMAIN_SEPARATOR = domainSeparator;
    }

    function pull(address token, address owner, address to, uint256 amount) external {
        IERC20(token).safeTransferFrom(owner, to, amount);
    }
}
