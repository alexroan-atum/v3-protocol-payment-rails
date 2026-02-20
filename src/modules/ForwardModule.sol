// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IForwardModule } from "../interfaces/IForwardModule.sol";
import { IActionModule } from "../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { Errors } from "../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ForwardModule
/// @author Credit Cooperative
/// @notice Module for forwarding tokens to a destination address
/// @dev Implements simple token transfer functionality using ActionModuleBase
contract ForwardModule is IForwardModule, ActionModuleBase {

    /// @inheritdoc ActionModuleBase
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    ) external override(ActionModuleBase, IActionModule) returns (DataTypes.ExecutionResult memory result) {
        DataTypes.ForwardParams memory forwardParams = decodeParams(params);

        // Validate recipient address
        if (!_isValidAddress(forwardParams.recipient)) {
            return _failedResult(token, "Zero recipient address");
        }

        // Validate minimum amount
        if (amount < forwardParams.minAmount) {
            return _failedResult(token, "Amount below minimum");
        }

        // Check balance
        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        // Transfer tokens from caller (Node) to recipient
        bool transferSuccess = _safeTransferFrom(token, msg.sender, forwardParams.recipient, amount);

        if (!transferSuccess) {
            return _failedResult(token, "Transfer failed");
        }

        return _successResult(amount, token, abi.encode(forwardParams.recipient));
    }

    /// @inheritdoc ActionModuleBase
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    ) external view override(ActionModuleBase, IActionModule) returns (bool isValid, string memory reason) {
        DataTypes.ForwardParams memory forwardParams = decodeParams(params);

        if (!_isValidAddress(forwardParams.recipient)) {
            return (false, "Zero recipient address");
        }

        if (amount < forwardParams.minAmount) {
            return (false, "Amount below minimum");
        }

        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    /// @inheritdoc ActionModuleBase
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata /* params */
    ) external pure override(ActionModuleBase, IActionModule) returns (uint256 estimatedOutput, address outputToken) {
        // For forward, output equals input (1:1 transfer)
        return (amount, token);
    }

    /// @inheritdoc ActionModuleBase
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "FORWARD";
    }

    /// @inheritdoc IForwardModule
    function encodeParams(DataTypes.ForwardParams calldata params) external pure returns (bytes memory) {
        return abi.encode(params.recipient, params.requireSuccessfulReceipt, params.minAmount);
    }

    /// @inheritdoc IForwardModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.ForwardParams memory params) {
        (params.recipient, params.requireSuccessfulReceipt, params.minAmount) = abi.decode(
            encoded,
            (address, bool, uint256)
        );
    }
}
