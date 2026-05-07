// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Controllable router mock for UniswapSwapModule unit tests.
/// Simulates a whitelisted router that can succeed, fail, partially fill, or steal tokens.
contract MockRouter {
    bool public shouldRevert;
    bool public shouldReturnFalse;

    function setShouldRevert(bool _val) external {
        shouldRevert = _val;
    }

    function setShouldReturnFalse(bool _val) external {
        shouldReturnFalse = _val;
    }

    /// @dev Standard swap: pulls sellToken from caller (module) and sends buyToken to recipient.
    function swap(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        address recipient,
        uint256 buyAmount
    )
        external
    {
        if (shouldRevert) revert("MockRouter: forced revert");
        if (shouldReturnFalse) return;

        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
        IERC20(buyToken).transfer(recipient, buyAmount);
    }

    /// @dev Partial-fill swap: pulls less sellToken than approved, sends buyToken to recipient.
    function partialSwap(
        address sellToken,
        uint256 actualSellAmount,
        address buyToken,
        address recipient,
        uint256 buyAmount
    )
        external
    {
        IERC20(sellToken).transferFrom(msg.sender, address(this), actualSellAmount);
        IERC20(buyToken).transfer(recipient, buyAmount);
    }

    /// @dev Theft attempt: takes sellToken but sends nothing back.
    function stealTokens(address sellToken, uint256 amount) external {
        IERC20(sellToken).transferFrom(msg.sender, address(this), amount);
    }

    /// @dev No-op: does nothing (swap succeeds at call level but produces no output).
    function noop() external pure { }

    receive() external payable { }
}
