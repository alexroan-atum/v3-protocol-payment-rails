// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { INode } from "../interfaces/INode.sol";
import { IActionModule } from "../interfaces/IActionModule.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Node
/// @author Credit Cooperative
/// @notice Core contract for routing tokens through configurable action modules
/// @dev Maintains token configurations and delegates execution to modules (Swap, Bridge, Forward)
/// @dev Execution is permissionless - anyone can trigger pre-configured actions
contract Node is INode, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Custom errors for gas-efficient reverts
    error ZeroTokenAddress();
    error NoneActionRequiresZeroModule();
    error ZeroModuleAddress();
    error InvalidModule();
    error ModuleValidationFailed();
    error TokenNotConfigured();
    error TokenNotEnabled();
    error NoActionConfigured();
    error CooldownNotElapsed();
    error BelowMinimumBalance();
    error ZeroAmount();
    error InsufficientBalance();

    /// @notice Mapping of token addresses to their configurations
    mapping(address => TokenConfig) private _tokenConfigs;

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @inheritdoc INode
    function configureToken(
        address token,
        ActionType actionType,
        address actionModule,
        uint256 minBalance,
        uint256 cooldownSeconds,
        bytes calldata moduleParams
    ) external onlyOwner {
        if (token == address(0)) revert ZeroTokenAddress();

        if (actionType == ActionType.NONE) {
            // When clearing config, module should be zero address
            if (actionModule != address(0)) revert NoneActionRequiresZeroModule();
        } else {
            // When setting an action, module must be valid
            if (actionModule == address(0)) revert ZeroModuleAddress();

            // Validate that module type matches (basic check)
            try IActionModule(actionModule).moduleType() returns (string memory moduleTypeStr) {
                // Module should return valid type
                if (bytes(moduleTypeStr).length == 0) revert InvalidModule();
            } catch {
                revert ModuleValidationFailed();
            }
        }

        _tokenConfigs[token] = TokenConfig({
            actionType: actionType,
            actionModule: actionModule,
            enabled: true,
            minBalance: minBalance,
            cooldownSeconds: cooldownSeconds,
            lastExecuted: 0,
            moduleParams: moduleParams
        });

        emit TokenConfigured(token, actionType, actionModule);
    }

    /// @inheritdoc INode
    function setTokenEnabled(address token, bool enabled) external onlyOwner {
        if (_tokenConfigs[token].actionType == ActionType.NONE) revert TokenNotConfigured();
        _tokenConfigs[token].enabled = enabled;
    }

    /// @inheritdoc INode
    function executeAction(address token, uint256 amount) external nonReentrant returns (bool success) {
        TokenConfig memory config = _tokenConfigs[token];
        if (!config.enabled) revert TokenNotEnabled();
        if (config.actionType == ActionType.NONE) revert NoActionConfigured();
        if (amount == 0) revert ZeroAmount();

        // Check amount meets minimum threshold (prevents inefficient small swaps)
        if (amount < config.minBalance) revert BelowMinimumBalance();

        // Check cooldown (skip if never executed before)
        if (config.lastExecuted != 0) {
            if (block.timestamp < config.lastExecuted + config.cooldownSeconds) {
                revert CooldownNotElapsed();
            }
        }

        // Check we have enough balance
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Update last executed timestamp
        _tokenConfigs[token].lastExecuted = block.timestamp;

        // Execute action via module with specific amount
        return _executeActionInternal(token, amount, config);
    }

    /// @inheritdoc INode
    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return _tokenConfigs[token];
    }

    /// @inheritdoc INode
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc INode
    function canExecute(address token) external view returns (bool, string memory) {
        TokenConfig memory config = _tokenConfigs[token];

        if (config.actionType == ActionType.NONE) {
            return (false, "No action configured");
        }

        if (!config.enabled) {
            return (false, "Token not enabled");
        }

        if (config.lastExecuted != 0 && block.timestamp < config.lastExecuted + config.cooldownSeconds) {
            return (false, "Cooldown not elapsed");
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < config.minBalance) {
            return (false, "Below minimum balance");
        }

        // Check module validation
        try IActionModule(config.actionModule).validate(token, balance, config.moduleParams) returns (
            bool isValid, string memory reason
        ) {
            if (!isValid) {
                return (false, reason);
            }
        } catch {
            return (false, "Module validation failed");
        }

        return (true, "");
    }

    /// @inheritdoc INode
    function estimateActionOutput(address token) external view returns (uint256 estimatedOutput, address outputToken) {
        TokenConfig memory config = _tokenConfigs[token];
        if (config.actionType == ActionType.NONE) revert NoActionConfigured();

        uint256 balance = IERC20(token).balanceOf(address(this));

        return IActionModule(config.actionModule).estimateOutput(token, balance, config.moduleParams);
    }

    /// @notice Internal function to execute action via module
    /// @param token Token address
    /// @param amount Amount to process
    /// @param config Token configuration
    /// @return success Whether execution succeeded
    function _executeActionInternal(address token, uint256 amount, TokenConfig memory config)
        private
        returns (bool success)
    {
        // Approve module to spend tokens
        IERC20(token).forceApprove(config.actionModule, amount);

        // Execute via module
        try IActionModule(config.actionModule).execute(token, amount, config.moduleParams) returns (
            IActionModule.ExecutionResult memory result
        ) {
            if (result.success) {
                emit ActionExecuted(
                    token, config.actionType, amount, result.amountOut, result.outputToken, msg.sender
                );
                return true;
            } else {
                // Revoke approval on failure
                IERC20(token).forceApprove(config.actionModule, 0);
                return false;
            }
        } catch {
            // Revoke approval on failure
            IERC20(token).forceApprove(config.actionModule, 0);
            return false;
        }
    }
}
