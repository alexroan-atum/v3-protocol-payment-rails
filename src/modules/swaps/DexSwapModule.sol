// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IDexSwapModule } from "../../interfaces/IDexSwapModule.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ISwapRouter } from "../../interfaces/ISwapRouter.sol";
import { IChainlinkAggregatorV3 } from "../../interfaces/IChainlinkAggregatorV3.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DexSwapModule
/// @author Credit Cooperative
/// @notice Oracle-only synchronous swap module — the permissionless executor controls nothing.
/// @dev See {IDexSwapModule} for the full architecture, security model, and execution flow.
///
/// All swap parameters are owner-configured in the static {DexSwapParams}. The executor calls
/// `PaymentRails.executeAction(token, amount)` — no `executionData`, no caller-controlled values.
///
/// The module computes `amountOutMinimum` on-chain from Chainlink oracle prices:
///   `oracleExpected * (10000 - maxSlippageBps) / 10000`
/// Oracle feeds are mandatory — there is no fallback to caller-supplied slippage.
///
/// The router is immutable (set once at construction). No owner key, no whitelist, no mutable
/// state. The module is fully stateless across transactions.
contract DexSwapModule is IDexSwapModule, ActionModuleBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDexSwapModule
    address public immutable override router;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _router Uniswap V3 SwapRouter address. Must be a contract. Immutable after deployment.
    constructor(address _router) {
        if (_router == address(0)) revert Errors.DexSwapModule_ZeroRouter();
        if (_router.code.length == 0) revert Errors.DexSwapModule_RouterNotContract(_router);
        router = _router;
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
        nonReentrant
        returns (DataTypes.ExecutionResult memory)
    {
        (bool valid, string memory reason, DataTypes.DexSwapParams memory cfg) = _validateParams(token, amount, params);
        if (!valid) return _failedResult(token, reason);

        if (!_hasSufficientBalance(token, amount)) return _failedResult(token, "Insufficient balance");

        (bool oracleOk, uint256 oracleFloor) = _computeOracleFloor(token, amount, cfg);
        if (!oracleOk) return _failedResult(token, "Oracle price unavailable");

        (bool ok, uint256 actualIn, uint256 amountOut) = _executeSwap(token, amount, cfg, oracleFloor);

        _returnLeftover(token, msg.sender);

        if (!ok) return _failedResult(token, "Router call failed");
        if (amountOut < oracleFloor) {
            revert Errors.DexSwapModule_InsufficientOutput(amountOut, oracleFloor);
        }

        emit SwapExecuted(msg.sender, token, cfg.targetToken, actualIn, amountOut);

        return _successResult(amountOut, cfg.targetToken, "");
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
        DataTypes.DexSwapParams memory cfg;
        (isValid, reason, cfg) = _validateParams(token, amount, params);
        if (!isValid) return (false, reason);

        (bool oracleOk,) = _computeOracleFloor(token, amount, cfg);
        if (!oracleOk) return (false, "Oracle price unavailable");

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
        (bool oracleOk, uint256 expected) = _computeExpectedOutput(token, amount, cfg);
        if (oracleOk) return (expected, cfg.targetToken);
        return (0, cfg.targetToken);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "SWAP";
    }

    /// @inheritdoc IDexSwapModule
    function encodeParams(DataTypes.DexSwapParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(
            params.targetToken,
            params.fee,
            params.maxSlippageBps,
            params.sellTokenPriceFeed,
            params.buyTokenPriceFeed,
            params.maxStaleness,
            params.swapDeadlineSeconds
        );
    }

    /// @inheritdoc IDexSwapModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.DexSwapParams memory params) {
        (
            params.targetToken,
            params.fee,
            params.maxSlippageBps,
            params.sellTokenPriceFeed,
            params.buyTokenPriceFeed,
            params.maxStaleness,
            params.swapDeadlineSeconds
        ) = abi.decode(encoded, (address, uint24, uint16, address, address, uint256, uint256));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Validates static params: encoding length, targetToken, amount, oracle config, deadline config.
    // solhint-disable-next-line code-complexity
    function _validateParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        pure
        returns (bool valid, string memory reason, DataTypes.DexSwapParams memory cfg)
    {
        if (params.length < 224) {
            return (false, "Invalid params encoding", cfg);
        }

        cfg = abi.decode(params, (DataTypes.DexSwapParams));

        if (cfg.targetToken == address(0)) return (false, "Zero target token", cfg);
        if (cfg.targetToken == token) return (false, "Same input and output token", cfg);
        if (amount == 0) return (false, "Zero sell amount", cfg);
        if (cfg.maxSlippageBps == 0 || cfg.maxSlippageBps > 10_000) return (false, "Invalid slippage bps", cfg);
        if (cfg.sellTokenPriceFeed == address(0)) return (false, "Missing sell token price feed", cfg);
        if (cfg.buyTokenPriceFeed == address(0)) return (false, "Missing buy token price feed", cfg);
        if (cfg.swapDeadlineSeconds == 0) return (false, "Zero swap deadline", cfg);

        return (true, "", cfg);
    }

    /// @dev Reads a Chainlink price feed and validates freshness, positivity, and magnitude.
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

    /// @dev Computes oracle-expected output: amount * sellPrice / buyPrice, decimal-adjusted.
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

    /// @dev Applies maxSlippageBps to oracle-expected output to get the minimum floor.
    function _computeOracleFloor(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg
    )
        private
        view
        returns (bool ok, uint256 floor)
    {
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

    /// @dev Pulls sellToken, builds exactInputSingle calldata with oracle floor as amountOutMinimum,
    /// calls the immutable router, measures output via balance diff, forwards to msg.sender.
    function _executeSwap(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg,
        uint256 oracleFloor
    )
        private
        returns (bool ok, uint256 actualIn, uint256 amountOut)
    {
        uint256 sellBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        actualIn = IERC20(token).balanceOf(address(this)) - sellBefore;

        IERC20(token).forceApprove(router, actualIn);

        uint256 buyTokenBefore = IERC20(cfg.targetToken).balanceOf(address(this));

        bytes memory swapCalldata = abi.encodeCall(
            ISwapRouter.exactInputSingle,
            (ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: cfg.targetToken,
                    fee: cfg.fee,
                    recipient: address(this),
                    deadline: block.timestamp + cfg.swapDeadlineSeconds,
                    amountIn: actualIn,
                    amountOutMinimum: oracleFloor,
                    sqrtPriceLimitX96: 0
                }))
        );

        (ok,) = router.call(swapCalldata);

        IERC20(token).forceApprove(router, 0);

        if (!ok) return (false, actualIn, 0);

        uint256 buyTokenAfter = IERC20(cfg.targetToken).balanceOf(address(this));
        if (buyTokenAfter < buyTokenBefore) return (false, actualIn, 0);
        amountOut = buyTokenAfter - buyTokenBefore;

        if (amountOut > 0) {
            IERC20(cfg.targetToken).safeTransfer(msg.sender, amountOut);
        }
    }

    /// @dev Transfers any sellToken remaining in the module back to the PaymentRails.
    function _returnLeftover(address token, address paymentRails) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(paymentRails, bal);
        }
    }
}
