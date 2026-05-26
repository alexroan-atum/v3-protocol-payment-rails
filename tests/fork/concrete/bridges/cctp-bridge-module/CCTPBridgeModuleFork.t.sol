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
    uint256 internal constant DEFAULT_MAX_FEE = 0;
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

    function _buildParams(uint32 domain) internal pure returns (bytes memory) {
        return abi.encode(
            domain, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_STANDARD, bytes("")
        );
    }

    function _buildParamsWithHook(uint32 domain) internal pure returns (bytes memory) {
        return abi.encode(
            domain,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            hex"deadbeef"
        );
    }

    function _buildParamsWithFee(uint32 domain, uint256 maxFee) internal pure returns (bytes memory) {
        return
            abi.encode(domain, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, maxFee, FINALITY_STANDARD, bytes(""));
    }

    function _buildParamsWithFinality(uint32 domain, uint32 finality) internal pure returns (bytes memory) {
        return
            abi.encode(domain, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, finality, bytes(""));
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
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            ""
        );

        module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();
    }

    function test_Execute_ReturnsSuccessResult() external {
        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(result.amountOut, BRIDGE_AMOUNT - DEFAULT_MAX_FEE);
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
            DEFAULT_MAX_FEE,
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
        bytes memory params = abi.encode(
            DOMAIN_BASE,
            bytes32(0), // zero mint recipient
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            bytes("")
        );

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero mint recipient");
    }

    function test_Validate_InvalidFinalityThreshold_ReturnsFalse() external view {
        bytes memory params = abi.encode(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            uint32(9999), // invalid finality threshold
            bytes("")
        );

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Invalid finality threshold");
    }

    function test_Validate_MaxFeeExceedsAmount_ReturnsFalse() external view {
        bytes memory params = _buildParamsWithFee(DOMAIN_BASE, BRIDGE_AMOUNT + 1);

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Max fee exceeds amount");
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
        uint256 maxFee = 1e6;
        bytes memory params = _buildParamsWithFee(DOMAIN_BASE, maxFee);

        vm.prank(address(paymentRails));
        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, BRIDGE_AMOUNT - maxFee);
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
