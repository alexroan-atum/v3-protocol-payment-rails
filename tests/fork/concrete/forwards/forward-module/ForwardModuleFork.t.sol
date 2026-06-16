// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { ForwardModule } from "../../../../../src/modules/forwards/ForwardModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Shared setup for ForwardModule fork tests against Ethereum mainnet.
abstract contract ForwardModuleForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event TokenConfigured(address indexed token, string actionType, address actionModule);

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

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint256 internal constant USDC_AMOUNT = 10_000e6;
    uint256 internal constant WETH_AMOUNT = 5 ether;
    uint256 internal constant DAI_AMOUNT = 10_000e18;

    uint256 internal constant SMALL_USDC = 1e6; // 1 USDC
    uint256 internal constant LARGE_USDC = 1_000_000e6; // 1M USDC

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    ForwardModule internal module;
    PaymentRails internal paymentRails;
    address internal owner;
    address internal recipient;
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
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");

        module = new ForwardModule();

        vm.prank(owner);
        paymentRails = new PaymentRails(owner);

        deal(USDC, address(paymentRails), USDC_AMOUNT * 10);
        deal(WETH, address(paymentRails), WETH_AMOUNT * 10);
        deal(DAI, address(paymentRails), DAI_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(address _recipient, uint256 minAmount) internal view returns (bytes memory) {
        return module.encodeParams(DataTypes.ForwardParams({ recipient: _recipient, minAmount: minAmount }));
    }

    function _executeForward(address token, uint256 amount) internal returns (DataTypes.ExecutionResult memory) {
        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(address(paymentRails));
        IERC20(token).approve(address(module), amount);
        DataTypes.ExecutionResult memory result = module.execute(token, amount, params);
        vm.stopPrank();

        return result;
    }

    function _executeForwardViaPaymentRails(
        address token,
        uint256 amount,
        uint256 minBalance
    )
        internal
        returns (bool success)
    {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(token, "FORWARD", address(module), minBalance, params, true);

        return paymentRails.executeAction(token, amount);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        CONSTRUCTOR / SETUP TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkConstructorTest is ForwardModuleForkBase {
    function test_Constructor_ModuleTypeIsForward() external view {
        assertEq(module.moduleType(), "FORWARD");
    }

    function test_Constructor_ModuleIsStateless() external view {
        assertTrue(address(module).code.length > 0, "Module should be deployed");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            EXECUTE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkExecuteTest is ForwardModuleForkBase {
    function test_Execute_ForwardUSDC_RecipientBalanceIncreases() external {
        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);
        uint256 paymentRailsBefore = IERC20(USDC).balanceOf(address(paymentRails));

        _executeForward(USDC, USDC_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(recipient), recipientBefore + USDC_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), paymentRailsBefore - USDC_AMOUNT);
    }

    function test_Execute_ForwardWETH_RecipientBalanceIncreases() external {
        uint256 recipientBefore = IERC20(WETH).balanceOf(recipient);
        uint256 paymentRailsBefore = IERC20(WETH).balanceOf(address(paymentRails));

        _executeForward(WETH, WETH_AMOUNT);

        assertEq(IERC20(WETH).balanceOf(recipient), recipientBefore + WETH_AMOUNT);
        assertEq(IERC20(WETH).balanceOf(address(paymentRails)), paymentRailsBefore - WETH_AMOUNT);
    }

    function test_Execute_ForwardDAI_RecipientBalanceIncreases() external {
        uint256 recipientBefore = IERC20(DAI).balanceOf(recipient);
        uint256 paymentRailsBefore = IERC20(DAI).balanceOf(address(paymentRails));

        _executeForward(DAI, DAI_AMOUNT);

        assertEq(IERC20(DAI).balanceOf(recipient), recipientBefore + DAI_AMOUNT);
        assertEq(IERC20(DAI).balanceOf(address(paymentRails)), paymentRailsBefore - DAI_AMOUNT);
    }

    function test_Execute_ModuleHoldsZeroTokensAfterForward() external {
        _executeForward(USDC, USDC_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module should hold zero USDC");
    }

    function test_Execute_ReturnsCorrectExecutionResult() external {
        DataTypes.ExecutionResult memory result = _executeForward(USDC, USDC_AMOUNT);

        assertTrue(result.success);
        assertEq(result.amountOut, USDC_AMOUNT);
        assertEq(result.outputToken, USDC);
    }

    function test_Execute_ReturnsEncodedRecipientInData() external {
        DataTypes.ExecutionResult memory result = _executeForward(USDC, USDC_AMOUNT);

        address decodedRecipient = abi.decode(result.data, (address));
        assertEq(decodedRecipient, recipient);
    }

    function test_Execute_SmallAmount_Succeeds() external {
        DataTypes.ExecutionResult memory result = _executeForward(USDC, SMALL_USDC);

        assertTrue(result.success);
        assertEq(result.amountOut, SMALL_USDC);
        assertEq(IERC20(USDC).balanceOf(recipient), SMALL_USDC);
    }

    function test_Execute_LargeAmount_Succeeds() external {
        deal(USDC, address(paymentRails), LARGE_USDC);

        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), LARGE_USDC);
        DataTypes.ExecutionResult memory result = module.execute(USDC, LARGE_USDC, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(IERC20(USDC).balanceOf(recipient), LARGE_USDC);
    }

    function test_Execute_ConsecutiveForwards_Succeed() external {
        DataTypes.ExecutionResult memory result1 = _executeForward(USDC, USDC_AMOUNT);
        DataTypes.ExecutionResult memory result2 = _executeForward(USDC, USDC_AMOUNT);

        assertTrue(result1.success);
        assertTrue(result2.success);
        assertEq(IERC20(USDC).balanceOf(recipient), USDC_AMOUNT * 2);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_Execute_ZeroRecipient_ReturnsFailure() external {
        bytes memory params = _buildParams(address(0), 0);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Zero recipient address");
    }

    function test_Execute_AmountBelowMinimum_ReturnsFailure() external {
        bytes memory params = _buildParams(recipient, USDC_AMOUNT + 1);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Amount below minimum");
    }

    function test_Execute_InsufficientBalance_ReturnsFailure() external {
        address emptyPaymentRails = makeAddr("emptyPaymentRails");
        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(emptyPaymentRails);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Insufficient balance");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            VALIDATE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkValidateTest is ForwardModuleForkBase {
    function test_Validate_ValidParams_ReturnsTrue() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(USDC, USDC_AMOUNT, params);

        assertTrue(isValid);
        assertEq(bytes(reason).length, 0);
    }

    function test_Validate_ZeroRecipient_ReturnsFalse() external view {
        bytes memory params = _buildParams(address(0), 0);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Zero recipient address");
    }

    function test_Validate_AmountBelowMinimum_ReturnsFalse() external view {
        bytes memory params = _buildParams(recipient, USDC_AMOUNT + 1);

        (bool isValid, string memory reason) = module.validate(USDC, USDC_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Amount below minimum");
    }

    function test_Validate_InsufficientBalance_ReturnsFalse() external {
        address emptyPaymentRails = makeAddr("emptyPaymentRails");
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(emptyPaymentRails);
        (bool isValid, string memory reason) = module.validate(USDC, USDC_AMOUNT, params);

        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ESTIMATE OUTPUT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkEstimateOutputTest is ForwardModuleForkBase {
    function test_EstimateOutput_ReturnsAmountAndToken_USDC() external view {
        bytes memory params = _buildParams(recipient, 0);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(USDC, USDC_AMOUNT, params);

        assertEq(estimatedOutput, USDC_AMOUNT);
        assertEq(outputToken, USDC);
    }

    function test_EstimateOutput_ReturnsAmountAndToken_WETH() external view {
        bytes memory params = _buildParams(recipient, 0);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(WETH, WETH_AMOUNT, params);

        assertEq(estimatedOutput, WETH_AMOUNT);
        assertEq(outputToken, WETH);
    }

    function test_EstimateOutput_ReturnsAmountAndToken_DAI() external view {
        bytes memory params = _buildParams(recipient, 0);

        (uint256 estimatedOutput, address outputToken) = module.estimateOutput(DAI, DAI_AMOUNT, params);

        assertEq(estimatedOutput, DAI_AMOUNT);
        assertEq(outputToken, DAI);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    ENCODE / DECODE PARAMS TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkEncodeDecodeTest is ForwardModuleForkBase {
    function test_EncodeDecodeParams_Roundtrip_PreservesAllFields() external view {
        DataTypes.ForwardParams memory original =
            DataTypes.ForwardParams({ recipient: recipient, minAmount: USDC_AMOUNT });

        bytes memory encoded = module.encodeParams(original);
        DataTypes.ForwardParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.recipient, original.recipient);
        assertEq(decoded.minAmount, original.minAmount);
    }

    function test_EncodeDecodeParams_DifferentRecipients_DifferentEncodings() external view {
        bytes memory params1 = _buildParams(recipient, 0);
        bytes memory params2 = _buildParams(attacker, 0);

        assertTrue(keccak256(params1) != keccak256(params2));
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    PAYMENT RAILS INTEGRATION TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkPaymentRailsIntegrationTest is ForwardModuleForkBase {
    function test_PaymentRailsIntegration_ForwardUSDC_Succeeds() external {
        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);

        bool success = _executeForwardViaPaymentRails(USDC, USDC_AMOUNT, USDC_AMOUNT);

        assertTrue(success);
        assertEq(IERC20(USDC).balanceOf(recipient), recipientBefore + USDC_AMOUNT);
    }

    function test_PaymentRailsIntegration_ForwardWETH_Succeeds() external {
        uint256 recipientBefore = IERC20(WETH).balanceOf(recipient);

        bool success = _executeForwardViaPaymentRails(WETH, WETH_AMOUNT, WETH_AMOUNT);

        assertTrue(success);
        assertEq(IERC20(WETH).balanceOf(recipient), recipientBefore + WETH_AMOUNT);
    }

    function test_PaymentRailsIntegration_PreviewExecution_ReturnsCorrectValues() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        uint256 paymentRailsBalance = IERC20(USDC).balanceOf(address(paymentRails));
        (uint256 estimatedOutput, address outputToken) = paymentRails.previewExecution(USDC);

        assertEq(estimatedOutput, paymentRailsBalance);
        assertEq(outputToken, USDC);
    }

    function test_PaymentRailsIntegration_GetTokenConfig_ReturnsStoredConfig() external {
        bytes memory params = _buildParams(recipient, USDC_AMOUNT);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(USDC);
        assertEq(config.actionType, "FORWARD");
        assertEq(config.actionModule, address(module));
        assertTrue(config.enabled);
        assertEq(config.minBalance, USDC_AMOUNT);
    }

    function test_PaymentRailsIntegration_EmitsActionExecutedEvent() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        vm.expectEmit(true, true, true, true, address(paymentRails));
        emit ActionExecuted(USDC, "FORWARD", USDC_AMOUNT, USDC_AMOUNT, USDC, address(this));

        paymentRails.executeAction(USDC, USDC_AMOUNT);
    }

    function test_PaymentRailsIntegration_EmitsTokenConfiguredEvent() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.expectEmit(true, true, true, true, address(paymentRails));
        emit TokenConfigured(USDC, "FORWARD", address(module));

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);
    }

    function test_PaymentRailsIntegration_TwoPaymentRailsShareOneModule() external {
        PaymentRails paymentRails2 = new PaymentRails(owner);
        deal(USDC, address(paymentRails2), USDC_AMOUNT * 10);

        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);
        paymentRails2.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);
        vm.stopPrank();

        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);

        assertTrue(paymentRails.executeAction(USDC, USDC_AMOUNT));
        assertTrue(paymentRails2.executeAction(USDC, USDC_AMOUNT));

        assertEq(IERC20(USDC).balanceOf(recipient), recipientBefore + USDC_AMOUNT * 2);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_PaymentRailsIntegration_ConsecutiveExecutions_DrainPaymentRails() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        assertTrue(paymentRails.executeAction(USDC, USDC_AMOUNT));
        assertTrue(paymentRails.executeAction(USDC, USDC_AMOUNT));
        assertTrue(paymentRails.executeAction(USDC, USDC_AMOUNT));

        assertEq(IERC20(USDC).balanceOf(recipient), USDC_AMOUNT * 3);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
    }

    function test_PaymentRailsIntegration_ApprovalConsumedAfterExecute() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        paymentRails.executeAction(USDC, USDC_AMOUNT);

        uint256 allowance = IERC20(USDC).allowance(address(paymentRails), address(module));
        assertEq(allowance, 0, "PaymentRails approval to module should be consumed after execute");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY / EDGE CASE TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkSecurityTest is ForwardModuleForkBase {
    function test_Security_ModuleHoldsZeroAfterMultipleForwards() external {
        _executeForward(USDC, USDC_AMOUNT);
        _executeForward(WETH, WETH_AMOUNT);
        _executeForward(DAI, DAI_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
        assertEq(IERC20(WETH).balanceOf(address(module)), 0);
        assertEq(IERC20(DAI).balanceOf(address(module)), 0);
    }

    function test_Security_NonOwnerCannotConfigureTokens() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);
    }

    function test_Security_AnyoneCanExecuteAction() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        bool success = paymentRails.executeAction(USDC, USDC_AMOUNT);
        assertTrue(success, "Any address should be able to execute");
    }

    function test_Security_RealTokenDecimalsAreCorrect() external view {
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC should be 6 decimals");
        assertEq(IERC20Metadata(WETH).decimals(), 18, "WETH should be 18 decimals");
        assertEq(IERC20Metadata(DAI).decimals(), 18, "DAI should be 18 decimals");
    }

    function test_Security_ForwardToContractAddress_Succeeds() external {
        // Forward to the paymentRails itself (a contract)
        bytes memory params = _buildParams(address(paymentRails), 0);

        uint256 paymentRailsBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success);
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), paymentRailsBefore);
    }

    function test_Security_PaymentRailsApprovalRevokedOnFailure() external {
        bytes memory params = _buildParams(address(0), 0); // will fail

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        bool success = paymentRails.executeAction(USDC, USDC_AMOUNT);
        assertFalse(success, "Should fail with zero recipient");

        uint256 allowance = IERC20(USDC).allowance(address(paymentRails), address(module));
        assertEq(allowance, 0, "PaymentRails approval to module should be revoked on failure");
    }

    function test_Security_MultipleTokensConfiguredIndependently() external {
        bytes memory usdcParams = _buildParams(recipient, 0);
        bytes memory wethParams = _buildParams(makeAddr("wethRecipient"), 0);

        vm.startPrank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, usdcParams, true);
        paymentRails.configureToken(WETH, "FORWARD", address(module), WETH_AMOUNT, wethParams, true);
        vm.stopPrank();

        assertTrue(paymentRails.executeAction(USDC, USDC_AMOUNT));
        assertTrue(paymentRails.executeAction(WETH, WETH_AMOUNT));

        assertEq(IERC20(USDC).balanceOf(recipient), USDC_AMOUNT);
        assertEq(IERC20(WETH).balanceOf(makeAddr("wethRecipient")), WETH_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(module)), 0);
        assertEq(IERC20(WETH).balanceOf(address(module)), 0);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                USDC BLOCKLIST GRACEFUL FAILURE TEST
