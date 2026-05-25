// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IForwardModule } from "../../interfaces/IForwardModule.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";

/// @title ForwardModule
/// @author Credit Cooperative
/// @notice See the documentation in {IForwardModule}.
contract ForwardModule is IForwardModule, ActionModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                        USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        override(ActionModuleBase, IActionModule)
        returns (DataTypes.ExecutionResult memory result)
    {
        DataTypes.ForwardParams memory forwardParams = decodeParams(params);

        if (!_isValidAddress(forwardParams.recipient)) {
            return _failedResult(token, "Zero recipient address");
        }

        if (amount < forwardParams.minAmount) {
            return _failedResult(token, "Amount below minimum");
        }

        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        bool transferSuccess = _safeTransferFrom(token, msg.sender, forwardParams.recipient, amount);

        if (!transferSuccess) {
            return _failedResult(token, "Transfer failed");
        }

        return _successResult(amount, token, abi.encode(forwardParams.recipient));
    }

    /*//////////////////////////////////////////////////////////////////////////
                        USER-FACING CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        override(ActionModuleBase, IActionModule)
        returns (bool isValid, string memory reason)
    {
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

    /// @inheritdoc IActionModule
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata /* params */
    )
        external
        pure
        override(ActionModuleBase, IActionModule)
        returns (uint256 estimatedOutput, address outputToken)
    {
        return (amount, token);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "FORWARD";
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FORWARD-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IForwardModule
    function encodeParams(DataTypes.ForwardParams calldata params) external pure returns (bytes memory) {
        return abi.encode(params.recipient, params.minAmount);
    }

    /// @inheritdoc IForwardModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.ForwardParams memory params) {
        (params.recipient, params.minAmount) = abi.decode(encoded, (address, uint256));
    }
}
