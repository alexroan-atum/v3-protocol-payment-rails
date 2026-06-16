// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Minimal GPv2Settlement mock with separate vaultRelayer address.
contract MockCowSettlement {
    bytes32 public immutable domainSeparator;
    address public immutable vaultRelayer;
    mapping(bytes32 => uint256) private _filledAmounts;

    constructor(bytes32 _domainSeparator, address _vaultRelayer) {
        domainSeparator = _domainSeparator;
        vaultRelayer = _vaultRelayer;
    }

    function filledAmount(bytes calldata orderUid) external view returns (uint256) {
        bytes32 orderDigest = bytes32(orderUid[:32]);
        return _filledAmounts[orderDigest];
    }

    function setFilledAmount(bytes32 orderDigest, uint256 amount) external {
        _filledAmounts[orderDigest] = amount;
    }

    function filledAmountByDigest(bytes32 orderDigest) external view returns (uint256) {
        return _filledAmounts[orderDigest];
    }

    mapping(bytes32 => bool) public invalidatedOrders;

    function invalidateOrder(bytes calldata orderUid) external {
        bytes32 orderDigest = bytes32(orderUid[:32]);
        invalidatedOrders[orderDigest] = true;
    }
}
