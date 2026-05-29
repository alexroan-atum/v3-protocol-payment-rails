// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";

/// @title ICowSwapModule
/// @author Credit Cooperative
/// @notice Interface for the async CowSwap order-book swap module.
/// @dev Direct-receiver design: buyToken flows from solver directly to PaymentRails (never staged).
/// Each PaymentRails MUST deploy its own private instance. Fee-on-transfer tokens are NOT supported.
interface ICowSwapModule is IActionModule {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new CowSwap order is created via `execute()`.
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

    /// @notice Emitted when an order is cancelled via `cancelOrder()`.
    event OrderCancelled(bytes32 indexed orderId, address indexed paymentRails, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Cancels a pending order and returns the locked sellToken to the PaymentRails.
    /// @dev Owner-only. Blocked if already filled or cancelled. Returns at most `meta.sellAmount`
    /// to protect concurrent orders. Post-expiry slot liberation makes cancel a harmless no-op.
    function cancelOrder(bytes32 orderId) external;

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the full metadata for an order (all fields zero if unknown).
    function getOrder(bytes32 orderId) external view returns (DataTypes.CowOrderMetadata memory metadata);

    /// @notice EIP-1271 signature validation called by CowSwap before settling an order.
    /// @dev Returns MAGIC iff signature is 32-byte orderId matching hash, order is pending, not expired, and not
    /// filled. Must never revert (EIP-1271 requirement).
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);

    /// @notice Address of the CowSwap GPv2Settlement contract (immutable).
    function cowSettlement() external view returns (address);

    /// @notice EIP-712 domain separator of the CowSwap settlement contract (cached at construction).
    function cowDomainSeparator() external view returns (bytes32);

    /// @notice ABI-encodes a {CowSwapParams} struct into bytes.
    function encodeParams(DataTypes.CowSwapParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes bytes back into a typed {CowSwapParams} struct.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.CowSwapParams memory params);
}
