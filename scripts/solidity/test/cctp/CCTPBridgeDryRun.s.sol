// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { CCTPBridgeModule } from "../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CCTPBridgeDryRun
/// @author Credit Cooperative
/// @notice Full simulation: deploy + configure + fund + execute. Validates the entire CCTP bridge
///         flow without spending gas. CCTPBridgeModule is stateless — all routing params are in
///         PaymentRails's moduleParams.
///
///      Usage (Ethereum Sepolia -> Base Sepolia):
///        source .env && forge script scripts/solidity/test/cctp/CCTPBridgeDryRun.s.sol \
///          --rpc-url $SOURCE_RPC_URL -vvvv
///
///      Usage (Base mainnet -> Arbitrum):
///        source .env && \
///          TOKEN_MESSENGER_V2=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d \
///          SOURCE_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
///          DEST_DOMAIN=3 \
///          forge script scripts/solidity/test/cctp/CCTPBridgeDryRun.s.sol \
///            --rpc-url $BASE_RPC_URL -vvvv
contract CCTPBridgeDryRun is Script, StdCheats {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    // Sepolia testnet defaults
    address internal constant DEFAULT_TOKEN_MESSENGER = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address internal constant DEFAULT_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint32 internal constant DEFAULT_DEST_DOMAIN = 6; // Base
    uint32 internal constant DEFAULT_FINALITY = 2000; // standard
    uint256 internal constant DEFAULT_BRIDGE_AMOUNT = 10_000_000; // 10 USDC
    uint256 internal constant DEFAULT_MIN_BALANCE = 1_000_000; // 1 USDC
    uint16 internal constant DEFAULT_MAX_FEE_BPS = 0; // 0 bps = zero fee

    struct Config {
        address tokenMessenger;
        address usdc;
        uint32 destDomain;
        uint32 finality;
        uint256 bridgeAmount;
        uint256 minBalance;
        uint16 maxFeeBps;
        address mintRecipient;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        Config memory cfg = _loadConfig();
        (address deployer,) = _deriveDeployer();

        if (cfg.mintRecipient == address(0)) cfg.mintRecipient = deployer;

        console2.log("=============================================================");
        console2.log("  CCTP Bridge Dry Run");
        console2.log("=============================================================");
        console2.log("Chain ID:          ", block.chainid);
        console2.log("Deployer:          ", deployer);
        console2.log("TokenMessengerV2:  ", cfg.tokenMessenger);
        console2.log("USDC:              ", cfg.usdc);
        console2.log("Dest domain:       ", uint256(cfg.destDomain));
        console2.log("Finality:          ", uint256(cfg.finality));
        console2.log("Bridge amount:     ", cfg.bridgeAmount);
        console2.log("Max fee bps:       ", uint256(cfg.maxFeeBps));
        console2.log("Mint recipient:    ", cfg.mintRecipient);
        console2.log("=============================================================");

        vm.startPrank(deployer);

        // --- Deploy ---
        PaymentRails paymentRails = new PaymentRails(deployer);
        CCTPBridgeModule module = new CCTPBridgeModule(cfg.tokenMessenger, cfg.usdc);
        console2.log("[DEPLOYED] PaymentRails:     ", address(paymentRails));
        console2.log("[DEPLOYED] CCTPBridgeModule: ", address(module));

        // --- Configure PaymentRails (all routing info in moduleParams) ---
        bytes memory moduleParams = module.encodeParams(
            DataTypes.CCTPBridgeParams({
                destinationDomain: cfg.destDomain,
                mintRecipient: bytes32(uint256(uint160(cfg.mintRecipient))),
                destinationCaller: bytes32(0),
                maxFeeBps: cfg.maxFeeBps,
                minFinalityThreshold: cfg.finality,
                hookData: bytes("")
            })
        );
        paymentRails.configureToken(cfg.usdc, "CCTP_BRIDGE", address(module), cfg.minBalance, moduleParams, true);
        console2.log("[CONFIGURED] USDC -> CCTP_BRIDGE on PaymentRails");

        vm.stopPrank();

        // --- Fund PaymentRails ---
        deal(cfg.usdc, address(paymentRails), cfg.bridgeAmount);
        console2.log("[FUNDED] PaymentRails via deal(): %s", vm.toString(cfg.bridgeAmount));

        // --- Execute ---
        vm.prank(deployer);
        bool success = paymentRails.executeAction(cfg.usdc, cfg.bridgeAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] depositForBurn called");

        // --- Verify ---
        _verify(cfg, module, paymentRails);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _verify(Config memory cfg, CCTPBridgeModule module, PaymentRails paymentRails) internal view {
        uint256 moduleBalance = IERC20(cfg.usdc).balanceOf(address(module));
        uint256 paymentRailsBalance = IERC20(cfg.usdc).balanceOf(address(paymentRails));

        console2.log("");
        console2.log("=============================================================");
        console2.log("  VERIFICATION");
        console2.log("=============================================================");
        console2.log("Module USDC balance: ", moduleBalance, " (expected: 0, burned by CCTP)");
        console2.log("PaymentRails USDC balance:   ", paymentRailsBalance, " (expected: 0, transferred out)");

        require(moduleBalance == 0, "Module still holds USDC");
        require(paymentRailsBalance == 0, "PaymentRails still holds USDC");

        console2.log("");
        console2.log("=============================================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("  Safe to deploy for real with --broadcast");
        console2.log("=============================================================");
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.tokenMessenger = vm.envOr("TOKEN_MESSENGER_V2", DEFAULT_TOKEN_MESSENGER);
        cfg.usdc = vm.envOr("SOURCE_USDC", DEFAULT_USDC);
        cfg.destDomain = uint32(vm.envOr("DEST_DOMAIN", uint256(DEFAULT_DEST_DOMAIN)));
        cfg.finality = uint32(vm.envOr("FINALITY", uint256(DEFAULT_FINALITY)));
        cfg.bridgeAmount = vm.envOr("BRIDGE_AMOUNT", DEFAULT_BRIDGE_AMOUNT);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.maxFeeBps = uint16(vm.envOr("MAX_FEE_BPS", uint256(DEFAULT_MAX_FEE_BPS)));
        cfg.mintRecipient = vm.envOr("MINT_RECIPIENT", address(0));
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
