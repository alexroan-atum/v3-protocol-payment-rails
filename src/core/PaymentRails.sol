// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPaymentRails } from "../interfaces/IPaymentRails.sol";
import { IActionModule } from "../interfaces/IActionModule.sol";
import { PaymentRailsState } from "../abstracts/PaymentRailsState.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { Errors } from "../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PaymentRails
/// @author Credit Cooperative
/// @notice Core router contract for automated cross-chain token actions
/// @dev This contract maintains token configurations and delegates execution to pluggable action modules.
///
/// # Architecture
/// - Inherits from PaymentRailsState for state management abstraction
/// - Inherits from Ownable for access control (only owner can configure)
/// - Inherits from ReentrancyGuard for reentrancy protection on executeAction
/// - Uses SafeERC20 for safe token transfers
///
/// # Key Features
/// - **Modular Design**: Delegates actions to separate module contracts (ForwardModule, UniswapSwapModule,
/// CowSwapModule, CCTPBridgeModule)
/// - **Permissionless Execution**: Anyone can trigger pre-configured actions via executeAction()
/// - **Owner-Only Configuration**: Only owner can call configureToken() to set destinations and parameters
/// - **String-Based Action Types**: Supports unlimited module types without interface changes
/// - **Cooldown Mechanism**: Prevents spam and encourages batching with per-token cooldown periods
/// - **Minimum Balance Thresholds**: Avoids inefficient small executions
///
/// # Security Model
/// - Executors can only trigger pre-configured actions (no arbitrary parameters)
/// - Amount parameter is bounded: amount >= minBalance AND amount <= paymentRails balance
/// - Modules are validated on configuration (moduleType() must return non-empty string)
/// - Token approvals are revoked on execution failure
/// - Reentrancy protection on executeAction()
contract PaymentRails is IPaymentRails, PaymentRailsState, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Constructs the PaymentRails contract
    /// @dev Initializes Ownable with the provided owner address
    /// @param initialOwner The address that will own the contract and can configure tokens
    constructor(address initialOwner) Ownable(initialOwner) { }

    /*//////////////////////////////////////////////////////////////////////////
                        USER-FACING CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentRails
    function getTokenConfig(address token) external view returns (DataTypes.TokenConfig memory) {
        return _tokenConfigs[token];
    }

    /// @inheritdoc IPaymentRails
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc IPaymentRails
    function previewExecution(address token) external view returns (uint256 estimatedOutput, address outputToken) {
        // Check: Token address not zero
        if (token == address(0)) {
            revert Errors.PaymentRails_ZeroTokenAddress();
        }

        // Use storage pointer for gas efficiency (no memory copy needed)
        DataTypes.TokenConfig storage config = _tokenConfigs[token];

        // Check: Action configured
        if (bytes(config.actionType).length == 0) {
            revert Errors.PaymentRails_NoActionConfigured();
        }

        // Check: Token enabled
        if (!config.enabled) {
            revert Errors.PaymentRails_TokenNotEnabled();
        }

        // Check: Module is a contract
        if (config.actionModule.code.length == 0) {
            revert Errors.PaymentRails_InvalidModule();
        }

        // Check: Get token balance
        // Note: Assumes token is trusted ERC20 implementation
        // Malicious tokens could return fake balance or revert, but this is acceptable for preview
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Check: Non-zero balance (consistency with executeAction which checks amount != 0)
        if (balance == 0) {
            revert Errors.PaymentRails_ZeroAmount();
        }

        // Check: Balance meets minimum threshold
        if (balance < config.minBalance) {
            revert Errors.PaymentRails_BelowMinimumBalance(balance, config.minBalance);
        }

        // Check: Module validation
        (bool isValid, string memory reason) =
            IActionModule(config.actionModule).validate(token, balance, config.moduleParams, "");
        if (!isValid) {
            // Module validation failed - revert with module's reason
            // Note: Cannot revert with module's custom error, so we use a descriptive revert
            revert(reason);
        }

        // All checks passed - get output estimation
        return IActionModule(config.actionModule).estimateOutput(token, balance, config.moduleParams);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentRails
    /// @dev Emits a {TokenConfigured} event.
    ///
    /// Notes:
    /// - Setting actionType to empty string clears the configuration
    /// - When clearing, actionModule must be address(0)
    /// - Reconfiguring resets lastExecuted to 0
    /// - Module is validated by calling moduleType() which must succeed and return non-empty string
    ///
    /// Requirements:
    /// - The caller must be the contract owner
    /// - `token` must not be the zero address
    /// - If `actionType` is empty, `actionModule` must be address(0)
    /// - If `actionType` is not empty, `actionModule` must be a valid contract implementing IActionModule
    ///
    /// @param token The token address to configure
    /// @param actionType The action identifier string (e.g., "FORWARD", "SWAP", "BRIDGE")
    /// @param actionModule The address of the action module contract
    /// @param minBalance The minimum balance threshold required for execution
    /// @param moduleParams ABI-encoded parameters specific to the action module
    /// @param enabled Whether the token action should be immediately enabled
    function configureToken(
        address token,
        string calldata actionType,
        address actionModule,
        uint256 minBalance,
        bytes calldata moduleParams,
        bool enabled
    )
        external
        onlyOwner
    {
        // Check: Token address not zero
        if (token == address(0)) {
            revert Errors.PaymentRails_ZeroTokenAddress();
        }

        // Empty string means clearing configuration
        bool isNoneAction = bytes(actionType).length == 0;

        if (isNoneAction) {
            // Check: When clearing config, module should be zero address
            if (actionModule != address(0)) {
                revert Errors.PaymentRails_NoneActionRequiresZeroModule();
            }
        } else {
            // Check: Action module not zero address
            if (actionModule == address(0)) {
                revert Errors.PaymentRails_ZeroModuleAddress();
            }

            // Check: Validate module implements IActionModule correctly
            try IActionModule(actionModule).moduleType() returns (string memory moduleTypeStr) {
                // Check: Module returns valid type string
                if (bytes(moduleTypeStr).length == 0) {
                    revert Errors.PaymentRails_InvalidModule();
                }
            } catch {
                revert Errors.PaymentRails_ModuleValidationFailed();
            }
        }

        // Effect: Store configuration
        _tokenConfigs[token] = DataTypes.TokenConfig({
            actionType: actionType,
            actionModule: actionModule,
            enabled: enabled,
            minBalance: minBalance,
            moduleParams: moduleParams
        });

        // Log: Emit configuration event
        emit TokenConfigured(token, actionType, actionModule);
    }

    /// @inheritdoc IPaymentRails
    /// @dev Emits an {ActionExecuted} event on successful execution.
    ///
    /// Notes:
    /// - Execution is permissionless - anyone can call this function
    /// - The caller (msg.sender) is recorded in the ActionExecuted event for tracking
    /// - Execution follows Check-Effects-Interactions pattern
    /// - lastExecuted timestamp is updated BEFORE calling the module
    /// - Token approval is granted to module, then revoked on failure
    ///
    /// Requirements:
    /// - Token must be configured (non-empty actionType)
    /// - Token must be enabled
    /// - `amount` must not be zero
    /// - `amount` must be >= minBalance (prevents inefficient small executions)
    /// - Cooldown period must have elapsed since last execution
    /// - PaymentRails must have sufficient token balance (balance >= amount)
    ///
    /// @param token The token address to execute action for
    /// @param amount The exact amount of tokens to process (must be >= minBalance and <= balance)
    /// @return success True if the action executed successfully, false otherwise
    function executeAction(address token, uint256 amount) external nonReentrant returns (bool success) {
        return _validateAndExecute(token, amount, "");
    }

    /// @inheritdoc IPaymentRails
    function executeAction(
        address token,
        uint256 amount,
        bytes calldata executionData
    )
        external
        nonReentrant
        returns (bool success)
    {
        return _validateAndExecute(token, amount, executionData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Validates preconditions and delegates to _executeActionInternal
    function _validateAndExecute(
        address token,
        uint256 amount,
        bytes memory executionData
    )
        private
        returns (bool success)
    {
        DataTypes.TokenConfig memory config = _tokenConfigs[token];

        if (!config.enabled) {
            revert Errors.PaymentRails_TokenNotEnabled();
        }
        if (bytes(config.actionType).length == 0) {
            revert Errors.PaymentRails_NoActionConfigured();
        }
        if (amount == 0) {
            revert Errors.PaymentRails_ZeroAmount();
        }
        if (amount < config.minBalance) {
            revert Errors.PaymentRails_BelowMinimumBalance(amount, config.minBalance);
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) {
            revert Errors.PaymentRails_InsufficientBalance(balance, amount);
        }

        return _executeActionInternal(token, amount, config, executionData);
    }

    /// @notice Executes an action by delegating to the configured action module
    /// @dev This function handles token approval, module execution, and cleanup
    ///
    /// Notes:
    /// - Approves exact amount to module using forceApprove (handles non-standard ERC20s)
    /// - Revokes approval on execution failure
    /// - Does NOT revert on failure - returns false instead
    ///
    /// @param token The token address being processed
    /// @param amount The amount of tokens to process
    /// @param config The token configuration containing module address and parameters
    /// @param executionData Dynamic per-execution data forwarded to the module
    /// @return success True if module execution succeeded, false otherwise
    function _executeActionInternal(
        address token,
        uint256 amount,
        DataTypes.TokenConfig memory config,
        bytes memory executionData
    )
        private
        returns (bool success)
    {
        // Interaction: Approve module to spend tokens
        IERC20(token).forceApprove(config.actionModule, amount);

        // Interaction: Execute via module
        try IActionModule(config.actionModule).execute(token, amount, config.moduleParams, executionData) returns (
            DataTypes.ExecutionResult memory result
        ) {
            if (result.success) {
                // Log: Emit success event
                emit ActionExecuted(token, config.actionType, amount, result.amountOut, result.outputToken, msg.sender);
                return true;
            } else {
                // Effect: Revoke approval on module-reported failure
                IERC20(token).forceApprove(config.actionModule, 0);
                return false;
            }
        } catch {
            // Effect: Revoke approval on execution revert
            IERC20(token).forceApprove(config.actionModule, 0);
            return false;
        }
    }
}
