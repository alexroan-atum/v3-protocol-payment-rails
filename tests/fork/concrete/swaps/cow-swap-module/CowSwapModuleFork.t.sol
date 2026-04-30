// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { IGPv2Settlement } from "../../../../../src/interfaces/IGPv2Settlement.sol";
import { Node } from "../../../../../src/core/Node.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CowSwapModuleForkBase
/// @notice Shared setup for all CowSwapModule fork tests against Ethereum mainnet.
/// @dev Forks Ethereum mainnet and interacts with the real GPv2Settlement contract.
///      Uses `deal` to provide real ERC20 balances without needing a whale account.
///
///      FORK vs UNIT vs INTEGRATION — scope boundaries:
///        - Unit tests:        MockCowSettlement, MockERC20, MockNode — logic in isolation.
///        - Integration tests: Real Node + real module, but mocked external deps.
///        - Fork tests (here): Real GPv2Settlement, real ERC20 tokens (USDC/DAI/WETH),
///                             real domain separator, real filledAmount storage reads.
///
///      What fork tests uniquely verify:
///        1. ABI compatibility — our IGPv2Settlement interface matches the deployed bytecode.
///        2. EIP-712 digest parity — orderId matches what the real settlement would compute.
///        3. Real token behavior — USDC (6 decimals), DAI (18 decimals), approval semantics.
///        4. Full lifecycle through Node — configure → execute → fill/cancel → verify balances.
abstract contract CowSwapModuleForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed node,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32 validTo,
        bytes32 appData
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed node, address token, uint256 amount);
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

    /// @dev Ethereum mainnet GPv2Settlement
    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    /// @dev Ethereum mainnet GPv2VaultRelayer (reads from GPV2_SETTLEMENT.vaultRelayer())
    address internal constant GPV2_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @dev Mainnet ERC20 token addresses
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @dev EIP-1271 constants
    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAILURE = 0xffffffff;

    /// @dev Default order parameters
    uint256 internal constant USDC_SELL_AMOUNT = 10_000e6; // 10,000 USDC
    uint256 internal constant DAI_SELL_AMOUNT = 10_000e18; // 10,000 DAI
    uint256 internal constant MIN_WETH_BUY = 3e18; // ~3 WETH floor
    uint256 internal constant MIN_USDC_BUY = 9_500e6; // 9,500 USDC floor
    uint32  internal constant DEFAULT_VALIDITY = 3_600; // 1 hour
    bytes32 internal constant DEFAULT_APP_DATA = keccak256("receivables-node-v1");

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    Node internal node;
    address internal owner;
    address internal attacker;

    /// @dev Cached real domain separator from GPv2Settlement
    bytes32 internal realDomainSeparator;

    /*//////////////////////////////////////////////////////////////////////////
                                SHARED STATE
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal _orderId;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // Fork Ethereum mainnet at a pinned block for deterministic, cache-friendly tests.
        // Block 21_900_000 (Feb 2025) — well after GPv2Settlement deployment.
        //
        // WHY PINNED: Tests use deal() for balances and vm.mockCall() for filledAmount — no
        // dependency on live chain state. The only real on-chain read is domainSeparator(), which
        // is immutable unless GPv2Settlement undergoes a full contract upgrade.
        //
        // WHEN TO BUMP: After a GPv2Settlement upgrade, or quarterly during active development.
        // Verify: cast call 0x9008D19f58AAbD9eD0D60971565AA8510560ab41 "domainSeparator()(bytes32)"
        vm.createSelectFork("ethereum", 21_900_000);

        owner = makeAddr("owner");
        attacker = makeAddr("attacker");

        // Cache the real domain separator before deploying
        realDomainSeparator = IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator();

        // Deploy module with real GPv2Settlement
        vm.startPrank(owner);
        module = new CowSwapModule(GPV2_SETTLEMENT, owner);
        node = new Node(owner);
        vm.stopPrank();

        // Fund the node with sell tokens via deal.
        // Note: only deal tokens that will be SOLD. buyToken (WETH) is delivered by the solver
        // to the node directly — no upfront balance needed.
        deal(USDC, address(node), USDC_SELL_AMOUNT * 10);
        deal(DAI, address(node), DAI_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                LIFECYCLE MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Creates a default PENDING USDC→WETH order via the module directly (node as caller).
    modifier givenPendingUsdcOrder() {
        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        _;
    }

    /// @dev Creates a PENDING order then cancels it.
    modifier givenCancelledUsdcOrder() {
        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        vm.prank(owner);
        module.cancelOrder(_orderId);
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(
        address targetToken,
        uint256 minBuyAmount,
        uint32 validityDuration,
        bytes32 appData
    ) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CowSwapParams({
                targetToken: targetToken,
                minBuyAmount: minBuyAmount,
                validityDuration: validityDuration,
                appData: appData
            })
        );
    }

    /// @dev Initiates an order by pranking as the node, approving the module, and calling execute.
    function _initiateOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 minBuyAmount,
        uint32 validityDuration,
        bytes32 appData
    ) internal returns (bytes32 orderId) {
        bytes memory params = _buildParams(buyToken, minBuyAmount, validityDuration, appData);

        vm.startPrank(address(node));
        IERC20(sellToken).approve(address(module), sellAmount);
        DataTypes.ExecutionResult memory result = module.execute(sellToken, sellAmount, params);
        vm.stopPrank();

        assertTrue(result.success, "Order initiation should succeed");
        return abi.decode(result.data, (bytes32));
    }

    /// @dev Initiates an order through the Node contract (configureToken + executeAction).
    function _initiateOrderViaNode(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 minBuyAmount,
        uint32 validityDuration,
        bytes32 appData
    ) internal returns (bytes32 orderId) {
        bytes memory params = _buildParams(buyToken, minBuyAmount, validityDuration, appData);

        vm.prank(owner);
        node.configureToken(sellToken, "COWSWAP", address(module), sellAmount, params, true);

        node.executeAction(sellToken, sellAmount);

        // Compute the expected orderId
        uint32 validTo = uint32(block.timestamp + validityDuration);
        return _computeExpectedOrderId(sellToken, buyToken, address(node), sellAmount, minBuyAmount, validTo, appData);
    }

    /// @dev Mocks the real GPv2Settlement.filledAmount(orderUid) to return `amount`.
    ///      Uses vm.mockCall to intercept the specific orderUid call — avoids needing to know
    ///      the internal storage layout of the real contract.
    /// @param orderId  The order digest (first 32 bytes of the UID).
    /// @param validTo  The order's validTo (last 4 bytes of the UID).
    /// @param amount   The filled amount to return.
    function _mockFilledAmount(bytes32 orderId, uint32 validTo, uint256 amount) internal {
        bytes memory orderUid = abi.encodePacked(orderId, address(module), validTo);
        vm.mockCall(
            GPV2_SETTLEMENT,
            abi.encodeWithSelector(IGPv2Settlement.filledAmount.selector, orderUid),
            abi.encode(amount)
        );
    }

    /// @dev Computes the GPv2Order EIP-712 digest — must match module's internal computation.
    function _computeExpectedOrderId(
        address sellToken,
        address buyToken,
        address receiver,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    ) internal view returns (bytes32) {
        bytes32 ORDER_TYPE_HASH = keccak256(
            "Order("
            "address sellToken,"
            "address buyToken,"
            "address receiver,"
            "uint256 sellAmount,"
            "uint256 buyAmount,"
            "uint32 validTo,"
            "bytes32 appData,"
            "uint256 feeAmount,"
            "string kind,"
            "bool partiallyFillable,"
            "string sellTokenBalance,"
            "string buyTokenBalance"
            ")"
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
}

/*//////////////////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_Constructor_Test is CowSwapModuleForkBase {
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

