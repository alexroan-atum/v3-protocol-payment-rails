// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { UniswapSwapModule } from "../../../../src/modules/swaps/UniswapSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../../../shared/mocks/MockERC20.sol";
import { MockRouter } from "../../../shared/mocks/MockRouter.sol";

/// @dev Minimal PaymentRails proxy — holds tokens, approves module, and forwards execute() calls.
contract SwapPaymentRailsProxy is Test {
    UniswapSwapModule public immutable module;

    constructor(address _module) {
        module = UniswapSwapModule(_module);
    }

    function executeSwap(
        address token,
        uint256 amount,
        bytes calldata params,
        bytes calldata executionData
    )
        external
        returns (DataTypes.ExecutionResult memory)
    {
        IERC20(token).approve(address(module), amount);
        return module.execute(token, amount, params, executionData);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            HANDLER CONTRACT
//////////////////////////////////////////////////////////////////////////*/

/// @title UniswapSwapModuleHandler
/// @notice Foundry invariant handler for UniswapSwapModule.
/// @dev Tracks ghost variables to enable invariant assertions.
///
/// Ghost variables mirror on-chain state so invariant functions can check
/// properties without requiring internal storage access.
///
/// Supported invariants:
///   INV-1: Module balance is always zero after any completed action
///   INV-2: Router approval from module is always zero after any completed action
///   INV-3: moduleType() always returns "SWAP"
///   INV-4: Router whitelist integrity — on-chain matches ghost state
///   INV-5: View functions never revert on arbitrary inputs
///   INV-6: Ownership consistency — on-chain matches ghost
///   INV-7: Token conservation — total sold by paymentRails == total received as buyToken
contract UniswapSwapModuleHandler is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                MODULE UNDER TEST
    //////////////////////////////////////////////////////////////////////////*/

    UniswapSwapModule internal module;
    SwapPaymentRailsProxy internal paymentRails;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockRouter internal router;

    /*//////////////////////////////////////////////////////////////////////////
                                GHOST VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev All router addresses ever added (may include removed ones)
    address[] public ghost_allRouters;

    /// @dev Per router: whether it is currently whitelisted
    mapping(address => bool) public ghost_routerIsAllowed;

    /// @dev Current owner of the module
    address public ghost_currentOwner;

    /// @dev Pending owner for Ownable2Step
    address public ghost_pendingOwner;

    /// @dev Total sellToken spent by paymentRails across all successful swaps
    uint256 public ghost_totalSellTokenSpent;

    /// @dev Total buyToken received by paymentRails across all successful swaps
    uint256 public ghost_totalBuyTokenReceived;

    /// @dev Total successful swap count
    uint256 public ghost_successfulSwapCount;

    /// @dev Set to true when a view function reverted (invariant violation)
    bool public ghost_viewFunctionReverted;

    /// @dev Tracks pending owner for acceptOwnership
    address internal pendingAcceptor;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        UniswapSwapModule _module,
        SwapPaymentRailsProxy _paymentRails,
        MockERC20 _sellToken,
        MockERC20 _buyToken,
        MockRouter _router,
        address _initialOwner
    ) {
        module = _module;
        paymentRails = _paymentRails;
        sellToken = _sellToken;
        buyToken = _buyToken;
        router = _router;
        ghost_currentOwner = _initialOwner;

        ghost_allRouters.push(address(_router));
        ghost_routerIsAllowed[address(_router)] = true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SWAP EXECUTION ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Executes a successful swap with bounded fuzz inputs.
    function handler_execute(uint256 sellAmount, uint256 buyAmount) external {
        sellAmount = bound(sellAmount, 1, 100_000e18);
        buyAmount = bound(buyAmount, 1, sellAmount);

        sellToken.mint(address(paymentRails), sellAmount);
        buyToken.mint(address(router), buyAmount);

        uint256 minAmountOut = buyAmount;
        bytes memory params = abi.encode(address(buyToken));
        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector,
            address(sellToken),
            sellAmount,
            address(buyToken),
            address(paymentRails),
            buyAmount
        );
        bytes memory executionData = abi.encode(address(router), minAmountOut, type(uint256).max, routerCalldata);

        uint256 prSellBefore = sellToken.balanceOf(address(paymentRails));
        uint256 prBuyBefore = buyToken.balanceOf(address(paymentRails));

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), sellAmount, params, executionData);

        if (result.success) {
            uint256 sellSpent = prSellBefore - sellToken.balanceOf(address(paymentRails));
            uint256 buyReceived = buyToken.balanceOf(address(paymentRails)) - prBuyBefore;
            ghost_totalSellTokenSpent += sellSpent;
            ghost_totalBuyTokenReceived += buyReceived;
            ghost_successfulSwapCount++;
        }
    }

    /// @dev Attempts a swap that should fail (router set to revert).
    function handler_executeFailingSwap(uint256 sellAmount) external {
        sellAmount = bound(sellAmount, 1, 100_000e18);

        sellToken.mint(address(paymentRails), sellAmount);

        router.setShouldRevert(true);

        bytes memory params = abi.encode(address(buyToken));
        bytes memory routerCalldata = abi.encodeWithSelector(
            MockRouter.swap.selector, address(sellToken), sellAmount, address(buyToken), address(paymentRails), 1
        );
        bytes memory executionData = abi.encode(address(router), uint256(1), type(uint256).max, routerCalldata);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), sellAmount, params, executionData);

        assertFalse(result.success, "Failing swap must not succeed");

        router.setShouldRevert(false);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ROUTER MANAGEMENT ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Adds a new router (creates a fresh MockRouter).
    function handler_addRouter(uint256) external {
        if (ghost_currentOwner == address(0)) return;

        MockRouter newRouter = new MockRouter();
        address newRouterAddr = address(newRouter);

        vm.prank(ghost_currentOwner);
        try module.addRouter(newRouterAddr) {
            ghost_allRouters.push(newRouterAddr);
            ghost_routerIsAllowed[newRouterAddr] = true;
        } catch { }
    }

    /// @dev Removes an existing router from the whitelist.
    function handler_removeRouter(uint256 routerIndex) external {
        if (ghost_currentOwner == address(0)) return;
        uint256 len = ghost_allRouters.length;
        if (len == 0) return;
        routerIndex = bound(routerIndex, 0, len - 1);
        address target = ghost_allRouters[routerIndex];

        if (!ghost_routerIsAllowed[target]) return;
        // Do not remove the primary router used for swaps
        if (target == address(router)) return;

        vm.prank(ghost_currentOwner);
        try module.removeRouter(target) {
            ghost_routerIsAllowed[target] = false;
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                        OWNERSHIP ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Transfers ownership to a new address.
    function handler_transferOwnership(uint256 newOwnerSeed) external {
        if (ghost_currentOwner == address(0)) return;

        address newOwner = makeAddr(string(abi.encodePacked("owner", newOwnerSeed)));
        pendingAcceptor = newOwner;

        vm.prank(ghost_currentOwner);
        try module.transferOwnership(newOwner) {
            ghost_pendingOwner = newOwner;
        } catch { }
    }

    /// @dev Accepts pending ownership.
    function handler_acceptOwnership() external {
        if (pendingAcceptor == address(0)) return;

        vm.prank(pendingAcceptor);
        try module.acceptOwnership() {
            ghost_currentOwner = pendingAcceptor;
            ghost_pendingOwner = address(0);
            pendingAcceptor = address(0);
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                        VIEW FUNCTION PROBING
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev INV-5: Calls view functions to verify they never revert.
    /// validate() requires a real ERC20 (calls balanceOf), so we use known tokens.
    /// estimateOutput, isRouterAllowed, moduleType are tested with arbitrary inputs.
    function handler_callViewFunctions(address arbitraryAddr, uint256 amount) external {
        bytes memory params = abi.encode(address(buyToken));

        // validate with real sellToken: must never revert
        try module.validate(address(sellToken), amount, params, "") returns (bool, string memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        // validate with real buyToken as sell (same-token path): must never revert
        try module.validate(address(buyToken), amount, params, "") returns (bool, string memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        // estimateOutput: pure function, must never revert
        try module.estimateOutput(arbitraryAddr, amount, params) returns (uint256, address) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        // isRouterAllowed: reads a mapping, must never revert
        try module.isRouterAllowed(arbitraryAddr) returns (bool) { }
        catch {
            ghost_viewFunctionReverted = true;
        }

        // moduleType: pure function, must never revert
        try module.moduleType() returns (string memory) { }
        catch {
            ghost_viewFunctionReverted = true;
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                GHOST HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function ghost_allRoutersLength() external view returns (uint256) {
        return ghost_allRouters.length;
    }
}
