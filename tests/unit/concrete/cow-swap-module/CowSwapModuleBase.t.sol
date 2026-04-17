// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../src/modules/CowSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { FailingTransferERC20 } from "../../../shared/mocks/FailingTransferERC20.sol";
import { FeeOnTransferERC20 } from "../../../shared/mocks/FeeOnTransferERC20.sol";
import { MockCowSettlement } from "../../../shared/mocks/MockCowSettlement.sol";
import { MockNode } from "../../../shared/mocks/MockNode.sol";

/*//////////////////////////////////////////////////////////////////////////
                            BASE TEST CONTRACT
//////////////////////////////////////////////////////////////////////////*/

/// @notice Shared setup, mocks, modifiers, and helpers for all CowSwapModule unit tests.
/// @dev Mirrors the Sablier BTT pattern: conditions map to modifiers, behaviors map to test functions.
abstract contract CowSwapModuleBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed node,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32 validTo,
        bytes32 appData
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed node, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cow.protocol.domain.separator.v1");
    bytes4  internal constant EIP1271_MAGIC    = 0x1626ba7e;
    bytes4  internal constant EIP1271_FAILURE  = 0xffffffff;

    uint256 internal constant DEFAULT_SELL_AMOUNT    = 1_000e18;
    uint256 internal constant DEFAULT_MIN_BUY_AMOUNT = 950e18;
    uint32  internal constant DEFAULT_VALIDITY       = 3_600; // 1 hour
    bytes32 internal constant DEFAULT_APP_DATA       = keccak256("receivables-node-v1");

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule  internal module;
    MockCowSettlement    internal cowSettlement;
    MockNode             internal node;
    MockERC20            internal sellToken;
    MockERC20            internal buyToken;
    FeeOnTransferERC20   internal fotSellToken;

    address internal attacker = makeAddr("attacker");

    /*//////////////////////////////////////////////////////////////////////////
                                SHARED TEST STATE
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal _orderId;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        address vaultRelayerAddr = makeAddr("vaultRelayer");
        cowSettlement = new MockCowSettlement(DOMAIN_SEPARATOR, vaultRelayerAddr);
        module        = new CowSwapModule(address(cowSettlement), address(this));
        node          = new MockNode(address(module));
        sellToken     = new MockERC20("USDC", "USDC");
        buyToken      = new MockERC20("WETH", "WETH");
        fotSellToken  = new FeeOnTransferERC20();

        sellToken.mint(address(node), DEFAULT_SELL_AMOUNT * 10);
        fotSellToken.mint(address(node), DEFAULT_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                LIFECYCLE MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier givenPendingOrder() {
        _orderId = _initiateDefaultOrder();
        _;
    }

    modifier givenCancelledOrder() {
        _orderId = _initiateDefaultOrder();
        module.cancelOrder(_orderId);
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                SETTLEMENT MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier givenSolverPulledSellToken() {
        vm.prank(module.vaultRelayer());
        sellToken.transferFrom(address(module), address(cowSettlement), DEFAULT_SELL_AMOUNT);
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CALLER MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenCallerIsAttacker() {
        vm.prank(attacker);
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildParams(
        address targetToken,
        uint256 minBuyAmount,
        uint32  validityDuration,
        bytes32 appData
    ) internal view returns (bytes memory) {
        return module.encodeParams(DataTypes.CowSwapParams({
            targetToken:      targetToken,
            minBuyAmount:     minBuyAmount,
            validityDuration: validityDuration,
            appData:          appData
        }));
    }

    function _buildDefaultParams() internal view returns (bytes memory) {
        return _buildParams(address(buyToken), DEFAULT_MIN_BUY_AMOUNT, DEFAULT_VALIDITY, DEFAULT_APP_DATA);
    }

    function _initiateDefaultOrder() internal returns (bytes32 orderId) {
        DataTypes.ExecutionResult memory result =
            node.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        return abi.decode(result.data, (bytes32));
    }

    function _initiateOrder(
        address targetToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint32  validityDuration,
        bytes32 appData
    ) internal returns (bytes32 orderId) {
        DataTypes.ExecutionResult memory result = node.initiateSwap(
            address(sellToken),
            sellAmount,
            _buildParams(targetToken, minBuyAmount, validityDuration, appData)
        );
        return abi.decode(result.data, (bytes32));
    }
}
