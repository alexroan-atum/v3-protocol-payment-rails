// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { Node } from "../../../../src/core/Node.sol";
import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockActionModule } from "../../../shared/mocks/MockActionModule.sol";

/// @dev Base test contract for Node unit tests.
///      Provides shared state, constants, mocks, modifiers, and helpers following Sablier BTT style.
abstract contract NodeBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event TokenConfigured(address indexed token, string actionType, address actionModule);

    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint256 internal constant INITIAL_BALANCE = 1000e18;
    uint256 internal constant MIN_BALANCE = 100e18;
    string internal constant ACTION_TYPE = "MOCK";

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    Node internal node;
    MockActionModule internal actionModule;
    MockERC20 internal token;

    address internal owner;
    address internal nonOwner;
    address internal executor;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");
        executor = makeAddr("executor");

        vm.startPrank(owner);
        node = new Node(owner);
        vm.stopPrank();

        actionModule = new MockActionModule();
        token = new MockERC20("Test Token", "TEST");

        token.mint(address(node), INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenCallerIsOwner() {
        vm.startPrank(owner);
        _;
        vm.stopPrank();
    }

    modifier whenCallerIsNotOwner() {
        vm.startPrank(nonOwner);
        _;
        vm.stopPrank();
    }

    modifier givenTokenConfigured() {
        vm.prank(owner);
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), true
        );
        _;
    }

    modifier givenTokenConfiguredDisabled() {
        vm.prank(owner);
        node.configureToken(
            address(token), ACTION_TYPE, address(actionModule), MIN_BALANCE, _defaultModuleParams(), false
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultModuleParams() internal pure returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}
