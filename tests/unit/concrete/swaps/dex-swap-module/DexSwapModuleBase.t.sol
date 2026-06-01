// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../../src/modules/swaps/DexSwapModule.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { FailingTransferERC20 } from "../../../../shared/mocks/FailingTransferERC20.sol";
import { RevertingTransferERC20 } from "../../../../shared/mocks/RevertingTransferERC20.sol";
import { MockRouter } from "../../../../shared/mocks/MockRouter.sol";
import { MockDexSwapPaymentRails } from "../../../../shared/mocks/MockDexSwapPaymentRails.sol";
import { MockChainlinkAggregator } from "../../../../shared/mocks/MockChainlinkAggregator.sol";

/*//////////////////////////////////////////////////////////////////////////
                            BASE TEST CONTRACT
//////////////////////////////////////////////////////////////////////////*/

/// @notice Shared setup, mocks, modifiers, and helpers for all DexSwapModule unit tests.
abstract contract DexSwapModuleBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event SwapExecuted(
        address indexed paymentRails, address indexed sellToken, address buyToken, uint256 amountIn, uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1000e18;
    uint256 internal constant DEFAULT_BUY_AMOUNT = 995e18;
    uint24 internal constant DEFAULT_FEE = 3000;
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant DEFAULT_MAX_STALENESS = 3600;
    uint256 internal constant DEFAULT_SWAP_DEADLINE = 300;

    int256 internal constant SELL_PRICE = 1e8;
    int256 internal constant BUY_PRICE = 1e8;
    uint8 internal constant FEED_DECIMALS = 8;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    MockRouter internal router;
    MockDexSwapPaymentRails internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    FailingTransferERC20 internal failingToken;
    RevertingTransferERC20 internal revertingToken;
    MockChainlinkAggregator internal sellFeed;
    MockChainlinkAggregator internal buyFeed;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        router = new MockRouter();
        module = new DexSwapModule(address(router), address(0), 0);
        paymentRails = new MockDexSwapPaymentRails(address(module));

        sellToken = new MockERC20("Sell Token", "SELL");
        buyToken = new MockERC20("Buy Token", "BUY");
        failingToken = new FailingTransferERC20();
        revertingToken = new RevertingTransferERC20();
        sellFeed = new MockChainlinkAggregator(SELL_PRICE, FEED_DECIMALS);
        buyFeed = new MockChainlinkAggregator(BUY_PRICE, FEED_DECIMALS);

        sellToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);
        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT * 100);
        failingToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);
        revertingToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);
        router.setOutputAmount(DEFAULT_BUY_AMOUNT);

        vm.label(address(module), "DexSwapModule");
        vm.label(address(router), "MockRouter");
        vm.label(address(paymentRails), "MockPaymentRails");
        vm.label(address(sellToken), "SellToken");
        vm.label(address(buyToken), "BuyToken");
        vm.label(address(sellFeed), "SellPriceFeed");
        vm.label(address(buyFeed), "BuyPriceFeed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenAllValidationsPass() {
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultParams() internal view returns (bytes memory) {
        return abi.encode(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
    }

    function _buildParams(address targetToken) internal view returns (bytes memory) {
        return abi.encode(
            targetToken,
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
    }

    function _buildParamsCustom(
        address targetToken,
        uint24 fee,
        uint16 slippageBps,
        address _sellFeed,
        address _buyFeed,
        uint256 maxStaleness,
        uint256 deadlineSeconds
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(targetToken, fee, slippageBps, _sellFeed, _buyFeed, maxStaleness, deadlineSeconds);
    }

    function _computeExpectedOutput(uint256 sellAmount) internal pure returns (uint256) {
        return Math.mulDiv(sellAmount, uint256(SELL_PRICE), uint256(BUY_PRICE));
    }

    function _computeOracleFloor(uint256 sellAmount) internal pure returns (uint256) {
        uint256 expected = _computeExpectedOutput(sellAmount);
        return Math.mulDiv(expected, 10_000 - uint256(DEFAULT_SLIPPAGE_BPS), 10_000);
    }
}
