// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared setup for CCTPBridgeModule fork tests against Ethereum mainnet.
abstract contract CCTPBridgeModuleForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event BridgeInitiated(
        address indexed paymentRails,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes hookData
    );

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

    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint32 internal constant DOMAIN_ARBITRUM = 3;
    uint32 internal constant DOMAIN_BASE = 6;
    uint256 internal constant BRIDGE_AMOUNT = 10_000e6;
    uint256 internal constant SMALL_BRIDGE_AMOUNT = 100e6;
    bytes32 internal constant DEFAULT_MINT_RECIPIENT =
        bytes32(uint256(uint160(0xBEeFbeefbEefbeEFbeEfbEEfBEeFbeEfBeEfBeef)));
    bytes32 internal constant DEFAULT_DESTINATION_CALLER = bytes32(0);
    uint16 internal constant DEFAULT_MAX_FEE_BPS = 0;
    uint32 internal constant FINALITY_STANDARD = 2000;
    uint32 internal constant FINALITY_FAST = 1000;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CCTPBridgeModule internal module;
    PaymentRails internal paymentRails;
    address internal owner;
    address internal attacker;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork("ethereum", 22_300_000);

        owner = makeAddr("owner");
        attacker = makeAddr("attacker");

        module = new CCTPBridgeModule(TOKEN_MESSENGER_V2, USDC);

        vm.prank(owner);
        paymentRails = new PaymentRails(owner);

        deal(USDC, address(paymentRails), BRIDGE_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(uint32 domain) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: domain,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: DEFAULT_MAX_FEE_BPS,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );
    }

    function _buildParamsWithHook(uint32 domain) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: domain,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: DEFAULT_MAX_FEE_BPS,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: hex"deadbeef"
            })
        );
    }

    function _buildParamsWithFee(uint32 domain, uint16 maxFeeBps) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: domain,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: maxFeeBps,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );
    }

    function _buildParamsWithFinality(uint32 domain, uint32 finality) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: domain,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: DEFAULT_MAX_FEE_BPS,
                minFinalityThreshold: finality,
                hookData: bytes("")
            })
        );
    }

    function _executeBridge(uint256 amount) internal returns (DataTypes.ExecutionResult memory) {
        return _executeBridgeToDomain(amount, DOMAIN_BASE);
    }

    function _executeBridgeToDomain(uint256 amount, uint32 domain) internal returns (DataTypes.ExecutionResult memory) {
        bytes memory params = _buildParams(domain);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), amount);
        DataTypes.ExecutionResult memory result = module.execute(USDC, amount, params);
        vm.stopPrank();

        return result;
    }

    function _executeBridgeViaPaymentRails(uint256 amount) internal returns (bool success) {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), amount, params, true);

        return paymentRails.executeAction(USDC, amount);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkConstructorTest is CCTPBridgeModuleForkBase {
    function test_Constructor_SetsTokenMessenger() external view {
        assertEq(module.tokenMessenger(), TOKEN_MESSENGER_V2);
    }

    function test_Constructor_SetsUsdc() external view {
        assertEq(module.usdc(), USDC);
    }

    function test_Constructor_ModuleTypeIsConstant() external view {
        assertEq(module.moduleType(), "CCTP_BRIDGE");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ABI COMPATIBILITY TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkABICompatibilityTest is CCTPBridgeModuleForkBase {
    function test_ABI_TokenMessengerV2_IsDeployedAtForkBlock() external view {
        assertTrue(TOKEN_MESSENGER_V2.code.length > 0, "TokenMessengerV2 must be deployed at fork block");
    }

    function test_ABI_DepositForBurn_MatchesRealTokenMessengerV2() external {
        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);
        assertTrue(result.success, "depositForBurn ABI must be compatible with real TokenMessengerV2");
    }

    function test_ABI_DepositForBurnWithHook_MatchesRealTokenMessengerV2() external {
        bytes memory params = _buildParamsWithHook(DOMAIN_BASE);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success, "depositForBurnWithHook ABI must be compatible with real TokenMessengerV2");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            EXECUTE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkExecuteTest is CCTPBridgeModuleForkBase {
    function test_Execute_BurnsRealUSDC_PaymentRailsBalanceDecreases() external {
        uint256 nodeBefore = IERC20(USDC).balanceOf(address(paymentRails));

        _executeBridge(BRIDGE_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeBefore - BRIDGE_AMOUNT);
    }

    function test_Execute_BurnsRealUSDC_ModuleBalanceIsZero() external {
        _executeBridge(BRIDGE_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module should hold zero USDC after burn");
    }

    function test_Execute_RevokesApprovalAfterBurn() external {
        _executeBridge(BRIDGE_AMOUNT);

        uint256 allowance = IERC20(USDC).allowance(address(module), TOKEN_MESSENGER_V2);
        assertEq(allowance, 0, "Module approval to TokenMessengerV2 must be zero after burn");
    }

    function test_Execute_EmitsBridgeInitiatedEvent() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);

        vm.expectEmit(true, true, true, true, address(module));
        emit BridgeInitiated(
            address(paymentRails),
            BRIDGE_AMOUNT,
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            BRIDGE_AMOUNT * uint256(DEFAULT_MAX_FEE_BPS) / 10_000,
            FINALITY_STANDARD,
            ""
        );

        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_ReturnsSuccessResult() external {
        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(result.amountOut, BRIDGE_AMOUNT - (BRIDGE_AMOUNT * uint256(DEFAULT_MAX_FEE_BPS) / 10_000));
        assertEq(result.outputToken, USDC);
    }

    function test_Execute_WithHookData_BurnsUSDCSuccessfully() external {
        bytes memory params = _buildParamsWithHook(DOMAIN_BASE);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Execute_WithHookData_EmitsBridgeInitiatedWithHookData() external {
        bytes memory params = _buildParamsWithHook(DOMAIN_BASE);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);

        vm.expectEmit(true, true, true, true, address(module));
        emit BridgeInitiated(
            address(paymentRails),
            BRIDGE_AMOUNT,
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            BRIDGE_AMOUNT * uint256(DEFAULT_MAX_FEE_BPS) / 10_000,
            FINALITY_STANDARD,
            hex"deadbeef"
        );

        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_ConsecutiveBridges_BothSucceed() external {
        DataTypes.ExecutionResult memory result1 = _executeBridge(BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result2 = _executeBridge(BRIDGE_AMOUNT);

        assertTrue(result1.success);
        assertTrue(result2.success);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Execute_SmallAmount_Succeeds() external {
        DataTypes.ExecutionResult memory result = _executeBridge(SMALL_BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Execute_WithFastFinality_Succeeds() external {
        bytes memory params = _buildParamsWithFinality(DOMAIN_BASE, FINALITY_FAST);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    NON-ZERO maxFeeBps EXECUTE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkMaxFeeBpsTest is CCTPBridgeModuleForkBase {
    uint16 internal constant FEE_BPS = 20; // 0.2%

    function _buildFastFinalityParams(uint32 domain, uint16 maxFeeBps) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: domain,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: maxFeeBps,
                minFinalityThreshold: FINALITY_FAST,
                hookData: bytes("")
            })
        );
    }

    function _buildFastFinalityParamsWithHook(uint32 domain, uint16 maxFeeBps) internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: domain,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: maxFeeBps,
                minFinalityThreshold: FINALITY_FAST,
                hookData: hex"deadbeef"
            })
        );
    }

    function test_Execute_NonZeroFeeBps_FastFinality_SucceedsAgainstRealTokenMessenger() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success, "Non-zero maxFeeBps must succeed against real TokenMessengerV2");
    }

    function test_Execute_NonZeroFeeBps_AmountOutReflectsComputedFee() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);
        uint256 expectedFee = (BRIDGE_AMOUNT * uint256(FEE_BPS)) / 10_000;

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertEq(result.amountOut, BRIDGE_AMOUNT - expectedFee);
    }

    function test_Execute_NonZeroFeeBps_EmitsCorrectComputedMaxFee() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);
        uint256 expectedFee = (BRIDGE_AMOUNT * uint256(FEE_BPS)) / 10_000;

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);

        vm.expectEmit(true, true, true, true, address(module));
        emit BridgeInitiated(
            address(paymentRails), BRIDGE_AMOUNT, DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, expectedFee, FINALITY_FAST, ""
        );

        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_NonZeroFeeBps_WithHookData_Succeeds() external {
        bytes memory params = _buildFastFinalityParamsWithHook(DOMAIN_BASE, FEE_BPS);
        uint256 expectedFee = (BRIDGE_AMOUNT * uint256(FEE_BPS)) / 10_000;

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(result.amountOut, BRIDGE_AMOUNT - expectedFee);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Execute_NonZeroFeeBps_SmallAmount_ComputedFeeScalesCorrectly() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);
        uint256 expectedFee = (SMALL_BRIDGE_AMOUNT * uint256(FEE_BPS)) / 10_000;

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), SMALL_BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, SMALL_BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(result.amountOut, SMALL_BRIDGE_AMOUNT - expectedFee);
    }

    function test_Execute_NonZeroFeeBps_ModuleHoldsZeroAfterBurn() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module must hold zero after non-zero fee bridge");
    }

    function test_Execute_NonZeroFeeBps_ApprovalRevokedAfterBurn() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertEq(
            IERC20(USDC).allowance(address(module), TOKEN_MESSENGER_V2),
            0,
            "Approval to TokenMessengerV2 must be zero after non-zero fee bridge"
        );
    }

    function test_Execute_NonZeroFeeBps_ViaPaymentRails_FullLifecycle() external {
        bytes memory params = _buildFastFinalityParams(DOMAIN_BASE, FEE_BPS);
        uint256 expectedFee = (BRIDGE_AMOUNT * uint256(FEE_BPS)) / 10_000;

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        uint256 balanceBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.expectEmit(true, true, true, true, address(module));
        emit BridgeInitiated(
            address(paymentRails), BRIDGE_AMOUNT, DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, expectedFee, FINALITY_FAST, ""
        );

        bool success = paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        assertTrue(success, "PaymentRails executeAction with non-zero feeBps must succeed");
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), balanceBefore - BRIDGE_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            VALIDATE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkValidateTest is CCTPBridgeModuleForkBase {
    function test_Validate_ValidParams_ReturnsTrue() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertTrue(isValid);
        assertEq(bytes(reason).length, 0);
    }

    function test_Validate_NonUSDC_ReturnsFalse() external {
        address fakeToken = makeAddr("fakeToken");
        bytes memory params = _buildParams(DOMAIN_BASE);

        (bool isValid, string memory reason) = module.validate(fakeToken, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Only USDC supported");
    }

    function test_Validate_ZeroAmount_ReturnsFalse() external view {
        bytes memory params = _buildParams(DOMAIN_BASE);

        (bool isValid, string memory reason) = module.validate(USDC, 0, params);

        assertFalse(isValid);
        assertEq(reason, "Zero bridge amount");
    }

    function test_Validate_ZeroMintRecipient_ReturnsFalse() external view {
        bytes memory params = module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: DOMAIN_BASE,
                mintRecipient: bytes32(0),
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: DEFAULT_MAX_FEE_BPS,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero mint recipient");
    }

    function test_Validate_InvalidFinalityThreshold_ReturnsFalse() external view {
        bytes memory params = module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: DOMAIN_BASE,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: DEFAULT_MAX_FEE_BPS,
                minFinalityThreshold: uint32(9999),
                hookData: bytes("")
            })
        );

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Invalid finality threshold");
    }

    function test_Validate_MaxFeeExceedsAmount_ReturnsFalse() external view {
        bytes memory params = _buildParamsWithFee(DOMAIN_BASE, uint16(10_000));

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Invalid max fee bps");
    }

    function test_Validate_InsufficientBalance_ReturnsFalse() external {
        address emptyPaymentRails = makeAddr("emptyPaymentRails");
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(emptyPaymentRails);
        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }

    function test_Validate_InvalidParamsEncoding_ReturnsFalse() external view {
        bytes memory params = hex"deadbeef"; // too short to decode

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ESTIMATE OUTPUT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkEstimateOutputTest is CCTPBridgeModuleForkBase {
    function test_EstimateOutput_ZeroMaxFee_ReturnsFullAmount() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(address(paymentRails));
        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, BRIDGE_AMOUNT);
        assertEq(outputToken, USDC);
    }

    function test_EstimateOutput_WithMaxFee_ReturnsAmountMinusFee() external {
        uint16 maxFeeBps = 20; // 0.2%
        bytes memory params = _buildParamsWithFee(DOMAIN_BASE, maxFeeBps);

        vm.prank(address(paymentRails));
        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, BRIDGE_AMOUNT - (BRIDGE_AMOUNT * uint256(maxFeeBps) / 10_000));
        assertEq(outputToken, USDC);
    }

    function test_EstimateOutput_InvalidParams_ReturnsZero() external view {
        bytes memory params = hex"deadbeef"; // too short to decode

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, 0);
        assertEq(outputToken, USDC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    NODE INTEGRATION LIFECYCLE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkPaymentRailsIntegrationTest is CCTPBridgeModuleForkBase {
    function test_PaymentRailsIntegration_FullLifecycle_BridgesSuccessfully() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        uint256 nodeBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        assertTrue(success, "PaymentRails executeAction should succeed");
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), nodeBefore - BRIDGE_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module should hold zero after bridge");
    }

    function test_PaymentRailsIntegration_EmitsActionExecutedEvent() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        vm.expectEmit(true, true, true, true, address(paymentRails));
        emit ActionExecuted(USDC, "CCTP_BRIDGE", BRIDGE_AMOUNT, BRIDGE_AMOUNT, USDC, address(this));

        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);
    }

    function test_PaymentRailsIntegration_PreviewExecution_ReturnsCorrectValues() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        uint256 nodeBalance = IERC20(USDC).balanceOf(address(paymentRails));
        (uint256 estimatedOutput, address outputToken) = paymentRails.previewExecution(USDC);

        assertEq(estimatedOutput, nodeBalance);
        assertEq(outputToken, USDC);
    }

    function test_PaymentRailsIntegration_ConsecutiveExecutions_DrainPaymentRails() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        assertTrue(paymentRails.executeAction(USDC, BRIDGE_AMOUNT));
        assertTrue(paymentRails.executeAction(USDC, BRIDGE_AMOUNT));

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_PaymentRailsIntegration_TwoPaymentRailsShareOneModule() external {
        PaymentRails paymentRails2 = new PaymentRails(owner);
        deal(USDC, address(paymentRails2), BRIDGE_AMOUNT * 10);

        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.startPrank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);
        paymentRails2.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);
        vm.stopPrank();

        assertTrue(paymentRails.executeAction(USDC, BRIDGE_AMOUNT));
        assertTrue(paymentRails2.executeAction(USDC, BRIDGE_AMOUNT));

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY / EDGE CASE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkSecurityTest is CCTPBridgeModuleForkBase {
    function test_Security_ApprovalAlwaysZeroAfterExecute() external {
        _executeBridge(BRIDGE_AMOUNT);

        assertEq(
            IERC20(USDC).allowance(address(module), TOKEN_MESSENGER_V2),
            0,
            "Approval to TokenMessengerV2 must be zero after every execute"
        );
    }

    function test_Security_ModuleHoldsNoUSDCAfterMultipleBridges() external {
        _executeBridge(BRIDGE_AMOUNT);
        _executeBridge(BRIDGE_AMOUNT);
        _executeBridge(BRIDGE_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module must never retain USDC after successful bridge");
    }

    function test_Security_NonOwnerCanExecute_Permissionless() external {
        address randomCaller = makeAddr("random");
        deal(USDC, randomCaller, BRIDGE_AMOUNT);

        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.startPrank(randomCaller);
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success, "Any address should be able to execute");
    }

    function test_Security_RealUSDCDecimalsAre6() external view {
        (bool success, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(success);
        uint8 decimals = abi.decode(data, (uint8));
        assertEq(decimals, 6);
    }

    function test_Security_RealUSDCBurnReducesTotalSupply() external {
        (, bytes memory data1) = USDC.staticcall(abi.encodeWithSignature("totalSupply()"));
        uint256 supplyBefore = abi.decode(data1, (uint256));

        _executeBridge(BRIDGE_AMOUNT);

        (, bytes memory data2) = USDC.staticcall(abi.encodeWithSignature("totalSupply()"));
        uint256 supplyAfter = abi.decode(data2, (uint256));

        assertEq(supplyAfter, supplyBefore - BRIDGE_AMOUNT, "Real USDC burn must reduce total supply");
    }

    function test_Security_PaymentRailsApprovalToModuleConsumedAfterExecute() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        uint256 paymentRailsToModuleAllowance = IERC20(USDC).allowance(address(paymentRails), address(module));
        assertEq(paymentRailsToModuleAllowance, 0, "PaymentRails approval to module should be consumed after execute");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    ENCODE / DECODE PARAMS TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkEncodeDecodeTest is CCTPBridgeModuleForkBase {
    function test_EncodeDecodeParams_Roundtrip_PreservesAllFields() external view {
        DataTypes.CCTPBridgeParams memory original = DataTypes.CCTPBridgeParams({
            destinationDomain: DOMAIN_BASE,
            mintRecipient: DEFAULT_MINT_RECIPIENT,
            destinationCaller: DEFAULT_DESTINATION_CALLER,
            maxFeeBps: 50,
            minFinalityThreshold: FINALITY_FAST,
            hookData: hex"deadbeef"
        });

        bytes memory encoded = module.encodeParams(original);
        DataTypes.CCTPBridgeParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.destinationDomain, original.destinationDomain);
        assertEq(decoded.mintRecipient, original.mintRecipient);
        assertEq(decoded.destinationCaller, original.destinationCaller);
        assertEq(decoded.maxFeeBps, original.maxFeeBps);
        assertEq(decoded.minFinalityThreshold, original.minFinalityThreshold);
        assertEq(keccak256(decoded.hookData), keccak256(original.hookData));
    }

    function test_EncodeDecodeParams_ZeroFeeBps_Roundtrip() external view {
        DataTypes.CCTPBridgeParams memory original = DataTypes.CCTPBridgeParams({
            destinationDomain: DOMAIN_ARBITRUM,
            mintRecipient: DEFAULT_MINT_RECIPIENT,
            destinationCaller: bytes32(0),
            maxFeeBps: 0,
            minFinalityThreshold: FINALITY_STANDARD,
            hookData: bytes("")
        });

        bytes memory encoded = module.encodeParams(original);
        DataTypes.CCTPBridgeParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.destinationDomain, DOMAIN_ARBITRUM);
        assertEq(decoded.maxFeeBps, 0);
        assertEq(decoded.hookData.length, 0);
    }

    function test_EncodeDecodeParams_DifferentDomains_DifferentEncodings() external view {
        bytes memory paramsBase = _buildParams(DOMAIN_BASE);
        bytes memory paramsArbitrum = _buildParams(DOMAIN_ARBITRUM);

        assertTrue(keccak256(paramsBase) != keccak256(paramsArbitrum));
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    EDGE CASE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkMaxFeeBpsEdgeCaseTest is CCTPBridgeModuleForkBase {
    function test_Execute_HighFeeBps_9999_SucceedsAgainstRealCCTP() external {
        // 99.99% fee ceiling — leaves only 1 USDC from a 10,000 USDC bridge
        uint16 highFeeBps = 9999;
        bytes memory params = module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: DOMAIN_BASE,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: highFeeBps,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );

        uint256 expectedFee = (BRIDGE_AMOUNT * uint256(highFeeBps)) / 10_000;

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success, "High feeBps must succeed against real TokenMessengerV2");
        assertEq(result.amountOut, BRIDGE_AMOUNT - expectedFee, "amountOut must reflect 99.99% fee ceiling");
        assertGt(expectedFee, 0, "Fee must be non-zero");
    }

    function test_Execute_SmallAmount_FeeBpsTruncatesToZero() external {
        // amount=1 (0.000001 USDC), maxFeeBps=1 → maxFee = 1 * 1 / 10000 = 0 (truncation)
        uint256 tinyAmount = 1;
        uint16 feeBps = 1;

        bytes memory params = module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: DOMAIN_BASE,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: feeBps,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );

        deal(USDC, address(paymentRails), tinyAmount);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), tinyAmount);
        DataTypes.ExecutionResult memory result = module.execute(USDC, tinyAmount, params);
        vm.stopPrank();

        assertTrue(result.success, "Tiny amount with fee truncation should succeed");
        assertEq(result.amountOut, tinyAmount, "amountOut must equal amount when fee truncates to 0");
    }

    function test_Execute_HighFeeBps_ViaPaymentRails_FullLifecycle() external {
        uint16 highFeeBps = 5000; // 50% fee ceiling
        bytes memory params = module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: DOMAIN_BASE,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: highFeeBps,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        uint256 balanceBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        assertTrue(success, "50% fee ceiling should succeed via PaymentRails");
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), balanceBefore - BRIDGE_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module must hold zero after bridge");
    }
}

