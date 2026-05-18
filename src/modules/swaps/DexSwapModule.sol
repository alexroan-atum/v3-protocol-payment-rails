// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IDexSwapModule } from "../../interfaces/IDexSwapModule.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title DexSwapModule
/// @author Credit Cooperative
/// @notice Synchronous swap module that executes atomic swaps through whitelisted DEX routers.
/// @dev See {IDexSwapModule} for the full architecture, security model, and execution flow.
///
/// The router sends output tokens directly to the PaymentRails (encoded in `routerCalldata`).
/// The module verifies the swap by measuring the PaymentRails's targetToken balance before and after
/// the router call — never trusting router return values.
///
/// A single instance may be shared across multiple PaymentRails, since the module holds no persistent
/// token state. Router whitelist and ownership are module-level (not per-PaymentRails).
contract DexSwapModule is IDexSwapModule, ActionModuleBase, Ownable2Step {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Whitelisted router addresses. Only these may be called during execute().
    mapping(address router => bool allowed) private _allowedRouters;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _owner Address that will own this module (manages router whitelist).
    constructor(address _owner) Ownable(_owner) { }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDexSwapModule
    function addRouter(address router) external onlyOwner {
        if (router == address(0)) revert Errors.DexSwapModule_ZeroRouter();
        if (router.code.length == 0) revert Errors.DexSwapModule_RouterNotContract(router);
        if (_allowedRouters[router]) revert Errors.DexSwapModule_RouterAlreadyAdded(router);

        _allowedRouters[router] = true;
        emit RouterAdded(router);
    }

    /// @inheritdoc IDexSwapModule
    function removeRouter(address router) external onlyOwner {
        if (!_allowedRouters[router]) revert Errors.DexSwapModule_RouterNotAllowed(router);

        _allowedRouters[router] = false;
        emit RouterRemoved(router);
    }

    /// @inheritdoc IActionModule
    function execute(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        override(ActionModuleBase, IActionModule)
        returns (DataTypes.ExecutionResult memory)
    {
        if (params.length < 32) return _failedResult(token, "Invalid params encoding");
        if (executionData.length == 0) return _failedResult(token, "Missing execution data");
        if (amount == 0) return _failedResult(token, "Zero sell amount");

        DataTypes.DexSwapParams memory cfg = decodeParams(params);
        DataTypes.DexSwapExecutionData memory exec = decodeExecutionData(executionData);

        {
            (bool valid, string memory reason) = _validateInputs(token, amount, cfg, exec);
            if (!valid) return _failedResult(token, reason);
        }

        (bool ok, uint256 actualIn, uint256 amountOut) = _executeSwap(token, amount, cfg.targetToken, exec);

        _returnLeftover(token, msg.sender);

        if (!ok) return _failedResult(token, "Router call failed");
        if (amountOut < exec.minAmountOut) {
            revert Errors.DexSwapModule_InsufficientOutput(amountOut, exec.minAmountOut);
        }

        emit SwapExecuted(msg.sender, token, cfg.targetToken, actualIn, amountOut, exec.router);

        return _successResult(amountOut, cfg.targetToken, abi.encode(exec.router));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        view
        override(ActionModuleBase, IActionModule)
        returns (bool isValid, string memory reason)
    {
        if (params.length < 32) return (false, "Invalid params encoding");

        DataTypes.DexSwapParams memory cfg = decodeParams(params);

        if (cfg.targetToken == address(0)) return (false, "Zero target token");
        if (cfg.targetToken == token) return (false, "Same input and output token");
        if (amount == 0) return (false, "Zero sell amount");

        if (executionData.length > 0) {
            (bool execValid, string memory execReason) = _validateExecutionData(executionData);
            if (!execValid) return (false, execReason);
        }

        if (!_hasSufficientBalance(token, amount)) return (false, "Insufficient balance");

        return (true, "");
    }

    /// @inheritdoc IActionModule
    function estimateOutput(
        address,
        uint256,
        bytes calldata params
    )
        external
        pure
        override(ActionModuleBase, IActionModule)
        returns (uint256 estimatedOutput, address outputToken)
    {
        DataTypes.DexSwapParams memory cfg = decodeParams(params);
        return (0, cfg.targetToken);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "SWAP";
    }

    /// @inheritdoc IDexSwapModule
    function isRouterAllowed(address router) external view returns (bool allowed) {
        return _allowedRouters[router];
    }

    /// @inheritdoc IDexSwapModule
    function encodeParams(DataTypes.DexSwapParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params.targetToken);
    }

    /// @inheritdoc IDexSwapModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.DexSwapParams memory params) {
        (params.targetToken) = abi.decode(encoded, (address));
    }

    /// @inheritdoc IDexSwapModule
    function encodeExecutionData(DataTypes.DexSwapExecutionData calldata data)
        external
        pure
        returns (bytes memory encoded)
    {
        return abi.encode(data.router, data.minAmountOut, data.deadline, data.routerCalldata);
    }

    /// @inheritdoc IDexSwapModule
    function decodeExecutionData(bytes calldata encoded)
        public
        pure
        returns (DataTypes.DexSwapExecutionData memory data)
    {
        (data.router, data.minAmountOut, data.deadline, data.routerCalldata) =
            abi.decode(encoded, (address, uint256, uint256, bytes));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Validates decoded execution data fields.
    function _validateExecutionData(bytes calldata executionData) private view returns (bool, string memory) {
        DataTypes.DexSwapExecutionData memory exec = decodeExecutionData(executionData);
        if (!_allowedRouters[exec.router]) return (false, "Router not allowed");
        if (exec.minAmountOut == 0) return (false, "Zero min amount out");
        if (block.timestamp > exec.deadline) return (false, "Deadline expired");
        return (true, "");
    }

    /// @dev Validates static config and execution data constraints.
    function _validateInputs(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg,
        DataTypes.DexSwapExecutionData memory exec
    )
        private
        view
        returns (bool, string memory)
    {
        if (cfg.targetToken == address(0)) return (false, "Zero target token");
        if (cfg.targetToken == token) return (false, "Same input and output token");
        if (!_allowedRouters[exec.router]) return (false, "Router not allowed");
        if (exec.minAmountOut == 0) return (false, "Zero min amount out");
        if (block.timestamp > exec.deadline) return (false, "Deadline expired");
        if (!_hasSufficientBalance(token, amount)) return (false, "Insufficient balance");
        return (true, "");
    }

    /// @dev Pulls sellToken via SafeERC20, calls the router, and measures output via balance diff.
    /// Uses balance-diff for the pull to correctly account for fee-on-transfer tokens.
    function _executeSwap(
        address token,
        uint256 amount,
        address targetToken,
        DataTypes.DexSwapExecutionData memory exec
    )
        private
        returns (bool ok, uint256 actualIn, uint256 amountOut)
    {
        uint256 sellBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        actualIn = IERC20(token).balanceOf(address(this)) - sellBefore;

        IERC20(token).forceApprove(exec.router, actualIn);

        uint256 buyTokenBefore = IERC20(targetToken).balanceOf(msg.sender);

        // solhint-disable-next-line avoid-low-level-calls
        (ok,) = exec.router.call(exec.routerCalldata);

        IERC20(token).forceApprove(exec.router, 0);

        if (!ok) return (false, actualIn, 0);

        uint256 buyTokenAfter = IERC20(targetToken).balanceOf(msg.sender);
        if (buyTokenAfter < buyTokenBefore) return (false, actualIn, 0);
        amountOut = buyTokenAfter - buyTokenBefore;
    }

    /// @dev Transfers any sellToken remaining in the module back to the PaymentRails.
    function _returnLeftover(address token, address paymentRails) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(paymentRails, bal);
        }
    }
}
