// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IForwardModule } from "../interfaces/IForwardModule.sol";
import { IActionModule } from "../interfaces/IActionModule.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ForwardModule
/// @author Credit Cooperative
/// @notice Module for forwarding tokens to a destination address
/// @dev Implements simple token transfer functionality
contract ForwardModule is IForwardModule {
    using SafeERC20 for IERC20;

    /// @inheritdoc IActionModule
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external returns (ExecutionResult memory result) {
        ForwardParams memory forwardParams = decodeParams(params);

        // Validate parameters
        if (forwardParams.recipient == address(0)) {
            return ExecutionResult({
                success: false,
                amountOut: 0,
                outputToken: token,
                data: "",
                failureReason: "Zero recipient address"
            });
        }

        if (amount < forwardParams.minAmount) {
            return ExecutionResult({
                success: false,
                amountOut: 0,
                outputToken: token,
                data: "",
                failureReason: "Amount below minimum"
            });
        }

        // Check balance
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        if (balance < amount) {
            return ExecutionResult({
                success: false,
                amountOut: 0,
                outputToken: token,
                data: "",
                failureReason: "Insufficient balance"
            });
        }

        // Transfer tokens from caller (Node) to recipient
        try IERC20(token).transferFrom(msg.sender, forwardParams.recipient, amount) {
            return ExecutionResult({
                success: true,
                amountOut: amount,
                outputToken: token,
                data: abi.encode(forwardParams.recipient),
                failureReason: ""
            });
        } catch Error(string memory reason) {
            return ExecutionResult({
                success: false,
                amountOut: 0,
                outputToken: token,
                data: "",
                failureReason: reason
            });
        } catch {
            return ExecutionResult({
                success: false,
                amountOut: 0,
                outputToken: token,
                data: "",
                failureReason: "Transfer failed"
            });
        }
    }

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view returns (bool isValid, string memory reason) {
        ForwardParams memory forwardParams = decodeParams(params);

        if (forwardParams.recipient == address(0)) {
            return (false, "Zero recipient address");
        }

        if (amount < forwardParams.minAmount) {
            return (false, "Amount below minimum");
        }

        // Check if caller has sufficient balance
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        if (balance < amount) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    /// @inheritdoc IActionModule
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata /* params */
    ) external pure returns (uint256 estimatedOutput, address outputToken) {
        // For forward, output equals input (1:1 transfer)
        return (amount, token);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure returns (string memory) {
        return "FORWARD";
    }

    /// @inheritdoc IForwardModule
    function encodeParams(ForwardParams calldata params) external pure returns (bytes memory) {
        return abi.encode(params.recipient, params.requireSuccessfulReceipt, params.minAmount);
    }

    /// @inheritdoc IForwardModule
    function decodeParams(bytes calldata encoded) public pure returns (ForwardParams memory params) {
        (params.recipient, params.requireSuccessfulReceipt, params.minAmount) = abi.decode(
            encoded,
            (address, bool, uint256)
        );
    }
}
