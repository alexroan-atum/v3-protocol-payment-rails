// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CCTPBridgeModuleForkBase
/// @notice Shared setup for all CCTPBridgeModule fork tests against Ethereum mainnet.
/// @dev Forks Ethereum mainnet and interacts with the real TokenMessengerV2 and USDC contracts.
///
///      FORK vs UNIT vs INTEGRATION — scope boundaries:
///        - Unit tests:        MockTokenMessengerV2, MockERC20, MockBridgePaymentRails — logic in isolation.
///        - Integration tests: Real PaymentRails + real module, but mocked external deps.
///        - Fork tests (here): Real TokenMessengerV2, real USDC, real burn lifecycle.
///
///      What fork tests uniquely verify:
///        1. ABI compatibility — our ITokenMessengerV2 interface matches the deployed bytecode.
///        2. Real USDC behavior — 6 decimals, approval semantics, actual burn mechanics.
///        3. Full burn lifecycle — USDC is actually burned by TokenMessengerV2 + TokenMinter.
///        4. Full lifecycle through PaymentRails — configure → executeAction → bridge → verify balances.
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

    event DomainConfigSet(
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    event DomainConfigRemoved(uint32 indexed destinationDomain);

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

    /// @dev Ethereum mainnet Circle TokenMessengerV2 (CCTP V2)
    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    /// @dev Ethereum mainnet USDC (FiatTokenV2_2 behind proxy)
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev CCTP domain IDs
    uint32 internal constant DOMAIN_ARBITRUM = 3;
    uint32 internal constant DOMAIN_BASE = 6;

    /// @dev Default bridge parameters
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

        vm.startPrank(owner);
        module = new CCTPBridgeModule(TOKEN_MESSENGER_V2, USDC, owner);
        paymentRails = new PaymentRails(owner);
        vm.stopPrank();

        deal(USDC, address(paymentRails), BRIDGE_AMOUNT * 10);

        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_STANDARD, ""
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                LIFECYCLE MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier givenDomainConfiguredWithHookData() {
        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_BASE,
            DEFAULT_MINT_RECIPIENT,
            DEFAULT_DESTINATION_CALLER,
            DEFAULT_MAX_FEE,
            FINALITY_STANDARD,
            hex"deadbeef"
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(uint32 domain) internal pure returns (bytes memory) {
        return abi.encode(domain);
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

    function test_Constructor_SetsOwner() external view {
        assertEq(module.owner(), owner);
    }

    function test_Constructor_ModuleTypeIsConstant() external view {
        assertEq(module.moduleType(), "CCTP_BRIDGE");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ABI COMPATIBILITY TESTS
//////////////////////////////////////////////////////////////////////////*/

/// @dev These tests verify our ITokenMessengerV2 interface matches the real deployed bytecode.
///      If the function selectors or parameter types differ, the calls revert.
contract CCTPBridgeModuleForkABICompatibilityTest is CCTPBridgeModuleForkBase {
    function test_ABI_TokenMessengerV2_IsDeployedAtForkBlock() external view {
        assertTrue(TOKEN_MESSENGER_V2.code.length > 0, "TokenMessengerV2 must be deployed at fork block");
    }

    function test_ABI_DepositForBurn_MatchesRealTokenMessengerV2() external {
        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);
        assertTrue(result.success, "depositForBurn ABI must be compatible with real TokenMessengerV2");
    }

    function test_ABI_DepositForBurnWithHook_MatchesRealTokenMessengerV2() external givenDomainConfiguredWithHookData {
        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);
        assertTrue(result.success, "depositForBurnWithHook ABI must be compatible with real TokenMessengerV2");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            EXECUTE TESTS
//////////////////////////////////////////////////////////////////////////*/

/// @dev Execute tests verify real USDC is burned by the TokenMessengerV2 + TokenMinter pipeline.
///      Unlike unit tests (where MockTokenMessengerV2 just records calls), here USDC is destroyed.
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

    function test_Execute_WithHookData_BurnsUSDCSuccessfully() external givenDomainConfiguredWithHookData {
        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);

        assertTrue(result.success);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Execute_WithHookData_EmitsBridgeInitiatedWithHookData() external givenDomainConfiguredWithHookData {
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
        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );

        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);

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

    function test_Validate_UnconfiguredDomain_ReturnsFalse() external view {
        bytes memory params = _buildParams(uint32(99));

        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Domain not configured");
    }

    function test_Validate_InsufficientBalance_ReturnsFalse() external {
        address emptyPaymentRails = makeAddr("emptyPaymentRails");
        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.prank(emptyPaymentRails);
        (bool isValid, string memory reason) = module.validate(USDC, BRIDGE_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ESTIMATE OUTPUT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkEstimateOutputTest is CCTPBridgeModuleForkBase {
    function test_EstimateOutput_ZeroMaxFee_ReturnsFullAmount() external view {
        bytes memory params = _buildParams(DOMAIN_BASE);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, BRIDGE_AMOUNT);
        assertEq(outputToken, USDC);
    }

    function test_EstimateOutput_WithMaxFee_ReturnsAmountMinusFee() external {
        uint256 maxFee = 1e6;
        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_BASE, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, maxFee, FINALITY_STANDARD, ""
        );

        bytes memory params = _buildParams(DOMAIN_BASE);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, BRIDGE_AMOUNT - maxFee);
        assertEq(outputToken, USDC);
    }

    function test_EstimateOutput_UnconfiguredDomain_ReturnsZero() external view {
        bytes memory params = _buildParams(uint32(99));

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, BRIDGE_AMOUNT, params);

        assertEq(estimatedOutput, 0);
        assertEq(outputToken, USDC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        DOMAIN CONFIG TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkDomainConfigTest is CCTPBridgeModuleForkBase {
    function test_SetDomainConfig_StoresCorrectValues() external view {
        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);

        assertTrue(config.isValid);
        assertEq(config.mintRecipient, DEFAULT_MINT_RECIPIENT);
        assertEq(config.destinationCaller, DEFAULT_DESTINATION_CALLER);
        assertEq(config.maxFee, DEFAULT_MAX_FEE);
        assertEq(config.minFinalityThreshold, FINALITY_STANDARD);
    }

    function test_SetDomainConfig_MultipleDomains() external {
        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );

        DataTypes.CCTPDomainConfig memory baseConfig = module.getDomainConfig(DOMAIN_BASE);
        DataTypes.CCTPDomainConfig memory arbConfig = module.getDomainConfig(DOMAIN_ARBITRUM);

        assertTrue(baseConfig.isValid);
        assertTrue(arbConfig.isValid);
        assertEq(baseConfig.minFinalityThreshold, FINALITY_STANDARD);
        assertEq(arbConfig.minFinalityThreshold, FINALITY_FAST);
    }

    function test_SetDomainConfig_EmitsDomainConfigSet() external {
        vm.expectEmit(true, false, false, true, address(module));
        emit DomainConfigSet(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST
        );

        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );
    }

    function test_RemoveDomainConfig_ClearsDomain() external {
        vm.prank(owner);
        module.removeDomainConfig(DOMAIN_BASE);

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_BASE);
        assertFalse(config.isValid);
    }

    function test_Execute_AfterDomainRemoval_ReturnsFalse() external {
        vm.prank(owner);
        module.removeDomainConfig(DOMAIN_BASE);

        bytes memory params = _buildParams(DOMAIN_BASE);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), BRIDGE_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, BRIDGE_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Domain not configured");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    NODE INTEGRATION LIFECYCLE TESTS
//////////////////////////////////////////////////////////////////////////*/

/// @dev These tests exercise the full production path: PaymentRails.configureToken → PaymentRails.executeAction →
///      CCTPBridgeModule.execute → TokenMessengerV2.depositForBurn → USDC burned.
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
                        OWNERSHIP TESTS
//////////////////////////////////////////////////////////////////////////*/

contract CCTPBridgeModuleForkOwnershipTest is CCTPBridgeModuleForkBase {
    function test_OwnershipTransfer_FullOwnable2StepFlow() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);

        assertEq(module.pendingOwner(), newOwner);
        assertEq(module.owner(), owner);

        vm.prank(newOwner);
        module.acceptOwnership();

        assertEq(module.owner(), newOwner);
        assertEq(module.pendingOwner(), address(0));
    }

    function test_OwnershipTransfer_NewOwnerCanReconfigure() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        vm.prank(newOwner);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );

        DataTypes.CCTPDomainConfig memory config = module.getDomainConfig(DOMAIN_ARBITRUM);
        assertTrue(config.isValid);
    }

    function test_OwnershipTransfer_OldOwnerBlockedAfterTransfer() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_FAST, ""
        );
    }

    function test_OwnershipTransfer_BridgeStillWorksAfterTransfer() external {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        module.transferOwnership(newOwner);
        vm.prank(newOwner);
        module.acceptOwnership();

        DataTypes.ExecutionResult memory result = _executeBridge(BRIDGE_AMOUNT);
        assertTrue(result.success, "Bridge should work after ownership transfer");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY / EDGE CASE TESTS
//////////////////////////////////////////////////////////////////////////*/

/// @dev These tests verify security properties that are only meaningful with real USDC
///      and the real TokenMessengerV2 — things like actual burn mechanics, total supply
///      changes, approval semantics, and permissionless execution with real tokens.
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

    function test_Security_NonOwnerCannotSetDomainConfig() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        module.setDomainConfig(
            DOMAIN_ARBITRUM, DEFAULT_MINT_RECIPIENT, DEFAULT_DESTINATION_CALLER, DEFAULT_MAX_FEE, FINALITY_STANDARD, ""
        );
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
