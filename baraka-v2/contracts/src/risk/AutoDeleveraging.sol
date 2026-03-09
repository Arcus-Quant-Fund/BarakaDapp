// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IAutoDeleveraging.sol";
import "../interfaces/IMarginEngine.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/ISubaccountManager.sol";
import "../interfaces/IFundingEngine.sol";

/**
 * @title AutoDeleveraging
 * @author Baraka Protocol v2
 * @notice Last-resort mechanism (dYdX v4 Tier 3): when InsuranceFund is exhausted
 *         and a bankrupt subaccount can't be fully settled, profitable opposing
 *         positions are reduced pro-rata to cover the shortfall.
 *
 *         How it works:
 *           1. LiquidationEngine detects negative equity after full close
 *           2. Calls executeADL(bankruptSubaccount, market, shortfall)
 *           3. ADL ranks opposing profitable positions by unrealized PnL (descending)
 *           4. Reduces the most profitable positions until shortfall is covered
 *           5. Counterparties receive fair settlement at oracle price
 *
 *         This should rarely activate — only when InsuranceFund is depleted.
 *         Traders can monitor ADLExecuted events and hedge accordingly.
 *
 * @dev Counterparty registry is maintained as a sorted list per market.
 *      In production, this would use an off-chain keeper to submit the ranked
 *      list. Here we accept on-chain iteration for correctness.
 */
