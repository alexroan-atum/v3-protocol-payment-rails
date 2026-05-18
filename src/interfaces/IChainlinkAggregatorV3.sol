// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title IChainlinkAggregatorV3
/// @notice Minimal Chainlink AggregatorV3Interface for oracle price reads.
/// @dev Only the functions required by {DexSwapModule} are included. For the full interface, see
/// https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol
interface IChainlinkAggregatorV3 {
    /// @notice Returns the number of decimals in the price feed's answer.
    function decimals() external view returns (uint8);

    /// @notice Returns the latest round data from the price feed.
    /// @return roundId The round ID.
    /// @return answer The price answer (may be negative in error states).
    /// @return startedAt Timestamp when the round started.
    /// @return updatedAt Timestamp when the answer was last updated.
    /// @return answeredInRound Deprecated — do not use for staleness checks.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
