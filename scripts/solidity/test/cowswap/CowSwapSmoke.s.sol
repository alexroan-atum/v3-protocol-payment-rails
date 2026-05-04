// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { Node } from "../../../../src/core/Node.sol";
import { CowSwapModule } from "../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CowSwapSmoke
/// @author Credit Cooperative
/// @notice Smoke test for the CowSwap module against already-deployed contracts.
/// @dev Operates on an existing Node + CowSwapModule deployment. Does NOT deploy new contracts.
///      Configures the token route, funds the Node, calls executeAction(), and logs:
///        - The exact curl command to submit the order to the CowSwap API
///        - The CowSwap Explorer link to monitor settlement
///        - Cast commands to verify balances and cancel if needed
///
///      REQUIRED environment variables:
///        NODE_ADDRESS    - Deployed Node contract address
///        MODULE_ADDRESS  - Deployed CowSwapModule contract address
///
///      OPTIONAL environment variables (defaults are for Ethereum mainnet USDC->WETH):
///        SELL_TOKEN          - Token to sell            (default: mainnet USDC)
///        BUY_TOKEN           - Token to receive         (default: mainnet WETH)
///        SELL_AMOUNT         - Amount in wei             (default: 5000000 = 5 USDC)
///        MIN_BUY_AMOUNT      - Floor on output in wei    (default: 1000000000000000 = 0.001 WETH)
///        VALIDITY_DURATION   - Order TTL in seconds      (default: 1800 = 30 min)
///        MIN_BALANCE         - Node minBalance threshold  (default: 1000000 = 1 USDC)
///        COWSWAP_API         - API base URL              (default: https://api.cow.fi/mainnet)
///        SKIP_CONFIGURE      - Set to "true" to skip configureToken (already configured)
///        SKIP_FUND           - Set to "true" to skip funding (Node already has balance)
///
///      IMPORTANT: Token addresses differ per chain. When running on Base, Arbitrum, etc.
///      you MUST set SELL_TOKEN, BUY_TOKEN, and COWSWAP_API for that chain.
///
///      Usage (Ethereum mainnet, default 5 USDC -> WETH):
///        source .env && forge script scripts/solidity/test/cowswap/CowSwapSmoke.s.sol \
///          --rpc-url $ETHEREUM_RPC_URL --broadcast -vvvv
///
///      Usage (Base, USDC -> WETH, recommended for cheap smoke tests):
///        SELL_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
///        BUY_TOKEN=0x4200000000000000000000000000000000000006 \
///        COWSWAP_API=https://api.cow.fi/base \
///        forge script scripts/solidity/test/cowswap/CowSwapSmoke.s.sol \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
///
///      Usage (subsequent runs - skip configure and fund):
///        SKIP_CONFIGURE=true SKIP_FUND=true \
///        forge script scripts/solidity/test/cowswap/CowSwapSmoke.s.sol \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract CowSwapSmoke is Script {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant DEFAULT_SELL_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address internal constant DEFAULT_BUY_TOKEN = 0xc02AAA39B223fe8d0A0e5595ab2d3EB9fa40Fc9E; // WETH

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1_000_000; // 1 USDC
    uint256 internal constant DEFAULT_MIN_BUY_AMOUNT = 200_000_000_000_000; // 0.0002 WETH (~$0.42 floor)
    uint256 internal constant DEFAULT_MIN_BALANCE = 1_000_000; // 1 USDC
    uint32 internal constant DEFAULT_VALIDITY_DURATION = 1800; // 30 minutes

    /*//////////////////////////////////////////////////////////////////////////
                                    STRUCTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Packed config to avoid stack-too-deep.
    struct Config {
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 minBuyAmount;
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
        // =====================================================================
        // Load deployed contract addresses (required)
        // =====================================================================
        address nodeAddr = vm.envAddress("NODE_ADDRESS");
        address moduleAddr = vm.envAddress("MODULE_ADDRESS");

        Node node = Node(nodeAddr);
        CowSwapModule module = CowSwapModule(moduleAddr);

        // =====================================================================
        // Load swap config (optional, has defaults)
        // =====================================================================
        Config memory cfg = _loadConfig();

        // =====================================================================
        // Derive broadcaster
        // =====================================================================
        address deployer;
        uint256 deployerKey;
        (deployer, deployerKey) = _deriveDeployer();

        // =====================================================================
        // Log header
        // =====================================================================
        console2.log("=============================================================");
        console2.log("  CowSwap Smoke Test");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Node:           ", nodeAddr);
        console2.log("Module:         ", moduleAddr);
        console2.log("Sell token:     ", cfg.sellToken);
        console2.log("Buy token:      ", cfg.buyToken);
        console2.log("Sell amount:    ", cfg.sellAmount);
        console2.log("Min buy:        ", cfg.minBuyAmount);
        console2.log("Validity (sec): ", uint256(cfg.validityDuration));
        console2.log("Skip configure: ", cfg.skipConfigure);
        console2.log("Skip fund:      ", cfg.skipFund);
        console2.log("=============================================================");

        // =====================================================================
        // Pre-flight checks
        // =====================================================================
        _preflight(cfg, module, node, deployer);

        // =====================================================================
        // Broadcast: configure, fund, execute
        // =====================================================================
        vm.startBroadcast(deployerKey);

        if (!cfg.skipConfigure) {
            _configure(cfg, module, node);
        }

        if (!cfg.skipFund) {
            IERC20(cfg.sellToken).transfer(nodeAddr, cfg.sellAmount);
            console2.log("[FUNDED] Node with:", cfg.sellAmount);
        }

        bool success = node.executeAction(cfg.sellToken, cfg.sellAmount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] CowSwap order created on-chain");

        vm.stopBroadcast();

        // =====================================================================
        // Post-broadcast instructions
        // =====================================================================
        // NOTE: We cannot compute the real orderId here because block.timestamp
        // at script-read-time differs from the actual mined block timestamp.
        // The orderId depends on validTo (= block.timestamp + duration), so even
        // a few seconds of drift produces a completely different EIP-712 digest.
        // The bash helper script parses the broadcast JSON to get the real values.
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
        cfg.sellAmount = vm.envOr("SELL_AMOUNT", DEFAULT_SELL_AMOUNT);
        cfg.minBuyAmount = vm.envOr("MIN_BUY_AMOUNT", DEFAULT_MIN_BUY_AMOUNT);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.validityDuration = uint32(vm.envOr("VALIDITY_DURATION", uint256(DEFAULT_VALIDITY_DURATION)));

        string memory defaultApi = "https://api.cow.fi/mainnet";
        cfg.cowswapApi = vm.envOr("COWSWAP_API", defaultApi);

        string memory defaultFalse = "false";
        cfg.skipConfigure = keccak256(bytes(vm.envOr("SKIP_CONFIGURE", defaultFalse))) == keccak256("true");
        cfg.skipFund = keccak256(bytes(vm.envOr("SKIP_FUND", defaultFalse))) == keccak256("true");

        // Use zero appData (registered with CowSwap as "{}").
        // Order ID uniqueness comes from different block.timestamp -> different validTo.
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

    function _preflight(Config memory cfg, CowSwapModule module, Node node, address deployer) internal view {
        // Verify contracts exist
        require(address(module).code.length > 0, "MODULE_ADDRESS is not a contract");
        require(address(node).code.length > 0, "NODE_ADDRESS is not a contract");

        // Verify module is a CowSwapModule (check cowSettlement is set)
        require(module.cowSettlement() != address(0), "Module cowSettlement is zero");
        console2.log("[OK] Module cowSettlement:", module.cowSettlement());

        // Verify Node ownership (deployer must be owner to configure)
        if (!cfg.skipConfigure) {
            address nodeOwner = node.owner();
            require(nodeOwner == deployer, "Deployer is not Node owner - cannot configure");
            console2.log("[OK] Deployer is Node owner");
        }

        // Verify deployer has enough sellToken to fund (unless skipping)
        if (!cfg.skipFund) {
            uint256 balance = IERC20(cfg.sellToken).balanceOf(deployer);
            require(balance >= cfg.sellAmount, "Deployer has insufficient sell token");
            console2.log("[OK] Deployer sell token balance:", balance);
        }

        // If skipping fund, verify Node already has enough balance
        if (cfg.skipFund) {
            uint256 nodeBalance = IERC20(cfg.sellToken).balanceOf(address(node));
            require(nodeBalance >= cfg.sellAmount, "Node has insufficient sell token balance");
            console2.log("[OK] Node sell token balance:", nodeBalance);
        }
    }

    function _configure(Config memory cfg, CowSwapModule module, Node node) internal {
        bytes memory moduleParams = module.encodeParams(
            DataTypes.CowSwapParams({
                targetToken: cfg.buyToken,
                minBuyAmount: cfg.minBuyAmount,
                validityDuration: cfg.validityDuration,
                appData: cfg.appData
            })
        );

        node.configureToken(cfg.sellToken, "COWSWAP", address(module), cfg.minBalance, moduleParams, true);
        console2.log("[CONFIGURED] %s -> COWSWAP", vm.toString(cfg.sellToken));
    }
}
