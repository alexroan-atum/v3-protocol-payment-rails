// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";

import { PaymentRails } from "../../../src/core/PaymentRails.sol";
import { ForwardModule } from "../../../src/modules/forwards/ForwardModule.sol";
import { CCTPBridgeModule } from "../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../src/types/DataTypes.sol";

/// @title DeploySepoliaTestSetup
/// @author Credit Cooperative
/// @notice One-shot Sepolia bring-up: deploys PaymentRails + ForwardModule + CCTPBridgeModule, whitelists
///         Base Sepolia on the bridge module, and configures USDC -> BRIDGE and TEST_TOKEN -> FORWARD.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeploySepoliaTestSetup.s.sol \
///          --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///      Required env: ETH_FROM + PRIVATE_KEY (or MNEMONIC). Optional overrides:
///        USDC_MIN_BALANCE (default 1_000_000 = 1 USDC)
///        FORWARD_MIN_BALANCE (default 0)
///        CCTP_MAX_FEE (default 0 = standard transfer, free)
///        CCTP_FINALITY (default 2000 = finalized; 1000 = fast)
contract DeploySepoliaTestSetup is Script {
    // Sepolia CCTP V2 (Circle official)
    address internal constant TOKEN_MESSENGER_V2 = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address internal constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    // Base Sepolia
    uint32 internal constant BASE_SEPOLIA_DOMAIN = 6;

    // Bridge destination wiring (per user request)
    address internal constant CCTP_MINT_RECIPIENT = 0xf44B95991CaDD73ed769454A03b3820997f00873;
    address internal constant CCTP_DESTINATION_CALLER = 0x474f2216ED9BC9958Cc688B4151b9f54E49e1470;

    // Forward token + destination (per user request)
    address internal constant FORWARD_TOKEN = 0xbF99CC41233D6420426D3d464c77585B216D51D7;
    address internal constant FORWARD_RECIPIENT = 0x97fCbc96ed23e4E9F0714008C8f137D57B4d6C97;

    function run()
        public
        returns (PaymentRails paymentRails, ForwardModule forwardModule, CCTPBridgeModule bridgeModule)
    {
        uint256 usdcMinBalance = vm.envOr("USDC_MIN_BALANCE", uint256(1_000_000));
        uint256 forwardMinBalance = vm.envOr("FORWARD_MIN_BALANCE", uint256(0));
        uint256 cctpMaxFee = vm.envOr("CCTP_MAX_FEE", uint256(0));
        uint32 cctpFinality = uint32(vm.envOr("CCTP_FINALITY", uint256(2000)));

        (address deployer, uint256 deployerKey) = _deriveDeployer();

        console2.log("=============================================================");
        console2.log("  DeploySepoliaTestSetup - Begin");
        console2.log("=============================================================");
        console2.log("Chain ID:           ", block.chainid);
        console2.log("Deployer / owner:   ", deployer);
        console2.log("=============================================================");

        vm.startBroadcast(deployerKey);

        paymentRails = new PaymentRails(deployer);
        forwardModule = new ForwardModule();
        bridgeModule = new CCTPBridgeModule(TOKEN_MESSENGER_V2, USDC_SEPOLIA, deployer);

        bridgeModule.setDomainConfig({
            destinationDomain: BASE_SEPOLIA_DOMAIN,
            mintRecipient: bytes32(uint256(uint160(CCTP_MINT_RECIPIENT))),
            destinationCaller: bytes32(uint256(uint160(CCTP_DESTINATION_CALLER))),
            maxFee: cctpMaxFee,
            minFinalityThreshold: cctpFinality,
            hookData: ""
        });

        bytes memory bridgeParams = abi.encode(DataTypes.CCTPBridgeParams({ destinationDomain: BASE_SEPOLIA_DOMAIN }));
        paymentRails.configureToken({
            token: USDC_SEPOLIA,
            actionType: "BRIDGE",
            actionModule: address(bridgeModule),
            minBalance: usdcMinBalance,
            moduleParams: bridgeParams,
            enabled: true
        });

        bytes memory forwardParams = abi.encode(
            DataTypes.ForwardParams({
                recipient: FORWARD_RECIPIENT, requireSuccessfulReceipt: false, minAmount: forwardMinBalance
            })
        );
        paymentRails.configureToken({
            token: FORWARD_TOKEN,
            actionType: "FORWARD",
            actionModule: address(forwardModule),
            minBalance: forwardMinBalance,
            moduleParams: forwardParams,
            enabled: true
        });

        vm.stopBroadcast();

        _log(paymentRails, forwardModule, bridgeModule);
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

    function _log(PaymentRails paymentRails, ForwardModule forwardModule, CCTPBridgeModule bridgeModule) internal pure {
        console2.log("=============================================================");
        console2.log("  DeploySepoliaTestSetup - Complete");
        console2.log("=============================================================");
        console2.log("PaymentRails:       ", address(paymentRails));
        console2.log("ForwardModule:      ", address(forwardModule));
        console2.log("CCTPBridgeModule:   ", address(bridgeModule));
        console2.log("");
        console2.log("USDC -> BRIDGE (Base Sepolia, domain 6)");
        console2.log("  token:            ", USDC_SEPOLIA);
        console2.log("  mintRecipient:    ", CCTP_MINT_RECIPIENT);
        console2.log("  destinationCaller:", CCTP_DESTINATION_CALLER);
        console2.log("");
        console2.log("FORWARD config");
        console2.log("  token:            ", FORWARD_TOKEN);
        console2.log("  recipient:        ", FORWARD_RECIPIENT);
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  PAYMENT_RAILS_ADDRESS=%s", vm.toString(address(paymentRails)));
        console2.log("  FORWARD_MODULE=%s", vm.toString(address(forwardModule)));
        console2.log("  BRIDGE_MODULE=%s", vm.toString(address(bridgeModule)));
        console2.log("=============================================================");
    }
}