//////////////////////////////////////////////////////////////////////////*/

contract ForwardModuleForkBlocklistTest is ForwardModuleForkBase {
    event ActionFailed(
        address indexed token, string actionType, uint256 amountIn, string reason, address indexed executor
    );

    function _blacklistAddress(address target) internal {
        (, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("blacklister()"));
        address blacklister = abi.decode(data, (address));
        vm.prank(blacklister);
        (bool ok,) = USDC.call(abi.encodeWithSignature("blacklist(address)", target));
        require(ok, "Failed to blacklist address");
    }

    function _unblacklistAddress(address target) internal {
        (, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("blacklister()"));
        address blacklister = abi.decode(data, (address));
        vm.prank(blacklister);
        (bool ok,) = USDC.call(abi.encodeWithSignature("unBlacklist(address)", target));
        require(ok, "Failed to unblacklist address");
    }

    function test_BlocklistedRecipient_ReturnsGracefulFailure() external {
        _blacklistAddress(recipient);

        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success, "Forward to blocklisted recipient must fail gracefully");
        assertEq(result.failureReason, "Transfer failed");
    }

    function test_BlocklistedRecipient_NoTokensLost() external {
        _blacklistAddress(recipient);

        uint256 paymentRailsBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_AMOUNT);
        module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), paymentRailsBefore, "PaymentRails balance unchanged");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module holds zero");
        assertEq(IERC20(USDC).balanceOf(recipient), 0, "Blocklisted recipient received nothing");
    }

    function test_BlocklistedRecipient_ViaPaymentRails_EmitsActionFailed() external {
        _blacklistAddress(recipient);

        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        vm.expectEmit(true, false, false, true, address(paymentRails));
        emit ActionFailed(USDC, "FORWARD", USDC_AMOUNT, "Transfer failed", address(this));

        bool success = paymentRails.executeAction(USDC, USDC_AMOUNT);
        assertFalse(success, "executeAction must return false for blocklisted recipient");
    }

    function test_BlocklistedRecipient_ViaPaymentRails_ApprovalRevoked() external {
        _blacklistAddress(recipient);

        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        paymentRails.executeAction(USDC, USDC_AMOUNT);

        assertEq(
            IERC20(USDC).allowance(address(paymentRails), address(module)),
            0,
            "Approval must be revoked after failed forward"
        );
    }

    function test_BlocklistedRecipient_Unblacklisted_ResumesNormally() external {
        bytes memory params = _buildParams(recipient, 0);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "FORWARD", address(module), USDC_AMOUNT, params, true);

        _blacklistAddress(recipient);
        assertFalse(paymentRails.executeAction(USDC, USDC_AMOUNT), "Should fail while blocklisted");

        _unblacklistAddress(recipient);
        assertTrue(paymentRails.executeAction(USDC, USDC_AMOUNT), "Should succeed after unblacklist");
        assertEq(IERC20(USDC).balanceOf(recipient), USDC_AMOUNT);
    }

    function test_BlocklistedPaymentRails_TransferFromFails() external {
        _blacklistAddress(address(paymentRails));

        bytes memory params = _buildParams(recipient, 0);

        vm.startPrank(address(paymentRails));
        IERC20(USDC).approve(address(module), USDC_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(USDC, USDC_AMOUNT, params);
        vm.stopPrank();

        assertFalse(result.success, "Transfer from blocklisted sender must fail");
        assertEq(result.failureReason, "Transfer failed");
    }
}
