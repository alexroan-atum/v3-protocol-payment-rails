// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { SwapModule } from "../../../../../src/modules/swaps/SwapModule.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { MockERC20 } from "../../../../shared/mocks/MockERC20.sol";

abstract contract SwapModuleBase is Test {
    uint256 internal constant DEFAULT_SELL_AMOUNT = 1000e18;
    uint24 internal constant DEFAULT_POOL_FEE = 3000;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 50;
    uint256 internal constant DEFAULT_MAX_DEVIATION_BPS = 500;
    uint32 internal constant DEFAULT_TWAP_PERIOD = 1800;

    SwapModule internal module;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal caller;
    address internal dexRouter;
    address internal priceOracle;

    function setUp() public virtual {
        caller = makeAddr("caller");
        dexRouter = makeAddr("dexRouter");
        priceOracle = makeAddr("priceOracle");

        module = new SwapModule();
        sellToken = new MockERC20("Sell Token", "SELL");
        buyToken = new MockERC20("Buy Token", "BUY");

        sellToken.mint(caller, DEFAULT_SELL_AMOUNT * 100);

        vm.label(address(module), "SwapModule");
        vm.label(address(sellToken), "SellToken");
        vm.label(address(buyToken), "BuyToken");
    }

    modifier whenTargetTokenIsZeroAddress() {
        _;
    }

    modifier whenDexRouterIsZeroAddress() {
        _;
    }

    modifier whenInputEqualsOutputToken() {
        _;
    }

    modifier whenCallerHasInsufficientBalance() {
        _;
    }

    modifier whenAllValidationsPass() {
        _;
    }

    function _defaultParams() internal view returns (bytes memory) {
        return module.encodeParams(_defaultSwapParams());
    }

    function _buildParams(address _targetToken, address _dexRouter) internal view returns (bytes memory) {
        DataTypes.SwapParams memory params = _defaultSwapParams();
        params.targetToken = _targetToken;
        params.dexRouter = _dexRouter;
        return module.encodeParams(params);
    }

    function _defaultSwapParams() internal view returns (DataTypes.SwapParams memory) {
        return DataTypes.SwapParams({
            targetToken: address(buyToken),
            dexRouter: dexRouter,
            path: "",
            poolFee: DEFAULT_POOL_FEE,
            slippageBps: DEFAULT_SLIPPAGE_BPS,
            priceOracle: priceOracle,
            maxPriceDeviationBps: DEFAULT_MAX_DEVIATION_BPS,
            useTwap: false,
            twapPeriod: DEFAULT_TWAP_PERIOD
        });
    }
}
