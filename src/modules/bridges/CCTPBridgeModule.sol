// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { ICCTPBridgeModule } from "../../interfaces/ICCTPBridgeModule.sol";
import { ITokenMessengerV2 } from "../../interfaces/ITokenMessengerV2.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CCTPBridgeModule
/// @author Credit Cooperative
/// @notice Action module that bridges USDC cross-chain via Circle's CCTP V2 protocol.
/// @dev Stateless — see {ICCTPBridgeModule} for lifecycle and configuration model.
contract CCTPBridgeModule is ICCTPBridgeModule, ActionModuleBase {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICCTPBridgeModule
    address public immutable override tokenMessenger;

    /// @inheritdoc ICCTPBridgeModule
    address public immutable override usdc;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _tokenMessenger Circle's TokenMessengerV2 on this chain.
    /// @param _usdc           Native USDC on this chain.
    constructor(address _tokenMessenger, address _usdc) {
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
        (bool valid, string memory reason, DataTypes.CCTPBridgeParams memory bridgeParams) =
            _validateBridgeParams(token, amount, params);
        if (!valid) {
            return _failedResult(token, reason);
        }

        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            return _failedResult(token, "Token transfer failed");
        }

        IERC20(usdc).forceApprove(tokenMessenger, amount);

        if (bridgeParams.hookData.length > 0) {
            ITokenMessengerV2(tokenMessenger)
                .depositForBurnWithHook(
                    amount,
                    bridgeParams.destinationDomain,
                    bridgeParams.mintRecipient,
                    usdc,
                    bridgeParams.destinationCaller,
                    bridgeParams.maxFee,
                    bridgeParams.minFinalityThreshold,
                    bridgeParams.hookData
                );
        } else {
            ITokenMessengerV2(tokenMessenger)
                .depositForBurn(
                    amount,
                    bridgeParams.destinationDomain,
                    bridgeParams.mintRecipient,
                    usdc,
                    bridgeParams.destinationCaller,
                    bridgeParams.maxFee,
                    bridgeParams.minFinalityThreshold
                );
        }

        // Defense-in-depth: revoke any leftover approval.
        IERC20(usdc).forceApprove(tokenMessenger, 0);

        emit BridgeInitiated(
            msg.sender,
            amount,
            bridgeParams.destinationDomain,
            bridgeParams.mintRecipient,
            bridgeParams.maxFee,
            bridgeParams.minFinalityThreshold,
            bridgeParams.hookData
        );

        return _successResult(
            amount - bridgeParams.maxFee, token, abi.encode(bridgeParams.destinationDomain, bridgeParams.mintRecipient)
        );
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
        (isValid, reason,) = _validateBridgeParams(token, amount, params);
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
        (bool valid,, DataTypes.CCTPBridgeParams memory bridgeParams) = _validateBridgeParams(token, amount, params);

        if (!valid) {
            return (0, token);
        }

        return (amount - bridgeParams.maxFee, token);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "CCTP_BRIDGE";
    }

    /// @inheritdoc ICCTPBridgeModule
    function encodeParams(DataTypes.CCTPBridgeParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(
            params.destinationDomain,
            params.mintRecipient,
            params.destinationCaller,
            params.maxFee,
            params.minFinalityThreshold,
            params.hookData
        );
    }

    /// @inheritdoc ICCTPBridgeModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.CCTPBridgeParams memory params) {
        (
            params.destinationDomain,
            params.mintRecipient,
            params.destinationCaller,
            params.maxFee,
            params.minFinalityThreshold,
            params.hookData
        ) = abi.decode(encoded, (uint32, bytes32, bytes32, uint256, uint32, bytes));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Shared validation. Returns decoded params so callers avoid a redundant decode.
    function _validateBridgeParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (bool valid, string memory reason, DataTypes.CCTPBridgeParams memory bridgeParams)
    {
        // 6 fixed slots + 1 bytes-offset slot = 7 × 32 = 224 bytes minimum.
        if (params.length < 224) {
            return (false, "Invalid params encoding", bridgeParams);
        }

        bridgeParams = decodeParams(params);

        if (amount == 0) {
            return (false, "Zero bridge amount", bridgeParams);
        }
        if (token != usdc) {
            return (false, "Only USDC supported", bridgeParams);
        }
        if (bridgeParams.mintRecipient == bytes32(0)) {
            return (false, "Zero mint recipient", bridgeParams);
        }
        if (bridgeParams.minFinalityThreshold != 1000 && bridgeParams.minFinalityThreshold != 2000) {
            return (false, "Invalid finality threshold", bridgeParams);
        }
        if (bridgeParams.maxFee >= amount) {
            return (false, "Max fee exceeds amount", bridgeParams);
        }
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance", bridgeParams);
        }

        return (true, "", bridgeParams);
    }
}
