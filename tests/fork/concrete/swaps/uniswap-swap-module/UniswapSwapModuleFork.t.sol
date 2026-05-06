// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, console2 } from "forge-std/src/Test.sol";
import { UniswapSwapModule } from "../../../../../src/modules/swaps/UniswapSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal interface for Uniswap V3 SwapRouter `exactInputSingle`.
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapSwapModuleForkBase
/// @notice Shared setup for UniswapSwapModule fork tests against Ethereum mainnet.
/// @dev Run with: forge test --match-contract UniswapSwapModuleFork --fork-url $ETHEREUM_RPC_URL -vvv
abstract contract UniswapSwapModuleForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event SwapExecuted(
        address indexed paymentRails,
        address indexed sellToken,
        address buyToken,
        uint256 amountIn,
        uint256 amountOut,
        address router
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
    event RouterAdded(address indexed router);

    /*//////////////////////////////////////////////////////////////////////////
                                MAINNET CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint256 internal constant WETH_SELL_AMOUNT = 1 ether;
    uint256 internal constant USDC_SELL_AMOUNT = 2000e6;
    uint256 internal constant DAI_SELL_AMOUNT = 2000e18;

    uint24 internal constant FEE_LOW = 500;
    uint24 internal constant FEE_MEDIUM = 3000;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    UniswapSwapModule internal module;
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
        module = new UniswapSwapModule(owner);
        paymentRails = new PaymentRails(owner);
        module.addRouter(UNISWAP_V3_ROUTER);
        vm.stopPrank();

        deal(WETH, address(paymentRails), WETH_SELL_AMOUNT * 10);
        deal(USDC, address(paymentRails), USDC_SELL_AMOUNT * 10);
        deal(DAI, address(paymentRails), DAI_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildSwapParams(address targetToken) internal view returns (bytes memory) {
        return module.encodeParams(DataTypes.UniswapSwapParams({ targetToken: targetToken }));
    }

    function _buildUniswapCalldata(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            IUniswapV3Router.exactInputSingle,
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _buildExecutionData(
        address router,
        uint256 minAmountOut,
        bytes memory routerCalldata
    )
        internal
        view
        returns (bytes memory)
    {
        return module.encodeExecutionData(
            DataTypes.UniswapSwapExecutionData({
                router: router,
                minAmountOut: minAmountOut,
                deadline: block.timestamp + 300,
                routerCalldata: routerCalldata
            })
        );
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        CONSTRUCTOR / SETUP TESTS
//////////////////////////////////////////////////////////////////////////*/

contract UniswapSwapModuleForkSetupTest is UniswapSwapModuleForkBase {
    function test_Setup_ModuleDeployedCorrectly() external view {
        assertEq(module.owner(), owner);
        assertTrue(module.isRouterAllowed(UNISWAP_V3_ROUTER));
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

contract UniswapSwapModuleForkWethToUsdcTest is UniswapSwapModuleForkBase {
    function test_Simulate_WethToUsdc_ViaPaymentRails() external {
        bytes memory swapParams = _buildSwapParams(USDC);

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);

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
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        vm.startPrank(address(paymentRails));
        IERC20(WETH).approve(address(module), WETH_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(WETH, WETH_SELL_AMOUNT, swapParams, executionData);
        vm.stopPrank();

        assertTrue(result.success, "Module execute should succeed");
        assertEq(result.outputToken, USDC, "Output token should be USDC");
        assertGt(result.amountOut, 0, "amountOut should be > 0");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        assertEq(result.amountOut, usdcReceived, "amountOut should match actual balance diff");

        address routerUsed = abi.decode(result.data, (address));
        assertEq(routerUsed, UNISWAP_V3_ROUTER, "Should report correct router");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    MAINNET SIMULATION: USDC → WETH
//////////////////////////////////////////////////////////////////////////*/

contract UniswapSwapModuleForkUsdcToWethTest is UniswapSwapModuleForkBase {
    function test_Simulate_UsdcToWeth_ViaPaymentRails() external {
        bytes memory swapParams = _buildSwapParams(WETH);
        bytes memory routerCalldata =
            _buildUniswapCalldata(USDC, WETH, FEE_MEDIUM, address(paymentRails), USDC_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        vm.prank(owner);
        paymentRails.configureToken(USDC, "SWAP", address(module), USDC_SELL_AMOUNT, swapParams, true);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT, executionData);
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

contract UniswapSwapModuleForkDaiToUsdcTest is UniswapSwapModuleForkBase {
    function test_Simulate_DaiToUsdc_ViaPaymentRails() external {
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(DAI, USDC, FEE_LOW, address(paymentRails), DAI_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        vm.prank(owner);
        paymentRails.configureToken(DAI, "SWAP", address(module), DAI_SELL_AMOUNT, swapParams, true);

        uint256 daiBefore = IERC20(DAI).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(DAI, DAI_SELL_AMOUNT, executionData);
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

contract UniswapSwapModuleForkValidationTest is UniswapSwapModuleForkBase {
    function test_Validate_ValidParams_ReturnsTrue() external {
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams, executionData);

        assertTrue(isValid, string.concat("Validation should pass, got: ", reason));
    }

    function test_Validate_UnwhitelistedRouter_ReturnsFalse() external {
        address fakeRouter = makeAddr("fakeRouter");
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory executionData = _buildExecutionData(fakeRouter, 1, "");

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams, executionData);

        assertFalse(isValid);
        assertEq(reason, "Router not allowed");
    }

    function test_Validate_ExpiredDeadline_ReturnsFalse() external {
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory executionData = module.encodeExecutionData(
            DataTypes.UniswapSwapExecutionData({
                router: UNISWAP_V3_ROUTER, minAmountOut: 1, deadline: block.timestamp - 1, routerCalldata: ""
            })
        );

        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, swapParams, executionData);

        assertFalse(isValid);
        assertEq(reason, "Deadline expired");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY: SLIPPAGE ENFORCEMENT
//////////////////////////////////////////////////////////////////////////*/

contract UniswapSwapModuleForkSlippageTest is UniswapSwapModuleForkBase {
    function test_Simulate_SlippageExceeded_Reverts() external {
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 0);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, type(uint256).max, routerCalldata);

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);
        assertFalse(success, "Should fail due to slippage protection");

        assertEq(
            IERC20(WETH).balanceOf(address(paymentRails)),
            WETH_SELL_AMOUNT * 10,
            "PaymentRails should retain all WETH after slippage revert"
        );
    }

    function test_Simulate_ReasonableSlippage_Succeeds() external {
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1000e6, routerCalldata);

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);
        assertTrue(success, "Swap with reasonable slippage should succeed");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY: ROUTER WHITELIST
//////////////////////////////////////////////////////////////////////////*/

contract UniswapSwapModuleForkRouterWhitelistTest is UniswapSwapModuleForkBase {
    function test_RouterWhitelist_UnlistedRouter_FailsGracefully() external {
        address unlisted = makeAddr("unlisted");
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(unlisted, 1, routerCalldata);

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);
        assertFalse(success, "Unlisted router should fail");

        assertEq(IERC20(WETH).balanceOf(address(paymentRails)), WETH_SELL_AMOUNT * 10);
    }

    function test_RouterWhitelist_AddAndRemove() external {
        address newRouter = makeAddr("newRouter");
        vm.etch(newRouter, hex"01");

        vm.startPrank(owner);

        module.addRouter(newRouter);
        assertTrue(module.isRouterAllowed(newRouter));

        module.removeRouter(newRouter);
        assertFalse(module.isRouterAllowed(newRouter));

        vm.stopPrank();
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    SECURITY: NO RESIDUAL STATE
//////////////////////////////////////////////////////////////////////////*/

contract UniswapSwapModuleForkResidualStateTest is UniswapSwapModuleForkBase {
    function test_NoResidualState_AfterSuccessfulSwap() external {
        bytes memory swapParams = _buildSwapParams(USDC);
        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);

        assertEq(IERC20(WETH).balanceOf(address(module)), 0, "No residual WETH");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "No residual USDC");
    }

    function test_NoResidualState_AfterConsecutiveSwaps() external {
        bytes memory swapParams = _buildSwapParams(USDC);

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, swapParams, true);

        for (uint256 i = 0; i < 3; i++) {
            bytes memory routerCalldata =
                _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
            bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

            bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);
            assertTrue(success, "Each swap should succeed");

            assertEq(IERC20(WETH).balanceOf(address(module)), 0);
            assertEq(IERC20(USDC).balanceOf(address(module)), 0);
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    FULL LIFECYCLE SIMULATION
//////////////////////////////////////////////////////////////////////////*/

contract UniswapSwapModuleForkLifecycleTest is UniswapSwapModuleForkBase {
    function test_Lifecycle_FullSimulation() external {
        console2.log("========================================");
        console2.log("  UniswapSwapModule Mainnet Fork Simulation");
        console2.log("========================================");
        console2.log("");

        console2.log("[1] Module deployed at:", address(module));
        console2.log("[1] PaymentRails deployed at:", address(paymentRails));
        console2.log("[1] Uniswap V3 Router whitelisted:", UNISWAP_V3_ROUTER);
        console2.log("");

        bytes memory swapParams = _buildSwapParams(USDC);
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

        bytes memory routerCalldata =
            _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        bytes memory executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);
        assertTrue(success, "First swap should succeed");

        uint256 usdcReceived1 = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        console2.log("[3] Swap #1: 1 WETH -> USDC");
        console2.log("    USDC received:", usdcReceived1 / 1e6, "USDC");
        console2.log("");

        usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        routerCalldata = _buildUniswapCalldata(WETH, USDC, FEE_MEDIUM, address(paymentRails), WETH_SELL_AMOUNT, 1);
        executionData = _buildExecutionData(UNISWAP_V3_ROUTER, 1, routerCalldata);

        success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT, executionData);
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
