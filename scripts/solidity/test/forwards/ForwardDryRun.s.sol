// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { ForwardModule } from "../../../../src/modules/forwards/ForwardModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ForwardDryRun
/// @author Credit Cooperative
/// @notice Full end-to-end simulation: deploy + configure + fund + execute in one script.
/// @dev Simulation-only — no --broadcast needed. Override token/recipient via env vars.
///
///      Usage (Ethereum mainnet fork):
///        source .env && forge script scripts/solidity/test/forwards/ForwardDryRun.s.sol \
///          --rpc-url $ETHEREUM_RPC_URL -vvvv
///
///      Usage (custom token):
///        source .env && TOKEN=0x... RECIPIENT=0x... AMOUNT=1000000 \
///          forge script scripts/solidity/test/forwards/ForwardDryRun.s.sol \
///            --rpc-url $ETHEREUM_RPC_URL -vvvv
contract ForwardDryRun is Script, StdCheats {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant DEFAULT_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    uint256 internal constant DEFAULT_AMOUNT = 1_000_000; // 1 USDC
    uint256 internal constant DEFAULT_MIN_BALANCE = 0;
    uint256 internal constant DEFAULT_MIN_AMOUNT = 0;

    struct Config {
        address token;
        uint256 amount;
        uint256 minBalance;
        uint256 minAmount;
        address recipient;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        Config memory cfg = _loadConfig();
        (address deployer,) = _deriveDeployer();

        if (cfg.recipient == address(0)) cfg.recipient = deployer;

        console2.log("=============================================================");
        console2.log("  Forward Full Dry Run (deploy + configure + fund + execute)");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("Token:          ", cfg.token);
        console2.log("Amount:         ", cfg.amount);
        console2.log("Recipient:      ", cfg.recipient);
        console2.log("Min amount:     ", cfg.minAmount);

        vm.startPrank(deployer);

        // --- Deploy ---
        PaymentRails paymentRails = new PaymentRails(deployer);
        console2.log("[DEPLOYED] PaymentRails:   ", address(paymentRails));

        ForwardModule module = new ForwardModule();
        console2.log("[DEPLOYED] ForwardModule:  ", address(module));

        // --- Configure ---
        bytes memory moduleParams =
            module.encodeParams(DataTypes.ForwardParams({ recipient: cfg.recipient, minAmount: cfg.minAmount }));
        paymentRails.configureToken(cfg.token, "FORWARD", address(module), cfg.minBalance, moduleParams, true);
        console2.log("[CONFIGURED] Token route set");

        vm.stopPrank();

        // --- Fund PaymentRails ---
        deal(cfg.token, address(paymentRails), cfg.amount);
        console2.log("[FUNDED] PaymentRails via deal():", cfg.amount);

        // --- Execute ---
        uint256 recipientBefore = IERC20(cfg.token).balanceOf(cfg.recipient);

        vm.prank(deployer);
        bool success = paymentRails.executeAction(cfg.token, cfg.amount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] Forward completed");

        // --- Verify ---
        _verify(cfg, module, paymentRails, recipientBefore);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _verify(
        Config memory cfg,
        ForwardModule module,
        PaymentRails paymentRails,
        uint256 recipientBefore
    )
        internal
        view
    {
        uint256 moduleBalance = IERC20(cfg.token).balanceOf(address(module));
        uint256 paymentRailsBalance = IERC20(cfg.token).balanceOf(address(paymentRails));
        uint256 recipientAfter = IERC20(cfg.token).balanceOf(cfg.recipient);
        uint256 received = recipientAfter - recipientBefore;

        console2.log("");
        console2.log("=============================================================");
        console2.log("  VERIFICATION");
        console2.log("=============================================================");
        console2.log("Module balance:        ", moduleBalance, " (expected: 0)");
        console2.log("PaymentRails balance:  ", paymentRailsBalance, " (expected: 0)");
        console2.log("Recipient received:    ", received);
        console2.log("Expected:              ", cfg.amount);

        require(moduleBalance == 0, "Module still holds tokens");
        require(paymentRailsBalance == 0, "PaymentRails still holds tokens");
        require(received == cfg.amount, "Recipient did not receive expected amount");

        console2.log("");
        console2.log("=============================================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("  Safe to deploy for real with --broadcast");
        console2.log("  Next: deploy/DeployPaymentRails.s.sol + deploy/DeployForwardModule.s.sol");
        console2.log("=============================================================");
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.token = vm.envOr("TOKEN", DEFAULT_TOKEN);
        cfg.amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.minAmount = vm.envOr("MIN_AMOUNT", DEFAULT_MIN_AMOUNT);
        cfg.recipient = vm.envOr("RECIPIENT", address(0));
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