contract CCTPBridgeModuleForkUSDCPauseTest is CCTPBridgeModuleForkBase {
    event ActionFailed(
        address indexed token, string actionType, uint256 amountIn, string reason, address indexed executor
    );

    function _pauseUSDC() internal {
        (, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("pauser()"));
        address usdcPauser = abi.decode(data, (address));
        vm.prank(usdcPauser);
        (bool ok,) = USDC.call(abi.encodeWithSignature("pause()"));
        require(ok, "Failed to pause USDC");
    }

    function _unpauseUSDC() internal {
        (, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("pauser()"));
        address usdcPauser = abi.decode(data, (address));
        vm.prank(usdcPauser);
        (bool ok,) = USDC.call(abi.encodeWithSignature("unpause()"));
        require(ok, "Failed to unpause USDC");
    }

    function test_Execute_USDCPaused_ReturnsGracefulFailure() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        vm.stopPrank();

        _pauseUSDC();

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);

        assertFalse(result.success, "Execute must fail gracefully when USDC is paused");
        assertEq(result.failureReason, "Token transfer failed");
    }

    function test_Execute_USDCPaused_NoTokensStranded() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        uint256 paymentRailsBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        vm.stopPrank();

        _pauseUSDC();

        vm.prank(address(paymentRails));
        module.execute(USDC, BRIDGE_AMOUNT, params);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), paymentRailsBefore, "PaymentRails balance unchanged");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module holds zero");
    }

    /// @dev USDC's approve() has a whenNotPaused modifier, so forceApprove reverts before the module is reached.
    function test_Execute_USDCPaused_ViaPaymentRails_RevertsAtApprove() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        _pauseUSDC();

        vm.expectRevert();
        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);
    }

    function test_Execute_USDCUnpaused_ResumesNormally() external {
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        _pauseUSDC();
        vm.expectRevert();
        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        _unpauseUSDC();
        assertTrue(paymentRails.executeAction(USDC, BRIDGE_AMOUNT), "Should succeed after unpause");
    }
}

