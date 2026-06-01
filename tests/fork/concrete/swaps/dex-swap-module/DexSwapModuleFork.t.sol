// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, console2 } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../../src/modules/swaps/DexSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { IChainlinkAggregatorV3 } from "../../../../../src/interfaces/IChainlinkAggregatorV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DexSwapModuleForkBase
/// @notice Shared setup for DexSwapModule fork tests against Ethereum mainnet.
/// @dev Run with: forge test --match-contract DexSwapModuleFork --fork-url $ETHEREUM_RPC_URL -vvv
///
///      Architecture change: DexSwapModule now has an immutable router (set at construction)
///      and requires oracle feeds for all swaps. There is no executionData — all parameters
///      are owner-configured in the static DexSwapParams.
abstract contract DexSwapModuleForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event SwapExecuted(
        address indexed paymentRails, address indexed sellToken, address buyToken, uint256 amountIn, uint256 amountOut
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

    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant DAI_USD_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    uint256 internal constant ORACLE_MAX_STALENESS = 86_400; // 24 hours (matches Chainlink stablecoin heartbeat)
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600; // 10 minutes

    uint256 internal constant WETH_SELL_AMOUNT = 1 ether;
    uint256 internal constant USDC_SELL_AMOUNT = 2000e6;
    uint256 internal constant DAI_SELL_AMOUNT = 2000e18;

    uint24 internal constant FEE_LOW = 500;
    uint24 internal constant FEE_MEDIUM = 3000;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    PaymentRails internal paymentRails;
    address internal owner;

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

        vm.startPrank(owner);
        module = new DexSwapModule(UNISWAP_V3_ROUTER, address(0), 0);
        paymentRails = new PaymentRails(owner);
        vm.stopPrank();

        deal(WETH, address(paymentRails), WETH_SELL_AMOUNT * 10);
        deal(USDC, address(paymentRails), USDC_SELL_AMOUNT * 10);
        deal(DAI, address(paymentRails), DAI_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Builds DexSwapParams with oracle feeds and slippage.
    function _buildSwapParams(
        address targetToken,
        uint24 fee,
        uint16 maxSlippageBps,
        address sellTokenPriceFeed,
        address buyTokenPriceFeed
    )
        internal
        view
        returns (bytes memory)
    {
        return module.encodeParams(
            DataTypes.DexSwapParams({
                targetToken: targetToken,
                fee: fee,
                maxSlippageBps: maxSlippageBps,
                sellTokenPriceFeed: sellTokenPriceFeed,
                buyTokenPriceFeed: buyTokenPriceFeed,
                maxStaleness: ORACLE_MAX_STALENESS,
                swapDeadlineSeconds: DEFAULT_DEADLINE_SECONDS
            })
        );
    }

    /// @dev Convenience overload for the common WETH→USDC case with 1% slippage.
    function _buildDefaultWethToUsdcParams() internal view returns (bytes memory) {
        return _buildSwapParams(USDC, FEE_MEDIUM, 100, ETH_USD_FEED, USDC_USD_FEED);
    }

    /// @dev Convenience overload for USDC→WETH with 1% slippage.
    function _buildDefaultUsdcToWethParams() internal view returns (bytes memory) {
        return _buildSwapParams(WETH, FEE_MEDIUM, 100, USDC_USD_FEED, ETH_USD_FEED);
    }

    /// @dev Convenience overload for DAI→USDC with 0.5% slippage.
    function _buildDefaultDaiToUsdcParams() internal view returns (bytes memory) {
        return _buildSwapParams(USDC, FEE_LOW, 50, DAI_USD_FEED, USDC_USD_FEED);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        CONSTRUCTOR / SETUP TESTS
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkSetupTest is DexSwapModuleForkBase {
    function test_Setup_ModuleDeployedCorrectly() external view {
        assertEq(module.router(), UNISWAP_V3_ROUTER);
    }

    function test_Setup_PaymentRailsFunded() external view {
        assertGe(IERC20(WETH).balanceOf(address(paymentRails)), WETH_SELL_AMOUNT);
        assertGe(IERC20(USDC).balanceOf(address(paymentRails)), USDC_SELL_AMOUNT);
    }

    function test_Setup_ModuleTypeIsSwap() external view {
        assertEq(module.moduleType(), "SWAP");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    MAINNET SIMULATION: WETH → USDC
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkWethToUsdcTest is DexSwapModuleForkBase {
    function test_Simulate_WethToUsdc_ViaPaymentRails() external {
        bytes memory swapParams = _buildDefaultWethToUsdcParams();

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);

        assertTrue(success, "Swap should succeed");

        uint256 wethAfter = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(paymentRails));

        assertEq(wethAfter, wethBefore - WETH_SELL_AMOUNT, "WETH should decrease by sell amount");
        assertGt(usdcAfter, usdcBefore, "USDC should increase");

        uint256 usdcReceived = usdcAfter - usdcBefore;

        assertGt(usdcReceived, 1000e6, "Should receive > 1000 USDC for 1 WETH");
        assertLt(usdcReceived, 10_000e6, "Should receive < 10000 USDC for 1 WETH");

        assertEq(IERC20(WETH).balanceOf(address(module)), 0, "Module should hold no WETH");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module should hold no USDC");

        console2.log("=== WETH -> USDC Swap Simulation ===");
        console2.log("WETH sold:", WETH_SELL_AMOUNT / 1e18, "ETH");
        console2.log("USDC received:", usdcReceived / 1e6, "USDC");
        console2.log("Effective price: $%s per ETH", usdcReceived / 1e6);
        console2.log("SIMULATION PASSED");
    }

    function test_Simulate_WethToUsdc_DirectModuleCall() external {
        bytes memory swapParams = _buildDefaultWethToUsdcParams();

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.startPrank(address(paymentRails));
        IERC20(WETH).approve(address(module), WETH_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(WETH, WETH_SELL_AMOUNT, swapParams);
        vm.stopPrank();

        assertTrue(result.success, "Module execute should succeed");
        assertEq(result.outputToken, USDC, "Output token should be USDC");
        assertGt(result.amountOut, 0, "amountOut should be > 0");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        assertEq(result.amountOut, usdcReceived, "amountOut should match actual balance diff");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    MAINNET SIMULATION: USDC → WETH
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkUsdcToWethTest is DexSwapModuleForkBase {
    function test_Simulate_UsdcToWeth_ViaPaymentRails() external {
        bytes memory swapParams = _buildDefaultUsdcToWethParams();

        vm.prank(owner);
        paymentRails.configureToken(USDC, "SWAP", address(module), USDC_SELL_AMOUNT, swapParams, true);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);
        assertTrue(success, "Swap should succeed");

        uint256 wethReceived = IERC20(WETH).balanceOf(address(paymentRails)) - wethBefore;
        assertGt(wethReceived, 0, "Should receive some WETH");
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), usdcBefore - USDC_SELL_AMOUNT);

        console2.log("=== USDC -> WETH Swap Simulation ===");
        console2.log("USDC sold:", USDC_SELL_AMOUNT / 1e6, "USDC");
        console2.log("WETH received (wei):", wethReceived);
        console2.log("SIMULATION PASSED");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    MAINNET SIMULATION: DAI → USDC
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkDaiToUsdcTest is DexSwapModuleForkBase {
    function test_Simulate_DaiToUsdc_ViaPaymentRails() external {
        bytes memory swapParams = _buildDefaultDaiToUsdcParams();

        vm.prank(owner);
        paymentRails.configureToken(DAI, "SWAP", address(module), DAI_SELL_AMOUNT, swapParams, true);

        uint256 daiBefore = IERC20(DAI).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(DAI, DAI_SELL_AMOUNT);
        assertTrue(success, "Swap should succeed");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        assertGt(usdcReceived, 0, "Should receive some USDC");
        assertEq(IERC20(DAI).balanceOf(address(paymentRails)), daiBefore - DAI_SELL_AMOUNT);

        assertGt(usdcReceived, 1900e6, "Should receive > 1900 USDC for 2000 DAI");
        assertLt(usdcReceived, 2100e6, "Should receive < 2100 USDC for 2000 DAI");

        console2.log("=== DAI -> USDC Swap Simulation ===");
        console2.log("DAI sold:", DAI_SELL_AMOUNT / 1e18, "DAI");
        console2.log("USDC received:", usdcReceived / 1e6, "USDC");
        console2.log("SIMULATION PASSED");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    VALIDATION TESTS ON MAINNET
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkValidationTest is DexSwapModuleForkBase {
    function test_Validate_ValidParams_ReturnsTrue() external {
        bytes memory swapParams = _buildDefaultWethToUsdcParams();

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams);

        assertTrue(isValid, string.concat("Validation should pass, got: ", reason));
    }

    function test_Validate_ZeroSellAmount_ReturnsFalse() external view {
        bytes memory swapParams = _buildDefaultWethToUsdcParams();

        (bool isValid, string memory reason) = module.validate(WETH, 0, swapParams);

        assertFalse(isValid);
        assertEq(reason, "Zero sell amount");
    }

    function test_Validate_ZeroTargetToken_ReturnsFalse() external view {
        bytes memory swapParams = _buildSwapParams(address(0), FEE_MEDIUM, 100, ETH_USD_FEED, USDC_USD_FEED);

        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams);

        assertFalse(isValid);
        assertEq(reason, "Zero target token");
    }

    function test_Validate_SameInputAndOutputToken_ReturnsFalse() external view {
        bytes memory swapParams = _buildSwapParams(WETH, FEE_MEDIUM, 100, ETH_USD_FEED, ETH_USD_FEED);

        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams);

        assertFalse(isValid);
        assertEq(reason, "Same input and output token");
    }

    function test_Validate_MissingSellTokenPriceFeed_ReturnsFalse() external view {
        bytes memory swapParams = _buildSwapParams(USDC, FEE_MEDIUM, 100, address(0), USDC_USD_FEED);

        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams);

        assertFalse(isValid);
        assertEq(reason, "Missing sell token price feed");
    }

    function test_Validate_MissingBuyTokenPriceFeed_ReturnsFalse() external view {
        bytes memory swapParams = _buildSwapParams(USDC, FEE_MEDIUM, 100, ETH_USD_FEED, address(0));

        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams);

        assertFalse(isValid);
        assertEq(reason, "Missing buy token price feed");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY: NO RESIDUAL STATE
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkResidualStateTest is DexSwapModuleForkBase {
    function test_NoResidualState_AfterSuccessfulSwap() external {
        bytes memory swapParams = _buildDefaultWethToUsdcParams();

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);

        assertEq(IERC20(WETH).balanceOf(address(module)), 0, "No residual WETH");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "No residual USDC");
    }

    function test_NoResidualState_AfterConsecutiveSwaps() external {
        bytes memory swapParams = _buildDefaultWethToUsdcParams();

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        for (uint256 i = 0; i < 3; i++) {
            bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);
            assertTrue(success, "Each swap should succeed");

            assertEq(IERC20(WETH).balanceOf(address(module)), 0);
            assertEq(IERC20(USDC).balanceOf(address(module)), 0);
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    FULL LIFECYCLE SIMULATION
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkLifecycleTest is DexSwapModuleForkBase {
    function test_Lifecycle_FullSimulation() external {
        console2.log("========================================");
        console2.log("  DexSwapModule Mainnet Fork Simulation");
        console2.log("========================================");
        console2.log("");

        console2.log("[1] Module deployed at:", address(module));
        console2.log("[1] PaymentRails deployed at:", address(paymentRails));
        console2.log("[1] Immutable router:", UNISWAP_V3_ROUTER);
        console2.log("");

        bytes memory swapParams = _buildDefaultWethToUsdcParams();
        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        DataTypes.TokenConfig memory config = paymentRails.getTokenConfig(WETH);
        assertEq(config.actionType, "SWAP");
        assertEq(config.actionModule, address(module));
        assertTrue(config.enabled);
        console2.log("[2] WETH configured: actionType=SWAP, minBalance=1 ETH");
        console2.log("");

        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);
        assertTrue(success, "First swap should succeed");

        uint256 usdcReceived1 = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        console2.log("[3] Swap #1: 1 WETH -> USDC");
        console2.log("    USDC received:", usdcReceived1 / 1e6, "USDC");
        console2.log("");

        usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);
        assertTrue(success, "Second swap should succeed");

        uint256 usdcReceived2 = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        console2.log("[4] Swap #2: 1 WETH -> USDC");
        console2.log("    USDC received:", usdcReceived2 / 1e6, "USDC");
        console2.log("");

        uint256 wethAfter = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(paymentRails));

        console2.log("[5] Final PaymentRails state:");
        console2.log("    WETH:", wethAfter / 1e18, "ETH");
        console2.log("    USDC:", usdcAfter / 1e6, "USDC");
        console2.log("    Total USDC from swaps:", (usdcReceived1 + usdcReceived2) / 1e6, "USDC");
        console2.log("");

        assertEq(wethAfter, wethBefore - (WETH_SELL_AMOUNT * 2), "Should have sold 2 WETH");
        assertGt(usdcReceived1 + usdcReceived2, 2000e6, "Should have received > 2000 USDC total");

        assertEq(IERC20(WETH).balanceOf(address(module)), 0, "Module holds no WETH");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "Module holds no USDC");

        console2.log("========================================");
        console2.log("  ALL SIMULATIONS PASSED");
        console2.log("========================================");
    }
}

