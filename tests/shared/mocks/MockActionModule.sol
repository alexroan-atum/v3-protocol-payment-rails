// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "../../../src/interfaces/IActionModule.sol";
import { DataTypes } from "../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Controllable mock implementing IActionModule for Node unit tests.
contract MockActionModule is IActionModule {
    bool public shouldSucceed = true;
    bool public shouldRevert;
    string public revertReason;

    bool public validationResult = true;
    string public validationReason = "";

    function setExecuteSuccess(bool _success) external {
        shouldSucceed = _success;
    }

    function setExecuteRevert(bool _revert, string memory _reason) external {
        shouldRevert = _revert;
        revertReason = _reason;
    }

    function setValidationResult(bool _valid, string memory _reason) external {
        validationResult = _valid;
        validationReason = _reason;
    }

    function execute(
        address token,
        uint256 amount,
        bytes calldata
    )
        external
        override
        returns (DataTypes.ExecutionResult memory)
    {
        if (shouldRevert) revert(revertReason);

        if (shouldSucceed) {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
            return DataTypes.ExecutionResult({
                success: true, amountOut: amount, outputToken: token, data: "", failureReason: ""
            });
        } else {
            return DataTypes.ExecutionResult({
                success: false, amountOut: 0, outputToken: token, data: "", failureReason: "Module execution failed"
            });
        }
    }

    function validate(address, uint256, bytes calldata) external view override returns (bool, string memory) {
        return (validationResult, validationReason);
    }

    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata
    )
        external
        pure
        override
        returns (uint256, address)
    {
        return (amount, token);
    }

    function moduleType() external pure override returns (string memory) {
        return "MOCK";
    }
}

/// @dev Mock module that returns an empty moduleType string (for testing Node_InvalidModule).
contract EmptyModuleTypeMock {
    function moduleType() external pure returns (string memory) {
        return "";
    }
}

/// @dev Mock module whose moduleType() reverts (for testing Node_ModuleValidationFailed).
contract RevertingModuleMock {
    function moduleType() external pure returns (string memory) {
        revert("not a module");
    }
}
