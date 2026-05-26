// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { CCTPBridgeModule } from "../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CCTPBridgeSmoke
/// @author Credit Cooperative
/// @notice Smoke test against deployed PaymentRails + CCTPBridgeModule. Configures, funds, and executes
///         a CCTP bridge in a single broadcast. Prints the bash command to poll attestation and relay.
///         CCTPBridgeModule is stateless — all routing params are in PaymentRails's moduleParams.
///
///      REQUIRED env vars:
///        PAYMENT_RAILS_ADDRESS, BRIDGE_MODULE
///
///      OPTIONAL env vars (defaults = Ethereum Sepolia -> Base Sepolia):
///        SOURCE_USDC, DEST_DOMAIN, BRIDGE_AMOUNT, MIN_BALANCE, MINT_RECIPIENT,
///        MAX_FEE, FINALITY, SKIP_CONFIGURE, SKIP_FUND
///
///      Usage (testnet, first run - deploys paymentRails config + funds + executes):
///        source .env && forge script scripts/solidity/test/cctp/CCTPBridgeSmoke.s.sol \
///          --rpc-url $SOURCE_RPC_URL --broadcast -vvvv
///
///      Usage (subsequent runs - skip config, just fund and execute):
///        source .env && SKIP_CONFIGURE=true \
///          forge script scripts/solidity/test/cctp/CCTPBridgeSmoke.s.sol \
///            --rpc-url $SOURCE_RPC_URL --broadcast -vvvv
contract CCTPBridgeSmoke is Script {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant DEFAULT_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint32 internal constant DEFAULT_DEST_DOMAIN = 6;
    uint32 internal constant DEFAULT_FINALITY = 2000;
    uint256 internal constant DEFAULT_BRIDGE_AMOUNT = 10_000_000;
    uint256 internal constant DEFAULT_MIN_BALANCE = 1_000_000;
    uint256 internal constant DEFAULT_MAX_FEE = 0;

    struct Config {
        address usdc;
        uint32 destDomain;
        uint32 finality;
        uint256 bridgeAmount;
        uint256 minBalance;
        uint256 maxFee;
        address mintRecipient;
        bool skipConfigure;
        bool skipFund;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        address paymentRailsAddr = vm.envAddress("PAYMENT_RAILS_ADDRESS");
        address moduleAddr = vm.envAddress("BRIDGE_MODULE");

        PaymentRails paymentRails = PaymentRails(paymentRailsAddr);
        CCTPBridgeModule module = CCTPBridgeModule(moduleAddr);

        Config memory cfg = _loadConfig();
        (address deployer, uint256 deployerKey) = _deriveDeployer();

        if (cfg.mintRecipient == address(0)) cfg.mintRecipient = deployer;

        console2.log("=============================================================");
        console2.log("  CCTP Bridge Smoke Test");
        console2.log("=============================================================");
        console2.log("Chain ID:          ", block.chainid);
        console2.log("Deployer:          ", deployer);
        console2.log("PaymentRails:      ", paymentRailsAddr);
        console2.log("Module:            ", moduleAddr);
        console2.log("USDC:              ", cfg.usdc);
        console2.log("Dest domain:       ", uint256(cfg.destDomain));
        console2.log("Bridge amount:     ", cfg.bridgeAmount);
        console2.log("Mint recipient:    ", cfg.mintRecipient);
        console2.log("Skip paymentRails cfg: ", cfg.skipConfigure);
        console2.log("Skip fund:         ", cfg.skipFund);
        console2.log("=============================================================");

        _preflight(cfg, module, paymentRails, deployer);

        vm.startBroadcast(deployerKey);

        if (!cfg.skipConfigure) {
            bytes memory moduleParams = abi.encode(
                cfg.destDomain,
                bytes32(uint256(uint160(cfg.mintRecipient))),
                bytes32(0),
                cfg.maxFee,
                cfg.finality,
                bytes("")
            );
            paymentRails.configureToken(cfg.usdc, "CCTP_BRIDGE", address(module), cfg.minBalance, moduleParams, true);
            console2.log("[NODE] Configured USDC -> CCTP_BRIDGE");
        }

        if (!cfg.skipFund) {
            IERC20(cfg.usdc).transfer(paymentRailsAddr, cfg.bridgeAmount);
            console2.log("[FUNDED] %s USDC to PaymentRails", vm.toString(cfg.bridgeAmount));
        }

        bool success = paymentRails.executeAction(cfg.usdc, cfg.bridgeAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] depositForBurn called");

        vm.stopBroadcast();

        _postBroadcast(cfg, module, paymentRails);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _preflight(
        Config memory cfg,
        CCTPBridgeModule module,
        PaymentRails paymentRails,
        address deployer
    )
        internal
        view
    {
        require(address(module).code.length > 0, "BRIDGE_MODULE is not a contract");
        require(address(paymentRails).code.length > 0, "PAYMENT_RAILS_ADDRESS is not a contract");

        require(module.usdc() == cfg.usdc, "Module USDC mismatch");
        console2.log("[OK] Module USDC:          ", module.usdc());
        console2.log("[OK] TokenMessengerV2:     ", module.tokenMessenger());

        if (!cfg.skipConfigure) {
            require(paymentRails.owner() == deployer, "Deployer is not PaymentRails owner");
            console2.log("[OK] Deployer is PaymentRails owner");
        }

        if (!cfg.skipFund) {
            uint256 balance = IERC20(cfg.usdc).balanceOf(deployer);
            require(balance >= cfg.bridgeAmount, "Deployer USDC insufficient");
            console2.log("[OK] Deployer USDC:        ", balance);
        } else {
            uint256 paymentRailsBalance = IERC20(cfg.usdc).balanceOf(address(paymentRails));
            require(paymentRailsBalance >= cfg.bridgeAmount, "PaymentRails USDC insufficient");
            console2.log("[OK] PaymentRails USDC:    ", paymentRailsBalance);
        }
    }

    function _postBroadcast(Config memory cfg, CCTPBridgeModule module, PaymentRails paymentRails) internal view {
        uint256 moduleBalance = IERC20(cfg.usdc).balanceOf(address(module));
        uint256 paymentRailsBalance = IERC20(cfg.usdc).balanceOf(address(paymentRails));

        console2.log("");
        console2.log("=============================================================");
        console2.log("  BROADCAST COMPLETE");
        console2.log("=============================================================");
        console2.log("Module USDC: ", moduleBalance, " (0 = burned)");
        console2.log("PaymentRails USDC:   ", paymentRailsBalance, " (0 = all bridged)");
        console2.log("");
        console2.log("  Poll attestation:");
        console2.log("    source .env && bash scripts/bash/cctp-poll-attestation.sh <TX_HASH>");
        console2.log("");
        console2.log("  Or check manually:");
        console2.log("    curl -s $IRIS_API/v2/messages/$SOURCE_DOMAIN?transactionHash=<TX_HASH>");
        console2.log("");
        console2.log("  Then relay on destination:");
        console2.log("    cast send $MESSAGE_TRANSMITTER_V2 'receiveMessage(bytes,bytes)' \\");
        console2.log("      <MESSAGE> <ATTESTATION> --mnemonic \"$MNEMONIC\" --rpc-url $DEST_RPC_URL");
        console2.log("=============================================================");
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.usdc = vm.envOr("SOURCE_USDC", DEFAULT_USDC);
        cfg.destDomain = uint32(vm.envOr("DEST_DOMAIN", uint256(DEFAULT_DEST_DOMAIN)));
        cfg.finality = uint32(vm.envOr("FINALITY", uint256(DEFAULT_FINALITY)));
        cfg.bridgeAmount = vm.envOr("BRIDGE_AMOUNT", DEFAULT_BRIDGE_AMOUNT);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.maxFee = vm.envOr("MAX_FEE", DEFAULT_MAX_FEE);
        cfg.mintRecipient = vm.envOr("MINT_RECIPIENT", address(0));

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
}