/*//////////////////////////////////////////////////////////////////////////
            ORACLE SLIPPAGE: MAINNET CHAINLINK FEED TESTS
//////////////////////////////////////////////////////////////////////////*/

/// @notice Validates oracle slippage enforcement against real Chainlink feeds on Ethereum mainnet.
/// @dev Uses ETH/USD, USDC/USD, and DAI/USD feeds at block 21_900_000.
contract DexSwapModuleForkOracleSlippageTest is DexSwapModuleForkBase {
    function test_Oracle_FeedsAreResponding() external view {
        (, int256 ethPrice,,,) = IChainlinkAggregatorV3(ETH_USD_FEED).latestRoundData();
        (, int256 usdcPrice,,,) = IChainlinkAggregatorV3(USDC_USD_FEED).latestRoundData();
        (, int256 daiPrice,,,) = IChainlinkAggregatorV3(DAI_USD_FEED).latestRoundData();

        assertGt(ethPrice, 0, "ETH/USD feed should return positive price");
        assertGt(usdcPrice, 0, "USDC/USD feed should return positive price");
        assertGt(daiPrice, 0, "DAI/USD feed should return positive price");

        assertEq(IChainlinkAggregatorV3(ETH_USD_FEED).decimals(), 8, "ETH/USD should be 8 decimals");
        assertEq(IChainlinkAggregatorV3(USDC_USD_FEED).decimals(), 8, "USDC/USD should be 8 decimals");
        assertEq(IChainlinkAggregatorV3(DAI_USD_FEED).decimals(), 8, "DAI/USD should be 8 decimals");

        console2.log("ETH/USD price:", uint256(ethPrice));
        console2.log("USDC/USD price:", uint256(usdcPrice));
        console2.log("DAI/USD price:", uint256(daiPrice));
    }

    function test_Oracle_EstimateOutput_WethToUsdc_RealisticPrice() external view {
        bytes memory params = _buildDefaultWethToUsdcParams();

        (uint256 estimated, address outputToken) = module.estimateOutput(WETH, WETH_SELL_AMOUNT, params);

        assertEq(outputToken, USDC, "Output token should be USDC");
        assertGt(estimated, 1000e6, "1 ETH should be worth > $1000 USDC");
        assertLt(estimated, 10_000e6, "1 ETH should be worth < $10000 USDC");

        console2.log("Oracle estimated output for 1 WETH -> USDC:", estimated / 1e6, "USDC");
    }

    function test_Oracle_EstimateOutput_UsdcToWeth_RealisticPrice() external view {
        bytes memory params = _buildDefaultUsdcToWethParams();

        (uint256 estimated, address outputToken) = module.estimateOutput(USDC, USDC_SELL_AMOUNT, params);

        assertEq(outputToken, WETH, "Output token should be WETH");
        assertGt(estimated, 0.1 ether, "2000 USDC should be worth > 0.1 ETH");
        assertLt(estimated, 5 ether, "2000 USDC should be worth < 5 ETH");

        console2.log("Oracle estimated output for 2000 USDC -> WETH (wei):", estimated);
    }

    function test_Oracle_EstimateOutput_DaiToUsdc_NearParity() external view {
        bytes memory params = _buildDefaultDaiToUsdcParams();

        (uint256 estimated, address outputToken) = module.estimateOutput(DAI, DAI_SELL_AMOUNT, params);

        assertEq(outputToken, USDC);
        // DAI and USDC are both ~$1, so 2000 DAI ≈ 2000 USDC
        assertGt(estimated, 1900e6, "2000 DAI should yield > 1900 USDC estimate");
        assertLt(estimated, 2100e6, "2000 DAI should yield < 2100 USDC estimate");

        console2.log("Oracle estimated output for 2000 DAI -> USDC:", estimated / 1e6, "USDC");
    }

    function test_Oracle_Validate_WethToUsdc_ReasonableSlippage_Passes() external {
        bytes memory params = _buildDefaultWethToUsdcParams();

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, params);

        assertTrue(isValid, string.concat("Should validate with oracle slippage, got: ", reason));
    }
}