contract AutoDeleveraging is IAutoDeleveraging, Ownable2Step, ReentrancyGuard {

    uint256 constant WAD = 1e18;
    /// AUDIT FIX (L3-M-5): Cap ADL processing operations to prevent gas DoS
    uint256 public constant MAX_ADL_ITERATIONS = 50;
    /// AUDIT FIX (P4-A2-3): Separate scan limit from processing limit.
    /// Previously, zero-PnL griefing accounts consumed iteration slots: an adversary pre-fills
    /// 50 participant slots with zero-PnL positions, and the ADL loop exhausts all iterations
    /// scanning them — no profitable counterparty is ever reached. Now the loop scans up to
    /// MAX_ADL_SCAN entries to FIND profitable counterparties, but only counts actual ADL
    /// position-reduction operations toward the MAX_ADL_ITERATIONS processing cap.
    uint256 public constant MAX_ADL_SCAN = 200;

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    IMarginEngine     public immutable marginEngine;
    IOracleAdapter    public immutable oracle;
    ISubaccountManager public immutable subaccountManager;
    /// AUDIT FIX (P5-M-21): FundingEngine reference for pre-ADL funding normalization.
    IFundingEngine    public fundingEngine;

    /// @notice Authorised callers (LiquidationEngine only)
    mapping(address => bool) public authorised;

    /// @notice Registered counterparties per market (for ADL ranking)
    ///         In production, this would be maintained by an off-chain indexer.
    mapping(bytes32 => bytes32[]) public marketParticipants;
    mapping(bytes32 => mapping(bytes32 => bool)) public isParticipant;

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _marginEngine,
        address _oracle,
        address _subaccountManager
    ) Ownable(initialOwner) {
        require(_marginEngine != address(0), "ADL: zero ME");
        require(_oracle != address(0), "ADL: zero oracle");
        require(_subaccountManager != address(0), "ADL: zero SAM");

        marginEngine = IMarginEngine(_marginEngine);
        oracle = IOracleAdapter(_oracle);
        subaccountManager = ISubaccountManager(_subaccountManager);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        authorised[caller] = status;
    }

    /// AUDIT FIX (P5-M-21): Set FundingEngine for pre-ADL funding normalization.
    function setFundingEngine(address _fundingEngine) external onlyOwner {
        require(_fundingEngine != address(0), "ADL: zero FE");
        fundingEngine = IFundingEngine(_fundingEngine);
    }

    /// AUDIT FIX (P2-HIGH-8): Prevent ownership renouncement — ADL requires owner for authorization management.
    function renounceOwnership() public view override onlyOwner {
        revert("ADL: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // Participant registry (called by MatchingEngine after fills)
    // ─────────────────────────────────────────────────────

    /// @notice Register a subaccount as a market participant (for ADL ranking).
    function registerParticipant(bytes32 marketId, bytes32 subaccount) external {
        require(authorised[msg.sender], "ADL: not authorised");
        if (!isParticipant[marketId][subaccount]) {
            isParticipant[marketId][subaccount] = true;
            marketParticipants[marketId].push(subaccount);
        }
    }

    // ─────────────────────────────────────────────────────
    // Core — execute ADL
    // ─────────────────────────────────────────────────────

    /// @notice Execute ADL for a bankrupt subaccount.
    /// AUDIT FIX (L3-H-3): Added bankruptWasLong parameter — position is already closed
    /// when ADL fires, so reading bankruptPos.size gives 0 (wrong-side targeting).
    function executeADL(
        bytes32 bankruptSubaccount,
        bytes32 marketId,
        uint256 shortfallWad,
        bool bankruptWasLong
    ) external override nonReentrant {
        require(authorised[msg.sender], "ADL: not authorised");
        require(shortfallWad > 0, "ADL: zero shortfall");

        uint256 indexPrice = oracle.getIndexPrice(marketId);
        /// AUDIT FIX (L3-M-4): Oracle staleness check in ADL
        require(!oracle.isStale(marketId), "ADL: stale oracle");
        uint256 remaining = shortfallWad;
        /// AUDIT FIX (P10-H-1): Use memory copy, NOT storage pointer.
        /// Using `storage` here caused a silent iterator corruption bug: when executeADL
        /// calls marginEngine.updatePosition() which triggers _cleanupPosition() which calls
        /// adl.removeParticipant() (swap-and-pop), the loop's `participants` view shifts
        /// mid-iteration — entries are skipped or processed twice, and the loop index can
        /// overshoot, triggering an array-bounds panic that silently exits the ADL execution.
        /// Copying to memory snaps the participant list at the start of the call.
        bytes32[] memory participants = marketParticipants[marketId];

        /// AUDIT FIX (P5-M-21): Settle funding for the market ONCE before the ADL loop.
        /// Without this, the first counterparty's updatePosition calls updateFunding() which
        /// advances lastUpdateTime; subsequent counterparties in the same block see elapsed=0
        /// and receive no funding settlement. Pre-settling normalizes funding across all.
        if (address(fundingEngine) != address(0)) {
            // Trigger funding accrual so all counterparties share the same cumulative index
            try fundingEngine.updateFunding(marketId) {} catch {}
        }

        // Find profitable opposing positions and reduce them.
        // If bankrupt was long → deleverage profitable shorts.
        // If bankrupt was short → deleverage profitable longs.
        /// AUDIT FIX (L3-M-5): Bounded loop — cap processing operations.
        /// AUDIT FIX (P4-A2-3): Scan up to MAX_ADL_SCAN entries, but only count actual
        /// ADL operations toward MAX_ADL_ITERATIONS. Zero-PnL entries are skipped without
        /// consuming the processing budget, neutralising the pre-fill griefing attack.
        uint256 scanLimit = participants.length > MAX_ADL_SCAN ? MAX_ADL_SCAN : participants.length;

        /// AUDIT FIX (P6-M-3): Build a local list of profitable opposing counterparties,
        /// sort by unrealizedPnl descending, then deleverage most profitable first.
        /// This ensures fairness per the dYdX v4 spec and prevents arbitrary ordering
        /// from insertion-order iteration (which could unfairly deleverage low-profit positions).
        bytes32[] memory candidates = new bytes32[](scanLimit);
        uint256[] memory candidatePnl = new uint256[](scanLimit);
        uint256 candidateCount;

        for (uint256 i = 0; i < scanLimit; i++) {
            bytes32 counterparty = participants[i];
            if (counterparty == bankruptSubaccount) continue;

            IMarginEngine.Position memory cPos = marginEngine.getPosition(counterparty, marketId);
            if (cPos.size == 0) continue;

            int256 unrealizedPnl;
            bool isOpposing;

            if (bankruptWasLong && cPos.size < 0) {
                unrealizedPnl = (int256(cPos.entryPrice) - int256(indexPrice)) * (-cPos.size) / int256(WAD);
                isOpposing = true;
            } else if (!bankruptWasLong && cPos.size > 0) {
                unrealizedPnl = (int256(indexPrice) - int256(cPos.entryPrice)) * cPos.size / int256(WAD);
                isOpposing = true;
            }

            if (!isOpposing || unrealizedPnl <= 0) continue;

            /// AUDIT FIX (P10-M-8): Subtract pending funding to get net PnL for ranking.
            /// Without this, a counterparty with large unrealized PnL but large outstanding
            /// funding debt ranks higher than one with lower PnL but no funding owed, even
            /// though the former is less net-profitable. Netting gives a fairer ranking.
            if (address(fundingEngine) != address(0)) {
                try fundingEngine.getPendingFunding(marketId, cPos.size, cPos.entryFundingIndex)
                    returns (int256 pendingFund)
                {
                    // pendingFund > 0 means position owes funding → reduces net PnL
                    unrealizedPnl -= pendingFund;
                } catch {}
            }
            if (unrealizedPnl <= 0) continue;

            candidates[candidateCount] = counterparty;
            candidatePnl[candidateCount] = uint256(unrealizedPnl);
            candidateCount++;
        }

        // Insertion sort by PnL descending (most profitable first).
        // Bounded by MAX_ADL_SCAN — at most 200 entries, ~40k comparisons.
        for (uint256 i = 1; i < candidateCount; i++) {
            uint256 keyPnl = candidatePnl[i];
            bytes32 keySub = candidates[i];
            uint256 j = i;
            while (j > 0 && candidatePnl[j - 1] < keyPnl) {
                candidatePnl[j] = candidatePnl[j - 1];
                candidates[j] = candidates[j - 1];
                j--;
            }
            candidatePnl[j] = keyPnl;
            candidates[j] = keySub;
        }

        // Deleverage sorted candidates (most profitable first)
        uint256 processed = 0;
        for (uint256 i = 0; i < candidateCount && remaining > 0 && processed < MAX_ADL_ITERATIONS; i++) {
            bytes32 counterparty = candidates[i];
            uint256 unrealizedPnl = candidatePnl[i];

            IMarginEngine.Position memory cPos = marginEngine.getPosition(counterparty, marketId);

            // Calculate how much of this counterparty's position to close
            uint256 maxCloseValue = unrealizedPnl;
            uint256 closeValue = remaining > maxCloseValue ? maxCloseValue : remaining;

            // Convert value to size: closeSize = closeValue * WAD / indexPrice
            /// AUDIT FIX (P5-M-4): Ceiling division — floor truncation on closeSize followed by
            /// floor on settledValue leaks ~1 WAD per counterparty. Over 10 counterparties,
            /// ~10 WAD of shortfall goes uncovered.
            uint256 closeSize = (closeValue * WAD + indexPrice - 1) / indexPrice;
            uint256 absCSize = _abs(cPos.size);
            if (closeSize > absCSize) closeSize = absCSize;

            // Close counterparty's position at oracle price (fair settlement)
            int256 sizeDelta = cPos.size > 0 ? -int256(closeSize) : int256(closeSize);
            marginEngine.updatePosition(counterparty, marketId, sizeDelta, indexPrice);

            /// AUDIT FIX (L3-M-2): Compute settled value once to avoid rounding drift
            uint256 settledValue = closeSize * indexPrice / WAD;
            remaining = settledValue >= remaining ? 0 : remaining - settledValue;

            emit ADLExecuted(marketId, bankruptSubaccount, counterparty, closeSize, indexPrice);
            processed++;
        }
    }

    /// @dev INFO (L3-I-3): Participant list cleanup implemented via removeParticipant below.
    /// @dev INFO (L3-I-7): setADL zero-address check implemented in LiquidationEngine.setADL (L3-L-1).

    /// AUDIT FIX (L3-L-5): Allow cleanup of participants with zero positions
    function removeParticipant(bytes32 marketId, bytes32 subaccount) external {
        require(authorised[msg.sender], "ADL: not authorised");
        require(isParticipant[marketId][subaccount], "ADL: not participant");

        isParticipant[marketId][subaccount] = false;
        bytes32[] storage participants = marketParticipants[marketId];
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] == subaccount) {
                participants[i] = participants[participants.length - 1];
                participants.pop();
                break;
            }
        }
        /// AUDIT FIX (P10-L-1): Emit event so off-chain indexers track participant list changes.
        emit ParticipantRemoved(marketId, subaccount);
    }

    /// AUDIT FIX (L3-L-2): Guard against type(int256).min overflow
    function _abs(int256 x) internal pure returns (uint256) {
        require(x != type(int256).min, "ADL: int256 min overflow");
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