contract CCTPBridgeModuleForkAmountOutCeilingTest is CCTPBridgeModuleForkBase {
    function test_AmountOut_IsAmountMinusCeilingFee_NotActualFee() external {
        uint16 feeBps = 100; // 1%
        uint256 expectedMaxFee = (BRIDGE_AMOUNT * uint256(feeBps)) / 10_000;

        bytes memory params = _buildParamsWithFee(DOMAIN_BASE, feeBps);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(result.amountOut, BRIDGE_AMOUNT - expectedMaxFee);
    }

    function test_AmountOut_ZeroFeeBps_ReportsFullAmount() external {
        bytes memory params = _buildParams(DOMAIN_BASE); // DEFAULT_MAX_FEE_BPS = 0

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(result.amountOut, BRIDGE_AMOUNT, "Zero fee means amountOut equals amount");
    }

    function test_AmountOut_TotalSupplyDecreasesFullAmount_RegardlessOfFee() external {
        uint16 feeBps = 100; // 1%
        bytes memory params = _buildParamsWithFee(DOMAIN_BASE, feeBps);

        uint256 supplyBefore = IERC20(USDC).totalSupply();

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        uint256 supplyAfter = IERC20(USDC).totalSupply();

        assertEq(supplyAfter, supplyBefore - BRIDGE_AMOUNT, "CCTP burns full amount, fee deducted on destination");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    INVALID DESTINATION DOMAIN TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkInvalidDomainTest is CCTPBridgeModuleForkBase {
    uint32 internal constant INVALID_DOMAIN = 999;

    event ActionFailed(
        address indexed token, string actionType, uint256 amountIn, string reason, address indexed executor
    );

    function _buildInvalidDomainParams() internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: INVALID_DOMAIN,
                mintRecipient: DEFAULT_MINT_RECIPIENT,
                destinationCaller: DEFAULT_DESTINATION_CALLER,
                maxFeeBps: DEFAULT_MAX_FEE_BPS,
                minFinalityThreshold: FINALITY_STANDARD,
                hookData: bytes("")
            })
        );
    }

    function test_Execute_InvalidDomain_DirectCall_Reverts() external {
        bytes memory params = _buildInvalidDomainParams();

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);

        vm.expectRevert();
        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_InvalidDomain_ViaPaymentRails_ReturnsFalse() external {
        bytes memory params = _buildInvalidDomainParams();

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        bool success = paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        assertFalse(success, "Invalid domain should cause failure");
    }

    function test_Execute_InvalidDomain_NoTokensLost() external {
        bytes memory params = _buildInvalidDomainParams();

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        uint256 paymentRailsBefore = IERC20(USDC).balanceOf(address(paymentRails));

        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), paymentRailsBefore, "PaymentRails balance unchanged");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module holds zero");
    }

    function test_Execute_InvalidDomain_ApprovalRevoked() external {
        bytes memory params = _buildInvalidDomainParams();

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);

        assertEq(IERC20(USDC).allowance(address(paymentRails), address(module)), 0, "Approval must be revoked");
    }

    function test_Execute_InvalidDomain_EmitsActionFailed() external {
        bytes memory params = _buildInvalidDomainParams();

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, params, true);

        vm.expectEmit(true, false, false, true, address(paymentRails));
        emit ActionFailed(USDC, "CCTP_BRIDGE", BRIDGE_AMOUNT, "Module execution reverted", address(this));

        paymentRails.executeAction(USDC, BRIDGE_AMOUNT);
    }

    function test_Execute_InvalidDomain_ValidDomainSucceedsAfter() external {
        bytes memory invalidParams = _buildInvalidDomainParams();

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, invalidParams, true);

        assertFalse(paymentRails.executeAction(USDC, BRIDGE_AMOUNT), "Invalid domain should fail");

        bytes memory validParams = _buildParams(DOMAIN_BASE);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "CCTP_BRIDGE", address(module), BRIDGE_AMOUNT, validParams, true);

        assertTrue(paymentRails.executeAction(USDC, BRIDGE_AMOUNT), "Valid domain should succeed after invalid");
    }
}