/*//////////////////////////////////////////////////////////////////////////
        ORACLE SLIPPAGE: MAINNET SWAP WITH ORACLE ENFORCEMENT
//////////////////////////////////////////////////////////////////////////*/

/// @notice End-to-end swap execution with oracle slippage protection on mainnet.
contract DexSwapModuleForkOracleSwapTest is DexSwapModuleForkBase {
    function test_Oracle_WethToUsdc_SwapSucceeds_WithOracleProtection() external {
        // Configure with 1% slippage tolerance
        bytes memory params = _buildDefaultWethToUsdcParams();

        (uint256 estimated,) = module.estimateOutput(WETH, WETH_SELL_AMOUNT, params);
        uint256 oracleFloor = estimated * 9900 / 10_000;

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, params, true);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);
        assertTrue(success, "Oracle-protected swap should succeed");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        assertGe(usdcReceived, oracleFloor, "Should receive at least the oracle floor");

        console2.log("=== Oracle-Protected WETH -> USDC Swap ===");
        console2.log("Oracle estimate:", estimated / 1e6, "USDC");
        console2.log("Oracle floor (1% slippage):", oracleFloor / 1e6, "USDC");
        console2.log("Actual received:", usdcReceived / 1e6, "USDC");
        console2.log("PASSED");
    }

    function test_Oracle_DaiToUsdc_SwapSucceeds_WithOracleProtection() external {
        bytes memory params = _buildDefaultDaiToUsdcParams();

        (uint256 estimated,) = module.estimateOutput(DAI, DAI_SELL_AMOUNT, params);
        uint256 oracleFloor = estimated * 9950 / 10_000; // 0.5% slippage

        vm.prank(owner);
        paymentRails.configureToken(DAI, "SWAP", address(module), DAI_SELL_AMOUNT, params, true);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(DAI, DAI_SELL_AMOUNT);
        assertTrue(success, "DAI->USDC oracle-protected swap should succeed");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        assertGe(usdcReceived, oracleFloor, "Should receive at least oracle floor");

        console2.log("=== Oracle-Protected DAI -> USDC Swap ===");
        console2.log("Oracle estimate:", estimated / 1e6, "USDC");
        console2.log("Oracle floor (0.5% slippage):", oracleFloor / 1e6, "USDC");
        console2.log("Actual received:", usdcReceived / 1e6, "USDC");
        console2.log("PASSED");
    }

    function test_Oracle_WethToUsdc_DirectModuleCall_WithOracle() external {
        bytes memory params = _buildDefaultWethToUsdcParams();

        (uint256 estimated,) = module.estimateOutput(WETH, WETH_SELL_AMOUNT, params);
        uint256 oracleFloor = estimated * 9900 / 10_000;

        vm.startPrank(address(paymentRails));
        IERC20(WETH).approve(address(module), WETH_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(WETH, WETH_SELL_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success, "Direct module call with oracle should succeed");
        assertGe(result.amountOut, oracleFloor, "amountOut should be >= oracle floor");
        assertEq(result.outputToken, USDC);
    }
}

