// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CowSwapSmoke
/// @author Credit Cooperative
/// @notice Smoke test for the CowSwap module against already-deployed contracts.
/// @dev Requires PAYMENT_RAILS_ADDRESS and MODULE_ADDRESS env vars. Override token addresses for non-mainnet chains.
/// Set SKIP_CONFIGURE=true / SKIP_FUND=true for subsequent runs.
contract CowSwapSmoke is Script {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant DEFAULT_SELL_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address internal constant DEFAULT_BUY_TOKEN = 0xc02AAA39B223fe8d0A0e5595ab2d3EB9fa40Fc9E; // WETH

    address internal constant DEFAULT_SELL_TOKEN_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD
    address internal constant DEFAULT_BUY_TOKEN_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1_000_000; // 1 USDC
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600; // 1 hour
    uint256 internal constant DEFAULT_MIN_BALANCE = 1_000_000; // 1 USDC
    uint32 internal constant DEFAULT_VALIDITY_DURATION = 1800; // 30 minutes

    /*//////////////////////////////////////////////////////////////////////////
                                    STRUCTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Packed config to avoid stack-too-deep.
    struct Config {
        address sellToken;
        address buyToken;
        address sellTokenFeed;
        address buyTokenFeed;
        uint256 sellAmount;
        uint16 maxSlippageBps;
        uint256 maxStaleness;
        uint256 minBalance;
        uint32 validityDuration;
        bytes32 appData;
        string cowswapApi;
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
        CowSwapModule module = CowSwapModule(moduleAddr);

        Config memory cfg = _loadConfig();

        address deployer;
        uint256 deployerKey;
        (deployer, deployerKey) = _deriveDeployer();

        console2.log("=============================================================");
        console2.log("  CowSwap Smoke Test");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("PaymentRails:           ", paymentRailsAddr);
        console2.log("Module:         ", moduleAddr);
        console2.log("Sell token:     ", cfg.sellToken);
        console2.log("Buy token:      ", cfg.buyToken);
        console2.log("Sell amount:    ", cfg.sellAmount);
        console2.log("Slippage bps:   ", uint256(cfg.maxSlippageBps));
        console2.log("Validity (sec): ", uint256(cfg.validityDuration));
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

        bool success = paymentRails.executeAction(cfg.sellToken, cfg.sellAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] CowSwap order created on-chain");

        vm.stopBroadcast();

        // orderId depends on mined block.timestamp — use cowswap-submit.sh to parse broadcast JSON
        console2.log("");
        console2.log("=============================================================");
        console2.log("  BROADCAST COMPLETE");
        console2.log("=============================================================");
        console2.log("");
        console2.log("  Submit the order to CowSwap API:");
        console2.log("    bash scripts/solidity/test/cowswap/cowswap-submit.sh");
        console2.log("");
        console2.log("  Or auto-submit:");
        console2.log("    AUTO_SUBMIT=true bash scripts/solidity/test/cowswap/cowswap-submit.sh");
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
        cfg.maxStaleness = vm.envOr("MAX_STALENESS", DEFAULT_MAX_STALENESS);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.validityDuration = uint32(vm.envOr("VALIDITY_DURATION", uint256(DEFAULT_VALIDITY_DURATION)));

        string memory defaultApi = "https://api.cow.fi/mainnet";
        cfg.cowswapApi = vm.envOr("COWSWAP_API", defaultApi);

        string memory defaultFalse = "false";
        cfg.skipConfigure = keccak256(bytes(vm.envOr("SKIP_CONFIGURE", defaultFalse))) == keccak256("true");
        cfg.skipFund = keccak256(bytes(vm.envOr("SKIP_FUND", defaultFalse))) == keccak256("true");

        cfg.appData = bytes32(0);
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
        CowSwapModule module,
        PaymentRails paymentRails,
        address deployer
    )
        internal
        view
    {
        require(address(module).code.length > 0, "MODULE_ADDRESS is not a contract");
        require(address(paymentRails).code.length > 0, "PAYMENT_RAILS_ADDRESS is not a contract");
        require(module.cowSettlement() != address(0), "Module cowSettlement is zero");
        console2.log("[OK] Module cowSettlement:", module.cowSettlement());

        if (!cfg.skipConfigure) {
            address paymentRailsOwner = paymentRails.owner();
            require(paymentRailsOwner == deployer, "Deployer is not PaymentRails owner - cannot configure");
            console2.log("[OK] Deployer is PaymentRails owner");
        }

        if (!cfg.skipFund) {
            uint256 balance = IERC20(cfg.sellToken).balanceOf(deployer);
            require(balance >= cfg.sellAmount, "Deployer has insufficient sell token");
            console2.log("[OK] Deployer sell token balance:", balance);
        }

        if (cfg.skipFund) {
            uint256 paymentRailsBalance = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
            require(paymentRailsBalance >= cfg.sellAmount, "PaymentRails has insufficient sell token balance");
            console2.log("[OK] PaymentRails sell token balance:", paymentRailsBalance);
        }
    }

    function _configure(Config memory cfg, CowSwapModule module, PaymentRails paymentRails) internal {
        bytes memory moduleParams = module.encodeParams(
            DataTypes.CowSwapParams({
                targetToken: cfg.buyToken,
                maxSlippageBps: cfg.maxSlippageBps,
                sellTokenPriceFeed: cfg.sellTokenFeed,
                buyTokenPriceFeed: cfg.buyTokenFeed,
                maxStaleness: cfg.maxStaleness,
                validityDuration: cfg.validityDuration,
                appData: cfg.appData
            })
        );

        paymentRails.configureToken(cfg.sellToken, "COWSWAP", address(module), cfg.minBalance, moduleParams, true);
        console2.log("[CONFIGURED] %s -> COWSWAP", vm.toString(cfg.sellToken));
    }
}
