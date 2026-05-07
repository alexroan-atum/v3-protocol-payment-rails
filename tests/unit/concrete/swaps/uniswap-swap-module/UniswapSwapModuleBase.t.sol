// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { UniswapSwapModule } from "../../../../../src/modules/swaps/UniswapSwapModule.sol";

import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";
import { FailingTransferERC20 } from "../../../../shared/mocks/FailingTransferERC20.sol";
import { RevertingTransferERC20 } from "../../../../shared/mocks/RevertingTransferERC20.sol";
import { FeeOnTransferERC20 } from "../../../../shared/mocks/FeeOnTransferERC20.sol";
import { MockRouter } from "../../../../shared/mocks/MockRouter.sol";
import { MockUniswapPaymentRails } from "../../../../shared/mocks/MockUniswapPaymentRails.sol";

/*//////////////////////////////////////////////////////////////////////////
                            BASE TEST CONTRACT
//////////////////////////////////////////////////////////////////////////*/

/// @notice Shared setup, mocks, modifiers, and helpers for all UniswapSwapModule unit tests.
abstract contract UniswapSwapModuleBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
    event SwapExecuted(
        address indexed paymentRails,
        address indexed sellToken,
        address buyToken,
        uint256 amountIn,
        uint256 amountOut,
        address router
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint256 internal constant DEFAULT_SELL_AMOUNT = 1000e18;
    uint256 internal constant DEFAULT_BUY_AMOUNT = 950e18;
    uint256 internal constant DEFAULT_MIN_AMOUNT_OUT = 900e18;
    uint256 internal constant DEFAULT_DEADLINE = type(uint256).max;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    UniswapSwapModule internal module;
    MockRouter internal router;
    MockUniswapPaymentRails internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    FailingTransferERC20 internal failingToken;
    RevertingTransferERC20 internal revertingToken;
    FeeOnTransferERC20 internal feeToken;

    address internal owner;
    address internal attacker;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        owner = address(this);
        attacker = makeAddr("attacker");

        module = new UniswapSwapModule(owner);
        router = new MockRouter();
        paymentRails = new MockUniswapPaymentRails(address(module));

        sellToken = new MockERC20("Sell Token", "SELL");
        buyToken = new MockERC20("Buy Token", "BUY");
        failingToken = new FailingTransferERC20();
        revertingToken = new RevertingTransferERC20();
        feeToken = new FeeOnTransferERC20();

        module.addRouter(address(router));

        sellToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);
        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT * 100);
        failingToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);
        revertingToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);
        feeToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 100);

        vm.label(address(module), "UniswapSwapModule");
        vm.label(address(router), "MockRouter");
        vm.label(address(paymentRails), "MockPaymentRails");
        vm.label(address(sellToken), "SellToken");
        vm.label(address(buyToken), "BuyToken");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenCallerIsNotOwner() {
        _;
    }

    modifier whenCallerIsOwner() {
        _;
    }

    modifier whenRouterIsZeroAddress() {
        _;
    }

    modifier whenRouterHasNoCode() {
        _;
    }

    modifier whenRouterIsAlreadyAdded() {
        _;
    }

    modifier whenRouterIsNotInWhitelist() {
        _;
    }

    modifier whenAllValidationsPass() {
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultParams() internal view returns (bytes memory) {
        return abi.encode(address(buyToken));
    }

    function _buildParams(address targetToken) internal pure returns (bytes memory) {
        return abi.encode(targetToken);
    }

    function _defaultExecutionData() internal view returns (bytes memory) {
        return _buildExecutionData(address(router), DEFAULT_MIN_AMOUNT_OUT, DEFAULT_DEADLINE, _defaultRouterCalldata());
    }

    function _buildExecutionData(
        address _router,
        uint256 minAmountOut,
        uint256 deadline,
        bytes memory routerCalldata
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_router, minAmountOut, deadline, routerCalldata);
    }

    function _defaultRouterCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            DEFAULT_SELL_AMOUNT,
            address(buyToken),
            address(paymentRails),
            DEFAULT_BUY_AMOUNT
        );
    }

    function _routerCalldataWithAmounts(uint256 sellAmount, uint256 _buyAmount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            sellAmount,
            address(buyToken),
            address(paymentRails),
            _buyAmount
        );
    }
}