/*//////////////////////////////////////////////////////////////////////////
        ORACLE SLIPPAGE: FULL LIFECYCLE WITH ORACLE
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleForkOracleLifecycleTest is DexSwapModuleForkBase {
    function test_Lifecycle_OracleProtectedSwaps() external {
        console2.log("=============================================");
        console2.log("  Oracle-Protected Lifecycle Simulation");
        console2.log("=============================================");
        console2.log("");

        // Step 1: Read oracle prices
        (, int256 ethPrice,,,) = IChainlinkAggregatorV3(ETH_USD_FEED).latestRoundData();
        (, int256 usdcPrice,,,) = IChainlinkAggregatorV3(USDC_USD_FEED).latestRoundData();
        console2.log("[1] ETH/USD:", uint256(ethPrice) / 1e8, "USD");
        console2.log("[1] USDC/USD:", uint256(usdcPrice) / 1e8, "USD");
        console2.log("");

        // Step 2: Configure WETH→USDC with oracle protection (1% slippage)
        bytes memory params = _buildDefaultWethToUsdcParams();
        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, params, true);

        // Step 3: Get oracle estimate
        (uint256 estimated,) = module.estimateOutput(WETH, WETH_SELL_AMOUNT, params);
        uint256 oracleFloor = estimated * 9900 / 10_000;
        console2.log("[2] Oracle estimate for 1 WETH:", estimated / 1e6, "USDC");
        console2.log("[2] Oracle floor (1%):", oracleFloor / 1e6, "USDC");
        console2.log("");

        // Step 4: Validate before executing
        vm.prank(address(paymentRails));
        (bool isValid,) = module.validate(WETH, WETH_SELL_AMOUNT, params);
        assertTrue(isValid, "Pre-execution validation should pass");
        console2.log("[3] Pre-execution validation: PASSED");
        console2.log("");

        // Step 5: Execute the swap
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));
        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);
        assertTrue(success, "Oracle-protected swap should succeed");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        console2.log("[4] Swap executed:");
        console2.log("    USDC received:", usdcReceived / 1e6, "USDC");
        console2.log("    Above oracle floor:", usdcReceived >= oracleFloor ? "YES" : "NO");
        console2.log("");

        // Step 6: Verify no residual state
        assertEq(IERC20(WETH).balanceOf(address(module)), 0, "No residual WETH");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "No residual USDC");
        console2.log("[5] Module residual state: CLEAN");
        console2.log("");

        // Step 7: Verify oracle floor was respected
        assertGe(usdcReceived, oracleFloor, "Received should be >= oracle floor");

        console2.log("");
        console2.log("=============================================");
        console2.log("  ORACLE LIFECYCLE SIMULATION PASSED");
        console2.log("=============================================");
    }
}
