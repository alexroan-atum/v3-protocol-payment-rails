// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Mock of Circle's TokenMessengerV2 for unit testing CCTPBridgeModule.
///      Records call arguments so tests can assert the correct CCTP path was taken.
contract MockTokenMessengerV2 {
    struct DepositCall {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
    }

    DepositCall[] public depositCalls;
    DepositCall[] public depositWithHookCalls;

    bool public shouldRevert;
    string public revertReason;

    function setRevert(bool _shouldRevert, string calldata _reason) external {
        shouldRevert = _shouldRevert;
        revertReason = _reason;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external
    {
        if (shouldRevert) revert(revertReason);

        depositCalls.push(
            DepositCall({
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                burnToken: burnToken,
                destinationCaller: destinationCaller,
                maxFee: maxFee,
                minFinalityThreshold: minFinalityThreshold,
                hookData: ""
            })
        );
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    )
        external
    {
        if (shouldRevert) revert(revertReason);

        depositWithHookCalls.push(
            DepositCall({
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                burnToken: burnToken,
                destinationCaller: destinationCaller,
                maxFee: maxFee,
                minFinalityThreshold: minFinalityThreshold,
                hookData: hookData
            })
        );
    }

    function getDepositCallCount() external view returns (uint256) {
        return depositCalls.length;
    }

    function getDepositWithHookCallCount() external view returns (uint256) {
        return depositWithHookCalls.length;
    }
}
