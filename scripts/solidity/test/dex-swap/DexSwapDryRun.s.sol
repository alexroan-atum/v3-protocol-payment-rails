// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { DexSwapModule } from "../../../../src/modules/swaps/DexSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DexSwapDryRun
/// @author Credit Cooperative
/// @notice Full end-to-end simulation: deploy + configure + fund + execute in one script.
/// @dev Simulation-only — no --broadcast needed. Override token addresses via env vars for non-mainnet chains.
///
///      Usage (Ethereum mainnet fork):
///        source .env && forge script scripts/solidity/test/dex-swap/DexSwapDryRun.s.sol \
///          --rpc-url $ETHEREUM_RPC_URL -vvvv
///
///      Usage (custom pair):
///        source .env && SELL_TOKEN=0x... BUY_TOKEN=0x... ROUTER=0x... \
///          forge script scripts/solidity/test/dex-swap/DexSwapDryRun.s.sol \
///            --rpc-url $ETHEREUM_RPC_URL -vvvv
contract DexSwapDryRun is Script, StdCheats {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    // Uniswap V3 SwapRouter on Ethereum mainnet
    address internal constant DEFAULT_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address internal constant DEFAULT_SELL_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address internal constant DEFAULT_BUY_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC

    address internal constant DEFAULT_SELL_TOKEN_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD
    address internal constant DEFAULT_BUY_TOKEN_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1e15; // 0.001 WETH
    uint256 internal constant DEFAULT_MIN_BALANCE = 1e15; // 0.001 WETH
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 500; // 5%
    uint24 internal constant DEFAULT_FEE = 500; // Uniswap 0.05% pool
    uint256 internal constant DEFAULT_MAX_STALENESS = 86_400; // 24 hours (generous for fork simulations)
    uint256 internal constant DEFAULT_SWAP_DEADLINE = 300; // 5 minutes

    struct Config {
        address routerAddr;
        address sellToken;
        address buyToken;
        address sellTokenFeed;
        address buyTokenFeed;
        uint256 sellAmount;
        uint16 maxSlippageBps;
        uint24 fee;
        uint256 maxStaleness;
        uint256 minBalance;
        uint256 swapDeadlineSeconds;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        Config memory cfg = _loadConfig();
        (address deployer,) = _deriveDeployer();

        console2.log("=============================================================");
        console2.log("  DexSwap Full Dry Run (deploy + configure + fund + execute)");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("Router:         ", cfg.routerAddr);
        console2.log("Sell token:     ", cfg.sellToken);
        console2.log("Buy token:      ", cfg.buyToken);
        console2.log("Sell amount:    ", cfg.sellAmount);
        console2.log("Slippage bps:   ", uint256(cfg.maxSlippageBps));
        console2.log("Pool fee:       ", uint256(cfg.fee));
        console2.log("Swap deadline:  ", cfg.swapDeadlineSeconds);

        vm.startPrank(deployer);

        // --- Deploy ---
        PaymentRails paymentRails = new PaymentRails(deployer);
        console2.log("[DEPLOYED] PaymentRails:   ", address(paymentRails));

        // sequencerUptimeFeed = address(0) and gracePeriod = 0 for L1 dry run
        DexSwapModule module = new DexSwapModule(cfg.routerAddr, address(0), 0);
        console2.log("[DEPLOYED] DexSwapModule:  ", address(module));
        console2.log("  router:          ", module.router());

        // --- Configure ---
        bytes memory moduleParams = module.encodeParams(
            DataTypes.DexSwapParams({
                targetToken: cfg.buyToken,
                fee: cfg.fee,
                maxSlippageBps: cfg.maxSlippageBps,
                sellTokenPriceFeed: cfg.sellTokenFeed,
                buyTokenPriceFeed: cfg.buyTokenFeed,
                maxStaleness: cfg.maxStaleness,
                swapDeadlineSeconds: cfg.swapDeadlineSeconds
            })
        );
        paymentRails.configureToken(cfg.sellToken, "SWAP", address(module), cfg.minBalance, moduleParams, true);
        console2.log("[CONFIGURED] Token route set");

        vm.stopPrank();

        // --- Fund PaymentRails ---
        deal(cfg.sellToken, address(paymentRails), cfg.sellAmount);
        console2.log("[FUNDED] PaymentRails via deal():", cfg.sellAmount);

        uint256 buyTokenBefore = IERC20(cfg.buyToken).balanceOf(address(paymentRails));

        vm.prank(deployer);
        bool success = paymentRails.executeAction(cfg.sellToken, cfg.sellAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] DexSwap completed");

        // --- Verify ---
        _verify(cfg, module, paymentRails, buyTokenBefore);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _verify(
        Config memory cfg,
        DexSwapModule module,
        PaymentRails paymentRails,
        uint256 buyTokenBefore
    )
        internal
        view
    {
        uint256 moduleSellBalance = IERC20(cfg.sellToken).balanceOf(address(module));
        uint256 paymentRailsSellBalance = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
        uint256 buyTokenAfter = IERC20(cfg.buyToken).balanceOf(address(paymentRails));
        uint256 received = buyTokenAfter - buyTokenBefore;

        console2.log("");
        console2.log("=============================================================");
        console2.log("  VERIFICATION");
        console2.log("=============================================================");
        console2.log("Module sell token leftover:      ", moduleSellBalance, " (expected: 0)");
        console2.log("PaymentRails sell token balance: ", paymentRailsSellBalance, " (expected: 0)");
        console2.log("PaymentRails buy token received: ", received);

        require(moduleSellBalance == 0, "Module still holds sell tokens");
        require(paymentRailsSellBalance == 0, "PaymentRails still holds sell tokens");
        require(received > 0, "No buy token received");

        console2.log("");
        console2.log("=============================================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("  Safe to deploy for real with --broadcast");
        console2.log("  Next: deploy/DeployPaymentRails.s.sol + deploy/DeployDexSwapModule.s.sol");
        console2.log("=============================================================");
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.routerAddr = vm.envOr("ROUTER", DEFAULT_ROUTER);
        cfg.sellToken = vm.envOr("SELL_TOKEN", DEFAULT_SELL_TOKEN);
        cfg.buyToken = vm.envOr("BUY_TOKEN", DEFAULT_BUY_TOKEN);
        cfg.sellTokenFeed = vm.envOr("SELL_TOKEN_FEED", DEFAULT_SELL_TOKEN_FEED);
        cfg.buyTokenFeed = vm.envOr("BUY_TOKEN_FEED", DEFAULT_BUY_TOKEN_FEED);
        cfg.sellAmount = vm.envOr("SELL_AMOUNT", DEFAULT_SELL_AMOUNT);
        cfg.maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(DEFAULT_SLIPPAGE_BPS)));
        cfg.fee = uint24(vm.envOr("POOL_FEE", uint256(DEFAULT_FEE)));
        cfg.maxStaleness = vm.envOr("MAX_STALENESS", DEFAULT_MAX_STALENESS);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.swapDeadlineSeconds = vm.envOr("SWAP_DEADLINE", DEFAULT_SWAP_DEADLINE);
    }

    function _deriveDeployer() internal returns (address deployer, uint256 deployerKey) {
        address ethFrom = vm.envOr("ETH_FROM", address(0));
        if (ethFrom != address(0)) {
            deployer = ethFrom;
            deployerKey = vm.envUint("PRIVATE_KEY");
        } else {
            string memory defaultMnemonic = "test test test test test test test test test test test junk";
            string memory mnemonic = vm.envOr("MNEMONIC", defaultMnemonic);
            (deployer, deployerKey) = deriveRememberKey(mnemonic, 0);
        }
    }
}