contract CowSwapModuleFork_Execute_Test is CowSwapModuleForkBase {
    /// @dev USDC → WETH order: verifies token transfer, approval, metadata, event, and result.
    function test_Execute_UsdcToWeth_TransfersSellTokenFromNodeToModule() external {
        uint256 nodeBefore = IERC20(USDC).balanceOf(address(node));
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        assertEq(IERC20(USDC).balanceOf(address(node)), nodeBefore - USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), moduleBefore + USDC_SELL_AMOUNT);
    }

    function test_Execute_UsdcToWeth_ApprovesGPv2SettlementForMaxUint256() external {
        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        uint256 allowance = IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER);
        assertEq(allowance, type(uint256).max);
    }

    function test_Execute_UsdcToWeth_StoresCorrectOrderMetadata() external {
        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.node, address(node));
        assertEq(meta.sellToken, USDC);
        assertEq(meta.buyToken, WETH);
        assertEq(meta.sellAmount, USDC_SELL_AMOUNT);
        assertEq(meta.validTo, uint32(block.timestamp + DEFAULT_VALIDITY));
        assertFalse(meta.cancelled);
    }

    function test_Execute_UsdcToWeth_EmitsOrderCreatedEvent() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 expectedOrderId = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, expectedValidTo, DEFAULT_APP_DATA
        );

        vm.startPrank(address(node));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);

        vm.expectEmit(true, true, true, true, address(module));
        emit OrderCreated(
            expectedOrderId, address(node), USDC, WETH, USDC_SELL_AMOUNT, MIN_WETH_BUY, expectedValidTo, DEFAULT_APP_DATA
        );

        module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_UsdcToWeth_ReturnsSuccessWithAmountOutZero() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.startPrank(address(node));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(result.amountOut, 0);
        assertEq(result.outputToken, WETH);
        assertTrue(result.data.length > 0);
    }

    function test_Execute_UsdcToWeth_ReturnsEncodedOrderIdInData() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 expectedOrderId = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, expectedValidTo, DEFAULT_APP_DATA
        );

        vm.startPrank(address(node));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        bytes32 returnedOrderId = abi.decode(result.data, (bytes32));
        assertEq(returnedOrderId, expectedOrderId);
    }

    /// @dev DAI → USDC order: ensures module works with 18-decimal tokens.
    function test_Execute_DaiToUsdc_TransfersDaiFromNodeToModule() external {
        uint256 nodeBefore = IERC20(DAI).balanceOf(address(node));

        _orderId = _initiateOrder(DAI, DAI_SELL_AMOUNT, USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        assertEq(IERC20(DAI).balanceOf(address(node)), nodeBefore - DAI_SELL_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);
    }

    function test_Execute_DaiToUsdc_StoresCorrectMetadata() external {
        _orderId = _initiateOrder(DAI, DAI_SELL_AMOUNT, USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.node, address(node));
        assertEq(meta.sellToken, DAI);
        assertEq(meta.buyToken, USDC);
        assertEq(meta.sellAmount, DAI_SELL_AMOUNT);
    }

    /// @dev Multiple concurrent orders with the same sell token.
    function test_Execute_ConcurrentOrders_CreateIndependentOrderIds() external {
        bytes32 orderId1 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        bytes32 orderId2 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("app-data-2"));

        assertTrue(orderId1 != orderId2, "Concurrent orders must have different orderIds");
    }

    function test_Execute_ConcurrentOrders_MaxApprovalSetOnce() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        uint256 allowanceAfterFirst = IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER);
        assertEq(allowanceAfterFirst, type(uint256).max);

        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("app-data-2"));

        // Approval remains max (not doubled or re-set)
        uint256 allowanceAfterSecond = IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER);
        assertEq(allowanceAfterSecond, type(uint256).max);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            VALIDATE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_Validate_Test is CowSwapModuleForkBase {
    /// @dev validate() calls _hasSufficientBalance(token, amount) which checks
    ///      msg.sender's balance. We prank as the node (which holds USDC from setUp).
    function test_Validate_ValidParams_ReturnsTrue() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(address(node));
        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertTrue(isValid);
        assertEq(bytes(reason).length, 0);
    }

    function test_Validate_ZeroSellAmount_ReturnsFalse() external view {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, 0, params);

        assertFalse(isValid);
        assertEq(reason, "Zero sell amount");
    }

    function test_Validate_ZeroTargetToken_ReturnsFalse() external view {
        bytes memory params = _buildParams(address(0), MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero target token");
    }

    function test_Validate_SameSellAndBuyToken_ReturnsFalse() external view {
        bytes memory params = _buildParams(USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Same sell and buy token");
    }

    function test_Validate_ZeroValidityDuration_ReturnsFalse() external view {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, 0, DEFAULT_APP_DATA);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_SELL_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero validity duration");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        IS VALID SIGNATURE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_IsValidSignature_Test is CowSwapModuleForkBase {
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

contract CowSwapModuleFork_CancelOrder_Test is CowSwapModuleForkBase {
    function test_CancelOrder_PendingOrder_ReturnsSellTokensToNode() external givenPendingUsdcOrder {
        uint256 nodeBefore = IERC20(USDC).balanceOf(address(node));
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        vm.prank(owner);
        module.cancelOrder(_orderId);

        assertEq(IERC20(USDC).balanceOf(address(node)), nodeBefore + USDC_SELL_AMOUNT);
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
        emit OrderCancelled(_orderId, address(node), USDC, USDC_SELL_AMOUNT);

        vm.prank(owner);
        module.cancelOrder(_orderId);
    }

    function test_CancelOrder_ConcurrentOrders_OnlyReturnsCancelledOrderAmount() external {
        bytes32 orderId1 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        bytes32 orderId2 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("app-data-2"));

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
        bytes32 orderId1 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        bytes32 orderId2 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("app-data-2"));

        vm.prank(owner);
        module.cancelOrder(orderId1);

        // Second order's isValidSignature should still return magic
        bytes memory sig2 = abi.encode(orderId2);
        bytes4 result = module.isValidSignature(orderId2, sig2);
        assertEq(result, EIP1271_MAGIC);
    }

    function test_CancelOrder_RevertWhen_CallerIsNotOwner() external givenPendingUsdcOrder {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_NotOwner.selector, attacker, owner));
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

