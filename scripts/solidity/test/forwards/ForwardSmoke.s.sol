// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { ForwardModule } from "../../../../src/modules/forwards/ForwardModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ForwardSmoke
/// @author Credit Cooperative
/// @notice Smoke test for the ForwardModule against already-deployed contracts.
/// @dev Requires PAYMENT_RAILS_ADDRESS and MODULE_ADDRESS env vars. Override token/recipient for non-mainnet.
///      Set SKIP_CONFIGURE=true / SKIP_FUND=true for subsequent runs.
///
///      Usage:
///        source .env && forge script scripts/solidity/test/forwards/ForwardSmoke.s.sol \
///          --rpc-url $ETHEREUM_RPC_URL --broadcast -vvvv
contract ForwardSmoke is Script {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant DEFAULT_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    uint256 internal constant DEFAULT_AMOUNT = 1_000_000; // 1 USDC
    uint256 internal constant DEFAULT_MIN_BALANCE = 0;
    uint256 internal constant DEFAULT_MIN_AMOUNT = 0;

    /*//////////////////////////////////////////////////////////////////////////
                                    STRUCTS
    //////////////////////////////////////////////////////////////////////////*/

    struct Config {
        address token;
        uint256 amount;
        uint256 minBalance;
        uint256 minAmount;
        address recipient;
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
        ForwardModule module = ForwardModule(moduleAddr);

        Config memory cfg = _loadConfig();
        (address deployer, uint256 deployerKey) = _deriveDeployer();

        if (cfg.recipient == address(0)) cfg.recipient = deployer;

        console2.log("=============================================================");
        console2.log("  Forward Smoke Test");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("PaymentRails:   ", paymentRailsAddr);
        console2.log("Module:         ", moduleAddr);
        console2.log("Token:          ", cfg.token);
        console2.log("Amount:         ", cfg.amount);
        console2.log("Recipient:      ", cfg.recipient);
        console2.log("Min amount:     ", cfg.minAmount);
        console2.log("Skip configure: ", cfg.skipConfigure);
        console2.log("Skip fund:      ", cfg.skipFund);
        console2.log("=============================================================");

        _preflight(cfg, module, paymentRails, deployer);

        vm.startBroadcast(deployerKey);

        if (!cfg.skipConfigure) {
            _configure(cfg, module, paymentRails);
        }

        if (!cfg.skipFund) {
            IERC20(cfg.token).transfer(paymentRailsAddr, cfg.amount);
            console2.log("[FUNDED] PaymentRails with:", cfg.amount);
        }

        uint256 recipientBefore = IERC20(cfg.token).balanceOf(cfg.recipient);

        bool success = paymentRails.executeAction(cfg.token, cfg.amount);
        require(success, "executeAction failed");
        console2.log("[EXECUTED] Forward completed");

        vm.stopBroadcast();

        uint256 recipientAfter = IERC20(cfg.token).balanceOf(cfg.recipient);
        uint256 received = recipientAfter - recipientBefore;

        console2.log("");
        console2.log("=============================================================");
        console2.log("  BROADCAST COMPLETE");
        console2.log("=============================================================");
        console2.log("Recipient received:", received);
        console2.log("Expected:          ", cfg.amount);
        require(received == cfg.amount, "Recipient did not receive expected amount");
        console2.log("[VERIFIED] Recipient balance increased by exact amount");
        console2.log("=============================================================");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.token = vm.envOr("TOKEN", DEFAULT_TOKEN);
        cfg.amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        cfg.minBalance = vm.envOr("MIN_BALANCE", DEFAULT_MIN_BALANCE);
        cfg.minAmount = vm.envOr("MIN_AMOUNT", DEFAULT_MIN_AMOUNT);
        cfg.recipient = vm.envOr("RECIPIENT", address(0));

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
        ForwardModule module,
        PaymentRails paymentRails,
        address deployer
    )
        internal
        view
    {
        require(address(module).code.length > 0, "MODULE_ADDRESS is not a contract");
        require(address(paymentRails).code.length > 0, "PAYMENT_RAILS_ADDRESS is not a contract");

        string memory mType = module.moduleType();
        require(keccak256(bytes(mType)) == keccak256("FORWARD"), "Module is not a ForwardModule");
        console2.log("[OK] Module type:", mType);

        if (!cfg.skipConfigure) {
            address paymentRailsOwner = paymentRails.owner();
            require(paymentRailsOwner == deployer, "Deployer is not PaymentRails owner - cannot configure");
            console2.log("[OK] Deployer is PaymentRails owner");
        }

        if (!cfg.skipFund) {
            uint256 balance = IERC20(cfg.token).balanceOf(deployer);
            require(balance >= cfg.amount, "Deployer has insufficient token balance");
            console2.log("[OK] Deployer token balance:", balance);
        } else {
            uint256 paymentRailsBalance = IERC20(cfg.token).balanceOf(address(paymentRails));
            require(paymentRailsBalance >= cfg.amount, "PaymentRails has insufficient token balance");
            console2.log("[OK] PaymentRails token balance:", paymentRailsBalance);
        }
    }

    function _configure(Config memory cfg, ForwardModule module, PaymentRails paymentRails) internal {
        bytes memory moduleParams =
            module.encodeParams(DataTypes.ForwardParams({ recipient: cfg.recipient, minAmount: cfg.minAmount }));

        paymentRails.configureToken(cfg.token, "FORWARD", address(module), cfg.minBalance, moduleParams, true);
        console2.log("[CONFIGURED] %s -> FORWARD", vm.toString(cfg.token));
    }
}
