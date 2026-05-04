// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 whose transferFrom always reverts (tests the catch branch of _safeTransferFrom).
contract RevertingTransferERC20 is ERC20 {
    constructor() ERC20("Revert", "REV") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("ALWAYS_REVERTS");
    }
}
