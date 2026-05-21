// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CCTPBridgeModule } from "../../../../src/modules/bridges/CCTPBridgeModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockTokenMessengerV2 } from "../../../shared/mocks/MockTokenMessengerV2.sol";

contract BridgePaymentRailsProxy is Test {
    CCTPBridgeModule public immutable module;

    constructor(address _module) {
        module = CCTPBridgeModule(_module);
    }

    function initiateBridge(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params);
    }
}

contract CCTPBridgeModuleHandler is Test {
    CCTPBridgeModule internal module;
    BridgePaymentRailsProxy internal paymentRails;
    MockERC20 internal usdc;
    MockERC20 internal otherToken;
    MockTokenMessengerV2 internal tokenMessenger;

    uint32[] public ghost_configuredDomains;
    mapping(uint32 => bool) public ghost_domainIsConfigured;
    mapping(uint32 => uint256) public ghost_domainMaxFee;
    mapping(uint32 => bool) public ghost_domainHasHookData;

    address public ghost_currentOwner;
    address public ghost_pendingOwner;

    uint256 public ghost_totalMintedToPaymentRails;

    uint32 internal constant MAX_DOMAIN = 10;

    address internal pendingAcceptor;

    constructor(
        CCTPBridgeModule _module,
        BridgePaymentRailsProxy _node,
        MockERC20 _usdc,
        MockERC20 _otherToken,
        MockTokenMessengerV2 _tokenMessenger,
        address _initialOwner
    ) {
        module = _module;
        paymentRails = _node;
        usdc = _usdc;
        otherToken = _otherToken;
        tokenMessenger = _tokenMessenger;
        ghost_currentOwner = _initialOwner;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        DOMAIN CONFIG ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function handler_setDomainConfig(uint32 domain, uint256 maxFee, bool useHookData) external {
        if (ghost_currentOwner == address(0)) return;
        domain = uint32(bound(domain, 0, MAX_DOMAIN));
        maxFee = bound(maxFee, 0, 10e6);

        bytes32 mintRecipient = bytes32(uint256(uint160(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB)));
        bytes memory hookData = useHookData ? bytes(hex"deadbeef") : bytes("");

        vm.prank(ghost_currentOwner);
        try module.setDomainConfig(domain, mintRecipient, bytes32(0), maxFee, 1000, hookData) {
            if (!ghost_domainIsConfigured[domain]) {
                ghost_configuredDomains.push(domain);
                ghost_domainIsConfigured[domain] = true;
            }
            ghost_domainMaxFee[domain] = maxFee;
            ghost_domainHasHookData[domain] = useHookData;
        } catch { }
    }

    function handler_removeDomainConfig(uint256 domainIndex) external {
        if (ghost_currentOwner == address(0)) return;
        uint256 len = ghost_configuredDomains.length;
        if (len == 0) return;
        domainIndex = bound(domainIndex, 0, len - 1);
        uint32 domain = ghost_configuredDomains[domainIndex];

        if (!ghost_domainIsConfigured[domain]) return;

        vm.prank(ghost_currentOwner);
        try module.removeDomainConfig(domain) {
            ghost_domainIsConfigured[domain] = false;
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                        EXECUTION ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function handler_execute(uint256 amount, uint256 domainIndex) external {
        uint256 len = ghost_configuredDomains.length;
        if (len == 0) return;
        domainIndex = bound(domainIndex, 0, len - 1);
        uint32 domain = ghost_configuredDomains[domainIndex];

        amount = bound(amount, 1, 100_000e6);

        usdc.mint(address(paymentRails), amount);
        ghost_totalMintedToPaymentRails += amount;

        bytes memory params = abi.encode(domain);
        paymentRails.initiateBridge(address(usdc), amount, params);
    }

    function handler_executeUnconfiguredDomain(uint256 amount) external {
        amount = bound(amount, 1, 100_000e6);
        uint32 unconfiguredDomain = MAX_DOMAIN + 1;

        usdc.mint(address(paymentRails), amount);
        ghost_totalMintedToPaymentRails += amount;

        bytes memory params = abi.encode(unconfiguredDomain);
        DataTypes.ExecutionResult memory result = paymentRails.initiateBridge(address(usdc), amount, params);

        assertFalse(result.success);
    }

    function handler_executeBelowMaxFee(uint256 domainIndex) external {
        uint256 len = ghost_configuredDomains.length;
        if (len == 0) return;
        domainIndex = bound(domainIndex, 0, len - 1);
        uint32 domain = ghost_configuredDomains[domainIndex];

        if (!ghost_domainIsConfigured[domain]) return;

        uint256 maxFee = ghost_domainMaxFee[domain];
        if (maxFee == 0) return;

        uint256 amount = maxFee;

        usdc.mint(address(paymentRails), amount);
        ghost_totalMintedToPaymentRails += amount;

        bytes memory params = abi.encode(domain);
        DataTypes.ExecutionResult memory result = paymentRails.initiateBridge(address(usdc), amount, params);

        assertFalse(result.success);
        assertEq(result.failureReason, "Max fee exceeds amount");
    }

    function handler_executeNonUSDC(uint256 amount, uint256 domainIndex) external {
        uint256 len = ghost_configuredDomains.length;
        if (len == 0) return;
        domainIndex = bound(domainIndex, 0, len - 1);
        uint32 domain = ghost_configuredDomains[domainIndex];

        amount = bound(amount, 1, 100_000e6);
        otherToken.mint(address(paymentRails), amount);

        bytes memory params = abi.encode(domain);

        vm.prank(address(paymentRails));
        IERC20(address(otherToken)).approve(address(module), amount);

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(otherToken), amount, params);

        assertFalse(result.success);
        assertEq(result.failureReason, "Only USDC supported");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        OWNERSHIP ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function handler_transferOwnership(uint256 newOwnerSeed) external {
        if (ghost_currentOwner == address(0)) return;

        address newOwner = makeAddr(string(abi.encodePacked("owner", newOwnerSeed)));
        pendingAcceptor = newOwner;

        vm.prank(ghost_currentOwner);
        try module.transferOwnership(newOwner) {
            ghost_pendingOwner = newOwner;
        } catch { }
    }

    function handler_acceptOwnership() external {
        if (pendingAcceptor == address(0)) return;

        vm.prank(pendingAcceptor);
        try module.acceptOwnership() {
            ghost_currentOwner = pendingAcceptor;
            ghost_pendingOwner = address(0);
            pendingAcceptor = address(0);
        } catch { }
    }

    function handler_renounceOwnership() external {
        if (ghost_currentOwner == address(0)) return;

        vm.prank(ghost_currentOwner);
        try module.renounceOwnership() {
            ghost_currentOwner = address(0);
            ghost_pendingOwner = address(0);
            pendingAcceptor = address(0);
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                        GHOST HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function ghost_configuredDomainsLength() external view returns (uint256) {
        return ghost_configuredDomains.length;
    }
}
