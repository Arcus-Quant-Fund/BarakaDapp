// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Mock Chainlink aggregator for OracleAdapter tests.
contract MockChainlinkAggregator {
    int256 public _answer;
    uint80 public _roundId;
    uint256 public _startedAt;
    uint256 public _updatedAt;
    uint80 public _answeredInRound;

    function setRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external {
        _roundId = roundId;
        _answer = answer;
        _startedAt = startedAt;
        _updatedAt = updatedAt;
        _answeredInRound = answeredInRound;
    }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
