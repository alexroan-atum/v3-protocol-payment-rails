// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.29 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";

import { Foo } from "../src/Foo.sol";

/// @title IERC20
/// @notice Minimal ERC20 interface for testing
interface IERC20 {
    /// @notice Returns the token balance of an account
    /// @param account The address to query
    /// @return The token balance
    function balanceOf(address account) external view returns (uint256);
}

/// @title FooTest
/// @author Credit Cooperative
/// @notice Test suite for the Foo contract
/// @dev If this is your first time with Forge, read this tutorial in the Foundry Book:
/// https://book.getfoundry.sh/forge/writing-tests
contract FooTest is Test {
    Foo internal foo;

    /// @notice Set up the test environment
    /// @dev A function invoked before each test case is run
    function setUp() public virtual {
        // Instantiate the contract-under-test.
        foo = new Foo();
    }

    /// @notice Tests that the echo function returns the input value
    /// @dev Basic test. Run it with `forge test -vvv` to see the console log
    function testExample() external view {
        console2.log("Hello World");
        uint256 x = 42;
        assertEq(foo.echo(x), x, "value mismatch");
    }

    /// @notice Fuzz test that validates echo function with random inputs
    /// @param x Random unsigned integer value (zero is rejected)
    /// @dev If you need more sophisticated input validation, use the `bound` utility instead
    /// See https://twitter.com/PaulRBerg/status/1622558791685242880
    function testFuzzExample(uint256 x) external view {
        vm.assume(x != 0); // or x = bound(x, 1, 100)
        assertEq(foo.echo(x), x, "value mismatch");
    }

    /// @notice Fork test that validates USDC balance against mainnet state
    /// @dev Runs against an Ethereum Mainnet fork. Requires `API_KEY_ALCHEMY` environment variable
    /// You can get an API key for free at https://alchemy.com
    function testForkExample() external {
        // Silently pass this test if there is no API key.
        string memory alchemyApiKey = vm.envOr("API_KEY_ALCHEMY", string(""));
        if (bytes(alchemyApiKey).length == 0) {
            return;
        }

        // Otherwise, run the test against the mainnet fork.
        vm.createSelectFork({ urlOrAlias: "mainnet", blockNumber: 16_428_000 });
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address holder = 0x7713974908Be4BEd47172370115e8b1219F4A5f0;
        uint256 actualBalance = IERC20(usdc).balanceOf(holder);
        uint256 expectedBalance = 196_307_713.810457e6;
        assertEq(actualBalance, expectedBalance);
    }
}
