// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { IGPv2Settlement } from "../../../../../src/interfaces/IGPv2Settlement.sol";
import { IChainlinkAggregatorV3 } from "../../../../../src/interfaces/IChainlinkAggregatorV3.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CowSwapModuleForkBase
/// @notice Shared setup for all CowSwapModule fork tests against Ethereum mainnet.
/// @dev Forks mainnet to verify ABI compatibility, EIP-712 digest parity, and real token behavior.
abstract contract CowSwapModuleForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed paymentRails,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed paymentRails, address token, uint256 amount);
    event TokenConfigured(address indexed token, string actionType, address indexed actionModule);
    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    /*//////////////////////////////////////////////////////////////////////////
                                MAINNET CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant GPV2_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAILURE = 0xffffffff;

    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant DAI_USD_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    uint256 internal constant USDC_SELL_AMOUNT = 10_000e6; // 10,000 USDC
    uint256 internal constant DAI_SELL_AMOUNT = 10_000e18; // 10,000 DAI
    uint16 internal constant SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant MAX_STALENESS = 86_400; // 1 day — generous for fork testing
    uint32 internal constant DEFAULT_VALIDITY = 3600; // 1 hour
    bytes32 internal constant DEFAULT_APP_DATA = keccak256("receivables-paymentRails-v1");

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    PaymentRails internal paymentRails;
    address internal owner;
    address internal attacker;

    bytes32 internal realDomainSeparator;

    /*//////////////////////////////////////////////////////////////////////////
                                SHARED STATE
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal _orderId;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork("ethereum", 21_900_000);

        owner = makeAddr("owner");
        attacker = makeAddr("attacker");

        realDomainSeparator = IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator();

        vm.startPrank(owner);
        paymentRails = new PaymentRails(owner);
        module = new CowSwapModule(GPV2_SETTLEMENT, owner, address(paymentRails));
        vm.stopPrank();

        deal(USDC, address(paymentRails), USDC_SELL_AMOUNT * 10);
        deal(DAI, address(paymentRails), DAI_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                LIFECYCLE MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier givenPendingUsdcOrder() {
        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        _;
    }

    modifier givenCancelledUsdcOrder() {
        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        vm.prank(owner);
        module.cancelOrder(_orderId);
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(
        address targetToken,
        address sellTokenFeed,
        address buyTokenFeed,
        uint16 maxSlippageBps,
        uint32 validityDuration,
        bytes32 appData
    )
        internal
        view
        returns (bytes memory)
    {
        return module.encodeParams(
            DataTypes.CowSwapParams({
                targetToken: targetToken,
                maxSlippageBps: maxSlippageBps,
                sellTokenPriceFeed: sellTokenFeed,
                buyTokenPriceFeed: buyTokenFeed,
                maxStaleness: MAX_STALENESS,
                validityDuration: validityDuration,
                appData: appData
            })
        );
    }

    function _initiateOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        address sellTokenFeed,
        address buyTokenFeed,
        uint32 validityDuration,
        bytes32 appData
    )
        internal
        returns (bytes32 orderId)
    {
        bytes memory params =
            _buildParams(buyToken, sellTokenFeed, buyTokenFeed, SLIPPAGE_BPS, validityDuration, appData);

        vm.startPrank(address(paymentRails));
        IERC20(sellToken).approve(address(module), sellAmount);
        DataTypes.ExecutionResult memory result = module.execute(sellToken, sellAmount, params);
        vm.stopPrank();

        assertTrue(result.success, "Order initiation should succeed");
        return abi.decode(result.data, (bytes32));
    }

    function _initiateOrderViaPaymentRails(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        address sellTokenFeed,
        address buyTokenFeed,
        uint32 validityDuration,
        bytes32 appData
    )
        internal
        returns (bytes32 orderId)
    {
        bytes memory params =
            _buildParams(buyToken, sellTokenFeed, buyTokenFeed, SLIPPAGE_BPS, validityDuration, appData);

        vm.prank(owner);
        paymentRails.configureToken(sellToken, "COWSWAP", address(module), sellAmount, params, true);

        paymentRails.executeAction(sellToken, sellAmount);

        // Compute the expected orderId
        uint32 validTo = uint32(block.timestamp + validityDuration);
        uint256 oracleFloor = _computeOracleFloor(sellToken, sellAmount, sellTokenFeed, buyToken, buyTokenFeed);
        return _computeExpectedOrderId(
            sellToken, buyToken, address(paymentRails), sellAmount, oracleFloor, validTo, appData
        );
    }

    function _mockFilledAmount(bytes32 orderId, uint32 validTo, uint256 amount) internal {
        bytes memory orderUid = abi.encodePacked(orderId, address(module), validTo);
        vm.mockCall(
            GPV2_SETTLEMENT, abi.encodeWithSelector(IGPv2Settlement.filledAmount.selector, orderUid), abi.encode(amount)
        );
    }

    function _computeExpectedOrderId(
        address sellToken,
        address buyToken,
        address receiver,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 ORDER_TYPE_HASH = keccak256(
            "Order(" "address sellToken," "address buyToken," "address receiver," "uint256 sellAmount,"
            "uint256 buyAmount," "uint32 validTo," "bytes32 appData," "uint256 feeAmount," "string kind,"
            "bool partiallyFillable," "string sellTokenBalance," "string buyTokenBalance" ")"
        );
        bytes32 KIND_SELL = keccak256("sell");
        bytes32 BALANCE_ERC20 = keccak256("erc20");

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                sellToken,
                buyToken,
                receiver,
                sellAmount,
                buyAmount,
                validTo,
                appData,
                uint256(0),
                KIND_SELL,
                false,
                BALANCE_ERC20,
                BALANCE_ERC20
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", realDomainSeparator, structHash));
    }

    function _computeOracleFloor(
        address sellToken,
        uint256 sellAmount,
        address sellTokenFeed,
        address buyToken,
        address buyTokenFeed
    )
        internal
        view
        returns (uint256 floor)
    {
        (, int256 sellPrice,,,) = IChainlinkAggregatorV3(sellTokenFeed).latestRoundData();
        uint8 sellFeedDec = IChainlinkAggregatorV3(sellTokenFeed).decimals();
        (, int256 buyPrice,,,) = IChainlinkAggregatorV3(buyTokenFeed).latestRoundData();
        uint8 buyFeedDec = IChainlinkAggregatorV3(buyTokenFeed).decimals();

        uint8 sellTokenDec = IERC20Metadata(sellToken).decimals();
        uint8 buyTokenDec = IERC20Metadata(buyToken).decimals();

        uint256 sellExp = uint256(sellTokenDec) + uint256(sellFeedDec);
        uint256 buyExp = uint256(buyTokenDec) + uint256(buyFeedDec);

        uint256 expected;
        if (buyExp >= sellExp) {
            uint256 scale = 10 ** (buyExp - sellExp);
            expected = Math.mulDiv(sellAmount, uint256(sellPrice) * scale, uint256(buyPrice));
        } else {
            uint256 scale = 10 ** (sellExp - buyExp);
            expected = Math.mulDiv(sellAmount, uint256(sellPrice), uint256(buyPrice) * scale);
        }

        floor = Math.mulDiv(expected, 10_000 - uint256(SLIPPAGE_BPS), 10_000);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkConstructorTest is CowSwapModuleForkBase {
    function test_Constructor_SetsCowSettlement() external view {
        assertEq(module.cowSettlement(), GPV2_SETTLEMENT);
    }

    function test_Constructor_CachesRealDomainSeparator() external view {
        bytes32 expected = IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator();
        assertEq(module.cowDomainSeparator(), expected);
        assertTrue(expected != bytes32(0), "Domain separator should be non-zero");
    }

    function test_Constructor_SetsOwner() external view {
        assertEq(module.owner(), owner);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            EXECUTE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkExecuteTest is CowSwapModuleForkBase {
    function test_Execute_UsdcToWeth_TransfersSellTokenFromPaymentRailsToModule() external {
        uint256 nodeBefore = IERC20(USDC).balanceOf(address(paymentRails));
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeBefore - USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), moduleBefore + USDC_SELL_AMOUNT);
    }

    function test_Execute_UsdcToWeth_ApprovesGPv2SettlementForMaxUint256() external {
        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        uint256 allowance = IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER);
        assertEq(allowance, type(uint256).max);
    }

    function test_Execute_UsdcToWeth_StoresCorrectOrderMetadata() external {
        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.paymentRails, address(paymentRails));
        assertEq(meta.sellToken, USDC);
        assertEq(meta.buyToken, WETH);
        assertEq(meta.sellAmount, USDC_SELL_AMOUNT);
        assertEq(meta.validTo, uint32(block.timestamp + DEFAULT_VALIDITY));
        assertFalse(meta.cancelled);
    }

    function test_Execute_UsdcToWeth_EmitsOrderCreatedEvent() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 expectedOrderId = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, expectedValidTo, DEFAULT_APP_DATA
        );

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);

        vm.expectEmit(true, true, true, true, address(module));
        emit OrderCreated(
            expectedOrderId,
            address(paymentRails),
            USDC,
            WETH,
            USDC_SELL_AMOUNT,
            oracleFloor,
            expectedValidTo,
            DEFAULT_APP_DATA
        );

        module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_UsdcToWeth_ReturnsSuccessWithAmountOutZero() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(result.amountOut, 0);
        assertEq(result.outputToken, WETH);
        assertTrue(result.data.length > 0);
    }

    function test_Execute_UsdcToWeth_ReturnsEncodedOrderIdInData() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 expectedOrderId = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, expectedValidTo, DEFAULT_APP_DATA
        );

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        bytes32 returnedOrderId = abi.decode(result.data, (bytes32));
        assertEq(returnedOrderId, expectedOrderId);
    }

    function test_Execute_DaiToUsdc_TransfersDaiFromPaymentRailsToModule() external {
        uint256 nodeBefore = IERC20(DAI).balanceOf(address(paymentRails));

        _orderId = _initiateOrder(
            DAI, DAI_SELL_AMOUNT, USDC, DAI_USD_FEED, USDC_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        assertEq(IERC20(DAI).balanceOf(address(paymentRails)), nodeBefore - DAI_SELL_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);
    }

    function test_Execute_DaiToUsdc_StoresCorrectMetadata() external {
        _orderId = _initiateOrder(
            DAI, DAI_SELL_AMOUNT, USDC, DAI_USD_FEED, USDC_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.paymentRails, address(paymentRails));
        assertEq(meta.sellToken, DAI);
        assertEq(meta.buyToken, USDC);
        assertEq(meta.sellAmount, DAI_SELL_AMOUNT);
    }

    function test_Execute_ConcurrentOrders_CreateIndependentOrderIds() external {
        bytes32 orderId1 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        bytes32 orderId2 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("app-data-2")
        );

        assertTrue(orderId1 != orderId2, "Concurrent orders must have different orderIds");
    }

    function test_Execute_ConcurrentOrders_MaxApprovalSetOnce() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        uint256 allowanceAfterFirst = IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER);
        assertEq(allowanceAfterFirst, type(uint256).max);

        _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("app-data-2")
        );

        // Approval remains max (not doubled or re-set)
        uint256 allowanceAfterSecond = IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER);
        assertEq(allowanceAfterSecond, type(uint256).max);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            VALIDATE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkValidateTest is CowSwapModuleForkBase {
    /// @dev validate() calls _hasSufficientBalance(token, amount) which checks
    ///      msg.sender's balance. We prank as the paymentRails (which holds USDC from setUp).
    function test_Validate_ValidParams_ReturnsTrue() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertTrue(isValid);
        assertEq(bytes(reason).length, 0);
    }

    function test_Validate_ZeroSellAmount_ReturnsFalse() external view {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, 0, params);

        assertFalse(isValid);
        assertEq(reason, "Zero sell amount");
    }

    function test_Validate_ZeroTargetToken_ReturnsFalse() external view {
        bytes memory params =
            _buildParams(address(0), USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero target token");
    }

    function test_Validate_SameSellAndBuyToken_ReturnsFalse() external view {
        bytes memory params =
            _buildParams(USDC, USDC_USD_FEED, USDC_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Same sell and buy token");
    }

    function test_Validate_ZeroValidityDuration_ReturnsFalse() external view {
        bytes memory params = _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, 0, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero validity duration");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        IS VALID SIGNATURE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkIsValidSignatureTest is CowSwapModuleForkBase {
    function test_IsValidSignature_PendingOrder_ReturnsMagicValue() external givenPendingUsdcOrder {
        bytes memory signature = abi.encode(_orderId);
        bytes4 result = module.isValidSignature(_orderId, signature);
        assertEq(result, EIP1271_MAGIC);
    }

    function test_IsValidSignature_PendingOrder_MismatchedHash_ReturnsFailure() external givenPendingUsdcOrder {
        bytes32 wrongHash = keccak256("wrong-hash");
        bytes memory signature = abi.encode(_orderId);
        bytes4 result = module.isValidSignature(wrongHash, signature);
        assertEq(result, EIP1271_FAILURE);
    }

    function test_IsValidSignature_ExpiredOrder_ReturnsFailure() external givenPendingUsdcOrder {
        // Warp past the order's validTo
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);

        bytes memory signature = abi.encode(_orderId);
        bytes4 result = module.isValidSignature(_orderId, signature);
        assertEq(result, EIP1271_FAILURE);
    }

    function test_IsValidSignature_CancelledOrder_ReturnsFailure() external givenCancelledUsdcOrder {
        bytes memory signature = abi.encode(_orderId);
        bytes4 result = module.isValidSignature(_orderId, signature);
        assertEq(result, EIP1271_FAILURE);
    }

    function test_IsValidSignature_UnknownOrder_ReturnsFailure() external view {
        bytes32 unknownId = keccak256("unknown");
        bytes memory signature = abi.encode(unknownId);
        bytes4 result = module.isValidSignature(unknownId, signature);
        assertEq(result, EIP1271_FAILURE);
    }

    function test_IsValidSignature_WrongSignatureLength_ReturnsFailure() external givenPendingUsdcOrder {
        // 31 bytes — too short
        bytes memory badSig = new bytes(31);
        bytes4 result = module.isValidSignature(_orderId, badSig);
        assertEq(result, EIP1271_FAILURE);
    }

    function test_IsValidSignature_NeverReverts() external givenPendingUsdcOrder {
        // Empty signature
        bytes4 r1 = module.isValidSignature(_orderId, "");
        assertEq(r1, EIP1271_FAILURE);

        // 33-byte signature
        bytes memory longSig = new bytes(33);
        bytes4 r2 = module.isValidSignature(_orderId, longSig);
        assertEq(r2, EIP1271_FAILURE);

        // Zero hash
        bytes memory validSig = abi.encode(_orderId);
        bytes4 r3 = module.isValidSignature(bytes32(0), validSig);
        assertEq(r3, EIP1271_FAILURE);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            CANCEL ORDER TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkCancelOrderTest is CowSwapModuleForkBase {
    function test_CancelOrder_PendingOrder_ReturnsSellTokensToPaymentRails() external givenPendingUsdcOrder {
        uint256 nodeBefore = IERC20(USDC).balanceOf(address(paymentRails));
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        vm.prank(owner);
        module.cancelOrder(_orderId);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeBefore + USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), moduleBefore - USDC_SELL_AMOUNT);
    }

    function test_CancelOrder_PendingOrder_MarksOrderAsCancelled() external givenPendingUsdcOrder {
        vm.prank(owner);
        module.cancelOrder(_orderId);

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertTrue(meta.cancelled);
    }

    function test_CancelOrder_PendingOrder_EmitsOrderCancelledEvent() external givenPendingUsdcOrder {
        vm.expectEmit(true, true, true, true, address(module));
        emit OrderCancelled(_orderId, address(paymentRails), USDC, USDC_SELL_AMOUNT);

        vm.prank(owner);
        module.cancelOrder(_orderId);
    }

    function test_CancelOrder_ConcurrentOrders_OnlyReturnsCancelledOrderAmount() external {
        bytes32 orderId1 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        bytes32 orderId2 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("app-data-2")
        );

        uint256 moduleBalanceBefore = IERC20(USDC).balanceOf(address(module));
        assertEq(moduleBalanceBefore, USDC_SELL_AMOUNT * 2);

        // Cancel only the first order
        vm.prank(owner);
        module.cancelOrder(orderId1);

        // Module should still hold the second order's tokens
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);

        // Second order should remain unaffected
        DataTypes.CowOrderMetadata memory meta2 = module.getOrder(orderId2);
        assertFalse(meta2.cancelled);
        assertEq(meta2.sellAmount, USDC_SELL_AMOUNT);
    }

    function test_CancelOrder_ConcurrentOrders_DoesNotAffectOtherPendingOrder() external {
        bytes32 orderId1 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        bytes32 orderId2 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("app-data-2")
        );

        vm.prank(owner);
        module.cancelOrder(orderId1);

        // Second order's isValidSignature should still return magic
        bytes memory sig2 = abi.encode(orderId2);
        bytes4 result = module.isValidSignature(orderId2, sig2);
        assertEq(result, EIP1271_MAGIC);
    }

    function test_CancelOrder_RevertWhen_CallerIsNotOwner() external givenPendingUsdcOrder {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        module.cancelOrder(_orderId);
    }

    function test_CancelOrder_RevertWhen_OrderIsUnknown() external {
        bytes32 unknownId = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_UnknownOrder.selector, unknownId));
        vm.prank(owner);
        module.cancelOrder(unknownId);
    }

    function test_CancelOrder_RevertWhen_OrderAlreadyCancelled() external givenCancelledUsdcOrder {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyCancelled.selector, _orderId));
        vm.prank(owner);
        module.cancelOrder(_orderId);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ESTIMATE OUTPUT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkEstimateOutputTest is CowSwapModuleForkBase {
    function test_EstimateOutput_ReturnsOracleExpectedOutputAndTargetToken() external view {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, USDC_SELL_AMOUNT, params);

        assertGt(estimatedOutput, 0, "Estimated output should be non-zero");
        assertEq(outputToken, WETH);
    }

    function test_EstimateOutput_DaiToUsdc_ReturnsCorrectValues() external view {
        bytes memory params =
            _buildParams(USDC, DAI_USD_FEED, USDC_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(DAI, DAI_SELL_AMOUNT, params);

        assertGt(estimatedOutput, 0, "Estimated output should be non-zero");
        assertEq(outputToken, USDC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    ORDER DIGEST COMPATIBILITY TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkOrderDigestTest is CowSwapModuleForkBase {
    function test_OrderDigest_MatchesGPv2Eip712Digest() external {
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 expectedOrderId = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, expectedValidTo, DEFAULT_APP_DATA
        );

        bytes32 actualOrderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        assertEq(actualOrderId, expectedOrderId);
    }

    function test_OrderDigest_DifferentAppDataProducesDifferentIds() external {
        bytes32 orderId1 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        bytes32 orderId2 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("different-app")
        );

        assertTrue(orderId1 != orderId2);
    }

    function test_OrderDigest_DomainSeparatorIsNonZero() external view {
        assertTrue(module.cowDomainSeparator() != bytes32(0));
    }

    function test_OrderDigest_DomainSeparatorMatchesSettlement() external view {
        assertEq(module.cowDomainSeparator(), IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator());
    }
}

/*//////////////////////////////////////////////////////////////////////////
                COWSWAP COMPATIBILITY GROUND-TRUTH TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkCowSwapCompatibilityTest is CowSwapModuleForkBase {
    bytes32 internal constant COWSWAP_ORDER_TYPE_HASH = keccak256(
        "Order(" "address sellToken," "address buyToken," "address receiver," "uint256 sellAmount," "uint256 buyAmount,"
        "uint32 validTo," "bytes32 appData," "uint256 feeAmount," "string kind," "bool partiallyFillable,"
        "string sellTokenBalance," "string buyTokenBalance" ")"
    );

    function test_OrderTypeHash_MatchesCowSwapCanonical() external {
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);

        bytes32 canonicalDigest = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, validTo, DEFAULT_APP_DATA
        );

        bytes32 moduleDigest = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        assertEq(moduleDigest, canonicalDigest, "Module ORDER_TYPE_HASH must match CowSwap canonical");
    }

    function test_Execute_ApprovesVaultRelayer_NotSettlement() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        assertEq(
            IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER),
            type(uint256).max,
            "VaultRelayer must have max approval"
        );
        assertEq(
            IERC20(USDC).allowance(address(module), GPV2_SETTLEMENT), 0, "Settlement itself must NOT have approval"
        );
    }

    function test_VaultRelayer_CanPullSellToken() external givenPendingUsdcOrder {
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_SETTLEMENT, USDC_SELL_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), moduleBefore - USDC_SELL_AMOUNT);
    }

    function test_Settlement_CannotPullSellToken() external givenPendingUsdcOrder {
        vm.prank(GPV2_SETTLEMENT);
        vm.expectRevert();
        IERC20(USDC).transferFrom(address(module), GPV2_SETTLEMENT, USDC_SELL_AMOUNT);
    }

    function test_VaultRelayer_MatchesSettlementReturnValue() external view {
        assertEq(module.vaultRelayer(), GPV2_VAULT_RELAYER);
        assertEq(module.vaultRelayer(), IGPv2Settlement(GPV2_SETTLEMENT).vaultRelayer());
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        OWNERSHIP TRANSFER TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkOwnershipTransferTest is CowSwapModuleForkBase {
    function test_OwnershipTransfer_SetsPendingOwner() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        assertEq(module.pendingOwner(), newOwner);
        assertEq(module.owner(), owner);
    }

    function test_OwnershipTransfer_DoesNotChangeOwnerUntilAccepted() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        vm.prank(owner);
        module.cancelOrder(_orderId);

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertTrue(meta.cancelled);
    }

    function test_OwnershipTransfer_AcceptOwnership_UpdatesOwner() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        vm.prank(newOwner);
        module.acceptOwnership();

        assertEq(module.owner(), newOwner);
    }

    function test_OwnershipTransfer_NewOwnerCanCancelOrders() external {
        address newOwner = makeAddr("newOwner");

        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        vm.prank(newOwner);
        module.cancelOrder(_orderId);

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertTrue(meta.cancelled);
    }

    function test_OwnershipTransfer_OldOwnerCannotCancelAfterTransfer() external {
        address newOwner = makeAddr("newOwner");

        _orderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        module.cancelOrder(_orderId);
    }

    function test_OwnershipTransfer_RevertWhen_NonOwnerCallsTransferOwnership() external {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        vm.prank(attacker);
        module.transferOwnership(attacker);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    LIFECYCLE: HAPPY PATH TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkLifecycleHappyPathTest is CowSwapModuleForkBase {
    /// @dev Full happy-path lifecycle: configure → execute → solver fills → isValidSignature=FAILURE.
    function test_Lifecycle_HappyPath_UsdcToWeth_FullFlow() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        uint256 nodeUsdcBefore = IERC20(USDC).balanceOf(address(paymentRails));
        uint256 nodeWethBefore = IERC20(WETH).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "PaymentRails executeAction should succeed");

        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeUsdcBefore - USDC_SELL_AMOUNT);

        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 orderId = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, validTo, DEFAULT_APP_DATA
        );

        bytes4 sigResult = module.isValidSignature(orderId, abi.encode(orderId));
        assertEq(sigResult, EIP1271_MAGIC, "isValidSignature should return MAGIC for pending order");

        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);

        uint256 wethDelivered = 4e18;
        deal(WETH, address(paymentRails), nodeWethBefore + wethDelivered);

        assertEq(IERC20(WETH).balanceOf(address(paymentRails)), nodeWethBefore + wethDelivered);
        assertEq(IERC20(WETH).balanceOf(address(module)), 0);
        _mockFilledAmount(orderId, validTo, USDC_SELL_AMOUNT);

        sigResult = module.isValidSignature(orderId, abi.encode(orderId));
        assertEq(sigResult, EIP1271_FAILURE, "isValidSignature should return FAILURE after fill");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, orderId));
        vm.prank(owner);
        module.cancelOrder(orderId);
    }

    function test_Lifecycle_HappyPath_DaiToUsdc_FullFlow() external {
        bytes memory params =
            _buildParams(USDC, DAI_USD_FEED, USDC_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(DAI, "COWSWAP", address(module), DAI_SELL_AMOUNT, params, true);

        uint256 nodeDaiBefore = IERC20(DAI).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(DAI, DAI_SELL_AMOUNT);
        assertTrue(success);

        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(paymentRails)), nodeDaiBefore - DAI_SELL_AMOUNT);

        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(DAI, DAI_SELL_AMOUNT, DAI_USD_FEED, USDC, USDC_USD_FEED);
        bytes32 orderId = _computeExpectedOrderId(
            DAI, USDC, address(paymentRails), DAI_SELL_AMOUNT, oracleFloor, validTo, DEFAULT_APP_DATA
        );

        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_MAGIC);

        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(DAI).transferFrom(address(module), GPV2_VAULT_RELAYER, DAI_SELL_AMOUNT);

        _mockFilledAmount(orderId, validTo, DAI_SELL_AMOUNT);

        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_FAILURE);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    LIFECYCLE: CANCEL PATH TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkLifecycleCancelPathTest is CowSwapModuleForkBase {
    function test_Lifecycle_CancelPath_ReturnsSellTokensToPaymentRails() external {
        bytes32 orderId = _initiateOrderViaPaymentRails(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        uint256 nodeUsdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.prank(owner);
        module.cancelOrder(orderId);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeUsdcBefore + USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_FAILURE);
    }

    function test_Lifecycle_CancelPath_ReExecuteAfterCancel() external {
        // First order
        bytes32 orderId1 = _initiateOrderViaPaymentRails(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        // Cancel it
        vm.prank(owner);
        module.cancelOrder(orderId1);

        bytes32 newAppData = keccak256("retry-1");
        bytes memory newParams =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, newAppData);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, newParams, true);

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "Re-execution after cancel should succeed");

        // Compute new orderId
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 orderId2 = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, validTo, newAppData
        );

        assertTrue(orderId1 != orderId2, "Re-executed order should have different orderId");
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
        assertEq(module.isValidSignature(orderId2, abi.encode(orderId2)), EIP1271_MAGIC);
        assertEq(module.isValidSignature(orderId1, abi.encode(orderId1)), EIP1271_FAILURE);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    LIFECYCLE: EXPIRY PATH TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkLifecycleExpiryPathTest is CowSwapModuleForkBase {
    function test_Lifecycle_ExpiryPath_ExpiredOrderCanBeCancelled() external givenPendingUsdcOrder {
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);

        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_FAILURE);

        uint256 nodeUsdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.prank(owner);
        module.cancelOrder(_orderId);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeUsdcBefore + USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Lifecycle_ExpiryPath_TokensRemainInModuleUntilCancel() external givenPendingUsdcOrder {
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);

        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.sellAmount, USDC_SELL_AMOUNT);
        assertFalse(meta.cancelled);
    }

    function test_Lifecycle_ExpiryPath_FullRecoveryFlow() external {
        bytes32 orderId1 = _initiateOrderViaPaymentRails(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);
        assertEq(module.isValidSignature(orderId1, abi.encode(orderId1)), EIP1271_FAILURE);

        vm.prank(owner);
        module.cancelOrder(orderId1);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);

        bytes32 newAppData = keccak256("retry-after-expiry");
        bytes memory newParams =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, newAppData);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, newParams, true);

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "Re-execution after expiry+cancel should succeed");

        uint32 newValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 orderId2 = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, newValidTo, newAppData
        );
        assertEq(module.isValidSignature(orderId2, abi.encode(orderId2)), EIP1271_MAGIC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                LIFECYCLE: CONCURRENT MULTI-TOKEN TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkLifecycleConcurrentMultiTokenTest is CowSwapModuleForkBase {
    /// @dev Two different token pairs (USDC→WETH and DAI→USDC) active simultaneously.
    function test_Lifecycle_Concurrent_TwoTokenPairs_IndependentlyPending() external {
        // Configure USDC→WETH
        bytes memory usdcParams =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, usdcParams, true);

        // Configure DAI→USDC
        bytes memory daiParams =
            _buildParams(USDC, DAI_USD_FEED, USDC_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, keccak256("dai-order"));
        vm.prank(owner);
        paymentRails.configureToken(DAI, "COWSWAP", address(module), DAI_SELL_AMOUNT, daiParams, true);

        // Execute both
        assertTrue(paymentRails.executeAction(USDC, USDC_SELL_AMOUNT));
        assertTrue(paymentRails.executeAction(DAI, DAI_SELL_AMOUNT));

        // Both orders should be independently pending
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);

        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 wethFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 usdcOrderId = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, wethFloor, validTo, DEFAULT_APP_DATA
        );
        uint256 usdcFloor = _computeOracleFloor(DAI, DAI_SELL_AMOUNT, DAI_USD_FEED, USDC, USDC_USD_FEED);
        bytes32 daiOrderId = _computeExpectedOrderId(
            DAI, USDC, address(paymentRails), DAI_SELL_AMOUNT, usdcFloor, validTo, keccak256("dai-order")
        );

        assertEq(module.isValidSignature(usdcOrderId, abi.encode(usdcOrderId)), EIP1271_MAGIC);
        assertEq(module.isValidSignature(daiOrderId, abi.encode(daiOrderId)), EIP1271_MAGIC);
    }

    /// @dev Cancel one token pair, verify the other is unaffected.
    function test_Lifecycle_Concurrent_CancelOneDoesNotAffectOther() external {
        bytes32 usdcOrderId = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );
        bytes32 daiOrderId = _initiateOrder(
            DAI, DAI_SELL_AMOUNT, USDC, DAI_USD_FEED, USDC_USD_FEED, DEFAULT_VALIDITY, keccak256("dai-order")
        );

        // Cancel USDC order
        vm.prank(owner);
        module.cancelOrder(usdcOrderId);

        // USDC returned, DAI still held
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);

        // DAI order still valid
        assertEq(module.isValidSignature(daiOrderId, abi.encode(daiOrderId)), EIP1271_MAGIC);
    }

    /// @dev Three concurrent USDC orders with different appData.
    function test_Lifecycle_Concurrent_ThreeOrdersSameToken_UniqueIds() external {
        bytes32 orderId1 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("order-1")
        );
        bytes32 orderId2 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("order-2")
        );
        bytes32 orderId3 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("order-3")
        );

        // All unique
        assertTrue(orderId1 != orderId2);
        assertTrue(orderId2 != orderId3);
        assertTrue(orderId1 != orderId3);

        // Module holds 3x
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT * 3);
    }

    /// @dev Cancel middle order of three — verify boundary orders unaffected.
    function test_Lifecycle_Concurrent_CancelMiddleOrder_LeavesOthersUnaffected() external {
        bytes32 orderId1 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("order-1")
        );
        bytes32 orderId2 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("order-2")
        );
        bytes32 orderId3 = _initiateOrder(
            USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, keccak256("order-3")
        );

        // Cancel middle order
        vm.prank(owner);
        module.cancelOrder(orderId2);

        // Module holds 2x (order 1 + order 3)
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT * 2);

        // Orders 1 and 3 still valid
        assertEq(module.isValidSignature(orderId1, abi.encode(orderId1)), EIP1271_MAGIC);
        assertEq(module.isValidSignature(orderId3, abi.encode(orderId3)), EIP1271_MAGIC);

        // Order 2 is cancelled
        assertEq(module.isValidSignature(orderId2, abi.encode(orderId2)), EIP1271_FAILURE);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    END-TO-END NODE INTEGRATION TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkPaymentRailsIntegrationTest is CowSwapModuleForkBase {
    function test_PaymentRailsIntegration_ConfiguresModuleSuccessfully() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(USDC);
        assertEq(config.actionType, "COWSWAP");
        assertEq(config.actionModule, address(module));
        assertTrue(config.enabled);
        assertEq(config.minBalance, USDC_SELL_AMOUNT);
    }

    function test_PaymentRailsIntegration_ExecuteActionCreatesOrder() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        uint256 nodeBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);

        assertTrue(success);
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeBefore - USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
    }

    function test_PaymentRailsIntegration_ExecuteActionEmitsActionExecutedEvent() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        vm.expectEmit(true, true, true, true, address(paymentRails));
        emit ActionExecuted(USDC, "COWSWAP", USDC_SELL_AMOUNT, 0, WETH, address(this));

        paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);
    }

    function test_PaymentRailsIntegration_CancelAfterPaymentRailsExecution_ReturnsSellTokensToPaymentRails() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        uint256 paymentRailsBalanceBefore = IERC20(USDC).balanceOf(address(paymentRails));

        paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);

        // Find the orderId from module state — get it by computing the expected digest
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        bytes32 orderId = _computeExpectedOrderId(
            USDC, WETH, address(paymentRails), USDC_SELL_AMOUNT, oracleFloor, validTo, DEFAULT_APP_DATA
        );

        vm.prank(owner);
        module.cancelOrder(orderId);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), paymentRailsBalanceBefore);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    /// @dev Verifies PaymentRails.previewExecution works with the real CowSwapModule on fork.
    function test_PaymentRailsIntegration_PreviewExecution_ReturnsExpectedOutput() external {
        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        (uint256 estimatedOutput, address outputToken) = paymentRails.previewExecution(USDC);

        uint256 oracleFloor = _computeOracleFloor(USDC, USDC_SELL_AMOUNT, USDC_USD_FEED, WETH, ETH_USD_FEED);
        assertGt(estimatedOutput, 0, "estimatedOutput should be non-zero");
        assertGe(estimatedOutput, oracleFloor, "estimatedOutput should be >= oracle floor (before slippage)");
        assertEq(outputToken, WETH);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    END-TO-END SIMULATED SETTLEMENT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkSimulatedSettlementTest is CowSwapModuleForkBase {
    function test_SimulatedSettlement_SolverFillsOrder() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);

        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);

        _mockFilledAmount(_orderId, meta.validTo, USDC_SELL_AMOUNT);

        bytes memory sig = abi.encode(_orderId);
        bytes4 sigResult = module.isValidSignature(_orderId, sig);
        assertEq(sigResult, EIP1271_FAILURE);
    }

    function test_SimulatedSettlement_CancelRevertsOnFilledOrder() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        _mockFilledAmount(_orderId, meta.validTo, USDC_SELL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, _orderId));
        vm.prank(owner);
        module.cancelOrder(_orderId);
    }

    function test_SimulatedSettlement_ModuleHoldsZeroSellTokenAfterSolverPull() external givenPendingUsdcOrder {
        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_SimulatedSettlement_BuyTokenDeliveredDirectlyToPaymentRails() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, DAI, USDC_USD_FEED, DAI_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        uint256 nodeDaiBefore = IERC20(DAI).balanceOf(address(paymentRails));
        uint256 buyAmount = 10_000e18;

        deal(DAI, address(paymentRails), nodeDaiBefore + buyAmount);

        assertEq(IERC20(DAI).balanceOf(address(paymentRails)), nodeDaiBefore + buyAmount);
        assertEq(IERC20(DAI).balanceOf(address(module)), 0);
    }

    function test_SimulatedSettlement_PartialFill_IsValidSignatureStillMagic() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        _mockFilledAmount(_orderId, meta.validTo, USDC_SELL_AMOUNT / 2);

        assertEq(
            module.isValidSignature(_orderId, abi.encode(_orderId)),
            EIP1271_MAGIC,
            "Partially filled order should still be valid"
        );
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    EDGE CASE / SECURITY FORK TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleForkSecurityTest is CowSwapModuleForkBase {
    function test_Security_FilledAmountCallDoesNotRevert() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        bytes memory orderUid = abi.encodePacked(_orderId, address(module), meta.validTo);
        uint256 filled = IGPv2Settlement(GPV2_SETTLEMENT).filledAmount(orderUid);
        assertEq(filled, 0);
    }

    function test_Security_IsValidSignature_NeverRevertsOnRealSettlement() external givenPendingUsdcOrder {
        module.isValidSignature(bytes32(0), "");
        module.isValidSignature(bytes32(0), abi.encode(bytes32(0)));
        module.isValidSignature(_orderId, abi.encode(bytes32(uint256(1))));
        module.isValidSignature(_orderId, new bytes(64));
    }

    function test_Security_SettlementCanPullTokensViaApproval() external givenPendingUsdcOrder {
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        vm.prank(GPV2_VAULT_RELAYER);
        bool success = IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertTrue(success);
        assertEq(IERC20(USDC).balanceOf(address(module)), moduleBefore - USDC_SELL_AMOUNT);
    }

    function test_Security_CancelOrder_CapsReturnAtSellAmount() external givenPendingUsdcOrder {
        deal(USDC, address(module), USDC_SELL_AMOUNT * 3);

        uint256 nodeBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.prank(owner);
        module.cancelOrder(_orderId);

        uint256 returned = IERC20(USDC).balanceOf(address(paymentRails)) - nodeBefore;
        assertEq(returned, USDC_SELL_AMOUNT);
    }

    function test_Security_OrderIdCollision_ReturnsFailedResult() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, USDC_USD_FEED, ETH_USD_FEED, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Order ID collision: use unique appData");
    }

    function test_Security_DomainSeparatorIsCachedCorrectly() external view {
        bytes32 first = module.cowDomainSeparator();
        bytes32 second = module.cowDomainSeparator();
        bytes32 fromSettlement = IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator();

        assertEq(first, second);
        assertEq(first, fromSettlement);
    }

    function test_Security_AttackerCannotCancelOrder() external givenPendingUsdcOrder {
        address randomCaller = makeAddr("random");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomCaller));
        vm.prank(randomCaller);
        module.cancelOrder(_orderId);

        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_MAGIC);
    }

    /// @dev M-02 fix: only the authorized paymentRails can call execute(). Other callers get _failedResult.
    function test_Security_UnauthorizedPaymentRails_ExecuteBlocked() external {
        vm.prank(owner);
        PaymentRails paymentRails2 = new PaymentRails(owner);
        deal(USDC, address(paymentRails2), USDC_SELL_AMOUNT * 10);

        bytes memory params =
            _buildParams(WETH, USDC_USD_FEED, ETH_USD_FEED, SLIPPAGE_BPS, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        // Authorized paymentRails succeeds
        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result1 = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result1.success, "authorized paymentRails must succeed");

        // Unauthorized paymentRails is blocked
        vm.startPrank(address(paymentRails2));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result2 = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result2.success, "unauthorized paymentRails must fail");
        assertEq(result2.failureReason, "Caller is not authorized PaymentRails");
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT, "only authorized order tokens in module");
    }
}
