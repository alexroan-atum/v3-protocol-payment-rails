// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { Node } from "../../../../src/core/Node.sol";
import { CCTPBridgeModule } from "../../../../src/modules/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CCTPBridgeSmoke
/// @author Credit Cooperative
/// @notice Smoke test against deployed Node + CCTPBridgeModule. Configures, funds, and executes
///         a CCTP bridge in a single broadcast. Prints the bash command to poll attestation and relay.
///
///      REQUIRED env vars:
///        NODE_ADDRESS, BRIDGE_MODULE
///
///      OPTIONAL env vars (defaults = Ethereum Sepolia -> Base Sepolia):
///        SOURCE_USDC, DEST_DOMAIN, BRIDGE_AMOUNT, MIN_BALANCE, MINT_RECIPIENT,
///        MAX_FEE, FINALITY, SKIP_CONFIGURE, SKIP_DOMAIN_CONFIG, SKIP_FUND
///
///      Usage (testnet, first run - deploys domain config + node config + funds + executes):
///        source .env && forge script scripts/solidity/test/cctp/CCTPBridgeSmoke.s.sol \
///          --rpc-url $SOURCE_RPC_URL --broadcast -vvvv
///
///      Usage (subsequent runs - skip config, just fund and execute):
///        source .env && SKIP_CONFIGURE=true SKIP_DOMAIN_CONFIG=true \
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
        bool skipDomainConfig;
        bool skipFund;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        address nodeAddr = vm.envAddress("NODE_ADDRESS");
        address moduleAddr = vm.envAddress("BRIDGE_MODULE");

        Node node = Node(nodeAddr);
        CCTPBridgeModule module = CCTPBridgeModule(moduleAddr);

        Config memory cfg = _loadConfig();
        (address deployer, uint256 deployerKey) = _deriveDeployer();

        if (cfg.mintRecipient == address(0)) cfg.mintRecipient = deployer;

        console2.log("=============================================================");
        console2.log("  CCTP Bridge Smoke Test");
        console2.log("=============================================================");
        console2.log("Chain ID:          ", block.chainid);
        console2.log("Deployer:          ", deployer);
        console2.log("Node:              ", nodeAddr);
        console2.log("Module:            ", moduleAddr);
        console2.log("USDC:              ", cfg.usdc);
        console2.log("Dest domain:       ", uint256(cfg.destDomain));
        console2.log("Bridge amount:     ", cfg.bridgeAmount);
        console2.log("Mint recipient:    ", cfg.mintRecipient);
        console2.log("Skip domain cfg:   ", cfg.skipDomainConfig);
        console2.log("Skip node cfg:     ", cfg.skipConfigure);
        console2.log("Skip fund:         ", cfg.skipFund);
        console2.log("=============================================================");

        _preflight(cfg, module, node, deployer);

        vm.startBroadcast(deployerKey);

        if (!cfg.skipDomainConfig) {
            bytes32 recipient = bytes32(uint256(uint160(cfg.mintRecipient)));
            module.setDomainConfig(cfg.destDomain, recipient, bytes32(0), cfg.maxFee, cfg.finality, "");
            console2.log("[DOMAIN] Configured domain %s", vm.toString(uint256(cfg.destDomain)));
        }

        if (!cfg.skipConfigure) {
            bytes memory moduleParams = abi.encode(cfg.destDomain);
            node.configureToken(cfg.usdc, "CCTP_BRIDGE", address(module), cfg.minBalance, moduleParams, true);
            console2.log("[NODE] Configured USDC -> CCTP_BRIDGE");
        }

        if (!cfg.skipFund) {
            IERC20(cfg.usdc).transfer(nodeAddr, cfg.bridgeAmount);
            console2.log("[FUNDED] %s USDC to Node", vm.toString(cfg.bridgeAmount));
        }

        bool success = node.executeAction(cfg.usdc, cfg.bridgeAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] depositForBurn called");

        vm.stopBroadcast();

        _postBroadcast(cfg, module, node);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _preflight(Config memory cfg, CCTPBridgeModule module, Node node, address deployer) internal view {
        require(address(module).code.length > 0, "BRIDGE_MODULE is not a contract");
        require(address(node).code.length > 0, "NODE_ADDRESS is not a contract");

        require(module.usdc() == cfg.usdc, "Module USDC mismatch");
        console2.log("[OK] Module USDC:          ", module.usdc());
        console2.log("[OK] TokenMessengerV2:     ", module.tokenMessenger());

        if (!cfg.skipDomainConfig || !cfg.skipConfigure) {
            require(node.owner() == deployer, "Deployer is not Node owner");
            console2.log("[OK] Deployer is Node owner");
        }

        if (!cfg.skipDomainConfig) {
            require(module.owner() == deployer, "Deployer is not Module owner");
            console2.log("[OK] Deployer is Module owner");
        }

        if (!cfg.skipFund) {
            uint256 balance = IERC20(cfg.usdc).balanceOf(deployer);
            require(balance >= cfg.bridgeAmount, "Deployer USDC insufficient");
            console2.log("[OK] Deployer USDC:        ", balance);
        } else {
            uint256 nodeBalance = IERC20(cfg.usdc).balanceOf(address(node));
            require(nodeBalance >= cfg.bridgeAmount, "Node USDC insufficient");
            console2.log("[OK] Node USDC:            ", nodeBalance);
        }
    }

    function _postBroadcast(Config memory cfg, CCTPBridgeModule module, Node node) internal view {
        uint256 moduleBalance = IERC20(cfg.usdc).balanceOf(address(module));
        uint256 nodeBalance = IERC20(cfg.usdc).balanceOf(address(node));

        console2.log("");
        console2.log("=============================================================");
        console2.log("  BROADCAST COMPLETE");
        console2.log("=============================================================");
        console2.log("Module USDC: ", moduleBalance, " (0 = burned)");
        console2.log("Node USDC:   ", nodeBalance, " (0 = all bridged)");
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
        cfg.skipDomainConfig = keccak256(bytes(vm.envOr("SKIP_DOMAIN_CONFIG", f))) == keccak256("true");
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
