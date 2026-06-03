// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { DexSwapModule } from "../../../../src/modules/swaps/DexSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DexSwapSmoke
/// @author Credit Cooperative
/// @notice Smoke test for the DexSwapModule against already-deployed contracts.
/// @dev Requires PAYMENT_RAILS_ADDRESS and MODULE_ADDRESS env vars. Override token addresses for non-mainnet chains.
///      Set SKIP_CONFIGURE=true / SKIP_FUND=true for subsequent runs.
///
///      Usage:
///        source .env && forge script scripts/solidity/test/dex-swap/DexSwapSmoke.s.sol \
///          --rpc-url $ETHEREUM_RPC_URL --broadcast -vvvv
contract DexSwapSmoke is Script {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant DEFAULT_SELL_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address internal constant DEFAULT_BUY_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    address internal constant DEFAULT_SELL_TOKEN_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD
    address internal constant DEFAULT_BUY_TOKEN_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1_000_000; // 1 USDC
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 500; // 5%
    uint24 internal constant DEFAULT_FEE = 500; // Uniswap 0.05% pool
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600; // 1 hour
    uint256 internal constant DEFAULT_MIN_BALANCE = 1_000_000; // 1 USDC
    uint256 internal constant DEFAULT_SWAP_DEADLINE = 300; // 5 minutes

    /*//////////////////////////////////////////////////////////////////////////
                                    STRUCTS
    //////////////////////////////////////////////////////////////////////////*/

    struct Config {
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
        bool skipConfigure;
        bool skipFund;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        address paymentRailsAddr = vm.envAddress("PAYMENT_RAILS_ADDRESS");
        address moduleAddr = vm.envAddress("MODULE_ADDRESS");

        PaymentRails paymentRails = PaymentRails(paymentRailsAddr);
        DexSwapModule module = DexSwapModule(moduleAddr);

        Config memory cfg = _loadConfig();
        (address deployer, uint256 deployerKey) = _deriveDeployer();

        console2.log("=============================================================");
        console2.log("  DexSwap Smoke Test");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("PaymentRails:   ", paymentRailsAddr);
        console2.log("Module:         ", moduleAddr);
        console2.log("Router:         ", module.router());
        console2.log("Sell token:     ", cfg.sellToken);
        console2.log("Buy token:      ", cfg.buyToken);
        console2.log("Sell amount:    ", cfg.sellAmount);
        console2.log("Slippage bps:   ", uint256(cfg.maxSlippageBps));
        console2.log("Pool fee:       ", uint256(cfg.fee));
        console2.log("Swap deadline:  ", cfg.swapDeadlineSeconds);
        console2.log("Skip configure: ", cfg.skipConfigure);
        console2.log("Skip fund:      ", cfg.skipFund);
        console2.log("=============================================================");

        _preflight(cfg, module, paymentRails, deployer);

        vm.startBroadcast(deployerKey);

        if (!cfg.skipConfigure) {
            _configure(cfg, module, paymentRails);
        }

        if (!cfg.skipFund) {
            IERC20(cfg.sellToken).transfer(paymentRailsAddr, cfg.sellAmount);
            console2.log("[FUNDED] PaymentRails with:", cfg.sellAmount);
        }

        uint256 buyTokenBefore = IERC20(cfg.buyToken).balanceOf(paymentRailsAddr);

        bool success = paymentRails.executeAction(cfg.sellToken, cfg.sellAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] DexSwap completed");

        vm.stopBroadcast();

        uint256 buyTokenAfter = IERC20(cfg.buyToken).balanceOf(paymentRailsAddr);
        uint256 received = buyTokenAfter - buyTokenBefore;

        console2.log("");
        console2.log("=============================================================");
        console2.log("  BROADCAST COMPLETE");
        console2.log("=============================================================");
        console2.log("Buy token received at PaymentRails:", received);
        require(received > 0, "No buy token received");
        console2.log("[VERIFIED] Swap produced output");

        uint256 moduleSellBalance = IERC20(cfg.sellToken).balanceOf(moduleAddr);
        console2.log("Module sell token leftover:        ", moduleSellBalance, " (expected: 0)");
        console2.log("=============================================================");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _loadConfig() internal view returns (Config memory cfg) {
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

        string memory f = "false";
        cfg.skipConfigure = keccak256(bytes(vm.envOr("SKIP_CONFIGURE", f))) == keccak256("true");
        cfg.skipFund = keccak256(bytes(vm.envOr("SKIP_FUND", f))) == keccak256("true");
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

    function _preflight(
        Config memory cfg,
        DexSwapModule module,
        PaymentRails paymentRails,
        address deployer
    )
        internal
        view
    {
        require(address(module).code.length > 0, "MODULE_ADDRESS is not a contract");
        require(address(paymentRails).code.length > 0, "PAYMENT_RAILS_ADDRESS is not a contract");

        require(module.router() != address(0), "Module router is zero");
        console2.log("[OK] Module router:", module.router());

        if (!cfg.skipConfigure) {
            address paymentRailsOwner = paymentRails.owner();
            require(paymentRailsOwner == deployer, "Deployer is not PaymentRails owner - cannot configure");
            console2.log("[OK] Deployer is PaymentRails owner");
        }

        if (!cfg.skipFund) {
            uint256 balance = IERC20(cfg.sellToken).balanceOf(deployer);
            require(balance >= cfg.sellAmount, "Deployer has insufficient sell token");
            console2.log("[OK] Deployer sell token balance:", balance);
        } else {
            uint256 paymentRailsBalance = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
            require(paymentRailsBalance >= cfg.sellAmount, "PaymentRails has insufficient sell token balance");
            console2.log("[OK] PaymentRails sell token balance:", paymentRailsBalance);
        }
    }

    function _configure(Config memory cfg, DexSwapModule module, PaymentRails paymentRails) internal {
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
        console2.log("[CONFIGURED] %s -> SWAP", vm.toString(cfg.sellToken));
    }
}
