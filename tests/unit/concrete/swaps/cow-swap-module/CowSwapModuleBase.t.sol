// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "../../../../shared/mocks/FeeOnTransferERC20.sol";
import { NoReturnERC20 } from "../../../../shared/mocks/NoReturnERC20.sol";
import { MockCowSettlement } from "../../../../shared/mocks/MockCowSettlement.sol";
import { MockPaymentRails } from "../../../../shared/mocks/MockPaymentRails.sol";
import { MockChainlinkAggregator } from "../../../../shared/mocks/MockChainlinkAggregator.sol";

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
        address indexed paymentRails,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed paymentRails, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cow.protocol.domain.separator.v1");
    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAILURE = 0xffffffff;

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1000e18;
    uint256 internal constant DEFAULT_MIN_BUY_AMOUNT = 950e18; // oracle floor: 1000e18 * (10000-500)/10000
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600;
    uint32 internal constant DEFAULT_VALIDITY = 3600; // 1 hour
    bytes32 internal constant DEFAULT_APP_DATA = keccak256("receivables-paymentRails-v1");

    int256 internal constant SELL_PRICE = 1e8;
    int256 internal constant BUY_PRICE = 1e8;
    uint8 internal constant FEED_DECIMALS = 8;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModule internal module;
    MockCowSettlement internal cowSettlement;
    MockPaymentRails internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    FeeOnTransferERC20 internal fotSellToken;
    NoReturnERC20 internal noReturnSellToken;
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    address internal attacker = makeAddr("attacker");

    /*//////////////////////////////////////////////////////////////////////////
                                SHARED TEST STATE
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal _orderId;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        address vaultRelayerAddr = makeAddr("vaultRelayer");
        cowSettlement = new MockCowSettlement(DOMAIN_SEPARATOR, vaultRelayerAddr);
        paymentRails = new MockPaymentRails();
        module = new CowSwapModule(address(cowSettlement), address(this), address(paymentRails), address(0), 0);
        paymentRails.setModule(address(module));
        sellToken = new MockERC20("USDC", "USDC");
        buyToken = new MockERC20("WETH", "WETH");
        fotSellToken = new FeeOnTransferERC20();
        noReturnSellToken = new NoReturnERC20();

        sellFeed = new MockChainlinkAggregator(SELL_PRICE, FEED_DECIMALS);
        buyFeed = new MockChainlinkAggregator(BUY_PRICE, FEED_DECIMALS);

        sellToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);
        fotSellToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);
        noReturnSellToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);
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
        uint16 maxSlippageBps,
        address _sellFeed,
        address _buyFeed,
        uint256 maxStaleness,
        uint32 validityDuration,
        bytes32 appData
    )
        internal
        view
        returns (bytes memory)
    {
        return module.encodeParams(
            DataTypes.CowSwapParams({
                targetToken: targetToken,
                maxSlippageBps: maxSlippageBps,
                sellTokenPriceFeed: _sellFeed,
                buyTokenPriceFeed: _buyFeed,
                maxStaleness: maxStaleness,
                validityDuration: validityDuration,
                appData: appData
            })
        );
    }

    function _buildDefaultParams() internal view returns (bytes memory) {
        return _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
    }

    function _initiateDefaultOrder() internal returns (bytes32 orderId) {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        return abi.decode(result.data, (bytes32));
    }

    function _initiateOrder(
        address targetToken,
        uint256 sellAmount,
        uint16 maxSlippageBps,
        uint32 validityDuration,
        bytes32 appData
    )
        internal
        returns (bytes32 orderId)
    {
        DataTypes.ExecutionResult memory result = paymentRails.initiateSwap(
            address(sellToken),
            sellAmount,
            _buildParams(
                targetToken,
                maxSlippageBps,
                address(sellFeed),
                address(buyFeed),
                DEFAULT_MAX_STALENESS,
                validityDuration,
                appData
            )
        );
        return abi.decode(result.data, (bytes32));
    }

    /// @dev Mirrors CowSwapModule._computeOrderDigest for test-side orderId computation.
    ///      Needed to verify struct cleanup when execute() fails (no orderId in result).
    function _computeTestOrderDigest(
        address _sellToken,
        address _buyToken,
        address _receiver,
        uint256 _sellAmount,
        uint256 _buyAmount,
        uint32 _validTo,
        bytes32 _appData
    )
        internal
        pure
        returns (bytes32)
    {
        bytes32 orderTypeHash = keccak256(
            "Order(" "address sellToken," "address buyToken," "address receiver," "uint256 sellAmount,"
            "uint256 buyAmount," "uint32 validTo," "bytes32 appData," "uint256 feeAmount," "string kind,"
            "bool partiallyFillable," "string sellTokenBalance," "string buyTokenBalance" ")"
        );
        bytes32 kindSell = keccak256("sell");
        bytes32 balanceErc20 = keccak256("erc20");

        bytes32 structHash = keccak256(
            abi.encode(
                orderTypeHash,
                _sellToken,
                _buyToken,
                _receiver,
                _sellAmount,
                _buyAmount,
                _validTo,
                _appData,
                uint256(0),
                kindSell,
                false,
                balanceErc20,
                balanceErc20
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }
}
