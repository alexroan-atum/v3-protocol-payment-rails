// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ICCTPBridgeModule } from "../../interfaces/ICCTPBridgeModule.sol";
import { ITokenMessengerV2 } from "../../interfaces/ITokenMessengerV2.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CCTPBridgeModule
/// @author Credit Cooperative
/// @notice Action module that bridges USDC cross-chain via Circle's CCTP V2 protocol.
/// @dev See {ICCTPBridgeModule} for the full lifecycle, configuration model, and security notes.
/// A single instance may be shared across multiple Nodes bridging to the same destinations.
contract CCTPBridgeModule is ICCTPBridgeModule, ActionModuleBase, Ownable2Step {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICCTPBridgeModule
    address public immutable override tokenMessenger;

    /// @inheritdoc ICCTPBridgeModule
    address public immutable override usdc;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Per-domain routing configuration, keyed by CCTP domain ID.
    mapping(uint32 destinationDomain => DataTypes.CCTPDomainConfig config) private _domainConfigs;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Reverts with {Errors.CCTPBridgeModule_ZeroTokenMessenger} if `_tokenMessenger` is the zero
    ///      address. Reverts with {Errors.CCTPBridgeModule_ZeroUSDC} if `_usdc` is the zero address.
    /// @param _tokenMessenger Address of Circle's TokenMessengerV2 on this chain.
    /// @param _usdc           Address of native USDC on this chain.
    /// @param _owner          Initial module owner (can call `setDomainConfig` / `removeDomainConfig`).
    constructor(address _tokenMessenger, address _usdc, address _owner) Ownable(_owner) {
        if (_tokenMessenger == address(0)) revert Errors.CCTPBridgeModule_ZeroTokenMessenger();
        if (_usdc == address(0)) revert Errors.CCTPBridgeModule_ZeroUSDC();

        tokenMessenger = _tokenMessenger;
        usdc = _usdc;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
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
        (
            bool valid,
            string memory reason,
            DataTypes.CCTPBridgeParams memory bridgeParams,
            DataTypes.CCTPDomainConfig memory config
        ) = _validateBridgeParams(token, amount, params);
        if (!valid) {
            return _failedResult(token, reason);
        }

        // --- Interactions ---

        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            return _failedResult(token, "Token transfer failed");
        }

        IERC20(usdc).forceApprove(tokenMessenger, amount);

        // Branch on hook data: non-empty → depositForBurnWithHook, empty → depositForBurn.
        // If the CCTP call reverts (paused, burn-limit exceeded, etc.) the entire execute() reverts
        // atomically — the Node's try/catch restores USDC to the Node.
        if (config.hookData.length > 0) {
            ITokenMessengerV2(tokenMessenger)
                .depositForBurnWithHook(
                    amount,
                    bridgeParams.destinationDomain,
                    config.mintRecipient,
                    usdc,
                    config.destinationCaller,
                    config.maxFee,
                    config.minFinalityThreshold,
                    config.hookData
                );
        } else {
            ITokenMessengerV2(tokenMessenger)
                .depositForBurn(
                    amount,
                    bridgeParams.destinationDomain,
                    config.mintRecipient,
                    usdc,
                    config.destinationCaller,
                    config.maxFee,
                    config.minFinalityThreshold
                );
        }

        // Revoke any leftover approval (defense-in-depth; depositForBurn should consume it all).
        IERC20(usdc).forceApprove(tokenMessenger, 0);

        emit BridgeInitiated(
            msg.sender,
            amount,
            bridgeParams.destinationDomain,
            config.mintRecipient,
            config.maxFee,
            config.minFinalityThreshold,
            config.hookData
        );

        return _successResult(
            amount - config.maxFee, token, abi.encode(bridgeParams.destinationDomain, config.mintRecipient)
        );
    }

    /// @inheritdoc ICCTPBridgeModule
    function setDomainConfig(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    )
        external
        onlyOwner
    {
        if (mintRecipient == bytes32(0)) {
            revert Errors.CCTPBridgeModule_ZeroMintRecipient();
        }
        if (minFinalityThreshold != 1000 && minFinalityThreshold != 2000) {
            revert Errors.CCTPBridgeModule_InvalidFinalityThreshold(minFinalityThreshold);
        }

        _domainConfigs[destinationDomain] = DataTypes.CCTPDomainConfig({
            isValid: true,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: maxFee,
            minFinalityThreshold: minFinalityThreshold,
            hookData: hookData
        });

        emit DomainConfigSet(destinationDomain, mintRecipient, destinationCaller, maxFee, minFinalityThreshold);
    }

    /// @inheritdoc ICCTPBridgeModule
    function removeDomainConfig(uint32 destinationDomain) external onlyOwner {
        if (!_domainConfigs[destinationDomain].isValid) {
            revert Errors.CCTPBridgeModule_DomainNotConfigured(destinationDomain);
        }

        delete _domainConfigs[destinationDomain];

        emit DomainConfigRemoved(destinationDomain);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
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
        (isValid, reason,,) = _validateBridgeParams(token, amount, params);
    }

    /// @inheritdoc ICCTPBridgeModule
    function getDomainConfig(uint32 destinationDomain)
        external
        view
        returns (DataTypes.CCTPDomainConfig memory config)
    {
        return _domainConfigs[destinationDomain];
    }

    /// @inheritdoc IActionModule
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        override(ActionModuleBase, IActionModule)
        returns (uint256 estimatedOutput, address outputToken)
    {
        if (params.length < 32) {
            return (0, token);
        }

        DataTypes.CCTPBridgeParams memory bridgeParams = decodeParams(params);
        DataTypes.CCTPDomainConfig memory config = _domainConfigs[bridgeParams.destinationDomain];

        if (!config.isValid || config.maxFee >= amount) {
            return (0, token);
        }

        return (amount - config.maxFee, token);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "CCTP_BRIDGE";
    }

    /// @inheritdoc ICCTPBridgeModule
    function encodeParams(DataTypes.CCTPBridgeParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params.destinationDomain);
    }

    /// @inheritdoc ICCTPBridgeModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.CCTPBridgeParams memory params) {
        (params.destinationDomain) = abi.decode(encoded, (uint32));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Shared validation for `execute` and `validate`. Returns the decoded params and domain
    ///      config on success so callers avoid a redundant decode / storage read.
    function _validateBridgeParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (
            bool valid,
            string memory reason,
            DataTypes.CCTPBridgeParams memory bridgeParams,
            DataTypes.CCTPDomainConfig memory config
        )
    {
        if (params.length < 32) {
            return (false, "Invalid params encoding", bridgeParams, config);
        }

        bridgeParams = decodeParams(params);

        if (amount == 0) {
            return (false, "Zero bridge amount", bridgeParams, config);
        }
        if (token != usdc) {
            return (false, "Only USDC supported", bridgeParams, config);
        }

        config = _domainConfigs[bridgeParams.destinationDomain];

        if (!config.isValid) {
            return (false, "Domain not configured", bridgeParams, config);
        }
        if (config.maxFee >= amount) {
            return (false, "Max fee exceeds amount", bridgeParams, config);
        }
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance", bridgeParams, config);
        }

        return (true, "", bridgeParams, config);
    }
}
