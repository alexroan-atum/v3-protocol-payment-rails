// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IAtumModule } from "../../interfaces/IAtumModule.sol";
import { IPermit2 } from "../../interfaces/IPermit2.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title AtumModule
/// @notice Minimal Node-bound Atum payment contract and ERC-1271 Permit2 owner.
/// @dev Each module deployment is permanently bound to one immutable Node. The module
///      is funded by that Node through `execute`, emits the current available source
///      balance and destination details for an offchain Atum keeper, and validates
///      generic Permit2 digests by keeper signature.
///
///      The module does not call Atum Escrow, compute request ids, compute fulfillment
///      amounts, decode Atum witness data, inspect Escrow state, classify payment
///      outcomes, reserve per-payment balances, or store per-payment recovery metadata.
///      The keeper derives source chain/source asset/request id and selects fulfillment
///      terms offchain.
///
///      `execute` is a Node funding action and payment availability signal, not a
///      complete Atum payment order. It moves additional source tokens into the module
///      and emits the module's full current balance for that token. The keeper should
///      create Atum payment requests from the available source balance, not merely from
///      the amount pulled by one Node action. Failed deposits, Escrow refunds, and
///      unused source balances remain in the module and can be picked up by a later
///      keeper request.
///
///      Keeper operating flow:
///      - Watch {AtumIntentCreated}; when emitted, read/use `availableSourceAmount` and
///        prepare a payment request for the available source balance.
///      - Watch Atum Escrow refund events and module token balances; when refunded
///        funds return, initiate a new payment request for the current module balance.
///      - Invalidate abandoned floating Permit2 digests before signing replacement
///        requests when those stale digests must not remain usable.
///
///      Pause is a rare fail-safe control for return-to-Node recovery. It blocks
///      new `execute` calls and ERC-1271 validation, makes `validate` fail, and enables
///      return-to-Node recovery. It does not revoke Permit2 approvals, invalidate
///      digests permanently, block inbound refunds or direct transfers, prove refund
///      attribution, or undo already consumed Permit2 nonces.
contract AtumModule is IAtumModule, ActionModuleBase, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev EIP-1271 magic value returned for valid signatures.
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev EIP-1271 failure value returned for invalid signatures.
    bytes4 internal constant EIP1271_FAILURE_VALUE = 0xffffffff;

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModule
    address public immutable override permit2;

    /// @inheritdoc IAtumModule
    bytes32 public immutable override permit2DomainSeparator;

    /// @inheritdoc IAtumModule
    address public immutable override node;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModule
    address public override keeper;

    /// @dev Permit2 digests that must no longer satisfy ERC-1271 checks.
    mapping(bytes32 digest => bool invalidated) private _invalidatedPermitDigests;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _permit2 Permit2 contract used by Atum Escrow on this source chain.
    /// @param _node Immutable Node allowed to call `execute`.
    /// @param _owner Module owner authorized to manage operations and keeper rotation.
    /// @param _keeper Keeper whose signatures validate Atum Permit2 digests.
    constructor(address _permit2, address _node, address _owner, address _keeper) Ownable(_owner) {
        if (_permit2 == address(0)) revert Errors.AtumModule_ZeroPermit2();
        if (_node == address(0)) revert Errors.AtumModule_ZeroNode();
        if (_keeper == address(0)) revert Errors.AtumModule_ZeroKeeper();

        permit2 = _permit2;
        node = _node;
        keeper = _keeper;
        permit2DomainSeparator = IPermit2(_permit2).DOMAIN_SEPARATOR();
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
        whenNotPaused
        returns (DataTypes.ExecutionResult memory result)
    {
        if (msg.sender != node) {
            revert Errors.AtumModule_NotNode(msg.sender, node);
        }

        (bool valid, string memory reason, DataTypes.AtumPaymentParams memory paymentParams) =
            _validatePaymentParams(token, amount, params);
        if (!valid) {
            return _failedResult(token, reason);
        }
        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        _pullExactToken(token, amount);

        if (IERC20(token).allowance(address(this), permit2) < type(uint256).max) {
            IERC20(token).forceApprove(permit2, type(uint256).max);
            emit Permit2ApprovalSet(token, permit2, type(uint256).max);
        }

        uint256 availableSourceAmount = IERC20(token).balanceOf(address(this));
        emit AtumIntentCreated(
            token,
            availableSourceAmount,
            paymentParams.destinationChain,
            paymentParams.destinationAccount,
            paymentParams.destinationAsset
        );

        return _successResult(0, token, "");
    }

    /// @inheritdoc IAtumModule
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert Errors.AtumModule_ZeroKeeper();

        address oldKeeper = keeper;
        keeper = newKeeper;

        emit KeeperSet(oldKeeper, newKeeper);
    }

    /// @inheritdoc IAtumModule
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IAtumModule
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IAtumModule
    function invalidateDigest(bytes32 digest) external onlyKeeper {
        _invalidateDigest(digest);
    }

    /// @inheritdoc IAtumModule
    function invalidateDigests(bytes32[] calldata digests) external onlyKeeper {
        uint256 length = digests.length;
        for (uint256 i; i < length; ++i) {
            _invalidateDigest(digests[i]);
        }
    }

    /// @inheritdoc IAtumModule
    function returnTokenBalance(address token) external onlyOwner returns (uint256 amountReturned) {
        amountReturned = _returnTokenBalance(token);
    }

    /// @inheritdoc IAtumModule
    function returnTokenBalances(address[] calldata tokens) external onlyOwner {
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            _returnTokenBalance(tokens[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            EIP-1271 SURFACE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Validates that `signature` was signed by the module keeper for `hash`.
    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        if (paused() || _invalidatedPermitDigests[hash]) {
            return EIP1271_FAILURE_VALUE;
        }
        if (keeper.isValidSignatureNow(hash, signature)) {
            return EIP1271_MAGIC_VALUE;
        }

        return EIP1271_FAILURE_VALUE;
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
        if (paused()) {
            return (false, "Module paused");
        }

        (isValid, reason,) = _validatePaymentParams(token, amount, params);
        if (!isValid) {
            return (false, reason);
        }
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance");
        }
        return (true, "");
    }

    /// @inheritdoc IAtumModule
    function isPermitDigestInvalidated(bytes32 digest) external view returns (bool) {
        return _invalidatedPermitDigests[digest];
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
        if (paused()) {
            return (0, token);
        }

        (bool valid,,) = _validatePaymentParams(token, amount, params);
        if (!valid) {
            return (0, token);
        }

        return (0, token);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "ATUM_PAYMENT";
    }

    /// @inheritdoc IAtumModule
    function encodeParams(DataTypes.AtumPaymentParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params.destinationChain, params.destinationAccount, params.destinationAsset);
    }

    /// @inheritdoc IAtumModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.AtumPaymentParams memory params) {
        (params.destinationChain, params.destinationAccount, params.destinationAsset) =
            abi.decode(encoded, (string, string, string));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _validatePaymentParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (bool valid, string memory reason, DataTypes.AtumPaymentParams memory paymentParams)
    {
        if (token == address(0)) {
            return (false, "Zero token", paymentParams);
        }
        if (amount == 0) {
            return (false, "Zero payment amount", paymentParams);
        }

        (valid, reason, paymentParams) = _decodeAndValidatePaymentParams(params);
        if (!valid) {
            return (false, reason, paymentParams);
        }

        return (true, "", paymentParams);
    }

    function _decodeAndValidatePaymentParams(bytes calldata params)
        private
        view
        returns (bool valid, string memory reason, DataTypes.AtumPaymentParams memory paymentParams)
    {
        if (params.length < 96) {
            return (false, "Invalid params encoding", paymentParams);
        }

        try this.decodeParams(params) returns (DataTypes.AtumPaymentParams memory decoded) {
            paymentParams = decoded;
        } catch {
            return (false, "Invalid params encoding", paymentParams);
        }

        if (bytes(paymentParams.destinationChain).length == 0) {
            return (false, "Empty destination chain", paymentParams);
        }
        if (bytes(paymentParams.destinationAccount).length == 0) {
            return (false, "Empty destination account", paymentParams);
        }
        if (bytes(paymentParams.destinationAsset).length == 0) {
            return (false, "Empty destination asset", paymentParams);
        }
        if (!_hasChainPrefix(paymentParams.destinationAsset, paymentParams.destinationChain)) {
            return (false, "Destination asset chain mismatch", paymentParams);
        }
        return (true, "", paymentParams);
    }

    function _pullExactToken(address token, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) {
            revert Errors.AtumModule_UnsupportedTokenReceivedAmount(amount, received);
        }
    }

    function _invalidateDigest(bytes32 digest) private {
        if (digest == bytes32(0)) revert Errors.AtumModule_ZeroDigest();

        _invalidatedPermitDigests[digest] = true;

        emit PermitDigestInvalidated(digest);
    }

    function _returnTokenBalance(address token) private returns (uint256 amountReturned) {
        if (token == address(0)) revert Errors.AtumModule_ZeroToken();

        amountReturned = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(node, amountReturned);

        emit TokenBalanceReturned(token, node, amountReturned);
    }

    function _hasChainPrefix(string memory asset, string memory chain) private pure returns (bool) {
        bytes memory assetBytes = bytes(asset);
        bytes memory chainBytes = bytes(chain);

        if (chainBytes.length == 0 || assetBytes.length <= chainBytes.length || assetBytes[chainBytes.length] != "/") {
            return false;
        }

        for (uint256 i; i < chainBytes.length; ++i) {
            if (assetBytes[i] != chainBytes[i]) {
                return false;
            }
        }

        return true;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert Errors.AtumModule_NotKeeper(msg.sender, keeper);
        _;
    }
}
