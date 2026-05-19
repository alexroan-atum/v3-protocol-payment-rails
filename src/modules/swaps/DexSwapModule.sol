// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IDexSwapModule } from "../../interfaces/IDexSwapModule.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { IChainlinkAggregatorV3 } from "../../interfaces/IChainlinkAggregatorV3.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
/// Oracle-enforced slippage protection: when Chainlink price feeds are configured in the static
/// params, the module computes a fair-price floor and rejects any execution where the caller's
/// `minAmountOut` is below `oracleExpected * (10000 - maxSlippageBps) / 10000`. This prevents
/// sandwich attacks by permissionless executors. When feeds are not configured, the module falls
/// back to the caller-supplied `minAmountOut` only.
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
        if (executionData.length == 0) return _failedResult(token, "Missing execution data");

        (
            bool valid,
            string memory reason,
            DataTypes.DexSwapParams memory cfg,
            DataTypes.DexSwapExecutionData memory exec
        ) = _validateSwapParams(token, amount, params, executionData);
        if (!valid) return _failedResult(token, reason);

        if (!_hasSufficientBalance(token, amount)) return _failedResult(token, "Insufficient balance");

        {
            (bool oracleValid, string memory oracleReason) = _checkOracleFloor(token, amount, cfg, exec.minAmountOut);
            if (!oracleValid) return _failedResult(token, oracleReason);
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
        DataTypes.DexSwapParams memory cfg;
        DataTypes.DexSwapExecutionData memory exec;

        (isValid, reason, cfg, exec) = _validateSwapParams(token, amount, params, executionData);
        if (!isValid) return (false, reason);

        if (executionData.length > 0) {
            (bool oracleValid, string memory oracleReason) =
                _checkOracleFloorValidate(token, amount, cfg, exec.minAmountOut);
            if (!oracleValid) return (false, oracleReason);
        }

        if (!_hasSufficientBalance(token, amount)) return (false, "Insufficient balance");

        return (true, "");
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
        DataTypes.DexSwapParams memory cfg = decodeParams(params);
        if (_hasOracleConfig(cfg)) {
            (bool oracleOk, uint256 expected) = _computeExpectedOutput(token, amount, cfg);
            if (oracleOk) return (expected, cfg.targetToken);
        }
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
        return abi.encode(
            params.targetToken,
            params.maxSlippageBps,
            params.sellTokenPriceFeed,
            params.buyTokenPriceFeed,
            params.maxStaleness
        );
    }

    /// @inheritdoc IDexSwapModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.DexSwapParams memory params) {
        (
            params.targetToken,
            params.maxSlippageBps,
            params.sellTokenPriceFeed,
            params.buyTokenPriceFeed,
            params.maxStaleness
        ) = abi.decode(encoded, (address, uint16, address, address, uint256));
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

    /// @dev Shared validation for `execute` and `validate`. Returns decoded params and execution
    ///      data on success so callers avoid redundant decoding.
    ///      Oracle floor enforcement is excluded: `execute` reverts (security-critical) while
    ///      `validate` returns a soft failure — callers apply the appropriate check after this.
    function _validateSwapParams(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        private
        view
        returns (
            bool valid,
            string memory reason,
            DataTypes.DexSwapParams memory cfg,
            DataTypes.DexSwapExecutionData memory exec
        )
    {
        if (params.length < 160) {
            return (false, "Invalid params encoding", cfg, exec);
        }

        cfg = decodeParams(params);

        if (cfg.targetToken == address(0)) return (false, "Zero target token", cfg, exec);
        if (cfg.targetToken == token) return (false, "Same input and output token", cfg, exec);
        if (amount == 0) return (false, "Zero sell amount", cfg, exec);

        if (executionData.length > 0) {
            bool execValid;
            string memory execReason;
            (execValid, execReason, exec) = _validateExecutionData(executionData);
            if (!execValid) return (false, execReason, cfg, exec);
        }

        return (true, "", cfg, exec);
    }

    /// @dev Validates execution data fields: router whitelist, minimum output, and deadline.
    function _validateExecutionData(bytes calldata executionData)
        private
        view
        returns (bool valid, string memory reason, DataTypes.DexSwapExecutionData memory exec)
    {
        exec = decodeExecutionData(executionData);
        if (!_allowedRouters[exec.router]) return (false, "Router not allowed", exec);
        if (exec.minAmountOut == 0) return (false, "Zero min amount out", exec);
        if (block.timestamp > exec.deadline) return (false, "Deadline expired", exec);
        return (true, "", exec);
    }

    /// @dev Returns true if oracle-based slippage enforcement is fully configured.
    function _hasOracleConfig(DataTypes.DexSwapParams memory cfg) private pure returns (bool) {
        return cfg.maxSlippageBps > 0 && cfg.sellTokenPriceFeed != address(0) && cfg.buyTokenPriceFeed != address(0);
    }

    /// @dev Validates minAmountOut against the oracle-derived floor. Reverts if below floor,
    /// returns soft failure if oracle is unavailable, and passes through if oracle is not configured.
    function _checkOracleFloor(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg,
        uint256 minAmountOut
    )
        private
        view
        returns (bool valid, string memory reason)
    {
        if (!_hasOracleConfig(cfg)) return (true, "");

        (bool oracleOk, uint256 oracleFloor) = _computeOracleFloor(token, amount, cfg);
        if (!oracleOk) return (false, "Oracle price unavailable");
        if (minAmountOut < oracleFloor) {
            revert Errors.DexSwapModule_SlippageExceedsOracleFloor(minAmountOut, oracleFloor);
        }
        return (true, "");
    }

    /// @dev Same as _checkOracleFloor but returns (false, reason) instead of reverting,
    /// suitable for the view-only validate() path.
    function _checkOracleFloorValidate(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg,
        uint256 minAmountOut
    )
        private
        view
        returns (bool valid, string memory reason)
    {
        if (!_hasOracleConfig(cfg)) return (true, "");

        (bool oracleOk, uint256 oracleFloor) = _computeOracleFloor(token, amount, cfg);
        if (!oracleOk) return (false, "Oracle price unavailable");
        if (minAmountOut < oracleFloor) return (false, "Slippage below oracle floor");
        return (true, "");
    }

    /// @dev Reads a Chainlink price feed and validates freshness, positivity, and magnitude.
    /// The uint128 upper bound prevents overflow in downstream mulDiv computations and is
    /// well above any realistic Chainlink price (aggregators use int192, and no asset price
    /// requires more than ~40 decimal digits).
    function _getOraclePrice(
        address feed,
        uint256 maxStaleness
    )
        private
        view
        returns (bool ok, uint256 price, uint8 feedDecimals)
    {
        try IChainlinkAggregatorV3(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (false, 0, 0);
            if (uint256(answer) > type(uint128).max) return (false, 0, 0);
            if (block.timestamp - updatedAt > maxStaleness) return (false, 0, 0);
            try IChainlinkAggregatorV3(feed).decimals() returns (uint8 dec) {
                return (true, uint256(answer), dec);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Computes the oracle-expected output using Chainlink prices and token decimals.
    /// Formula: expectedOutput = amount * sellPrice / buyPrice, adjusted for decimal differences.
    /// Uses Math.mulDiv for overflow-safe 512-bit intermediate arithmetic.
    function _computeExpectedOutput(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg
    )
        private
        view
        returns (bool ok, uint256 expectedOutput)
    {
        uint256 sellPrice;
        uint256 buyPrice;
        uint256 sellExp;
        uint256 buyExp;

        {
            uint8 sellFeedDec;
            uint8 buyFeedDec;
            bool oracleOk;
            (oracleOk, sellPrice, sellFeedDec) = _getOraclePrice(cfg.sellTokenPriceFeed, cfg.maxStaleness);
            if (!oracleOk) return (false, 0);
            (oracleOk, buyPrice, buyFeedDec) = _getOraclePrice(cfg.buyTokenPriceFeed, cfg.maxStaleness);
            if (!oracleOk) return (false, 0);

            (bool sellDecOk, uint8 sellTokenDec) = _getTokenDecimals(token);
            if (!sellDecOk) return (false, 0);
            (bool buyDecOk, uint8 buyTokenDec) = _getTokenDecimals(cfg.targetToken);
            if (!buyDecOk) return (false, 0);

            sellExp = uint256(sellTokenDec) + uint256(sellFeedDec);
            buyExp = uint256(buyTokenDec) + uint256(buyFeedDec);
        }

        if (buyExp >= sellExp) {
            uint256 scale = 10 ** (buyExp - sellExp);
            if (sellPrice > type(uint256).max / scale) return (false, 0);
            expectedOutput = Math.mulDiv(amount, sellPrice * scale, buyPrice);
        } else {
            uint256 scale = 10 ** (sellExp - buyExp);
            if (buyPrice > type(uint256).max / scale) return (false, 0);
            expectedOutput = Math.mulDiv(amount, sellPrice, buyPrice * scale);
        }

        return (true, expectedOutput);
    }

    /// @dev Applies maxSlippageBps to the oracle-expected output to get the minimum floor.
    function _computeOracleFloor(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg
    )
        private
        view
        returns (bool ok, uint256 floor)
    {
        if (cfg.maxSlippageBps > 10_000) return (false, 0);

        (bool oracleOk, uint256 expected) = _computeExpectedOutput(token, amount, cfg);
        if (!oracleOk) return (false, 0);

        floor = Math.mulDiv(expected, 10_000 - uint256(cfg.maxSlippageBps), 10_000);
        return (true, floor);
    }

    /// @dev Safe wrapper for IERC20Metadata.decimals().
    function _getTokenDecimals(address token) private view returns (bool ok, uint8 tokenDecimals) {
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return (true, dec);
        } catch {
            return (false, 0);
        }
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
