// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IAutoDeleveraging
 * @notice Last-resort mechanism: when InsuranceFund is exhausted, reduces profitable
 *         opposing positions pro-rata to cover shortfall. dYdX v4 Tier 3.
 */
interface IAutoDeleveraging {
    event ADLExecuted(
        bytes32 indexed marketId,
        bytes32 indexed bankruptSubaccount,
        bytes32 indexed counterparty,
        uint256 sizeReduced,
        uint256 price
    );

    /// AUDIT FIX (P10-L-1): Emit event when participant is removed from ADL list.
    /// Without this, off-chain monitoring has no way to know the participant list changed —
    /// indexers and keepers maintain stale participant counts, making ADL coverage estimates wrong.
    event ParticipantRemoved(bytes32 indexed marketId, bytes32 indexed subaccount);

    /// AUDIT FIX (P15-M-9): Transparency event for off-chain verification of ADL fairness.
    /// Emits raw PnL, PnL-to-notional ratio, and rank in the sorted candidate list so
    /// anyone can verify the most profitable counterparties were deleveraged first.
    event CounterpartyDeleveraged(
        bytes32 indexed subaccount,
        bytes32 indexed counterparty,
        bytes32 indexed marketId,
        uint256 counterpartyPnL,
        int256 counterpartyPnlRatio,
        uint256 counterpartyRank,
        uint256 size
    );

    /// @notice Execute ADL for a bankrupt subaccount. Called by LiquidationEngine.
    /// @param bankruptSubaccount The subaccount that went bankrupt.
    /// @param marketId The market with the bankrupt position.
    /// @param shortfallWad The remaining shortfall in WAD to cover.
    /// @param bankruptWasLong Whether the bankrupt position was long (true) or short (false).
    ///        AUDIT FIX (L3-H-3): Position is already closed when ADL fires, so direction
    ///        must be passed explicitly to avoid wrong-side targeting.
    function executeADL(
        bytes32 bankruptSubaccount,
        bytes32 marketId,
        uint256 shortfallWad,
        bool bankruptWasLong
    ) external;

    /// AUDIT FIX (P7-M-2): Register a subaccount as a market participant for ADL ranking.
    /// Called by MatchingEngine after successful fills.
    function registerParticipant(bytes32 marketId, bytes32 subaccount) external;

    /// AUDIT FIX (P9-H-3): Remove a subaccount from ADL participant list.
    /// Called by MarginEngine when position closes to zero (auto-cleanup).
    function removeParticipant(bytes32 marketId, bytes32 subaccount) external;
}
