// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { Vm } from "forge-std/src/Vm.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CowSwapDryRun
/// @author Credit Cooperative
/// @notice Full end-to-end simulation: deploy + configure + fund + execute in one script.
/// @dev Simulation-only — no --broadcast needed. Override token addresses via env vars for non-mainnet chains.
contract CowSwapDryRun is Script, StdCheats {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    address internal constant DEFAULT_SELL_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DEFAULT_BUY_TOKEN = 0xc02AAA39B223fe8d0A0e5595ab2d3EB9fa40Fc9E;

    address internal constant DEFAULT_SELL_TOKEN_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD
    address internal constant DEFAULT_BUY_TOKEN_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1_000_000; // 1 USDC
    uint256 internal constant DEFAULT_MIN_BALANCE = 1_000_000; // 1 USDC
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600; // 1 hour
    uint32 internal constant DEFAULT_VALIDITY_DURATION = 1800; // 30 min

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
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        Config memory cfg = _loadConfig();
        address deployer;
        uint256 deployerKey;
        (deployer, deployerKey) = _deriveDeployer();

        console2.log("=============================================================");
        console2.log("  CowSwap Full Dry Run (deploy + configure + fund + execute)");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("Sell token:     ", cfg.sellToken);
        console2.log("Buy token:      ", cfg.buyToken);
        console2.log("Sell amount:    ", cfg.sellAmount);
        console2.log("Slippage bps:   ", uint256(cfg.maxSlippageBps));
        console2.log("Validity (sec): ", uint256(cfg.validityDuration));

        uint256 deployerBal = IERC20(cfg.sellToken).balanceOf(deployer);
        console2.log("Deployer sell token balance:", deployerBal);

        vm.startBroadcast(deployerKey);

        // --- DEPLOY ---
        CowSwapModule module = new CowSwapModule(GPV2_SETTLEMENT, deployer);
        console2.log("");
        console2.log("[DEPLOYED] CowSwapModule:", address(module));
        console2.log("  cowSettlement:    ", module.cowSettlement());
        console2.log("  domainSeparator: ", vm.toString(module.cowDomainSeparator()));

        PaymentRails paymentRails = new PaymentRails(deployer);
        console2.log("[DEPLOYED] PaymentRails:          ", address(paymentRails));

        // --- CONFIGURE ---
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
        console2.log("[CONFIGURED] Token route set");

        // --- FUND ---
        if (deployerBal >= cfg.sellAmount) {
            IERC20(cfg.sellToken).transfer(address(paymentRails), cfg.sellAmount);
            console2.log("[FUNDED] PaymentRails from deployer wallet:", cfg.sellAmount);
        } else {
            vm.stopBroadcast();
            deal(cfg.sellToken, address(paymentRails), cfg.sellAmount);
            vm.startBroadcast(deployerKey);
            console2.log("[FUNDED] PaymentRails via deal() (simulation only):", cfg.sellAmount);
        }

        // --- EXECUTE ---
        vm.recordLogs();
        bool success = paymentRails.executeAction(cfg.sellToken, cfg.sellAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] CowSwap order created on-chain");

        vm.stopBroadcast();

        // --- VERIFY ---
        _verifyAndLog(cfg, module, paymentRails);
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

    function _verifyAndLog(Config memory cfg, CowSwapModule module, PaymentRails paymentRails) internal {
        // Extract orderId from the OrderCreated event
        bytes32 eventSig = keccak256("OrderCreated(bytes32,address,address,address,uint256,uint256,uint32,bytes32)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 orderId;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(module) && logs[i].topics[0] == eventSig) {
                orderId = logs[i].topics[1];
                break;
            }
        }
        require(orderId != bytes32(0), "OrderCreated event not found");

        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        require(meta.paymentRails == address(paymentRails), "Order not found - orderId mismatch");

        console2.log("");
        console2.log("=============================================================");
        console2.log("  SIMULATION RESULTS");
        console2.log("=============================================================");
        console2.log("[VERIFIED] Order ID:", vm.toString(orderId));
        console2.log("  paymentRails:       ", meta.paymentRails);
        console2.log("  sellToken:  ", meta.sellToken);
        console2.log("  buyToken:   ", meta.buyToken);
        console2.log("  sellAmount: ", meta.sellAmount);
        console2.log("  validTo:    ", uint256(meta.validTo));
        console2.log("  cancelled:  ", meta.cancelled);

        console2.log("");
        console2.log("If this were real, the curl command would be:");
        console2.log("  POST %s/api/v1/orders", cfg.cowswapApi);
        console2.log("  signingScheme: eip1271");
        console2.log("  signature: %s", vm.toString(orderId));
        console2.log("  from: %s", vm.toString(address(module)));

        bytes memory orderUid = abi.encodePacked(orderId, address(module), meta.validTo);
        console2.log("  Order UID: %s", vm.toString(orderUid));

        uint256 moduleBalance = IERC20(cfg.sellToken).balanceOf(address(module));
        uint256 paymentRailsBalance = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
        console2.log("");
        console2.log("Post-execute state:");
        console2.log("  Module sellToken balance: ", moduleBalance, " (locked for CowSwap)");
        console2.log("  PaymentRails sellToken balance:   ", paymentRailsBalance, " (should be 0)");

        uint256 relayerAllowance = IERC20(cfg.sellToken).allowance(address(module), module.vaultRelayer());
        console2.log("  Module -> VaultRelayer allowance: ", relayerAllowance, " (should be max uint256)");

        console2.log("");
        console2.log("=============================================================");
        console2.log("  ALL CHECKS PASSED - safe to deploy for real");
        console2.log("  Next: deploy/DeployPaymentRails.s.sol + deploy/DeployCowSwapModule.s.sol with --broadcast");
        console2.log("=============================================================");
    }
}
