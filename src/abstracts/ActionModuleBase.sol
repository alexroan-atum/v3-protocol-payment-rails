// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IActionModule } from "../interfaces/IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ActionModuleBase
/// @notice Abstract base contract providing common functionality for all action modules
/// @dev Inheriting contracts must implement execute(), validate(), estimateOutput(), and moduleType()
/// @dev Provides helper functions for common operations like balance checks and error handling
abstract contract ActionModuleBase is IActionModule {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Checks if the caller has sufficient balance of a token.
    /// @param token The token address to check.
    /// @param amount The required amount.
    /// @return True if caller has sufficient balance, false otherwise.
    function _hasSufficientBalance(address token, uint256 amount) internal view returns (bool) {
        return IERC20(token).balanceOf(msg.sender) >= amount;
    }

    /// @notice Creates a failed ExecutionResult with a reason.
    /// @param token The token being processed (used as outputToken in failure).
    /// @param reason The failure reason message.
    /// @return result ExecutionResult with success=false.
    function _failedResult(
        address token,
        string memory reason
    )
        internal
        pure
        returns (DataTypes.ExecutionResult memory result)
    {
        return DataTypes.ExecutionResult({
            success: false, amountOut: 0, outputToken: token, data: "", failureReason: reason
        });
    }

    /// @notice Creates a successful ExecutionResult.
    /// @param amountOut The amount of output token produced.
    /// @param outputToken The address of the output token.
    /// @param data Additional module-specific data.
    /// @return result ExecutionResult with success=true.
    function _successResult(
        uint256 amountOut,
        address outputToken,
        bytes memory data
    )
        internal
        pure
        returns (DataTypes.ExecutionResult memory result)
    {
        return DataTypes.ExecutionResult({
            success: true, amountOut: amountOut, outputToken: outputToken, data: data, failureReason: ""
        });
    }

    /// @notice Validates that an address is not zero.
    /// @param addr The address to validate.
    /// @return True if address is not zero, false otherwise.
    function _isValidAddress(address addr) internal pure returns (bool) {
        return addr != address(0);
    }

    /// @notice Safely transfers tokens from caller to recipient.
    /// @dev Uses OZ's trySafeTransferFrom to handle non-standard ERC20 tokens (e.g. USDT)
    /// that do not return a bool on transferFrom.
    /// @param token The token to transfer.
    /// @param from The sender address.
    /// @param to The recipient address.
    /// @param amount The amount to transfer.
    /// @return success True if transfer succeeded, false otherwise.
    function _safeTransferFrom(address token, address from, address to, uint256 amount)
        internal
        returns (bool success)
    {
        return IERC20(token).trySafeTransferFrom(from, to, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        REQUIRED INTERFACE IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function execute(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        virtual
        returns (DataTypes.ExecutionResult memory result);

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        view
        virtual
        returns (bool isValid, string memory reason);

    /// @inheritdoc IActionModule
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        virtual
        returns (uint256 estimatedOutput, address outputToken);

    /// @inheritdoc IActionModule
    function moduleType() external pure virtual returns (string memory);
}