contract CowSwapModuleFork_EstimateOutput_Test is CowSwapModuleForkBase {
    function test_EstimateOutput_ReturnsMinBuyAmountAndTargetToken() external view {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, USDC_SELL_AMOUNT, params);

        assertEq(estimatedOutput, MIN_WETH_BUY);
        assertEq(outputToken, WETH);
    }

    function test_EstimateOutput_DaiToUsdc_ReturnsCorrectValues() external view {
        bytes memory params = _buildParams(USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(DAI, DAI_SELL_AMOUNT, params);

        assertEq(estimatedOutput, MIN_USDC_BUY);
        assertEq(outputToken, USDC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    ORDER DIGEST COMPATIBILITY TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_OrderDigest_Test is CowSwapModuleForkBase {
    /// @dev Verifies the module's internal digest matches our independent EIP-712 computation
    ///      using the real GPv2Settlement domain separator.
    function test_OrderDigest_MatchesGPv2Eip712Digest() external {
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 expectedOrderId = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, expectedValidTo, DEFAULT_APP_DATA
        );

        bytes32 actualOrderId =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        assertEq(actualOrderId, expectedOrderId);
    }

    function test_OrderDigest_DifferentAppDataProducesDifferentIds() external {
        bytes32 orderId1 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        bytes32 orderId2 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("different-app"));

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

/// @dev These tests verify the module is compatible with CowSwap's actual protocol,
///      not just internally consistent. They would have caught both mainnet bugs:
///      1. ORDER_TYPE_HASH using bytes32 instead of string for kind/balance fields
///      2. Approving cowSettlement instead of vaultRelayer
contract CowSwapModuleFork_CowSwapCompatibility_Test is CowSwapModuleForkBase {
    /// @dev The canonical GPv2Order EIP-712 type hash from CowSwap's source.
    ///      See: https://github.com/cowprotocol/contracts/blob/main/src/contracts/libraries/GPv2Order.sol
    bytes32 internal constant COWSWAP_ORDER_TYPE_HASH = keccak256(
        "Order("
        "address sellToken,"
        "address buyToken,"
        "address receiver,"
        "uint256 sellAmount,"
        "uint256 buyAmount,"
        "uint32 validTo,"
        "bytes32 appData,"
        "uint256 feeAmount,"
        "string kind,"
        "bool partiallyFillable,"
        "string sellTokenBalance,"
        "string buyTokenBalance"
        ")"
    );

    function test_OrderTypeHash_MatchesCowSwapCanonical() external {
        // Compute a digest using the canonical type hash and compare with module output.
        // If the module uses a different type hash, the digests will differ.
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);

        bytes32 canonicalDigest = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, validTo, DEFAULT_APP_DATA
        );

        bytes32 moduleDigest =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        assertEq(moduleDigest, canonicalDigest, "Module ORDER_TYPE_HASH must match CowSwap canonical");
    }

    function test_Execute_ApprovesVaultRelayer_NotSettlement() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        assertEq(
            IERC20(USDC).allowance(address(module), GPV2_VAULT_RELAYER),
            type(uint256).max,
            "VaultRelayer must have max approval"
        );
        assertEq(
            IERC20(USDC).allowance(address(module), GPV2_SETTLEMENT),
            0,
            "Settlement itself must NOT have approval"
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

contract CowSwapModuleFork_OwnershipTransfer_Test is CowSwapModuleForkBase {
    /// @dev Verifies the full Ownable2Step flow: transferOwnership → acceptOwnership.
    ///      Critical for pre-deployment: ensures ownership handoff works on the real fork.
    function test_OwnershipTransfer_SetsPendingOwner() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        assertEq(module.pendingOwner(), newOwner);
        // Owner should NOT change until accepted
        assertEq(module.owner(), owner);
    }

    function test_OwnershipTransfer_DoesNotChangeOwnerUntilAccepted() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        // Original owner can still cancel orders
        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

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

        // Create order under old owner
        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        // Transfer ownership
        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        // New owner cancels the order
        vm.prank(newOwner);
        module.cancelOrder(_orderId);

        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertTrue(meta.cancelled);
    }

    function test_OwnershipTransfer_OldOwnerCannotCancelAfterTransfer() external {
        address newOwner = makeAddr("newOwner");

        _orderId = _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        // Old owner should be rejected
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_NotOwner.selector, owner, newOwner));
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

contract CowSwapModuleFork_Lifecycle_HappyPath_Test is CowSwapModuleForkBase {
    /// @dev Full happy-path lifecycle through Node:
    ///      configure → executeAction → isValidSignature=MAGIC → solver fills → isValidSignature=FAILURE
    ///      This is the EXACT flow that happens in production.
    function test_Lifecycle_HappyPath_UsdcToWeth_FullFlow() external {
        // --- Step 1: Node owner configures USDC with CowSwapModule ---
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        // --- Step 2: Anyone executes the action through Node ---
        uint256 nodeUsdcBefore = IERC20(USDC).balanceOf(address(node));
        uint256 nodeWethBefore = IERC20(WETH).balanceOf(address(node));

        bool success = node.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "Node executeAction should succeed");

        // Module now holds the sell tokens
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(node)), nodeUsdcBefore - USDC_SELL_AMOUNT);

        // --- Step 3: isValidSignature returns MAGIC (CowSwap solver can fill) ---
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, validTo, DEFAULT_APP_DATA
        );

        bytes4 sigResult = module.isValidSignature(orderId, abi.encode(orderId));
        assertEq(sigResult, EIP1271_MAGIC, "isValidSignature should return MAGIC for pending order");

        // --- Step 4: Simulate solver pulling sellToken via GPv2Settlement approval ---
        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module should hold zero USDC after solver pull");

        // --- Step 5: Simulate solver delivering buyToken directly to node ---
        uint256 wethDelivered = 4e18; // ~4 WETH (better than minimum)
        deal(WETH, address(node), nodeWethBefore + wethDelivered);

        assertEq(IERC20(WETH).balanceOf(address(node)), nodeWethBefore + wethDelivered);
        assertEq(IERC20(WETH).balanceOf(address(module)), 0, "Module should never hold buyToken");

        // --- Step 6: Mock filledAmount to report full fill ---
        _mockFilledAmount(orderId, validTo, USDC_SELL_AMOUNT);

        // --- Step 7: isValidSignature returns FAILURE (order is filled) ---
        sigResult = module.isValidSignature(orderId, abi.encode(orderId));
        assertEq(sigResult, EIP1271_FAILURE, "isValidSignature should return FAILURE after fill");

        // --- Step 8: Cancel should revert (order is filled) ---
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, orderId));
        vm.prank(owner);
        module.cancelOrder(orderId);
    }

    /// @dev Same lifecycle with DAI→USDC to verify 18-decimal → 6-decimal path.
    function test_Lifecycle_HappyPath_DaiToUsdc_FullFlow() external {
        bytes memory params = _buildParams(USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(DAI, "COWSWAP", address(module), DAI_SELL_AMOUNT, params, true);

        uint256 nodeDaiBefore = IERC20(DAI).balanceOf(address(node));

        bool success = node.executeAction(DAI, DAI_SELL_AMOUNT);
        assertTrue(success);

        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(node)), nodeDaiBefore - DAI_SELL_AMOUNT);

        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _computeExpectedOrderId(
            DAI, USDC, address(node), DAI_SELL_AMOUNT, MIN_USDC_BUY, validTo, DEFAULT_APP_DATA
        );

        // isValidSignature should be valid
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_MAGIC);

        // Simulate fill
        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(DAI).transferFrom(address(module), GPV2_VAULT_RELAYER, DAI_SELL_AMOUNT);

        _mockFilledAmount(orderId, validTo, DAI_SELL_AMOUNT);

        // Should be invalid now
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_FAILURE);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    LIFECYCLE: CANCEL PATH TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_Lifecycle_CancelPath_Test is CowSwapModuleForkBase {
    /// @dev Full cancel lifecycle: Node executes → owner cancels → tokens return to Node.
    function test_Lifecycle_CancelPath_ReturnsSellTokensToNode() external {
        bytes32 orderId = _initiateOrderViaNode(
            USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        uint256 nodeUsdcBefore = IERC20(USDC).balanceOf(address(node));

        vm.prank(owner);
        module.cancelOrder(orderId);

        // All sell tokens returned to node
        assertEq(IERC20(USDC).balanceOf(address(node)), nodeUsdcBefore + USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module should hold zero after cancel");

        // isValidSignature should return failure
        assertEq(module.isValidSignature(orderId, abi.encode(orderId)), EIP1271_FAILURE);
    }

    /// @dev Cancel then re-execute with new appData: verifies clean state recovery.
    function test_Lifecycle_CancelPath_ReExecuteAfterCancel() external {
        // First order
        bytes32 orderId1 = _initiateOrderViaNode(
            USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        // Cancel it
        vm.prank(owner);
        module.cancelOrder(orderId1);

        // Reconfigure with different appData and re-execute
        bytes32 newAppData = keccak256("retry-1");
        bytes memory newParams = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, newAppData);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, newParams, true);

        bool success = node.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "Re-execution after cancel should succeed");

        // Compute new orderId
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId2 = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, validTo, newAppData
        );

        // New orderId should differ
        assertTrue(orderId1 != orderId2, "Re-executed order should have different orderId");

        // Module holds exactly the new sell amount
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);

        // New order should be valid
        assertEq(module.isValidSignature(orderId2, abi.encode(orderId2)), EIP1271_MAGIC);

        // Old order remains cancelled
        assertEq(module.isValidSignature(orderId1, abi.encode(orderId1)), EIP1271_FAILURE);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    LIFECYCLE: EXPIRY PATH TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_Lifecycle_ExpiryPath_Test is CowSwapModuleForkBase {
    /// @dev Order expires without being filled: isValidSignature=FAILURE, owner can still cancel.
    function test_Lifecycle_ExpiryPath_ExpiredOrderCanBeCancelled() external givenPendingUsdcOrder {
        // Warp past expiry
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);

        // isValidSignature should return failure (expired)
        assertEq(
            module.isValidSignature(_orderId, abi.encode(_orderId)),
            EIP1271_FAILURE,
            "Expired order should return FAILURE from isValidSignature"
        );

        uint256 nodeUsdcBefore = IERC20(USDC).balanceOf(address(node));

        // Owner should still be able to cancel and recover sell tokens
        vm.prank(owner);
        module.cancelOrder(_orderId);

        assertEq(IERC20(USDC).balanceOf(address(node)), nodeUsdcBefore + USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    /// @dev Order expires, owner does NOT cancel: tokens remain in module until manual cancel.
    function test_Lifecycle_ExpiryPath_TokensRemainInModuleUntilCancel() external givenPendingUsdcOrder {
        // Warp past expiry
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);

        // Tokens are still in the module — they don't auto-return
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);

        // Order metadata still exists (not auto-cleaned)
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        assertEq(meta.sellAmount, USDC_SELL_AMOUNT);
        assertFalse(meta.cancelled, "Expired order is NOT auto-cancelled");
    }

    /// @dev Validates the full expiry → cancel → re-execute path.
    function test_Lifecycle_ExpiryPath_FullRecoveryFlow() external {
        // Step 1: Create order via Node
        bytes32 orderId1 = _initiateOrderViaNode(
            USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA
        );

        // Step 2: Time passes, order expires
        vm.warp(block.timestamp + DEFAULT_VALIDITY + 1);
        assertEq(module.isValidSignature(orderId1, abi.encode(orderId1)), EIP1271_FAILURE);

        // Step 3: Owner cancels expired order, tokens return
        vm.prank(owner);
        module.cancelOrder(orderId1);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);

        // Step 4: Re-execute with new appData
        bytes32 newAppData = keccak256("retry-after-expiry");
        bytes memory newParams = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, newAppData);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, newParams, true);

        bool success = node.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "Re-execution after expiry+cancel should succeed");

        // New order is valid
        uint32 newValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId2 = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, newValidTo, newAppData
        );
        assertEq(module.isValidSignature(orderId2, abi.encode(orderId2)), EIP1271_MAGIC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                LIFECYCLE: CONCURRENT MULTI-TOKEN TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_Lifecycle_ConcurrentMultiToken_Test is CowSwapModuleForkBase {
    /// @dev Two different token pairs (USDC→WETH and DAI→USDC) active simultaneously.
    function test_Lifecycle_Concurrent_TwoTokenPairs_IndependentlyPending() external {
        // Configure USDC→WETH
        bytes memory usdcParams = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, usdcParams, true);

        // Configure DAI→USDC
        bytes memory daiParams = _buildParams(USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, keccak256("dai-order"));
        vm.prank(owner);
        node.configureToken(DAI, "COWSWAP", address(module), DAI_SELL_AMOUNT, daiParams, true);

        // Execute both
        assertTrue(node.executeAction(USDC, USDC_SELL_AMOUNT));
        assertTrue(node.executeAction(DAI, DAI_SELL_AMOUNT));

        // Both orders should be independently pending
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(module)), DAI_SELL_AMOUNT);

        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 usdcOrderId = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, validTo, DEFAULT_APP_DATA
        );
        bytes32 daiOrderId = _computeExpectedOrderId(
            DAI, USDC, address(node), DAI_SELL_AMOUNT, MIN_USDC_BUY, validTo, keccak256("dai-order")
        );

        assertEq(module.isValidSignature(usdcOrderId, abi.encode(usdcOrderId)), EIP1271_MAGIC);
        assertEq(module.isValidSignature(daiOrderId, abi.encode(daiOrderId)), EIP1271_MAGIC);
    }

    /// @dev Cancel one token pair, verify the other is unaffected.
    function test_Lifecycle_Concurrent_CancelOneDoesNotAffectOther() external {
        bytes32 usdcOrderId =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
        bytes32 daiOrderId =
            _initiateOrder(DAI, DAI_SELL_AMOUNT, USDC, MIN_USDC_BUY, DEFAULT_VALIDITY, keccak256("dai-order"));

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
        bytes32 orderId1 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("order-1"));
        bytes32 orderId2 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("order-2"));
        bytes32 orderId3 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("order-3"));

        // All unique
        assertTrue(orderId1 != orderId2);
        assertTrue(orderId2 != orderId3);
        assertTrue(orderId1 != orderId3);

        // Module holds 3x
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT * 3);
    }

    /// @dev Cancel middle order of three — verify boundary orders unaffected.
    function test_Lifecycle_Concurrent_CancelMiddleOrder_LeavesOthersUnaffected() external {
        bytes32 orderId1 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("order-1"));
        bytes32 orderId2 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("order-2"));
        bytes32 orderId3 =
            _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, keccak256("order-3"));

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

contract CowSwapModuleFork_NodeIntegration_Test is CowSwapModuleForkBase {
    function test_NodeIntegration_ConfiguresModuleSuccessfully() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        DataTypes.TokenConfig memory config = node.getTokenConfig(USDC);
        assertEq(config.actionType, "COWSWAP");
        assertEq(config.actionModule, address(module));
        assertTrue(config.enabled);
        assertEq(config.minBalance, USDC_SELL_AMOUNT);
    }

    function test_NodeIntegration_ExecuteActionCreatesOrder() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        uint256 nodeBefore = IERC20(USDC).balanceOf(address(node));

        bool success = node.executeAction(USDC, USDC_SELL_AMOUNT);

        assertTrue(success);
        assertEq(IERC20(USDC).balanceOf(address(node)), nodeBefore - USDC_SELL_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), USDC_SELL_AMOUNT);
    }

    function test_NodeIntegration_ExecuteActionEmitsActionExecutedEvent() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        vm.expectEmit(true, true, true, true, address(node));
        emit ActionExecuted(USDC, "COWSWAP", USDC_SELL_AMOUNT, 0, WETH, address(this));

        node.executeAction(USDC, USDC_SELL_AMOUNT);
    }

    function test_NodeIntegration_CancelAfterNodeExecution_ReturnsSellTokensToNode() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        uint256 nodeBalanceBefore = IERC20(USDC).balanceOf(address(node));

        node.executeAction(USDC, USDC_SELL_AMOUNT);

        // Find the orderId from module state — get it by computing the expected digest
        uint32 validTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _computeExpectedOrderId(
            USDC, WETH, address(node), USDC_SELL_AMOUNT, MIN_WETH_BUY, validTo, DEFAULT_APP_DATA
        );

        vm.prank(owner);
        module.cancelOrder(orderId);

        assertEq(IERC20(USDC).balanceOf(address(node)), nodeBalanceBefore);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    /// @dev Verifies Node.previewExecution works with the real CowSwapModule on fork.
    function test_NodeIntegration_PreviewExecution_ReturnsMinBuyAmount() external {
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.prank(owner);
        node.configureToken(USDC, "COWSWAP", address(module), USDC_SELL_AMOUNT, params, true);

        (uint256 estimatedOutput, address outputToken) = node.previewExecution(USDC);

        assertEq(estimatedOutput, MIN_WETH_BUY);
        assertEq(outputToken, WETH);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    END-TO-END SIMULATED SETTLEMENT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CowSwapModuleFork_SimulatedSettlement_Test is CowSwapModuleForkBase {
    /// @dev Simulates a CowSwap solver filling an order:
    ///      1. Solver (via GPv2Settlement) pulls sellToken from module
    ///      2. filledAmount is mocked to report the fill
    ///      3. isValidSignature returns failure for a filled order
    function test_SimulatedSettlement_SolverFillsOrder() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);

        // Step 1: Simulate solver pulling sellToken from module via GPv2Settlement's max approval.
        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);

        // Step 2: Mock filledAmount to report the order as fully filled.
        _mockFilledAmount(_orderId, meta.validTo, USDC_SELL_AMOUNT);

        // isValidSignature should now return failure (order fully filled)
        bytes memory sig = abi.encode(_orderId);
        bytes4 sigResult = module.isValidSignature(_orderId, sig);
        assertEq(sigResult, EIP1271_FAILURE);
    }

    function test_SimulatedSettlement_CancelRevertsOnFilledOrder() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);

        // Mock filledAmount to report order as filled
        _mockFilledAmount(_orderId, meta.validTo, USDC_SELL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_OrderAlreadyFilled.selector, _orderId));
        vm.prank(owner);
        module.cancelOrder(_orderId);
    }

    function test_SimulatedSettlement_ModuleHoldsZeroSellTokenAfterSolverPull() external givenPendingUsdcOrder {
        // Solver pulls via settlement
        vm.prank(GPV2_VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    /// @dev Verifies the direct-receiver design: buyToken goes to node, never to module.
    ///      Uses DAI as buyToken stand-in (since solver delivers buyToken to node address directly).
    function test_SimulatedSettlement_BuyTokenDeliveredDirectlyToNode() external {
        // Create a USDC→DAI order so we can deal DAI (which works on this RPC)
        _initiateOrder(USDC, USDC_SELL_AMOUNT, DAI, 9_500e18, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        uint256 nodeDaiBefore = IERC20(DAI).balanceOf(address(node));
        uint256 buyAmount = 10_000e18;

        // Simulate: solver sends buyToken (DAI) directly to node (receiver=node in GPv2Order)
        deal(DAI, address(node), nodeDaiBefore + buyAmount);

        assertEq(IERC20(DAI).balanceOf(address(node)), nodeDaiBefore + buyAmount);
        // Module never holds buyToken
        assertEq(IERC20(DAI).balanceOf(address(module)), 0);
    }

    /// @dev Simulates a partial fill scenario: filledAmount < sellAmount.
    ///      isValidSignature should still return MAGIC (order not fully filled yet).
    function test_SimulatedSettlement_PartialFill_IsValidSignatureStillMagic() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);

        // Simulate partial fill (50% of sellAmount)
        _mockFilledAmount(_orderId, meta.validTo, USDC_SELL_AMOUNT / 2);

        // isValidSignature should still return MAGIC — not fully filled
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

contract CowSwapModuleFork_Security_Test is CowSwapModuleForkBase {
    /// @dev Verifies that the module can interact with the real GPv2Settlement's filledAmount
    ///      without reverting — important because the real contract's ABI must match.
    function test_Security_FilledAmountCallDoesNotRevert() external givenPendingUsdcOrder {
        DataTypes.CowOrderMetadata memory meta = module.getOrder(_orderId);
        bytes memory orderUid = abi.encodePacked(_orderId, address(module), meta.validTo);
        uint256 filled = IGPv2Settlement(GPV2_SETTLEMENT).filledAmount(orderUid);
        assertEq(filled, 0); // Fresh order — nothing filled
    }

    /// @dev Verifies isValidSignature never reverts on the real settlement, even with garbage input.
    function test_Security_IsValidSignature_NeverRevertsOnRealSettlement() external givenPendingUsdcOrder {
        // All these must return a value (MAGIC or FAILURE) — never revert.
        module.isValidSignature(bytes32(0), "");
        module.isValidSignature(bytes32(0), abi.encode(bytes32(0)));
        module.isValidSignature(_orderId, abi.encode(bytes32(uint256(1))));
        module.isValidSignature(_orderId, new bytes(64));
    }

    /// @dev Verifies that GPv2VaultRelayer can actually pull tokens via the max approval.
    function test_Security_SettlementCanPullTokensViaApproval() external givenPendingUsdcOrder {
        uint256 moduleBefore = IERC20(USDC).balanceOf(address(module));

        // GPv2VaultRelayer pulls tokens — this tests the real transferFrom path
        vm.prank(GPV2_VAULT_RELAYER);
        bool success = IERC20(USDC).transferFrom(address(module), GPV2_VAULT_RELAYER, USDC_SELL_AMOUNT);

        assertTrue(success);
        assertEq(IERC20(USDC).balanceOf(address(module)), moduleBefore - USDC_SELL_AMOUNT);
    }

    /// @dev cancelOrder must cap return at meta.sellAmount, even if module holds more.
    function test_Security_CancelOrder_CapsReturnAtSellAmount() external givenPendingUsdcOrder {
        // Give module extra USDC beyond what this order deposited
        deal(USDC, address(module), USDC_SELL_AMOUNT * 3);

        uint256 nodeBefore = IERC20(USDC).balanceOf(address(node));

        vm.prank(owner);
        module.cancelOrder(_orderId);

        // Should return exactly USDC_SELL_AMOUNT, not the full 3x balance
        uint256 returned = IERC20(USDC).balanceOf(address(node)) - nodeBefore;
        assertEq(returned, USDC_SELL_AMOUNT);
    }

    /// @dev Duplicate order with same params in same block must fail.
    function test_Security_OrderIdCollision_ReturnsFailedResult() external {
        _initiateOrder(USDC, USDC_SELL_AMOUNT, WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.startPrank(address(node));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Order ID collision: use unique appData");
    }

    /// @dev Verifies module deployed against real settlement has a consistent domain separator
    ///      across multiple calls (cached correctly).
    function test_Security_DomainSeparatorIsCachedCorrectly() external view {
        bytes32 first = module.cowDomainSeparator();
        bytes32 second = module.cowDomainSeparator();
        bytes32 fromSettlement = IGPv2Settlement(GPV2_SETTLEMENT).domainSeparator();

        assertEq(first, second);
        assertEq(first, fromSettlement);
    }

    /// @dev Verifies that a non-owner cannot cancel an order even on a real fork.
    function test_Security_AttackerCannotCancelOrder() external givenPendingUsdcOrder {
        address randomCaller = makeAddr("random");

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModule_NotOwner.selector, randomCaller, owner));
        vm.prank(randomCaller);
        module.cancelOrder(_orderId);

        // Order should still be valid
        assertEq(module.isValidSignature(_orderId, abi.encode(_orderId)), EIP1271_MAGIC);
    }

    /// @dev Verifies that an order created by one node cannot be confused with another node's order.
    ///      Different callers (nodes) produce different orderIds even with identical params,
    ///      because receiver=msg.sender is baked into the EIP-712 digest.
    function test_Security_DifferentNodes_ProduceDifferentOrderIds() external {
        // Deploy a second Node
        vm.prank(owner);
        Node node2 = new Node(owner);
        deal(USDC, address(node2), USDC_SELL_AMOUNT * 10);

        // Create orders from both nodes with identical params
        bytes memory params = _buildParams(WETH, MIN_WETH_BUY, DEFAULT_VALIDITY, DEFAULT_APP_DATA);

        vm.startPrank(address(node));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result1 = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        vm.startPrank(address(node2));
        IERC20(USDC).approve(address(module), USDC_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result2 = module.execute(USDC, USDC_SELL_AMOUNT, params);
        vm.stopPrank();

        bytes32 orderId1 = abi.decode(result1.data, (bytes32));
        bytes32 orderId2 = abi.decode(result2.data, (bytes32));

        // OrderIds differ because receiver (node address) differs
        assertTrue(orderId1 != orderId2, "Orders from different nodes must have different orderIds");

        // Both should be independently valid
        assertEq(module.isValidSignature(orderId1, abi.encode(orderId1)), EIP1271_MAGIC);
        assertEq(module.isValidSignature(orderId2, abi.encode(orderId2)), EIP1271_MAGIC);
    }
}
